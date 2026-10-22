import Foundation

private final class StopOwnershipReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let helper: FixtureHelper
    private var reads = 0
    init(_ helper: FixtureHelper) { self.helper = helper }
    func read() -> Bool? {
        lock.lock(); reads += 1; lock.unlock()
        return helper.sleepDisabled
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
}

extension IntegrationTests {
    @MainActor static func masterStopOwnershipTests() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coddle-stop-ownership-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }

        for external in [true, nil] as [Bool?] {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true
            f.helper.sleepDisabled = external
            let store = OnboardingStore(directory: root.appendingPathComponent(external == nil ? "unknown" : "external-on"))
            try! ConfigStore.save(f.config, at: store.configURL)
            var services = f.services()
            let probe = StopOwnershipReadProbe(f.helper)
            services.helper.readSleepDisabled = { probe.read() }
            let m = AppModel(services: services, onboardingStore: store)
            await m.waitForPendingOperations()
            m.setKeepAwakeEnabled(false); await m.waitForPendingOperations()
            expect(m.taskStopStatus == "onboarding.stopped" && !store.bootstrap().record.stopPending,
                   "ordinary master OFF completes without owning another app's global lid state")
            expect(probe.count == 0 && f.helper.writes.isEmpty && f.helper.sleepDisabled == external,
                   "ordinary stop neither reads nor changes unowned global lid state")
            m.setKeepAwakeEnabled(true); await m.waitForPendingOperations()
            expect(m.keepAwake && m.systemAwakeApplied,
                   "unowned external lid state cannot lock out the next ordinary session")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true
            f.helper.sleepDisabled = true
            let store = OnboardingStore(directory: root.appendingPathComponent("interrupted-ordinary"))
            try! ConfigStore.save(f.config, at: store.configURL)
            var services = f.services()
            var holdOff = false
            var resumeOff: CheckedContinuation<Void, Never>?
            services.setSystemAwake = { on in
                if holdOff && !on {
                    holdOff = false
                    await withCheckedContinuation { resumeOff = $0 }
                }
                f.systemAssertions.append(on)
                return true
            }
            let m = AppModel(services: services, onboardingStore: store)
            await m.waitForPendingOperations()
            holdOff = true
            m.setKeepAwakeEnabled(false)
            for _ in 0..<500 where resumeOff == nil { try? await Task.sleep(for: .milliseconds(2)) }
            expect(resumeOff != nil, "ordinary OFF is held before verification completes")
            await m.onboarding?.waitForPersistence()
            let pending = store.bootstrap().record
            expect(pending.stopPending && pending.stopLidRequired == false,
                   "ordinary OFF persists the absence of lid cleanup responsibility before completion")
            m.shutdownKeepAwake()
            resumeOff?.resume(); resumeOff = nil
            await m.waitForPendingOperations()
            expect(store.bootstrap().record.stopPending, "interrupted stop leaves its recovery journal")
            let restarted = AppModel(services: services, onboardingStore: store)
            await restarted.waitForPendingOperations()
            expect(restarted.taskStopStatus == "onboarding.stopped" && !store.bootstrap().record.stopPending &&
                   f.helper.sleepDisabled == true && f.helper.writes.isEmpty,
                   "actual ordinary stop journal recovers without touching another owner's flag")
            restarted.shutdownKeepAwake(); await restarted.waitForPendingOperations()
        }

        // The optional journal field distinguishes ordinary interrupted stops
        // from lid cleanup. Missing fields in older journals remain conservative.
        for required in [false, true, nil] as [Bool?] {
            for external in [true, nil] as [Bool?] {
                let f = ModelFixture(); defer { f.clean() }
                f.config.keepDisplayAwake = true; f.config.keepAwakeOnLidClosed = true
                f.helper.sleepDisabled = external
                let name = "restart-\(String(describing: required))-\(String(describing: external))"
                let store = OnboardingStore(directory: root.appendingPathComponent(name))
                try! ConfigStore.save(f.config, at: store.configURL)
                var record = store.bootstrap().record
                record.stopPending = true
                record.stopLidRequired = required
                let encoded = try! JSONEncoder().encode(record)
                let decoded = try! JSONDecoder().decode(OnboardingRecord.self, from: encoded)
                expect(decoded.stopLidRequired == required, "optional stop ownership round-trips")
                if required == nil {
                    let object = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
                    expect(object["stopLidRequired"] == nil, "older journal without ownership field remains readable")
                }
                try! store.save(decoded)
                let probe = StopOwnershipReadProbe(f.helper)
                var services = f.services()
                services.helper.readSleepDisabled = { probe.read() }
                let m = AppModel(services: services, onboardingStore: store)
                await m.waitForPendingOperations()
                expect(!m.keepAwake && m.keepDisplayAwake && m.keepAwakeOnLidClosed &&
                       !m.systemAwakeApplied && !m.displayAwakeApplied,
                       "interrupted stop preserves saved preferences without activating them")
                if required == false {
                    expect(m.taskStopStatus == "onboarding.stopped" && !store.bootstrap().record.stopPending,
                           "ordinary interrupted stop completes without claiming external lid state")
                    expect(probe.count == 0 && f.helper.writes.isEmpty && f.helper.sleepDisabled == external,
                           "ordinary stop recovery leaves external true or unknown untouched")
                    m.setKeepAwakeEnabled(true); await m.waitForPendingOperations()
                    expect(m.keepAwake && m.systemAwakeApplied, "ordinary restart recovery permits a new session")
                } else {
                    let pending = store.bootstrap().record
                    expect(m.taskStopStatus == "onboarding.stopPartial" && pending.stopPending && pending.stopLidRequired == true,
                           "owned or legacy interrupted lid stop retains durable cleanup responsibility")
                    expect(probe.count > 0 && m.lidStateUnconfirmed,
                           "owned recovery still requires actual lid readback")
                    m.setKeepAwakeEnabled(true); await m.waitForPendingOperations()
                    expect(!m.keepAwake, "unresolved owned cleanup continues to block a new session")
                    f.helper.installed = true
                    m.setKeepAwakeEnabled(false); await m.waitForPendingOperations()
                    let confirmed = store.bootstrap().record
                    expect(m.taskStopStatus == "onboarding.stopped" && !confirmed.stopPending && confirmed.stopLidRequired == nil,
                           "verified owned OFF clears both recovery fields")
                }
                m.shutdownKeepAwake(); await m.waitForPendingOperations()
            }
        }

        for orphanLid in [false, true] {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepDisplayAwake = true
            f.config.keepAwakeOnLidClosed = orphanLid
            f.helper.sleepDisabled = true
            let store = OnboardingStore(directory: root.appendingPathComponent(orphanLid ? "orphan-lid" : "orphan-display"))
            try! ConfigStore.save(f.config, at: store.configURL)
            let probe = StopOwnershipReadProbe(f.helper)
            var services = f.services()
            services.helper.readSleepDisabled = { probe.read() }
            let m = AppModel(services: services, onboardingStore: store)
            await m.waitForPendingOperations()
            expect(!m.keepAwake && m.keepDisplayAwake && m.keepAwakeOnLidClosed == orphanLid &&
                   !m.systemAwakeApplied && !m.displayAwakeApplied && !m.lidAwakeApplied,
                   "saved inactive preferences never enable the master or any control")
            m.setKeepAwakeEnabled(false); await m.waitForPendingOperations()
            expect(m.taskStopStatus == "onboarding.stopped" && !store.bootstrap().record.stopPending && probe.count == 0,
                   "inactive display or lid preferences never acquire global lid responsibility")
            expect(f.helper.writes.isEmpty && f.helper.sleepDisabled == true && m.keepAwakeOnLidClosed == orphanLid,
                   "stopping inactive preferences preserves them and leaves another owner unchanged")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        for required in [false, true, nil] as [Bool?] {
            let f = ModelFixture(); defer { f.clean() }
            f.helper.sleepDisabled = true
            let store = OnboardingStore(directory: root.appendingPathComponent("storage-retry-\(String(describing: required))"))
            try! ConfigStore.save(f.config, at: store.configURL)
            var record = store.bootstrap().record
            record.stopPending = true
            record.stopLidRequired = required
            try! Data("temporarily unreadable journal".utf8).write(to: store.url)
            let probe = StopOwnershipReadProbe(f.helper)
            var services = f.services()
            services.helper.readSleepDisabled = { probe.read() }
            let m = AppModel(services: services, onboardingStore: store)
            await m.waitForPendingOperations()
            expect(m.onboarding?.storageError != nil, "unreadable startup journal blocks normal setup")
            try! store.save(record)
            await m.onboarding?.retryStorage(); await m.waitForPendingOperations()
            let recovered = store.bootstrap().record
            if required == false {
                expect(m.taskStopStatus == "onboarding.stopped" && !recovered.stopPending && probe.count == 0,
                       "storage retry retains the absence of lid responsibility")
            } else {
                expect(m.taskStopStatus == "onboarding.stopPartial" && recovered.stopPending &&
                       recovered.stopLidRequired == true && probe.count > 0,
                       "storage retry cannot discard recovered owned or legacy lid responsibility")
                f.helper.installed = true
                m.setKeepAwakeEnabled(false); await m.waitForPendingOperations()
                expect(m.taskStopStatus == "onboarding.stopped" && !store.bootstrap().record.stopPending,
                       "recovered owned cleanup still completes only after verified OFF")
            }
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true
            f.helper.sleepDisabled = true
            let store = OnboardingStore(directory: root.appendingPathComponent("late-helper-discovery"))
            try! ConfigStore.save(f.config, at: store.configURL)
            var services = f.services()
            var holdRead = false
            var resumeRead: CheckedContinuation<Void, Never>?
            services.systemAssertionActive = {
                if holdRead {
                    holdRead = false
                    await withCheckedContinuation { resumeRead = $0 }
                }
                return f.systemAssertions.last ?? false
            }
            let m = AppModel(services: services, onboardingStore: store)
            await m.waitForPendingOperations()
            holdRead = true
            m.setKeepAwakeEnabled(false)
            for _ in 0..<500 where resumeRead == nil { try? await Task.sleep(for: .milliseconds(2)) }
            expect(resumeRead != nil, "ordinary stop waits at assertion readback")
            f.helper.installed = true
            f.helper.writeError = HelperError(message: "late helper OFF unconfirmed")
            m.refreshHelperInstalled(); await m.waitForHelperCleanup()
            expect(m.lidStateUnconfirmed, "late helper discovery establishes cleanup responsibility")
            resumeRead?.resume(); resumeRead = nil
            await m.waitForPendingOperations()
            let pending = store.bootstrap().record
            expect(m.taskStopStatus == "onboarding.stopPartial" && pending.stopPending && pending.stopLidRequired == true,
                   "late owned lid cleanup cannot be cleared by the earlier ordinary-only stop snapshot")
            f.helper.writeError = nil
            m.setKeepAwakeEnabled(false); await m.waitForPendingOperations()
            expect(m.taskStopStatus == "onboarding.stopped" && !store.bootstrap().record.stopPending,
                   "late discovered responsibility completes after a verified retry")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true
            let store = OnboardingStore(directory: root.appendingPathComponent("chosen-lid-no-helper"))
            try! ConfigStore.save(f.config, at: store.configURL)
            let m = AppModel(services: f.services(), onboardingStore: store)
            await m.waitForPendingOperations()
            m.keepAwakeOnLidClosed = true; await m.waitForPendingOperations()
            m.setKeepAwakeEnabled(false); await m.waitForPendingOperations()
            expect(m.taskStopStatus == "onboarding.stopPartial" && store.bootstrap().record.stopLidRequired == true,
                   "clearing an attempted lid intent retains its unconfirmed cleanup responsibility")
            f.helper.installed = true
            m.setKeepAwakeEnabled(false); await m.waitForPendingOperations()
            expect(m.taskStopStatus == "onboarding.stopped", "attempted lid cleanup completes after confirmed helper OFF")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
    }
}
