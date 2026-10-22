import AppKit
import Foundation

private final class SamplingFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var readCount = 0
    private var iconIDs: [pid_t] = []
    private var mainThreadRead = false
    let gate = DispatchSemaphore(value: 0)

    var reads: Int { lock.lock(); defer { lock.unlock() }; return readCount }
    var icons: [pid_t] { lock.lock(); defer { lock.unlock() }; return iconIDs }
    var touchedMain: Bool { lock.lock(); defer { lock.unlock() }; return mainThreadRead }

    func read() -> EnergyUsageSnapshot {
        lock.lock()
        readCount += 1
        let first = readCount == 1
        mainThreadRead = mainThreadRead || Thread.isMainThread
        lock.unlock()
        if first { gate.wait() }
        return EnergyUsageSnapshot(timestamp: 100, processes: (1...4).map {
            EnergyProcessUsage(id: pid_t($0), name: "Fixture \($0)", bundleIdentifier: "fixture.\($0)",
                startTime: UInt64($0), cpuTimeNs: UInt64($0) * 1_000_000_000,
                wakeups: 0, lifetimeSeconds: 10)
        })
    }
    func icon(_ pid: pid_t) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        iconIDs.append(pid)
        mainThreadRead = mainThreadRead || Thread.isMainThread
        return nil // Missing icons are cached too; no real application is queried.
    }
}

private actor EnergySampleGate {
    private var pending: CheckedContinuation<EnergySample, Never>?
    private(set) var requests = 0
    func read() async -> EnergySample {
        requests += 1
        return await withCheckedContinuation { pending = $0 }
    }
    func complete() {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: EnergySample(apps: [], statusKey: "energySample.ready"))
    }
}

private actor DwellLoadGate {
    private var pending: CheckedContinuation<[String: Double], Never>?
    private(set) var requests = 0
    func load() async -> [String: Double] {
        requests += 1
        return await withCheckedContinuation { pending = $0 }
    }
    func complete() {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: ["learned": 100])
    }
}

private actor NetworkSampleGate {
    private var pending: CheckedContinuation<NetworkFingerprint, Never>?
    private(set) var requests = 0
    func read(_ preferred: String?) async -> NetworkFingerprint {
        requests += 1
        return await withCheckedContinuation { pending = $0 }
    }
    func complete(_ key: String) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: NetworkFingerprint(key: key))
    }
}

private final class HardwareOrderFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var events: [String] { lock.lock(); defer { lock.unlock() }; return values }
    func record(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
}

