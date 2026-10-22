import Foundation
import Combine
import ServiceManagement

extension IntegrationTests {
    @MainActor static func mainActorOperationTests() async {
        // OFF must win even when an old assertion creation completes later.
        do {
            let f = ModelFixture(); defer { f.clean() }
            var started = false
            var services = f.services()
            services.setSystemAwake = { on in
                if on { started = true; try? await Task.sleep(for: .milliseconds(120)) }
                f.systemAssertions.append(on)
                return true
            }
            let m = AppModel(services: services); await m.waitForPendingOperations()
            var states: [Bool] = []
            let token = m.$systemAwakeApplied.sink { states.append($0) }
            m.keepAwake = true
            for _ in 0..<50 where !started { try? await Task.sleep(for: .milliseconds(2)) }
            m.keepAwake = false
            await m.waitForPendingOperations()
            expect(f.systemAssertions.suffix(2) == [true, false], "late assertion creation is followed by newest OFF")
            expect(!states.contains(true) && !m.systemAwakeApplied,
                   "superseded assertion result cannot confirm the new intent")
            token.cancel(); m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
        // A stale successful ON is still a physical fact if the subsequent OFF
        // fails. Do not present the desired OFF as a confirmed release.
        do {
            let f = ModelFixture(); defer { f.clean() }
            var began = false, rejectOff = false
            var services = f.services()
            services.setSystemAwake = { on in
                if on { began = true; try? await Task.sleep(for: .milliseconds(100)) }
                if !on && rejectOff { return false }
                f.systemAssertions.append(on)
                return true
            }
            let m = AppModel(services: services); await m.waitForPendingOperations()
            m.keepAwake = true
            for _ in 0..<50 where !began { try? await Task.sleep(for: .milliseconds(2)) }
            rejectOff = true; m.keepAwake = false
            await m.waitForPendingOperations()
            expect(!m.keepAwake && m.systemAwakeApplied && m.awakeFeedbackError != nil,
                   "failed newest OFF retains actual ON from a superseded successful creation")
            rejectOff = false; m.keepAwake = false
            await m.waitForPendingOperations()
            expect(!m.systemAwakeApplied && m.awakeFeedbackError == nil, "release retry confirms OFF after late ON")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
        // Exercise the actual ServiceManagement worker with a slow synchronous
        // boundary, without registering anything with the operating system.
        do {
            let fake = LoginWorkerState()
            let worker = LoginItemWorker(readStatus: { fake.status }, update: { fake.set($0) })
            let f = ModelFixture(); defer { f.clean() }
            var services = f.services()
            services.loginStatus = { await worker.status() }
            services.setLogin = { try await worker.setEnabled($0) }
            let m = AppModel(services: services); await m.waitForPendingOperations()
            let start = ContinuousClock.now
            m.setLaunchAtLogin(true)
            try? await Task.sleep(for: .milliseconds(20))
            expect(ContinuousClock.now - start < .milliseconds(100) && m.loginBusy && !m.launchAtLogin,
                   "slow login registration keeps UI responsive without premature success")
            m.setLaunchAtLogin(false)
            await m.waitForPendingOperations()
            expect(!m.launchAtLogin && !m.loginBusy && fake.writes == [true, false],
                   "login changes stay ordered and read back the final state")
            expect(!fake.usedMainThread, "login registration and readback execute outside main thread")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
    }
}

private final class LoginWorkerState: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var recordedWrites: [Bool] = []
    private var mainThread = false
    var status: SMAppService.Status {
        lock.lock(); defer { lock.unlock() }
        mainThread = mainThread || Thread.isMainThread
        return enabled ? .enabled : .notRegistered
    }
    var writes: [Bool] { lock.lock(); defer { lock.unlock() }; return recordedWrites }
    var usedMainThread: Bool { lock.lock(); defer { lock.unlock() }; return mainThread }
    func set(_ on: Bool) {
        Thread.sleep(forTimeInterval: 0.15)
        lock.lock(); defer { lock.unlock() }
        mainThread = mainThread || Thread.isMainThread
        enabled = on; recordedWrites.append(on)
    }
}
