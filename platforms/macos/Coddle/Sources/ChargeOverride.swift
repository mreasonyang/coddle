import Foundation

/// What a non-root, sandboxless process can observe about macOS's periodic
/// "charge to 100% for calibration" override of the native charge limit.
///
/// Apple documents that the Mac "will occasionally charge to 100% to maintain
/// accurate battery state-of-charge estimates". While it does, the native limit
/// read (`PowerUI` get limit / enabled) keeps reporting the configured target,
/// so a naive panel says "holding at 80%" while the pack charges past it.
///
/// Two observables bear on this, and the detector ORs them:
///
/// 1. `darwinState > 0` is *positive evidence* of an override. `powerd` owns the
///    Darwin notification `com.apple.system.powersources.chargingtofulloverride`,
///    registers a check token for it, and sets its state before posting, so the
///    state is readable by any process through `notify_get_state`.
/// 2. A state of `0` is **not** evidence that no override is happening. A name
///    `powerd` never registered reads `0` too (verified: a probe of a bogus name
///    returns `NOTIFY_STATUS_OK` and `0`), so a genuine "no override" `0` and a
///    "this name does not exist" `0` are indistinguishable. The bounded pack
///    inference below must therefore run even after a `0` read.
///
/// The union keeps the panel honest if the notification is ever renamed or
/// dropped (the inference still fires) and — while the notification works — it
/// also covers the early phase of an override (pack still below the limit and
/// charging up) that the inference alone cannot see.
struct ChargeOverrideInputs: Equatable {
    /// State of `com.apple.system.powersources.chargingtofulloverride`, read via
    /// a check token. `nil` when the token could not be registered or read.
    var darwinState: UInt64?
    /// Native limit from PowerUI (`nil` when unsupported / unreadable).
    var limit: Int?
    var limitEnabled: Bool
    var externalConnected: Bool
    var isCharging: Bool
    var percent: Int?
}

/// The single-sample verdict for the override detector. `packOnly` is a
/// *candidate*: a working limit is still just a firmware target, and the gauge
/// can reach it with charging current still flowing, so a single sample is not
/// enough to report an override. `ChargeOverrideDebouncer` requires it to
/// persist. `darwin` is positive evidence and needs no corroboration.
enum ChargeOverrideEvidence: Equatable {
    case none
    /// The pack is on AC, actively charging *strictly above* an enforced limit,
    /// below 100% — the one state a functioning limit cannot hold. No positive
    /// Darwin state was read, so this is inference only.
    case packOnly
    /// `powerd`'s notification reported a non-zero state. Positive evidence.
    case darwin
}

/// Whether the OS is overriding the charge limit, and how that was established.
///
/// The two active cases carry different epistemic weight, and the panel must not
/// blur them (see `ControlPanel`):
/// - `.confirmed` comes from `powerd` itself, so the panel may state the cause
///   ("macOS is charging to 100% for calibration").
/// - `.inferred` is only the pack's own behaviour, so the panel may state the
///   observable fact ("charging past your limit") but must not assert why.
enum ChargeOverrideSignal: Equatable {
    case none
    case inferred
    case confirmed

    var isActive: Bool { self != .none }
}

/// Single-sample evidence. Pure; the persistence requirement lives in
/// `ChargeOverrideDebouncer`.
enum ChargeOverrideDetector {
    static func evidence(_ input: ChargeOverrideInputs) -> ChargeOverrideEvidence {
        // With no enforced limit there is nothing for the OS to override, and a
        // calibration message ("your N% limit resumes…") would be nonsense.
        guard input.limitEnabled else { return .none }

        // Positive evidence: powerd says an override is active. Trustworthy on
        // its own; AC-gating is handled by the display gate in AppModel.
        if let state = input.darwinState, state > 0 { return .darwin }

        // Bounded inference, run even after a `0` read (see `ChargeOverrideInputs`).
        // It fires only on the one pack state a *working* limit makes impossible:
        //
        //   on AC, actively charging, STRICTLY ABOVE the enforced limit, below 100%.
        //
        // Why `>` and not `>=` — the correction this round makes, contradicted by
        // measurement: the limit is a firmware target, so a normal charge ends
        // with a short tail where the gauge already reads the target while the
        // charging current is still tapering to zero. A 463-sample trace of a full
        // charge to an 80% limit recorded exactly one window of
        // `percent == 80 && isCharging` (~57 s, 17:44:53–17:45:52), and **no
        // sample ever exceeded 80**; afterwards the pack sat at 80% with
        // `isCharging == 0`. So `percent == limit` while charging is the ordinary
        // end of a normal charge, and the round-2 rule (`>=`) would have raised
        // the calibration banner on every charge. Only `percent > limit` while
        // charging is the state a holding limit does not produce.
        //
        // How long it can *legitimately* persist: on a normal charge, not at all
        // (0/463 samples above the limit; the tail sat exactly at the limit). The
        // condition is reachable only by (i) a genuine calibration override, which
        // lasts minutes to hours, or (ii) a limit *lowered* below a pack that is
        // currently charging — where the firmware stops charging (`isCharging`
        // -> 0) within seconds and then self-discharges. The debouncer's hold
        // rejects (ii); (i) is the signal we want.
        //
        // Bounds: `limit in 80..<100` mirrors PowerUI's hard floor (available
        // limits are 80/85/90/95/100) so we never reason about targets the
        // firmware cannot express. `percent < 100` excludes the one legitimately
        // reachable charging state at the very top.
        guard let limit = input.limit, (80..<100).contains(limit),
              input.externalConnected, input.isCharging,
              let percent = input.percent, percent > limit, percent < 100
        else { return .none }
        return .packOnly
    }
}

/// Turns single-sample evidence into a signal, requiring the pack-only candidate
/// to persist across consecutive refreshes. Pure, and injected with the clock,
/// so the whole rule is unit-testable without real hardware.
struct ChargeOverrideDebouncer {
    /// How long the `packOnly` condition must hold before it is reported.
    ///
    /// At the app's default `refreshSeconds` of 5 s this is two intervals, i.e.
    /// three consecutive positive samples: enough that a one- or two-second
    /// firmware overshoot (or a transient right after the limit changes) cannot
    /// flash a banner, while a genuine override — minutes to hours — pays a
    /// negligible delay. Worst-case detection latency is the hold window plus up
    /// to one refresh interval for the first positive sample to land, i.e.
    /// `requiredPackHold + refreshSeconds` (15 s at the default 5 s refresh).
    static let requiredPackHold: TimeInterval = 10

    /// When the current uninterrupted run of `packOnly` samples began, or nil
    /// when the last sample carried no pack evidence.
    private(set) var packHoldStartedAt: TimeInterval?

    /// Feed one sample. `now` is any monotonic clock, in seconds. `.confirmed`
    /// returns immediately (positive evidence) and clears the hold; `.packOnly`
    /// accumulates it; anything else resets it.
    mutating func update(_ input: ChargeOverrideInputs, at now: TimeInterval) -> ChargeOverrideSignal {
        switch ChargeOverrideDetector.evidence(input) {
        case .darwin:
            packHoldStartedAt = nil
            return .confirmed
        case .packOnly:
            let started = packHoldStartedAt ?? now
            packHoldStartedAt = started
            guard now - started >= Self.requiredPackHold else { return .none }
            return .inferred
        case .none:
            packHoldStartedAt = nil
            return .none
        }
    }
}
