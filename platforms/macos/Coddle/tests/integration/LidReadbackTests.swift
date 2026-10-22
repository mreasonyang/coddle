import Combine
import Foundation

/// Models acknowledgements and the separately observed global flag without
/// touching the real daemon, pmset, or the user's configuration.
private final class LidReadbackProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let helper: FixtureHelper
    private var acknowledgeOnly = false
    private var overrideEnabled = false
    private var overrideValue: Bool?
    private var readCount = 0
    private var requests: [Bool] = []
    private var nextReadGate: DispatchSemaphore?
    private var readBlocked = false

    init(_ helper: FixtureHelper) { self.helper = helper }

    func configure(acknowledgeOnly: Bool, overrideEnabled: Bool = false, value: Bool? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.acknowledgeOnly = acknowledgeOnly
        self.overrideEnabled = overrideEnabled
        overrideValue = value
    }

    func write(_ on: Bool) -> Result<Void, HelperError> {
        lock.lock()
        requests.append(on)
        let skipWrite = acknowledgeOnly
        lock.unlock()
        return skipWrite ? .success(()) : helper.write(on)
    }

    func read() -> Bool? {
        lock.lock()
        readCount += 1
        let value = overrideEnabled ? overrideValue : helper.sleepDisabled
        let gate = nextReadGate
        nextReadGate = nil
        if gate != nil { readBlocked = true }
        lock.unlock()
        gate?.wait()
        return value
    }

    func blockNextRead(_ gate: DispatchSemaphore) {
        lock.lock(); nextReadGate = gate; readBlocked = false; lock.unlock()
    }

    var counts: (reads: Int, writes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (readCount, requests.count)
    }

    var hasBlockedRead: Bool {
        lock.lock(); defer { lock.unlock() }
        return readBlocked
    }
}

