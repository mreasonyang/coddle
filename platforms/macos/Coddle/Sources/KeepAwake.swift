import Foundation
import IOKit
import IOKit.pwr_mgt

/// User-space "keep awake" built on IOPM power assertions.
///
/// These assertions block *idle* sleep (system and/or display) and need no root.
/// They CANNOT block lid-close (clamshell) sleep — that case is handled by the
/// privileged helper's `disablesleep`. Assertions are bound to this process, so
/// the kernel releases them automatically if the app exits or crashes; we still
/// release them explicitly on toggle-off and on quit.
protocol KeepAwakeControlling: AnyObject {
    var systemIsActive: Bool? { get }
    var displayIsActive: Bool? { get }
    func setSystemAwake(_ on: Bool) -> Bool
    func setDisplayAwake(_ on: Bool) -> Bool
    func release() -> Bool
}

final class KeepAwakeController: KeepAwakeControlling {
    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0

    var systemIsActive: Bool? { isActive(systemAssertion) }
    var displayIsActive: Bool? { isActive(displayAssertion) }

    private func isActive(_ id: IOPMAssertionID) -> Bool? {
        guard id != 0 else { return false }
        guard let values = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any],
              let level = values[kIOPMAssertionLevelKey] as? NSNumber else { return nil }
        return level.intValue != 0
    }

    deinit {
        release()
    }

    /// Release any held assertions.
    @discardableResult
    func release() -> Bool {
        let system = setSystemAwake(false)
        let display = setDisplayAwake(false)
        return system && display
    }

    /// Create/release only the system-idle assertion. Returns false when the
    /// desired assertion could not be obtained.
    @discardableResult
    func setSystemAwake(_ on: Bool) -> Bool {
        if on {
            guard systemAssertion == 0 else { return true }
            var id: IOPMAssertionID = 0
            let rc = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Coddle Agent Mode" as CFString,
                &id)
            guard rc == kIOReturnSuccess else { return false }
            systemAssertion = id
            return true
        }
        guard systemAssertion != 0 else { return true }
        let ok = IOPMAssertionRelease(systemAssertion) == kIOReturnSuccess
        if ok { systemAssertion = 0 }
        return ok
    }

    /// Create/release only the display-idle assertion. This is the single owner
    /// for display-sleep: "keep the display awake" and "keep awake" both route
    /// through here so there is never more than one assertion.
    @discardableResult
    func setDisplayAwake(_ on: Bool) -> Bool {
        if on {
            guard displayAssertion == 0 else { return true }
            var id: IOPMAssertionID = 0
            let rc = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Coddle Agent Mode" as CFString,
                &id)
            guard rc == kIOReturnSuccess else { return false }
            displayAssertion = id
            return true
        }
        guard displayAssertion != 0 else { return true }
        let ok = IOPMAssertionRelease(displayAssertion) == kIOReturnSuccess
        if ok { displayAssertion = 0 }
        return ok
    }
}

/// Serial ownership keeps assertion IDs ordered while synchronous powerd calls
/// run off the UI actor. A release queued during a delayed create runs afterward.
final class KeepAwakeWorker: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let makeController: () -> any KeepAwakeControlling
        var controller: (any KeepAwakeControlling)?
        init(_ makeController: @escaping () -> any KeepAwakeControlling) {
            self.makeController = makeController
        }
    }

    private let queue = DispatchQueue(label: "com.coddle.assertions", qos: .utility)
    private let state: State

    init(makeController: @escaping () -> any KeepAwakeControlling = { KeepAwakeController() }) {
        state = State(makeController)
    }

    deinit {
        let state = state
        // Keep the last controller reference on its queue even when its owner
        // is discarded on MainActor; its deinit can also release assertions.
        queue.async {
            _ = state.controller?.release()
            state.controller = nil
        }
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable (any KeepAwakeControlling) -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                let controller = self.state.controller ?? self.state.makeController()
                self.state.controller = controller
                continuation.resume(returning: operation(controller))
            }
        }
    }

    func setSystemAwake(_ on: Bool) async -> Bool { await perform { $0.setSystemAwake(on) } }
    func setDisplayAwake(_ on: Bool) async -> Bool { await perform { $0.setDisplayAwake(on) } }
    @discardableResult
    func release() async -> Bool { await perform { $0.release() } }
    func displayIsActive() async -> Bool? { await perform { $0.displayIsActive } }
    func systemIsActive() async -> Bool? { await perform { $0.systemIsActive } }
}

/// Lid (clamshell) state read from `IOPMrootDomain` — no root required.
///
/// `closed` is true when the lid is shut. `causesSleep` is false when an
/// external display lets the Mac stay awake in clamshell mode (so toggling
/// `disablesleep` is unnecessary in that case).
func readClamshellState() -> (closed: Bool, causesSleep: Bool)? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }

    func boolProperty(_ key: CFString) -> Bool? {
        guard let val = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        if let b = val as? Bool { return b }
        if let n = val as? NSNumber { return n.boolValue }
        return nil
    }

    guard let closed = boolProperty("AppleClamshellState" as CFString) else {
        return nil
    }
    let causesSleep = boolProperty("AppleClamshellCausesSleep" as CFString) ?? true
    return (closed: closed, causesSleep: causesSleep)
}