extension IntegrationTests {
    @MainActor static func responsivenessTests() async {
        // The production sampler holds a deliberately blocked read off the UI
        // actor, then loads only the selected icons and reuses their nil cache.
        do {
            let fixture = SamplingFixture()
            let worker = EnergySamplingWorker(readUsage: { fixture.read() }, readIcon: { fixture.icon($0) })
            let sample = Task { await worker.sample(limit: 2) }
            for _ in 0..<100 where fixture.reads == 0 { await settle() }
            expect(fixture.reads == 1, "energy sampling starts on its worker")
            var heartbeat = false
            Task { @MainActor in heartbeat = true }
            await settle()
            expect(heartbeat && !fixture.touchedMain, "blocked process read leaves main actor responsive")
            fixture.gate.signal()
            let first = await sample.value
            expect(first.apps.map(\.id) == [4, 3] && fixture.icons == [4, 3],
                   "energy sampling loads icons only for selected top apps")
            _ = await worker.sample(limit: 2)
            expect(fixture.icons == [4, 3] && !fixture.touchedMain,
                   "repeated energy sampling reuses cached icons including unavailable icons")
        }
        do {
            let gate = EnergySampleGate()
            var clock = 10.0
            let monitor = EnergyAppMonitor(sample: { _ in await gate.read() }, now: { clock })
            let first = Task { await monitor.sampleTopApps() }
            let second = Task { await monitor.sampleTopApps() }
            for _ in 0..<100 {
                if await gate.requests == 1 { break }
                await settle()
            }
            await gate.complete()
            _ = await first.value
            _ = await second.value
            _ = await monitor.sampleTopApps()
            let coalescedRequests = await gate.requests
            expect(coalescedRequests == 1 && monitor.statusKey == "energySample.ready",
                   "concurrent energy requests coalesce and empty results are throttled")
            clock += 1.6
            let third = Task { await monitor.sampleTopApps() }
            for _ in 0..<100 {
                if await gate.requests == 2 { break }
                await settle()
            }
            await gate.complete()
            _ = await third.value
            let refreshedRequests = await gate.requests
            expect(refreshedRequests == 2, "empty energy results refresh after throttle expires")
        }
        do {
            let loadGate = DwellLoadGate()
            let networkGate = NetworkSampleGate()
            let notifications = NotificationCenter()
            var saves = 0
            let engine = AwayEngine(readFingerprint: { await networkGate.read($0) },
                loadDwell: { await loadGate.load() }, saveDwell: { _ in saves += 1 },
                notifications: notifications, scheduleTimers: false)
            engine.update(config: .init())
            for _ in 0..<100 {
                if await loadGate.requests == 1 { break }
                await settle()
            }
            var config = AwayEngine.Configuration()
            config.usualMinDwellSeconds = 50
            engine.update(config: config)
            notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
            expect(saves == 0, "sleep during initial dwell load never overwrites learning with an empty model")
            await loadGate.complete()
            await engine.waitForPendingSample()
            let sleepingReads = await networkGate.requests
            expect(sleepingReads == 0, "network sampling waits for dwell loading and respects intervening sleep")
            notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
            for _ in 0..<100 {
                if await networkGate.requests == 1 { break }
                await settle()
            }
            await networkGate.complete("learned")
            await engine.waitForPendingSample()
            let loadRequests = await loadGate.requests
            expect(loadRequests == 1 && engine.status.isUsual && saves == 1,
                   "loaded dwell survives configuration changes and is applied once under latest settings")
            engine.stop()
        }
        // A completed old network request must not update the detector, save
        // dwell or publish UI state under a new configuration or after stop.
        do {
            let gate = NetworkSampleGate()
            let notifications = NotificationCenter()
            var updates: [AwayStatus] = []
            var saves = 0
            let engine = AwayEngine(readFingerprint: { await gate.read($0) }, loadDwell: { [:] },
                saveDwell: { _ in saves += 1 }, notifications: notifications, scheduleTimers: false)
            engine.onUpdate = { updates.append($0) }
            engine.update(config: .init())
            for _ in 0..<100 {
                if await gate.requests == 1 { break }
                await settle()
            }
            var config = AwayEngine.Configuration()
            config.usualFingerprints = ["current"]
            engine.update(config: config)
            await gate.complete("stale")
            for _ in 0..<100 {
                if await gate.requests == 2 { break }
                await settle()
            }
            expect(updates.isEmpty && saves == 0 && engine.status.fingerprint == nil,
                   "network result from old configuration is discarded before detector or UI mutation")
            await gate.complete("current")
            await engine.waitForPendingSample()
            expect(engine.status.isUsual && engine.status.fingerprint == AwayDetector.shortHash("current") && saves == 1,
                   "latest configuration receives its own fresh network sample")
            engine.update(config: config)
            for _ in 0..<100 {
                if await gate.requests == 3 { break }
                await settle()
            }
            notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
            await gate.complete("asleep-stale")
            await engine.waitForPendingSample()
            expect(engine.status.fingerprint == AwayDetector.shortHash("current"),
                   "pre-sleep network read cannot publish while asleep")
            notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
            for _ in 0..<100 {
                if await gate.requests == 4 { break }
                await settle()
            }
            engine.stop()
            let previousSaves = saves
            await gate.complete("stopped-stale")
            await engine.waitForPendingSample()
            notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
            await settle()
            let stoppedRequests = await gate.requests
            expect(stoppedRequests == 4 && saves == previousSaves && engine.status.fingerprint == AwayDetector.shortHash("current"),
                   "stop rejects in-flight network results and wake cannot restart a stopped engine")
        }
        // Use the real engine and model together: a stale away verdict must
        // neither release newly restored keep-awake nor lift an active guard.
        do {
            let fixture = ModelFixture(); defer { fixture.clean() }
            fixture.config.keepAwake = true
            fixture.config.keepDisplayAwake = true
            fixture.config.awayAfterMinutes = 0
            fixture.config.usualFingerprints = ["usual"]
            let gate = NetworkSampleGate()
            let engine = AwayEngine(readFingerprint: { await gate.read($0) }, loadDwell: { [:] },
                saveDwell: { _ in }, notifications: fixture.workspace, scheduleTimers: false)
            var services = fixture.services()
            services.configureAway = {
                var config = $0
                // Collapse only the elapsed-away grace period in this fixture;
                // the production model and generation/pending policy remain intact.
                config.awayAfterMinutes = 0
                engine.update(config: config)
                return engine.status
            }
            services.subscribeAway = { engine.onUpdate = $0 }
            services.stopAway = { engine.stop() }
            let model = AppModel(services: services)
            await model.waitForPendingOperations()
            for _ in 0..<100 {
                if await gate.requests == 1 { break }
                await settle()
            }
            await gate.complete("away")
            await engine.waitForPendingSample(); await settle()
            await model.waitForPendingOperations()
            expect(model.bagGuardActive && fixture.systemAssertions.last == false,
                   "accepted away sample activates guard before re-enable regression")

            model.awayDetectionEnabled = false
            await model.waitForPendingOperations()
            expect(!model.bagGuardActive && fixture.systemAssertions.last == true,
                   "explicitly disabling away protection restores requested keep-awake")
            let systemBefore = fixture.systemAssertions.count
            let displayBefore = fixture.displayAssertions.count
            model.awayDetectionEnabled = true
            model.refresh()
            await model.waitForPendingOperations()
            for _ in 0..<100 {
                if await gate.requests == 2 { break }
                await settle()
            }
            expect(model.awayStatus.configurationSamplePending && !model.bagGuardActive &&
                   !fixture.systemAssertions.dropFirst(systemBefore).contains(false) &&
                   !fixture.displayAssertions.dropFirst(displayBefore).contains(false),
                   "re-enabling away detection never releases keep-awake using the old away verdict")
            await gate.complete("usual")
            await engine.waitForPendingSample(); await settle()
            await model.waitForPendingOperations()
            expect(!model.awayStatus.configurationSamplePending && !model.bagGuardActive &&
                   !fixture.systemAssertions.dropFirst(systemBefore).contains(false),
                   "fresh usual sample completes re-enable without a transient sleep opportunity")

            model.networkSampleSeconds += 5
            for _ in 0..<100 {
                if await gate.requests == 3 { break }
                await settle()
            }
            await gate.complete("away")
            await engine.waitForPendingSample(); await settle()
            await model.waitForPendingOperations()
            expect(model.bagGuardActive, "fresh away sample reactivates protection")
            let protectedSystemCount = fixture.systemAssertions.count
            let protectedDisplayCount = fixture.displayAssertions.count
            model.networkSampleSeconds += 5
            model.refresh()
            await model.waitForPendingOperations()
            for _ in 0..<100 {
                if await gate.requests == 4 { break }
                await settle()
            }
            expect(model.awayStatus.configurationSamplePending && model.bagGuardActive &&
                   !fixture.systemAssertions.dropFirst(protectedSystemCount).contains(true) &&
                   !fixture.displayAssertions.dropFirst(protectedDisplayCount).contains(true),
                   "configuration refresh preserves active bag protection while the new sample is pending")
            await gate.complete("away")
            await engine.waitForPendingSample(); await settle()
            await model.waitForPendingOperations()
            expect(!model.awayStatus.configurationSamplePending && model.bagGuardActive,
                   "unchanged away verdict still publishes completion and preserves protection")
            model.shutdownKeepAwake()
            await model.waitForPendingOperations()
        }
        do {
            let io = HardwareIO(label: "coddle.integration.immediate-completion")
            var allSucceeded = true
            // Each await is immediately followed by another admission, with no
            // sleep/yield masking a release-after-resume race.
            for value in 0..<500 {
                let result = await io.run { value }
                if case .success(let actual) = result { allSucceeded = allSucceeded && actual == value }
                else { allSucceeded = false }
            }
            expect(allSucceeded, "a completed hardware call always admits an immediate subsequent call")
        }
        do {
            let io = HardwareIO(label: "coddle.integration.completion-order")
            let order = HardwareOrderFixture()
            let operationGate = DispatchSemaphore(value: 0)
            let recoveryGate = DispatchSemaphore(value: 0)
            io.onRecovery {
                order.record("released")
                recoveryGate.wait()
            }
            let first = Task {
                let result = await io.run {
                    order.record("started")
                    operationGate.wait()
                    return 1
                }
                order.record("delivered")
                let next = await io.run { 2 }
                return (result, next)
            }
            for _ in 0..<100 where !order.events.contains("started") { await settle() }
            let busy = await io.run { 99 }
            if case .failure(let error) = busy {
                expect(error.message == "error.hardwarePending", "in-flight hardware work rejects overlapping admission")
            } else { expect(false, "overlapping operation must remain pending") }
            operationGate.signal()
            for _ in 0..<100 where !order.events.contains("released") { await settle() }
            expect(!order.events.contains("delivered"), "success is not delivered ahead of the admission release notification")
            recoveryGate.signal()
            let result = await first.value
            if case .success(1) = result.0, case .success(2) = result.1 {
                expect(true, "release then completion allows the waiting caller to immediately run again")
            } else { expect(false, "completion must not expose occupied admission") }
        }
        do {
            let io = HardwareIO(label: "coddle.integration.timeout-order")
            let order = HardwareOrderFixture()
            let operationGate = DispatchSemaphore(value: 0)
            io.onRecovery {
                order.record(Thread.isMainThread ? "recovery-on-main" : "recovery")
            }
            let timedOut = await io.run(timeout: 0.025) {
                order.record("started")
                operationGate.wait()
                order.record("operation-finished")
                return 1
            }
            if case .failure(let error) = timedOut {
                expect(error.message == "error.hardwareTimeout" && error.awaitingRecovery,
                       "timeout releases only caller while reporting pending recovery")
            } else { expect(false, "blocked hardware operation must time out") }
            expect(!order.events.contains("recovery"), "timeout never announces recovery before operation actually returns")
            let blocked = await io.run { order.record("overlap"); return 2 }
            if case .failure(let error) = blocked {
                expect(error.message == "error.hardwarePending" && !order.events.contains("overlap"),
                       "timed-out hardware operation keeps admission closed until actual return")
            } else { expect(false, "uncertain old operation must block subsequent writes") }
            operationGate.signal()
            for _ in 0..<100 where !order.events.contains("recovery") { await settle() }
            let events = order.events
            expect(events == ["started", "operation-finished", "recovery"],
                   "late hardware completion emits exactly one off-main recovery after returning")
            let retry = await io.run { 3 }
            if case .success(3) = retry {
                expect(true, "hardware recovery exposes free admission before retry")
            } else { expect(false, "post-recovery operation must be admitted") }
        }
    }
}