extension IntegrationTests {
    @MainActor static func lidReadbackTests() async {
        for target in [true, false] {
            for actual: Bool? in [!target, nil] {
                let f = ModelFixture(); defer { f.clean() }
                f.config.keepAwake = true
                f.helper.installed = true
                let probe = LidReadbackProbe(f.helper)
                var services = f.services()
                services.helper.setDisablesleep = { probe.write($0) }
                services.helper.readSleepDisabled = { probe.read() }
                let m = AppModel(services: services); await m.waitForPendingOperations()
                if !target {
                    m.keepAwakeOnLidClosed = true
                    await m.waitForPendingOperations()
                    expect(m.lidAwakeApplied, "OFF scenario starts with confirmed ON")
                }
                probe.configure(acknowledgeOnly: true, overrideEnabled: true, value: actual)
                let reads = probe.counts.reads
                m.keepAwakeOnLidClosed = target
                await m.waitForPendingOperations()
                expect(probe.counts.reads > reads, "ordinary lid action reads after RPC")
                expect(m.lidAwakeApplied == (actual == true), "lid activity uses actual readback, including failed OFF")
                expect(m.lidStateUnconfirmed, "mismatch and missing readback remain pending")
                expect(m.helperStatus == "helper.lidStateUnconfirmed", "acknowledgement alone never clears mismatch")
                probe.configure(acknowledgeOnly: false)
                m.refresh(); await m.waitForPendingOperations()
                expect(m.lidAwakeApplied == target && !m.lidStateUnconfirmed && m.helperStatus == nil,
                       "successful write and matching readback resolve pending state")
                m.shutdownKeepAwake(); await m.waitForPendingOperations()
            }
        }

        // A lease can acknowledge renewal without repeating its original ON
        // write. Refresh observes an independent global-state change read-only.
        for actual: Bool? in [false, nil] {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true
            f.helper.installed = true
            let probe = LidReadbackProbe(f.helper)
            var services = f.services()
            services.helper.setDisablesleep = { probe.write($0) }
            services.helper.readSleepDisabled = { probe.read() }
            let m = AppModel(services: services); await m.waitForPendingOperations()
            m.keepAwakeOnLidClosed = true; await m.waitForPendingOperations()
            expect(m.lidAwakeApplied && !m.lidStateUnconfirmed, "initial ON is confirmed")
            probe.configure(acknowledgeOnly: true, overrideEnabled: true, value: actual)
            let beforeRefresh = probe.counts
            m.refresh(); await m.waitForPendingOperations()
            expect(probe.counts.reads == beforeRefresh.reads + 1, "active refresh checks the global flag once")
            expect(probe.counts.writes == beforeRefresh.writes, "ordinary active refresh does not write or renew")
            expect(!m.lidAwakeApplied && m.lidStateUnconfirmed, "refresh removes a stale ON claim")
            let beforeRenewal = probe.counts
            m.refreshHelperInstalled(); await m.waitForPendingOperations()
            expect(probe.counts.writes == beforeRenewal.writes + 1 && probe.counts.reads == beforeRenewal.reads + 1,
                   "renewal acknowledgement also requires readback")
            expect(!m.lidAwakeApplied && m.helperStatus == "helper.lidStateUnconfirmed",
                   "lease acknowledgement cannot turn false or unknown into active")
            probe.configure(acknowledgeOnly: false)
            m.keepAwakeOnLidClosed = false; await m.waitForPendingOperations()
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true
            f.helper.sleepDisabled = true // An external owner, with no Coddle helper.
            let probe = LidReadbackProbe(f.helper)
            var services = f.services()
            services.helper.setDisablesleep = { probe.write($0) }
            services.helper.readSleepDisabled = { probe.read() }
            let m = AppModel(services: services); await m.waitForPendingOperations()
            m.refresh(); await m.waitForPendingOperations()
            expect(probe.counts.reads == 0 && probe.counts.writes == 0, "optional absent helper does not claim external global state")
            expect(!m.lidAwakeApplied && !m.lidStateUnconfirmed && m.helperStatus == nil,
                   "unrelated global flag does not become Coddle active or pending")
            f.helper.installed = true
            m.refresh(); await m.waitForPendingOperations()
            expect(f.helper.writes.last == false && probe.counts.reads > 0 && !m.lidAwakeApplied,
                   "quiet discovery retains startup OFF when the daemon appears")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true
            f.helper.installed = true
            let probe = LidReadbackProbe(f.helper)
            var services = f.services()
            services.helper.setDisablesleep = { probe.write($0) }
            services.helper.readSleepDisabled = { probe.read() }
            let m = AppModel(services: services); await m.waitForPendingOperations()
            let gate = DispatchSemaphore(value: 0)
            probe.blockNextRead(gate)
            m.keepAwakeOnLidClosed = true
            for _ in 0..<100 where !probe.hasBlockedRead { try? await Task.sleep(for: .milliseconds(2)) }
            expect(probe.hasBlockedRead, "old ON readback is held in flight")
            let beforeRefresh = probe.counts
            m.refresh()
            await settle()
            expect(probe.counts.writes == beforeRefresh.writes, "refresh does not supersede the in-flight action")
            m.keepAwakeOnLidClosed = false
            var lateStates: [Bool] = []
            let observation = m.$lidAwakeApplied.dropFirst().sink { lateStates.append($0) }
            gate.signal()
            await m.waitForPendingOperations()
            expect(!lateStates.contains(true), "old confirmed ON is never published after newer OFF")
            expect(!m.lidAwakeApplied && !m.lidStateUnconfirmed && f.helper.sleepDisabled == false,
                   "latest OFF wins after the old readback completes")
            observation.cancel()
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true
            f.helper.installed = true
            let m = AppModel(services: f.services()); await m.waitForPendingOperations()
            m.keepAwakeOnLidClosed = true; await m.waitForPendingOperations()
            f.helper.writeError = HelperError(message: "fixture OFF timeout")
            m.keepAwakeOnLidClosed = false; await m.waitForPendingOperations()
            expect(m.lidAwakeApplied && m.lidStateUnconfirmed, "failed OFF preserves observed active state and retry responsibility")
            expect(m.helperStatus == "fixture OFF timeout", "readback never hides the original RPC error")
            f.helper.sleepDisabled = false
            m.keepAwakeOnLidClosed = false; await m.waitForPendingOperations()
            expect(!m.lidAwakeApplied && m.lidStateUnconfirmed && m.helperStatus == "fixture OFF timeout",
                   "an OFF snapshot does not discharge an unacknowledged command's retry responsibility")
            f.helper.writeError = nil
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
            expect(!m.lidAwakeApplied && !m.lidStateUnconfirmed, "shutdown OFF is confirmed by readback")
        }

        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("coddle-lid-stop-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = OnboardingStore(directory: root)
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true
            f.helper.installed = true
            f.config.keepAwakeOnLidClosed = true
            try! ConfigStore.save(f.config, at: store.configURL)
            let m = AppModel(services: f.services(), onboardingStore: store)
            await m.waitForPendingOperations()
            expect(m.lidAwakeApplied, "durable stop scenario starts with confirmed lid ON")
            f.helper.sleepDisabled = false
            f.helper.writeError = HelperError(message: "fixture unacknowledged OFF")
            m.restoreSystemDefaults(); await m.waitForPendingOperations()
            expect(!m.lidAwakeApplied && m.lidStateUnconfirmed && m.helperStatus == "fixture unacknowledged OFF",
                   "OFF readback retains the unacknowledged request and its original error")
            expect(m.taskStopStatus == "onboarding.stopPartial" && m.taskStopLid == .unknown,
                   "unified stop cannot contradict pending lid feedback")
            expect(m.taskStopOrdinary == .confirmed && m.taskStopDisplay == .confirmed,
                   "uncertain lid completion does not hide confirmed ordinary and display OFF")
            expect(m.onboarding?.record.stopPending == true && store.bootstrap().record.stopPending,
                   "unacknowledged OFF retains in-memory and durable cleanup responsibility")
            f.helper.writeError = nil
            m.restoreSystemDefaults(); await m.waitForPendingOperations()
            expect(m.taskStopStatus == "onboarding.stopped" && m.taskStopLid == .confirmed,
                   "acknowledged OFF and matching readback complete the stop")
            expect(!m.lidStateUnconfirmed && m.helperStatus == nil && m.onboarding?.record.stopPending == false &&
                   !store.bootstrap().record.stopPending, "successful retry clears feedback and durable stop responsibility")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true
            f.helper.installed = true
            let m = AppModel(services: f.services()); await m.waitForPendingOperations()
            f.helper.sleepDisabled = true
            f.helper.writeError = HelperError(message: "fixture unacknowledged ON")
            let result = await m.applySetupAwake(.lid)
            await m.waitForPendingOperations()
            expect(result.0 == .confirmed && result.1 == .unknown,
                   "setup cannot confirm an unacknowledged lid lease from the global ON flag")
            expect(m.lidAwakeApplied && m.lidStateUnconfirmed && m.helperStatus == "fixture unacknowledged ON",
                   "setup retains the observed flag while exposing unconfirmed ownership")
            f.helper.writeError = nil
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
    }
}
