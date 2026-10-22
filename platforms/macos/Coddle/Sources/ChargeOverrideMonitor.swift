import Foundation
import Dispatch
import notify

/// Reads and watches `powerd`'s "charging to full" override signal.
///
/// `powerd` registers a check token for
/// `com.apple.system.powersources.chargingtofulloverride` and sets its state
/// (0 = no override, non-zero = active) before posting it. Both registering the
/// check token and subscribing to the notification are available to an ordinary
/// non-root, sandboxless process, so this is the direct signal the panel reads.
///
/// Everything here is best-effort and side-effect free: it reads state and
/// subscribes, and never writes SMC or the limit. If registration or the read
/// fails the getter returns `nil`.
///
/// A caveat that defines the detector's shape: `notify_get_state` returns `0`
/// for a name that was never registered, so a returned `0` is **not** proof the
/// name exists. A missing or renamed notification is indistinguishable from a
/// genuine "no override". That is exactly why `ChargeOverrideDetector` ORs this
/// signal with the bounded pack inference instead of trusting a `0`.
final class ChargeOverrideMonitor {
    /// The name `powerd` carries on this platform. The test suite asserts this
    /// exact literal, so a change here fails loudly.
    static let productionNotificationName = "com.apple.system.powersources.chargingtofulloverride"

    /// The notification name this monitor reads. Injectable so the real read
    /// path can be exercised against a private name; defaults to production.
    let notificationName: String

    /// Fired on the main queue whenever the override state changes. Empty until
    /// `onChange` is assigned.
    var onChange: (() -> Void)?

    private var checkToken: Int32 = 0
    private var dispatchToken: Int32 = 0
    private var hasCheck = false
    private var hasDispatch = false

    init(notificationName: String = ChargeOverrideMonitor.productionNotificationName) {
        self.notificationName = notificationName
        hasCheck = notify_register_check(notificationName, &checkToken) == NOTIFY_STATUS_OK
        let handler: @Sendable (Int32) -> Void = { [weak self] _ in
            self?.onChange?()
        }
        hasDispatch = notify_register_dispatch(
            notificationName, &dispatchToken, DispatchQueue.main, handler) == NOTIFY_STATUS_OK
    }

    /// Current override state, or `nil` when the direct signal is unavailable.
    /// A `0` is a real reading *or* a name that was never registered; the two
    /// are not distinguishable here, which is why the detector also infers.
    func state() -> UInt64? {
        guard hasCheck else { return nil }
        var value: UInt64 = 0
        guard notify_get_state(checkToken, &value) == NOTIFY_STATUS_OK else { return nil }
        return value
    }

    deinit {
        if hasCheck { notify_cancel(checkToken) }
        if hasDispatch { notify_cancel(dispatchToken) }
    }
}
