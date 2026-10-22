import Foundation

private final class FakeAssertions: KeepAwakeControlling {
    var system = false
    var display = false
    var operations: [String] = []
    var mainThreadAccess: [Bool] = []
    var beforeCreate: (() -> Void)?
    var afterRelease: (() -> Void)?

    var displayIsActive: Bool? { display }
    var systemIsActive: Bool? {
        mainThreadAccess.append(Thread.isMainThread)
        return system
    }
    func setSystemAwake(_ on: Bool) -> Bool {
        mainThreadAccess.append(Thread.isMainThread)
        if on { beforeCreate?() }
        system = on
        operations.append(on ? "system-on" : "system-off")
        return true
    }
    func setDisplayAwake(_ on: Bool) -> Bool {
        mainThreadAccess.append(Thread.isMainThread)
        display = on
        operations.append(on ? "display-on" : "display-off")
        return true
    }
    func release() -> Bool {
        mainThreadAccess.append(Thread.isMainThread)
        system = false; display = false
        operations.append("release")
        afterRelease?()
        return true
    }
}

@main private struct AssertionWorkerTests {
    @MainActor private static var checks = 0
    @MainActor private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), "assertion worker regression failed: \(message)")
    }

    @MainActor static func main() async {
        let fake = FakeAssertions()
        let started = DispatchSemaphore(value: 0)
        fake.beforeCreate = {
            started.signal()
            Thread.sleep(forTimeInterval: 0.15)
        }
        let worker = KeepAwakeWorker {
            precondition(!Thread.isMainThread, "assertion initialization must run off main")
            return fake
        }
        var createFinished = false
        let create = Task { @MainActor in
            let result = await worker.setSystemAwake(true)
            createFinished = true
            return result
        }
        let began = await waitForSignal(started)
        expect(began, "delayed create entered worker")
        create.cancel()
        var heartbeat = false
        let pulse = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(10))
            heartbeat = true
        }
        let release = Task { await worker.release() }
        try? await Task.sleep(for: .milliseconds(30))
        expect(heartbeat && !createFinished, "main actor heartbeat runs during delayed powerd call")
        _ = await pulse.value
        let created = await create.value
        let released = await release.value
        expect(created && released, "caller cancellation does not abandon an admitted create")
        expect(fake.operations == ["system-on", "release"], "release executes after late create")
        let active = await worker.systemIsActive()
        expect(active == false, "late create cannot reacquire after release")
        let display = await worker.setDisplayAwake(true)
        let finalRelease = await worker.release()
        expect(display && finalRelease && !fake.display, "display assertion shares serial lifecycle")
        expect(!fake.mainThreadAccess.contains(true), "assertion create, release and readback all run off main")

        let dropped = FakeAssertions()
        let deinitReleased = DispatchSemaphore(value: 0)
        dropped.afterRelease = { deinitReleased.signal() }
        var owner: KeepAwakeWorker? = KeepAwakeWorker { dropped }
        _ = await owner!.setSystemAwake(true)
        owner = nil
        let cleaned = await waitForSignal(deinitReleased)
        expect(cleaned && !dropped.system, "discarding worker still releases assertions")
        expect(!dropped.mainThreadAccess.contains(true), "worker deinit never releases on main thread")
        print("assertion-worker-tests: \(checks) checks passed (fake powerd calls; no hardware writes)")
    }

    private static func waitForSignal(_ signal: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: signal.wait(timeout: .now() + 2) == .success)
            }
        }
    }
}
