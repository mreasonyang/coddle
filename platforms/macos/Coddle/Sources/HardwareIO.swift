import Foundation

struct HardwareFailure: Error, Sendable {
    let message: String
    var awaitingRecovery = false
}

struct HardwareSnapshot: Sendable {
    var battery: BatteryInfo
    var clamshellClosed: Bool?
    var clamshellCausesSleep: Bool?
    var supportsLimit: Bool
    var availableLimits: [Int]
    var currentLimit: Int?
    var limitEnabled: Bool
    var supportsTemporaryFullCharge: Bool
    var availableEnergyModes: [EnergyMode]
    var energyMode: EnergyMode?
}

/// Serial, bounded admission for blocking private APIs. A timeout releases the
/// caller, not the underlying operation: until that operation returns no second
/// operation is admitted, so uncertain late writes cannot overtake newer writes.
/// Use separate instances for charge I/O and helper lease traffic.
final class HardwareIO: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var occupied = false
    private var recoveryNeeded = false
    private var recoveryHandler: (@Sendable () -> Void)?

    init(label: String) { queue = DispatchQueue(label: label, qos: .utility) }

    private func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !occupied else { recoveryNeeded = true; return false }
        occupied = true
        return true
    }

    /// Only signalled after a timed-out operation actually finishes, or after
    /// a rejected operation can safely be retried. It never runs on the UI actor.
    func onRecovery(_ handler: @escaping @Sendable () -> Void) {
        lock.lock(); recoveryHandler = handler; lock.unlock()
    }

    private func release(afterTimeout: Bool) {
        lock.lock()
        occupied = false
        let handler = recoveryNeeded || afterTimeout ? recoveryHandler : nil
        recoveryNeeded = false
        lock.unlock()
        handler?()
    }

    func run<T: Sendable>(timeout: TimeInterval = 4,
                         _ operation: @escaping @Sendable () -> T) async -> Result<T, HardwareFailure> {
        guard acquire() else {
            return .failure(HardwareFailure(message: "error.hardwarePending", awaitingRecovery: true))
        }
        return await withCheckedContinuation { continuation in
            let completion = HardwareCompletion(continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                completion.take()?.resume(returning: .failure(HardwareFailure(message: "error.hardwareTimeout", awaitingRecovery: true)))
            }
            queue.async {
                let value = operation()
                // Claim completion before releasing admission so the timeout cannot
                // race a successful delivery. Release before resuming: the caller
                // may immediately submit another operation on a different thread.
                let pending = completion.take()
                self.release(afterTimeout: pending == nil)
                pending?.resume(returning: .success(value))
            }
        }
    }
}

private final class HardwareCompletion<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<T, HardwareFailure>, Never>?
    init(_ continuation: CheckedContinuation<Result<T, HardwareFailure>, Never>) {
        self.continuation = continuation
    }
    func take() -> CheckedContinuation<Result<T, HardwareFailure>, Never>? {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        return pending
    }
}
