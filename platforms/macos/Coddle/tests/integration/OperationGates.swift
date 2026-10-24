import Foundation

/// Hold a real synchronous worker boundary until the main actor has checked
/// its pending state. Wall-clock delays cannot guarantee that overlap on CI.
final class BlockingTestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var began = false
    private var opened = false
    private var expired = false

    var entered: Bool { condition.lock(); defer { condition.unlock() }; return began }
    var timedOut: Bool { condition.lock(); defer { condition.unlock() }; return expired }

    func hold() {
        condition.lock()
        began = true
        let deadline = Date(timeIntervalSinceNow: 5)
        while !opened {
            if !condition.wait(until: deadline) { expired = true; break }
        }
        condition.unlock()
    }

    func open() {
        condition.lock(); opened = true; condition.broadcast(); condition.unlock()
    }

    @MainActor func waitForEntry() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !entered && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return entered && !timedOut
    }
}

/// Keep an asynchronous fixture operation pending while newer UI intent is
/// queued. Opening also admits later reads, so coalescing remains observable.
@MainActor final class AsyncTestGate {
    private var began = false
    private var opened = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        began = true
        guard !opened else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        opened = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }

    func waitForEntry() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !began && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return began
    }
}
