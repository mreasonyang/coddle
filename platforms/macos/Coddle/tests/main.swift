// Headless assertion-style test runner for the pure logic subset.
//
// Compiled by build.sh into build/coddle-tests; not part of the app. Any failed
// expectation prints a message and exits non-zero, so CI fails on a real
// regression.
//
// Coverage: SmartPolicy / CoddleConfig / BatteryInfo / battery property-bag
// parsing / chargeStatus / AwayDetector / bag guard / HelperManager / helper
// command dispatch / Localizer + i18n completeness
// decisions.
import Foundation
import notify

var checks = 0

/// Assert `condition`; on failure print the message and exit(1).
func expect(_ condition: Bool, _ message: String) {
    checks += 1
    guard condition else {
        print("FAIL: \(message)")
        exit(1)
    }
}

// MARK: - Helpers

/// A profile with `minSamples` AC observations in every hour bucket; the given
/// hours are then forced to `acCount` AC observations (e.g. 0 = never on AC).
func makeProfile(minSamples: Int, offACHours: [(hour: Int, acCount: Int)]) -> SmartPolicy.Profile {
    var p = SmartPolicy.Profile()
    for h in 0..<24 {
        for _ in 0..<minSamples { p.observe(hour: h, onAC: true) }
    }
    for (hour, acCount) in offACHours {
        p.ac[hour] = acCount
    }
    return p
}

/// A `BatteryInfo` with just the fields `chargeStatus` consults.
func battery(
    present: Bool = true,
    installed: Bool = true,
    charging: Bool = false,
    ac: Bool = false,
    full: Bool = false,
    percent: Int? = nil,
    reason: Int? = nil,
    amperage: Int? = nil
) -> BatteryInfo {
    var b = BatteryInfo()
    b.present = present
    b.installed = installed
    b.percent = percent
    b.isCharging = charging
    b.externalConnected = ac
    b.fullyCharged = full
    b.notChargingReason = reason
    b.amperage = amperage
    return b
}

/// Field-by-field equality for `CoddleConfig` (it is intentionally not Equatable).
func sameConfig(_ a: CoddleConfig, _ b: CoddleConfig) -> Bool {
    a.holdLimit == b.holdLimit
        && a.manualLimit == b.manualLimit
        && a.topupLimit == b.topupLimit
        && a.topupLeadHours == b.topupLeadHours
        && a.minSamplesPerHour == b.minSamplesPerHour
        && a.refreshSeconds == b.refreshSeconds
        && a.smartEnabled == b.smartEnabled
        && a.iconOnly == b.iconOnly
        && a.showInDock == b.showInDock
        && a.showMenuBarIcon == b.showMenuBarIcon
        && a.language == b.language
        && a.theme == b.theme
        && a.keepAwake == b.keepAwake
        && a.keepAwakeOnLidClosed == b.keepAwakeOnLidClosed
        && a.awayDetectionEnabled == b.awayDetectionEnabled
        && a.networkSampleSeconds == b.networkSampleSeconds
        && a.usualMinDwellSeconds == b.usualMinDwellSeconds
        && a.awayAfterMinutes == b.awayAfterMinutes
        && a.offlineAwayAfterMinutes == b.offlineAwayAfterMinutes
        && a.idleSeconds == b.idleSeconds
        && a.requireBattery == b.requireBattery
        && a.lowBatteryWarnPercent == b.lowBatteryWarnPercent
        && a.keepDisplayAwake == b.keepDisplayAwake
        && a.usualFingerprints == b.usualFingerprints
}

// MARK: - SmartPolicy.decide

// Insufficient history -> hold the default limit; never tops up.
do {
    let d = SmartPolicy().decide(hour: 10, profile: SmartPolicy.Profile())
    expect(d.target == 80, "empty profile holds default 80 (got \(d.target))")
    expect(d.target != 100, "empty profile must not top up")
}

// Single sample must not trigger a top-up (first-tick regression).
// Probe hour 9 — inside the {8,9} window a bogus single-sample prediction would
// open — so this actually fails if the min-samples guard regresses.
do {
    var p = SmartPolicy.Profile()
    p.observe(hour: 10, onAC: true)
    let d = SmartPolicy().decide(hour: 9, profile: p)
    expect(d.target == 80, "single sample must not top up at hour 9 (got \(d.target))")
    expect(d.target != 100, "single sample must not top up")
}

// Top-up window excludes the unplug hour itself (lead = 2).
do {
    let policy = SmartPolicy()
    let p = makeProfile(minSamples: 3, offACHours: [(10, 0)])
    expect(p.predictedUnplugHour(minSamples: 3) == 10, "hour 10 predicted as the unplug hour")
    expect(policy.decide(hour: 10, profile: p).target == 80,
           "unplug hour itself: no top-up (holds 80)")
    expect(policy.decide(hour: 9, profile: p).target == 100, "1h before unplug: top up to 100")
    expect(policy.decide(hour: 8, profile: p).target == 100, "2h before unplug: top up to 100")
    expect(policy.decide(hour: 7, profile: p).target == 80, "3h before unplug: no top-up")
}

// topupLeadHours == 0 never tops up.
do {
    var policy = SmartPolicy()
    policy.topupLeadHours = 0
    let p = makeProfile(minSamples: 3, offACHours: [(10, 0)])
    for h in 0..<24 {
        expect(policy.decide(hour: h, profile: p).target != 100, "lead=0 hour \(h) never tops up")
    }
}

// Out-of-range limits are normalized to 0...100.
do {
    var high = SmartPolicy()
    high.defaultLimit = 150
    expect(high.decide(hour: 0, profile: SmartPolicy.Profile()).target == 100,
           "defaultLimit>100 clamps to 100")

    var low = SmartPolicy()
    low.defaultLimit = -5
    expect(low.decide(hour: 0, profile: SmartPolicy.Profile()).target == 0,
           "defaultLimit<0 clamps to 0")

    let p = makeProfile(minSamples: 3, offACHours: [(10, 0)])
    var topHigh = SmartPolicy()
    topHigh.topupLimit = 250
    expect(topHigh.decide(hour: 9, profile: p).target == 100,
           "topupLimit>100 clamps to 100")

    var topLow = SmartPolicy()
    topLow.topupLimit = -10
    expect(topLow.decide(hour: 9, profile: p).target == 0,
           "topupLimit<0 clamps to 0")
}

// Hour argument normalization — assert a target INSIDE the {8,9} window so an
// unnormalized hour would fail (a plain decide(24)==decide(0) would not).
do {
    let policy = SmartPolicy()
    let p = makeProfile(minSamples: 3, offACHours: [(10, 0)])
    expect(policy.decide(hour: 33, profile: p).target == 100, "hour 33 wraps to 9 (top up)")
    expect(policy.decide(hour: -15, profile: p).target == 100, "hour -15 wraps to 9 (top up)")
    expect(policy.decide(hour: 32, profile: p).target == 100, "hour 32 wraps to 8 (top up)")
    expect(policy.decide(hour: -1, profile: p).target == 80, "hour -1 wraps to 23 (hold)")
}

// clamp interplay: hold and topup limits are independent and each clamped.
do {
    var policy = SmartPolicy()
    policy.defaultLimit = 90
    policy.topupLimit = 70
    let p = makeProfile(minSamples: 3, offACHours: [(10, 0)])
    expect(policy.decide(hour: 9, profile: p).target == 70, "clamp interplay: topup 70 used in window")
    expect(policy.decide(hour: 12, profile: p).target == 90, "clamp interplay: hold 90 outside window")

    var over = SmartPolicy()
    over.defaultLimit = 120   // clamps to 100
    over.topupLimit = 60
    expect(over.decide(hour: 3, profile: p).target == 100, "clamp interplay: over-range hold clamps to 100")
    expect(over.decide(hour: 9, profile: p).target == 60, "clamp interplay: in-range topup 60 kept")
}

// minSamplesPerHour boundary: exactly enough samples predicts, one fewer holds.
do {
    var p = SmartPolicy.Profile()
    for _ in 0..<3 { p.observe(hour: 5, onAC: true) }   // p == 1
    for _ in 0..<3 { p.observe(hour: 6, onAC: false) }  // p == 0
    var policy = SmartPolicy()
    policy.minSamplesPerHour = 3
    expect(p.predictedUnplugHour(minSamples: 3) == 6, "minSamples 3: hour 6 predicted")
    expect(policy.decide(hour: 5, profile: p).target == 100,
           "minSamples 3 (met): hour before predicted -> topup")
    policy.minSamplesPerHour = 4
    expect(p.predictedUnplugHour(minSamples: 4) == nil, "minSamples 4: no bucket qualifies")
    expect(policy.decide(hour: 5, profile: p).target == 80,
           "minSamples 4 (unmet): holds default")
}

// Top-up window wraps past midnight for an early predicted unplug hour.
do {
    let policy = SmartPolicy()
    let p = makeProfile(minSamples: 3, offACHours: [(0, 0)])
    expect(p.predictedUnplugHour(minSamples: 3) == 0, "hour 0 predicted as unplug")
    expect(policy.decide(hour: 23, profile: p).target == 100, "topup wraps to hour 23")
    expect(policy.decide(hour: 22, profile: p).target == 100, "topup wraps to hour 22")
    expect(policy.decide(hour: 21, profile: p).target == 80, "3h before wrap: hold")
}

// MARK: - SmartPolicy.Profile

// observe counts and wraps the hour.
do {
    var p = SmartPolicy.Profile()
    p.observe(hour: 3, onAC: true)
    p.observe(hour: 3, onAC: false)
    p.observe(hour: 27, onAC: true) // wraps to hour 3
    expect(p.total[3] == 3, "hour 3 total == 3 (got \(p.total[3]))")
    expect(p.ac[3] == 2, "hour 3 ac == 2 (got \(p.ac[3]))")
    p.observe(hour: -1, onAC: false) // wraps to hour 23
    expect(p.total[23] == 1, "hour -1 wraps to 23 (got \(p.total[23]))")
}

// probability is nil until observed, then the AC ratio.
do {
    var p = SmartPolicy.Profile()
    expect(p.probability(5) == nil, "probability is nil with no samples")
    p.observe(hour: 5, onAC: true)
    p.observe(hour: 5, onAC: false)
    p.observe(hour: 5, onAC: true)
    p.observe(hour: 5, onAC: true)
    expect(p.probability(5) == 0.75, "probability == 0.75")
    expect(p.probability(29) == 0.75, "probability normalizes hour 29 -> 5")
}

// probability with a mixed sample set.
do {
    var p = SmartPolicy.Profile()
    for _ in 0..<2 { p.observe(hour: 0, onAC: true) }
    for _ in 0..<3 { p.observe(hour: 0, onAC: false) }
    expect(p.probability(0) == 0.4, "probability 2/5 == 0.4")
    expect(p.total[0] == 5, "total counts every sample")
    expect(p.ac[0] == 2, "ac counts only the AC samples")
}

// predictedUnplugHour needs enough samples; ties break toward the lowest hour.
do {
    expect(SmartPolicy.Profile().predictedUnplugHour(minSamples: 1) == nil,
           "no samples -> no prediction")

    let tied = makeProfile(minSamples: 3, offACHours: [(5, 0), (7, 0)])
    expect(tied.predictedUnplugHour(minSamples: 3) == 5,
           "ties break toward the lowest hour (5)")
    expect(tied.predictedUnplugHour(minSamples: 4) == nil,
           "below the min-samples threshold -> nil")
}

// tie-break again with two equal lowest-probability buckets far apart.
do {
    var p = SmartPolicy.Profile()
    for _ in 0..<3 { p.observe(hour: 3, onAC: false) }
    for _ in 0..<3 { p.observe(hour: 20, onAC: false) }
    expect(p.predictedUnplugHour(minSamples: 3) == 3, "tie-break: lowest hour (3) wins")
}

// MARK: - BatteryInfo.healthPercent

do {
    var b = BatteryInfo()
    b.fullChargeCapacity = 5927
    b.designCapacity = 6249
    expect(b.healthPercent == 94.8, "health 5927/6249 == 94.8")

    var missing = BatteryInfo()
    missing.fullChargeCapacity = 5927
    expect(missing.healthPercent == nil, "health is nil when design capacity is missing")

    var zero = BatteryInfo()
    zero.fullChargeCapacity = 5927
    zero.designCapacity = 0
    expect(zero.healthPercent == nil, "health is nil when design capacity is 0")
}

// MARK: - BatteryInfo.chargeStatus (precedence matrix)

do {
    // Absent / not installed.
    expect(battery(present: false).chargeStatus(limit: nil, enabled: false) == .noBattery,
           "no battery: present == false -> noBattery")
    expect(battery(installed: false).chargeStatus(limit: 80, enabled: true) == .noBattery,
           "no battery: installed == false -> noBattery")

    // Charging wins over everything once present.
    expect(battery(charging: true, ac: false, percent: 42).chargeStatus(limit: 80, enabled: true) == .charging,
           "charging: isCharging beats the rest")

    // Plugged in: charged at full / 100%.
    expect(battery(ac: true, full: true).chargeStatus(limit: nil, enabled: false) == .charged,
           "charged: FullyCharged -> charged")
    expect(battery(ac: true, percent: 100).chargeStatus(limit: 80, enabled: true) == .charged,
           "charged: 100% beats holding")
    expect(battery(ac: true, percent: 100).chargeStatus(limit: 100, enabled: true) == .charged,
           "charged: 100% is charged not holding")

    // Plugged in: holding at the enforced limit.
    expect(battery(ac: true, percent: 80).chargeStatus(limit: 80, enabled: true) == .holding(limit: 80),
           "holding: at the limit -> holding(80)")
    expect(battery(ac: true, percent: 95).chargeStatus(limit: 80, enabled: true) == .holding(limit: 80),
           "holding: above the limit -> holding(80)")
    expect(battery(ac: true, percent: 50, reason: 0x0100_0000).chargeStatus(limit: 80, enabled: true) == .holding(limit: 80),
           "holding: NotChargingReason bit 24 -> holding")
    expect(battery(ac: true, percent: 50, reason: 0x0100_0000).chargeStatus(limit: 80, enabled: false) == .notCharging,
           "holding: NotChargingReason without an enforced limit -> notCharging")
    expect(battery(ac: true, percent: 50, reason: 0x00FF_FFFF).chargeStatus(limit: 80, enabled: true) == .notCharging,
           "holding: other NotChargingReason bits are not a hold")
    expect(battery(ac: true, percent: 80).chargeStatus(limit: 0, enabled: true) == .notCharging,
           "holding: limit 0 is not enforced")

    // Plugged in: generic not charging.
    expect(battery(ac: true, percent: 79).chargeStatus(limit: 80, enabled: true) == .notCharging,
           "notCharging: below the limit")
    expect(battery(ac: true, percent: 79).chargeStatus(limit: 80, enabled: false) == .notCharging,
           "notCharging: limit disabled")
    expect(battery(ac: true, percent: 79).chargeStatus(limit: nil, enabled: true) == .notCharging,
           "notCharging: nil limit")
    expect(battery(ac: true, percent: nil).chargeStatus(limit: 80, enabled: true) == .notCharging,
           "notCharging: no percent reading below limit")

    // Unplugged: discharging vs on battery.
    expect(battery(ac: false, amperage: -500).chargeStatus(limit: nil, enabled: false) == .discharging,
           "discharging: negative amperage")
    expect(battery(ac: false, amperage: 0).chargeStatus(limit: nil, enabled: false) == .onBattery,
           "onBattery: zero amperage")
    expect(battery(ac: false, amperage: 100).chargeStatus(limit: nil, enabled: false) == .onBattery,
           "onBattery: positive amperage")
    expect(battery(ac: false, amperage: nil).chargeStatus(limit: nil, enabled: false) == .onBattery,
           "onBattery: no amperage reading")
}

// MARK: - Charging-to-full override detector (pure)

// A positive Darwin state is positive evidence of an override. A zero state is
// NOT proof of absence — a missing or renamed notification reads 0 too — so the
// bounded pack inference always participates. The inference requires the pack to
// be STRICTLY above the limit (the tester's 463-sample trace never saw the gauge
// exceed the limit; the normal tail sits at exactly the limit) and it must
// persist across refreshes before it is reported, so a normal charge cannot
// raise the banner.
do {
    func input(_ state: UInt64?, limit: Int? = 80, enabled: Bool = true,
               ac: Bool = true, charging: Bool = true,
               percent: Int? = 90) -> ChargeOverrideInputs {
        ChargeOverrideInputs(darwinState: state, limit: limit, limitEnabled: enabled,
                             externalConnected: ac, isCharging: charging, percent: percent)
    }

    // --- Single-sample evidence -------------------------------------------------

    // Positive Darwin state is evidence on its own, even while not charging.
    expect(ChargeOverrideDetector.evidence(input(1, charging: false, percent: 80)) == .darwin,
           "override evidence: non-zero state is positive evidence, even while not charging")

    // Strictly above the limit while charging on AC is the pack-only candidate.
    expect(ChargeOverrideDetector.evidence(input(0, charging: true, percent: 85)) == .packOnly,
           "override evidence: zero state plus charging above the limit is a candidate")
    expect(ChargeOverrideDetector.evidence(input(nil, charging: true, percent: 85)) == .packOnly,
           "override evidence: unreadable state plus charging above the limit is a candidate")

    // THE FALSE ALARM (the tester's exact case): charging exactly at the limit is
    // the ordinary end of a charge, not an override. It must be `none` — the
    // round-2 `>=` rule made this the first override tick.
    expect(ChargeOverrideDetector.evidence(input(0, charging: true, percent: 80)) == .none,
           "override evidence: charging exactly at the limit is not evidence (tester's false alarm)")
    expect(ChargeOverrideDetector.evidence(input(nil, charging: true, percent: 80)) == .none,
           "override evidence: unreadable state at exactly the limit is not evidence")

    // The normal ~5% dead band: parked below the limit and topping up again.
    expect(ChargeOverrideDetector.evidence(input(nil, charging: true, percent: 77)) == .none,
           "override evidence: pack below the limit while charging is the normal dead band")
    expect(ChargeOverrideDetector.evidence(input(nil, charging: true, percent: 79)) == .none,
           "override evidence: one point below the limit is still the dead band")

    // Ineligible / ambiguous inputs produce no evidence.
    expect(ChargeOverrideDetector.evidence(input(0, charging: false, percent: 90)) == .none,
           "override evidence: zero state and no charging is inactive")
    expect(ChargeOverrideDetector.evidence(input(nil, charging: false, percent: 90)) == .none,
           "override evidence: above the limit but not charging -> inactive")
    expect(ChargeOverrideDetector.evidence(input(nil, ac: false, charging: true, percent: 90)) == .none,
           "override evidence: on battery -> inference inactive")
    expect(ChargeOverrideDetector.evidence(input(nil, enabled: false, charging: true, percent: 90)) == .none,
           "override evidence: disabled limit cannot be overridden")
    expect(ChargeOverrideDetector.evidence(input(nil, limit: 100, charging: true, percent: 100)) == .none,
           "override evidence: a 100% limit is not an override")
    expect(ChargeOverrideDetector.evidence(input(nil, limit: nil, charging: true, percent: 90)) == .none,
           "override evidence: missing limit reading -> inactive")
    expect(ChargeOverrideDetector.evidence(input(nil, charging: true, percent: nil)) == .none,
           "override evidence: missing percent -> inactive")
    expect(ChargeOverrideDetector.evidence(input(nil, charging: true, percent: 100)) == .none,
           "override evidence: at 100% the calibration is done -> inactive")
    // A limit below PowerUI's floor cannot be enforced, so it never infers.
    expect(ChargeOverrideDetector.evidence(input(nil, limit: 60, charging: true, percent: 90)) == .none,
           "override evidence: a below-floor limit never infers")

    // Even a positive Darwin state respects an unenforced limit: with no limit
    // set there is nothing to override.
    expect(ChargeOverrideDetector.evidence(input(1, enabled: false, charging: true, percent: 90)) == .none,
           "override evidence: positive state with no enforced limit stays inactive")

    // --- Debounce ---------------------------------------------------------------

    let hold = ChargeOverrideDebouncer.requiredPackHold
    expect(hold > 0, "override debounce: the hold window is positive")

    // (a) The tester's false alarm, sustained: `percent == limit` while charging
    // for 40 samples (200 s at the default 5 s cadence, far longer than the ~57 s
    // window they recorded). It must never become active, however long it holds.
    do {
        var debouncer = ChargeOverrideDebouncer()
        var becameActive = false
        for i in 0..<40 {
            let now = 1_000.0 + Double(i) * 5
            if debouncer.update(input(0, charging: true, percent: 80), at: now) != .none {
                becameActive = true
            }
        }
        expect(!becameActive,
               "override debounce: percent == limit while charging never activates, sustained 200 s")
    }

    // (b) True positive: `percent > limit` while charging on AC with state 0.
    // Inactive until the hold elapses, then inferred, and it stays inferred.
    do {
        var debouncer = ChargeOverrideDebouncer()
        expect(debouncer.update(input(0, charging: true, percent: 81), at: 0) == .none,
               "override debounce: one above-limit sample is not enough")
        expect(debouncer.update(input(0, charging: true, percent: 82), at: hold / 2) == .none,
               "override debounce: half the hold window is not enough")
        expect(debouncer.update(input(0, charging: true, percent: 83), at: hold) == .inferred,
               "override debounce: the hold window activates the inference")
        expect(debouncer.update(input(0, charging: true, percent: 90), at: hold + 5) == .inferred,
               "override debounce: the inference stays active while the condition holds")
    }

    // A one-and-a-half-second firmware overshoot never reaches a second positive
    // sample, let alone the hold window.
    do {
        var debouncer = ChargeOverrideDebouncer()
        expect(debouncer.update(input(0, charging: true, percent: 81), at: 0) == .none,
               "override debounce: overshoot first sample")
        expect(debouncer.update(input(0, charging: true, percent: 80), at: 1.5) == .none,
               "override debounce: a 1.5 s overshoot never activates")
    }

    // (c) The hold resets when the condition breaks mid-window.
    do {
        var debouncer = ChargeOverrideDebouncer()
        _ = debouncer.update(input(0, charging: true, percent: 81), at: 0)
        _ = debouncer.update(input(0, charging: true, percent: 82), at: hold / 2)
        // Condition breaks: back to exactly the limit.
        expect(debouncer.update(input(0, charging: true, percent: 80), at: hold / 2 + 1) == .none,
               "reset: the broken condition is inactive")
        // The window restarts from scratch — the original onset time no longer counts.
        expect(debouncer.update(input(0, charging: true, percent: 83), at: hold) == .none,
               "reset: a new sample does not inherit the broken window")
        expect(debouncer.update(input(0, charging: true, percent: 84), at: hold + hold / 2) == .none,
               "reset: the new window still needs the full hold")
        expect(debouncer.update(input(0, charging: true, percent: 85), at: hold + hold) == .inferred,
               "reset: the new window activates after a full hold")
    }

    // Darwin evidence bypasses the hold and clears any accumulated window.
    do {
        var debouncer = ChargeOverrideDebouncer()
        expect(debouncer.update(input(0, charging: true, percent: 81), at: 0) == .none,
               "darwin: accumulate a pack window")
        expect(debouncer.update(input(1, charging: false, percent: 80), at: 1) == .confirmed,
               "darwin: a positive state is confirmed immediately, regardless of the pack")
        expect(debouncer.update(input(0, charging: true, percent: 82), at: 2) == .none,
               "darwin: clearing the state also clears the pack window")
    }
}

// MARK: - Charge-override monitor (real Darwin notify round trip)

// The integration and render fixtures substitute a value for
// `chargeOverrideState`, so without this the actual `notify_*` plumbing could
// regress and CI would still pass. A private name keeps the production
// notification untouched, and the production name is pinned so a change fails
// loudly.
do {
    expect(ChargeOverrideMonitor.productionNotificationName
            == "com.apple.system.powersources.chargingtofulloverride",
           "override monitor: production name is powerd's charging-to-full literal")

    let name = "com.example.coddle.test.chargeoverride.\(UUID().uuidString)"
    var setToken: Int32 = 0
    expect(notify_register_check(name, &setToken) == NOTIFY_STATUS_OK,
           "override monitor: test can register a check token for a private name")
    let monitor = ChargeOverrideMonitor(notificationName: name)
    expect(monitor.notificationName == name,
           "override monitor: the injected name is retained (not silently the production one)")

    // A name that was never registered reads `0` — the reason a `0` cannot be
    // treated as proof of absence (this is the tester's falsified assumption).
    expect(monitor.state() == 0,
           "override monitor: never-set private name reads 0 through the monitor")

    expect(notify_set_state(setToken, 0) == NOTIFY_STATUS_OK,
           "override monitor: test can set the private name's state to 0")
    expect(monitor.state() == 0, "override monitor: state 0 reads back through the monitor")

    expect(notify_set_state(setToken, 1) == NOTIFY_STATUS_OK,
           "override monitor: test can set a non-zero state")
    expect(monitor.state() == 1, "override monitor: non-zero state reads back through the monitor")

    expect(notify_set_state(setToken, 7) == NOTIFY_STATUS_OK,
           "override monitor: test can set an arbitrary non-zero state")
    expect(monitor.state() == 7, "override monitor: arbitrary non-zero state reads back")

    notify_cancel(setToken)
}

// MARK: - Battery property-bag parsing (parseSmartBattery(_ dict:))

// A full bag with nested BatteryData / ChargerData exactly as IOKit hands them
// over (`NSNumber` values). This is the shape `readBattery()` consumes.
do {
    let bag: [String: Any] = [
        "Amperage": NSNumber(value: -1234),
        "BatteryInstalled": NSNumber(value: true),
        "CurrentCapacity": NSNumber(value: 5123),
        "CycleCount": NSNumber(value: 312),
        "ExternalConnected": NSNumber(value: true),
        "FullyCharged": NSNumber(value: false),
        "IsCharging": NSNumber(value: false),
        "MaxCapacity": NSNumber(value: 5927),
        "BatteryData": [
            "BatterySerialNumber": "C0123456789",
            "DesignCapacity": NSNumber(value: 6249),
            "FullChargeCapacity": NSNumber(value: 5927),
        ],
        "ChargerData": [
            "NotChargingReason": NSNumber(value: 16777216),
            "ChargingCurrent": NSNumber(value: 0),
        ],
    ]
    let b = parseSmartBattery(bag)
    expect(b.present, "battery: present with keys")
    expect(b.installed, "battery: installed")
    expect(b.amperage == -1234, "battery: negative amperage")
    expect(b.cycleCount == 312, "battery: cycle count")
    expect(b.externalConnected == true, "battery: ExternalConnected true")
    expect(b.isCharging == false, "battery: IsCharging false")
    expect(b.fullyCharged == false, "battery: FullyCharged false")
    expect(b.designCapacity == 6249, "battery: nested BatteryData.DesignCapacity")
    expect(b.fullChargeCapacity == 5927, "battery: nested BatteryData.FullChargeCapacity")
    expect(b.notChargingReason == 16777216, "battery: nested ChargerData.NotChargingReason")
    expect(b.percent == 86, "battery: percent 5123/5927 rounds to 86")
    expect(b.healthPercent == 94.8, "battery: health 5927/6249 == 94.8")
    expect(b.chargeStatus(limit: 80, enabled: true) == .holding(limit: 80),
           "battery: the parsed bag reports holding at 80")
}

// Natively bridged `Int` / `Bool` values (as fixture literals supply them), plus
// a discharging pack. The accessors must tolerate both representations.
do {
    let bag: [String: Any] = [
        "BatteryInstalled": true,
        "ExternalConnected": false,
        "Amperage": -500,
        "CurrentCapacity": 40,
        "MaxCapacity": 80,
    ]
    let b = parseSmartBattery(bag)
    expect(b.installed == true, "battery: bridged installed Bool")
    expect(b.externalConnected == false, "battery: bridged ExternalConnected false")
    expect(b.amperage == -500, "battery: bridged amperage")
    expect(b.percent == 50, "battery: percent 40/80 == 50")
    expect(b.chargeStatus(limit: nil, enabled: false) == .discharging,
           "battery: unplugged + negative amperage -> discharging")
    expect(b.designCapacity == nil && b.fullChargeCapacity == nil,
           "battery: missing BatteryData -> nil capacities")
    expect(b.healthPercent == nil, "battery: health nil without capacities")
}

// Nested BatteryData + BatteryInstalled false.
do {
    let bag: [String: Any] = [
        "BatteryInstalled": false,
        "ExternalConnected": true,
        "BatteryData": ["DesignCapacity": 5000, "FullChargeCapacity": 4500],
    ]
    let b = parseSmartBattery(bag)
    expect(b.installed == false, "battery: BatteryInstalled false")
    expect(b.healthPercent == 90.0, "battery: nested BatteryData health 90")
    expect(b.chargeStatus(limit: nil, enabled: false) == .noBattery,
           "battery: not installed -> noBattery")
}

// Degenerate inputs.
do {
    let empty = parseSmartBattery([:])
    expect(!empty.present, "battery: empty bag -> not present")
    expect(empty.percent == nil && empty.cycleCount == nil && empty.designCapacity == nil,
           "battery: empty bag -> nil fields")
    expect(empty.installed, "battery: installed defaults to true")

    let zeroMax = parseSmartBattery(["CurrentCapacity": 5, "MaxCapacity": 0])
    expect(zeroMax.percent == nil, "battery: MaxCapacity 0 -> nil percent")
}

// Percent rounding, not truncation: 2/3 must round to 67 (floor would give 66).
do {
    let b = parseSmartBattery(["CurrentCapacity": 2, "MaxCapacity": 3])
    expect(b.percent == 67, "battery: 2/3 rounds to 67 (floor would be 66)")
}

// MARK: - Battery pack child service (parseSmartBattery(_:pack:))

// The real macOS 27 / M4 Pro shape: the useful keys live in the pack's nested
// `BatteryData`, while `AppleSmartBattery` carries the macOS percentages.
do {
    let apple: [String: Any] = [
        "CurrentCapacity": NSNumber(value: 78),
        "MaxCapacity": NSNumber(value: 100),
        "BatteryInstalled": NSNumber(value: true),
        "ExternalConnected": NSNumber(value: true),
        "BatteryData": ["DesignCapacity": NSNumber(value: 6249),
                        "FullChargeCapacity": NSNumber(value: 5882)],
    ]
    let pack: [String: Any] = [
        "BankCount": NSNumber(value: 3),
        "BatteryData": [
            "Temperature": NSNumber(value: 3429),
            "VirtualTemperature": NSNumber(value: 3429),
            "AppleRawCurrentCapacity": NSNumber(value: 4324),
            "AppleRawMaxCapacity": NSNumber(value: 5882),
            "StateOfCharge": NSNumber(value: 74),
        ],
    ]
    let b = parseSmartBattery(apple, pack: pack)
    expect(b.hardwarePercent == 73.5, "pack: raw 4324/5882 == 73.5% (one decimal)")
    expect(b.temperatureCelsius.map { abs($0 - 34.29) < 0.0001 } == true,
           "pack: 3429 centi-°C -> 34.29 °C")
    expect(b.percent == 78, "pack: the macOS percent is unchanged by pack fields")
    expect(b.healthPercent == 94.1, "pack: health still from AppleSmartBattery 5882/6249")
    // 78 >= 75 while the hardware 73.5 < 75: holding here proves the decision
    // still uses the macOS percent, not the hardware one.
    expect(b.chargeStatus(limit: 75, enabled: true) == .holding(limit: 75),
           "pack: chargeStatus still keys off the macOS percent")
}

// Top-level pack keys (the shape ioreg prints after flattening) must parse too.
do {
    let pack: [String: Any] = [
        "Temperature": 3429,
        "AppleRawCurrentCapacity": 4324,
        "AppleRawMaxCapacity": 5882,
    ]
    let b = parseSmartBattery(["CurrentCapacity": 78, "MaxCapacity": 100], pack: pack)
    expect(b.hardwarePercent == 73.5, "pack: top-level raw capacities parse")
    expect(b.temperatureCelsius.map { abs($0 - 34.29) < 0.0001 } == true,
           "pack: top-level Temperature parses")
}

// Temperature falls back to VirtualTemperature when Temperature is missing/zero.
do {
    let missing = parseSmartBattery([:], pack: ["BatteryData": ["VirtualTemperature": 3000]])
    expect(missing.temperatureCelsius == 30.0, "pack: VirtualTemperature fallback")
    let zero = parseSmartBattery([:], pack: ["BatteryData": ["Temperature": 0, "VirtualTemperature": 3000]])
    expect(zero.temperatureCelsius == 30.0, "pack: Temperature 0 falls back to VirtualTemperature")
}

// Only exactly 0 is the "unavailable" sentinel. A cold-soaked pack legitimately
// reads below zero; that is a real reading, not "unavailable".
do {
    let cold = parseSmartBattery([:], pack: ["BatteryData": ["Temperature": -500]])
    expect(cold.temperatureCelsius == -5.0, "pack: -500 centi-°C -> -5.0 °C (a cold pack is valid)")
    let coldFallback = parseSmartBattery([:], pack: ["BatteryData": [
        "Temperature": 0, "VirtualTemperature": -500,
    ]])
    expect(coldFallback.temperatureCelsius == -5.0,
           "pack: Temperature 0 / VirtualTemperature -500 -> -5.0 °C")
}

// Hardware percent falls back to RemainingCapacity / FullChargeCapacity.
do {
    let pack: [String: Any] = ["BatteryData": ["RemainingCapacity": 4410, "FullChargeCapacity": 5882]]
    let b = parseSmartBattery([:], pack: pack)
    expect(b.hardwarePercent == 75.0, "pack: RemainingCapacity/FullChargeCapacity fallback == 75.0%")
}

// Absent pack / missing / malformed keys must be nil, never 0.
do {
    let noPack = parseSmartBattery(["CurrentCapacity": 78, "MaxCapacity": 100])
    expect(noPack.hardwarePercent == nil, "pack: no pack -> nil hardware percent (not 0)")
    expect(noPack.temperatureCelsius == nil, "pack: no pack -> nil temperature (not 0)")

    let emptyPack = parseSmartBattery([:], pack: [:])
    expect(emptyPack.hardwarePercent == nil, "pack: empty pack -> nil hardware percent")
    expect(emptyPack.temperatureCelsius == nil, "pack: empty pack -> nil temperature")

    let zeroTemp = parseSmartBattery([:], pack: ["BatteryData": ["Temperature": 0]])
    expect(zeroTemp.temperatureCelsius == nil, "pack: Temperature 0 -> nil (never 0.0 °C)")

    let noRaw = parseSmartBattery([:], pack: ["BatteryData": ["Temperature": 3400, "AppleRawMaxCapacity": 0]])
    expect(noRaw.hardwarePercent == nil, "pack: raw max 0 with no fallback -> nil percent")

    let negativeRaw = parseSmartBattery([:], pack: ["BatteryData": [
        "AppleRawCurrentCapacity": -5, "AppleRawMaxCapacity": 5882,
    ]])
    expect(negativeRaw.hardwarePercent == nil, "pack: non-positive raw capacity -> nil percent")

    let malformed = parseSmartBattery([:], pack: ["BatteryData": [
        "Temperature": "hot", "AppleRawCurrentCapacity": "x", "AppleRawMaxCapacity": 5882,
    ]])
    expect(malformed.temperatureCelsius == nil, "pack: non-numeric Temperature -> nil")
    expect(malformed.hardwarePercent == nil, "pack: non-numeric raw capacity -> nil")

    let implausibleTemp = parseSmartBattery([:], pack: ["BatteryData": ["Temperature": 65000]])
    expect(implausibleTemp.temperatureCelsius == nil, "pack: implausible temperature -> nil")
}

// Hardware percent clamps to 0...100 like the macOS percent does.
do {
    let over = parseSmartBattery([:], pack: ["BatteryData": [
        "AppleRawCurrentCapacity": 6000, "AppleRawMaxCapacity": 5882,
    ]])
    expect(over.hardwarePercent == 100.0, "pack: over-full raw ratio clamps to 100%")
}

// 0xFFFF (65535) is the gauge's "unknown" sentinel — the same one this driver
// uses for e.g. AvgTimeToEmpty. Either half of either pair at the sentinel must
// yield nil, never a fabricated rate (no 6.6% from a 0xFFFF max).
do {
    let maxSentinel = parseSmartBattery([:], pack: ["BatteryData": [
        "AppleRawCurrentCapacity": 4323, "AppleRawMaxCapacity": 65535]])
    expect(maxSentinel.hardwarePercent == nil, "pack: raw max 0xFFFF -> nil (never a fake 6.6%)")
    let curSentinel = parseSmartBattery([:], pack: ["BatteryData": [
        "AppleRawCurrentCapacity": 65535, "AppleRawMaxCapacity": 5882]])
    expect(curSentinel.hardwarePercent == nil, "pack: raw current 0xFFFF -> nil (never a fake 100.0%)")
    let fbSentinel = parseSmartBattery([:], pack: ["BatteryData": [
        "RemainingCapacity": 4410, "FullChargeCapacity": 65535]])
    expect(fbSentinel.hardwarePercent == nil, "pack: fallback full 0xFFFF -> nil")
}

// MARK: - Power Flow telemetry (parseSmartBattery(_:pack:))

// Real AC telemetry shape: SystemPowerIn, SystemLoad, BatteryPower == 0, AdapterDetails.
do {
    let bag: [String: Any] = [
        "ExternalConnected": true,
        "Voltage": 12431,
        "Amperage": 0,
        "PowerTelemetryData": [
            "SystemPowerIn": 23710,
            "SystemLoad": 23710,
            "BatteryPower": 0,
        ],
        "AdapterDetails": [
            "Watts": 90,
        ],
    ]
    let b = parseSmartBattery(bag)
    expect(b.powerFlow != nil, "power flow: telemetry parsed")
    expect(b.powerFlow?.adapterWatts == 90, "power flow: 90W adapter parsed from AdapterDetails")
    expect(b.powerFlow?.systemPowerInWatts == 23.7, "power flow: 23710 mW -> 23.7 W system power in")
    expect(b.powerFlow?.systemLoadWatts == 23.7, "power flow: 23710 mW -> 23.7 W system load")
    expect(b.powerFlow?.batteryPowerWatts == 0.0, "power flow: 0 mA amperage -> 0.0 W battery flow (bypassed)")
}

// Battery power calculation from Voltage & Amperage: charging (+24.5 W)
do {
    let bag: [String: Any] = [
        "ExternalConnected": true,
        "Voltage": 12431,
        "Amperage": 1970, // 12431 * 1970 / 1_000_000 = 24.489 W -> 24.5 W
        "PowerTelemetryData": [
            "SystemPowerIn": 45000,
            "SystemLoad": 20500,
        ],
        "AppleRawAdapterDetails": [
            ["Watts": 70],
        ],
    ]
    let b = parseSmartBattery(bag)
    expect(b.powerFlow?.batteryPowerWatts == 24.5, "power flow: +24.5 W charging battery flow")
    expect(b.powerFlow?.adapterWatts == 70, "power flow: 70W from AppleRawAdapterDetails array")
    expect(b.powerFlow?.systemPowerInWatts == 45.0, "power flow: 45.0 W input")
    expect(b.powerFlow?.systemLoadWatts == 20.5, "power flow: 20.5 W system load")
}

// Battery power calculation: discharging on AC (drain under heavy load, e.g. -15.2 W)
do {
    let bag: [String: Any] = [
        "ExternalConnected": true,
        "Voltage": 12000,
        "Amperage": -1267, // 12000 * -1267 / 1_000_000 = -15.204 W -> -15.2 W
        "PowerTelemetryData": [
            "SystemPowerIn": 30000,
            "SystemLoad": 45200,
        ],
    ]
    let b = parseSmartBattery(bag)
    expect(b.powerFlow?.batteryPowerWatts == -15.2, "power flow: -15.2 W discharging battery flow")
    expect(b.powerFlow?.systemPowerInWatts == 30.0, "power flow: 30.0 W input")
    expect(b.powerFlow?.systemLoadWatts == 45.2, "power flow: 45.2 W system load")
}

// Idle threshold / deadband: small trickle currents (|raw| < 0.05 W) are treated as 0.0 W (bypassed).
do {
    let posTrickle = parseSmartBattery(["Voltage": 12000, "Amperage": 2, "ExternalConnected": true])
    expect(posTrickle.powerFlow?.batteryPowerWatts == 0.0, "power flow: +0.024 W rounds to 0.0 W bypassed")

    let negTrickle = parseSmartBattery(["Voltage": 12000, "Amperage": -2, "ExternalConnected": true])
    expect(negTrickle.powerFlow?.batteryPowerWatts == 0.0, "power flow: -0.024 W rounds to 0.0 W bypassed")
}

// Discharging on battery (no AC): input is 0.0 W, system load derived from battery discharge if telemetry absent.
do {
    let bag: [String: Any] = [
        "ExternalConnected": false,
        "Voltage": 12000,
        "Amperage": -1267,
    ]
    let b = parseSmartBattery(bag)
    expect(b.powerFlow?.systemPowerInWatts == 0.0, "power flow: unplugged -> 0.0 W input")
    expect(b.powerFlow?.batteryPowerWatts == -15.2, "power flow: -15.2 W battery flow")
    expect(b.powerFlow?.systemLoadWatts == 15.2, "power flow: system load derived from battery discharge")
    expect(b.powerFlow?.adapterWatts == nil, "power flow: no adapter when unplugged")
}

// Fallback to BatteryPower when Voltage or Amperage is unavailable.
do {
    let bag: [String: Any] = [
        "ExternalConnected": true,
        "PowerTelemetryData": [
            "SystemPowerIn": 50000,
            "SystemLoad": 25000,
            "BatteryPower": 25000,
        ],
    ]
    let b = parseSmartBattery(bag)
    expect(b.powerFlow?.batteryPowerWatts == 25.0, "power flow: fallback to BatteryPower mW -> 25.0 W")
    expect(b.powerFlow?.systemLoadWatts == 25.0, "power flow: 25.0 W load")
}

// Top-level fallback keys and AppleRawAdapterDetails dictionary shape.
do {
    let bag: [String: Any] = [
        "SystemPowerIn": 40000,
        "SystemLoad": 40000,
        "AdapterWatts": 96,
        "BatteryPower": 0,
        "ExternalConnected": true,
    ]
    let b = parseSmartBattery(bag)
    expect(b.powerFlow?.adapterWatts == 96, "power flow: top-level AdapterWatts parsed")
    expect(b.powerFlow?.systemPowerInWatts == 40.0, "power flow: top-level SystemPowerIn parsed")
    expect(b.powerFlow?.systemLoadWatts == 40.0, "power flow: top-level SystemLoad parsed")
    expect(b.powerFlow?.batteryPowerWatts == 0.0, "power flow: top-level BatteryPower parsed")

    let rawDictBag: [String: Any] = [
        "AppleRawAdapterDetails": ["Watts": 140],
    ]
    let b2 = parseSmartBattery(rawDictBag)
    expect(b2.powerFlow?.adapterWatts == 140, "power flow: AppleRawAdapterDetails dict parsed")
}

// Sentinel rejection: negative power in, 0xFFFF (65535), and out-of-band values.
do {
    let sentinels: [String: Any] = [
        "PowerTelemetryData": [
            "SystemPowerIn": -500,
            "SystemLoad": 65535,
            "BatteryPower": 65535,
        ],
        "AdapterDetails": [
            "Watts": 65535,
        ],
        "Voltage": 65535,
        "Amperage": 65535,
    ]
    let b = parseSmartBattery(sentinels)
    expect(b.powerFlow == nil, "power flow: sentinels rejected -> nil powerFlow")

    let badWatts = parseSmartBattery(["AdapterDetails": ["Watts": -1]])
    expect(badWatts.powerFlow == nil, "power flow: negative adapter watts rejected")

    let crazyWatts = parseSmartBattery(["AdapterDetails": ["Watts": 1000]])
    expect(crazyWatts.powerFlow == nil, "power flow: >500W adapter rejected")

    let badSystemIn = parseSmartBattery(["PowerTelemetryData": ["SystemPowerIn": 65535]])
    expect(badSystemIn.powerFlow == nil, "power flow: 0xFFFF SystemPowerIn rejected")
}

// Missing telemetry: empty bag or bag with unrelated keys must yield nil powerFlow.
do {
    let empty = parseSmartBattery([:])
    expect(empty.powerFlow == nil, "power flow: empty bag -> nil powerFlow")

    let unrelated = parseSmartBattery(["BatteryInstalled": true, "CycleCount": 10])
    expect(unrelated.powerFlow == nil, "power flow: unrelated keys -> nil powerFlow")
}

// Conservation of energy: AC drain load calculation when SystemLoad key is omitted (30W in - (-15W bat) = 45.0W load).
do {
    let bag: [String: Any] = [
        "ExternalConnected": true,
        "PowerTelemetryData": [
            "SystemPowerIn": 30000,
            "BatteryPower": -15000,
        ],
    ]
    let b = parseSmartBattery(bag)
    expect(b.powerFlow?.systemPowerInWatts == 30.0, "power flow: 30W system power in")
    expect(b.powerFlow?.batteryPowerWatts == -15.0, "power flow: -15W battery assist/drain")
    expect(b.powerFlow?.systemLoadWatts == 45.0, "power flow: AC drain load derived as 30 - (-15) = 45.0W")
}

// Fallback to AppleRawAdapterDetails when AdapterDetails exists without Watts or has Watts: 0.
do {
    let bagWithoutWatts: [String: Any] = [
        "ExternalConnected": true,
        "AdapterDetails": ["FamilyCode": 0x1234, "Description": "dock"],
        "AppleRawAdapterDetails": [["Watts": 85]],
    ]
    let b1 = parseSmartBattery(bagWithoutWatts)
    expect(b1.powerFlow?.adapterWatts == 85, "power flow: fallback to AppleRawAdapterDetails when AdapterDetails lacks Watts")

    let bagZeroWatts: [String: Any] = [
        "ExternalConnected": true,
        "AdapterDetails": ["Watts": 0],
        "AppleRawAdapterDetails": [["Watts": 90]],
    ]
    let b2 = parseSmartBattery(bagZeroWatts)
    expect(b2.powerFlow?.adapterWatts == 90, "power flow: fallback to AppleRawAdapterDetails when AdapterDetails has Watts: 0")
}

// Multi-adapter resolution picking a 96W charger when index 0 has Watts: 0.
do {
    let bagMulti: [String: Any] = [
        "ExternalConnected": true,
        "BestAdapterIndex": 0,
        "AppleRawAdapterDetails": [
            ["Watts": 0, "Description": "passive_hub"],
            ["Watts": 96, "Description": "usb_c_power_adapter"],
        ],
    ]
    let b = parseSmartBattery(bagMulti)
    expect(b.powerFlow?.adapterWatts == 96, "power flow: multi-adapter picks 96W charger when index 0 has Watts: 0")
}

// Idle unplugged state reporting 0.0 W without power.bypassed.
do {
    let bundle = Bundle(url: appDir().appendingPathComponent("Resources")) ?? .main
    let loc = Localizer(language: "en", resourceBundle: bundle)
    let bypassedTag = loc.tr("power.bypassed")
    expect(bypassedTag == "Bypassed", "localizer: power.bypassed is Bypassed")

    // Direct presentation logic verification
    let unpluggedText = PowerFlowPresentation.batteryFlowText(watts: 0.0, externalConnected: false, tr: loc.tr)
    expect(unpluggedText == "0.0 W", "power flow: idle unplugged reports '0.0 W'")
    expect(!unpluggedText.contains(bypassedTag), "power flow: idle unplugged does not contain 'power.bypassed'")

    let pluggedText = PowerFlowPresentation.batteryFlowText(watts: 0.0, externalConnected: true, tr: loc.tr)
    expect(pluggedText == "0.0 W (Bypassed)", "power flow: idle plugged reports '0.0 W (Bypassed)'")
    expect(pluggedText.contains(bypassedTag), "power flow: idle plugged contains 'power.bypassed'")

    // Icon gating verification
    expect(PowerFlowPresentation.batteryFlowIcon(watts: 0.0, externalConnected: false) == "battery.100",
           "power flow: idle unplugged icon is battery.100")
    expect(PowerFlowPresentation.batteryFlowIcon(watts: 0.0, externalConnected: true) == "powerplug.fill",
           "power flow: idle plugged icon is powerplug.fill")

    // End-to-end parsed unplugged idle battery
    let bagUnpluggedIdle: [String: Any] = [
        "ExternalConnected": false,
        "Voltage": 12000,
        "Amperage": 2, // trickle < 0.05W -> 0.0 W
    ]
    let b = parseSmartBattery(bagUnpluggedIdle)
    expect(b.externalConnected == false, "battery: unplugged")
    expect(b.powerFlow?.batteryPowerWatts == 0.0, "power flow: 0.0 W battery power")
    let rendered = PowerFlowPresentation.batteryFlowText(watts: b.powerFlow?.batteryPowerWatts, externalConnected: b.externalConnected, tr: loc.tr)
    expect(rendered == "0.0 W", "power flow: end-to-end idle unplugged reports '0.0 W' without bypassed tag")
    expect(!rendered.contains(bypassedTag), "power flow: end-to-end idle unplugged does not contain bypassed tag")
}

// MARK: - AwayDetector

let t0 = Date(timeIntervalSince1970: 1_700_000_000)

// No model at all (no learned dwell, no manual allowlist) -> never away.
do {
    var d = AwayDetector()
    let v = d.sample(key: "mac:x", now: t0)
    expect(v.isAway == false, "away: no model -> not away")
    expect(v.isUsual == false, "away: no model -> not usual")
    let off = d.sample(key: nil, now: t0.addingTimeInterval(3600))
    expect(off.isAway == false, "away: no model + long offline -> not away")
}

// usualKeys: dwell >= threshold, plus the manual allowlist.
do {
    let usual = AwayDetector.usualKeys(dwell: ["a": 100, "b": 10], minDwellSeconds: 50, manual: ["c"])
    expect(usual == ["a", "c"], "away: usualKeys = dwell>=min plus manual")
    expect(AwayDetector.usualKeys(dwell: [:], minDwellSeconds: 50, manual: []).isEmpty,
           "away: no dwell and no manual -> empty")
    expect(AwayDetector.usualKeys(dwell: ["a": 1], minDwellSeconds: 9999, manual: ["z"]) == ["z"],
           "away: manual allowlist alone forms a model")
    expect(AwayDetector.usualKeys(dwell: ["a": 50], minDwellSeconds: 50, manual: []).contains("a"),
           "away: dwell exactly at the threshold counts")
}

// The awayAfterMinutes delay on a network that is not usual.
do {
    var d = AwayDetector()
    d.config = AwayDetector.Configuration(
        usualMinDwellSeconds: 10, awayAfterMinutes: 15,
        offlineAwayAfterMinutes: 10, usualFingerprints: ["home"])
    expect(d.sample(key: "cafe", now: t0).isAway == false,
           "away: just-arrived unusual network -> not away")
    expect(d.sample(key: "cafe", now: t0.addingTimeInterval(14 * 60)).isAway == false,
           "away: 14 min unusual (within delay) -> not away")
    let v15 = d.sample(key: "cafe", now: t0.addingTimeInterval(15 * 60))
    expect(v15.isAway == true, "away: 15 min unusual -> away")
    expect(v15.awayForSeconds == 0, "away: awayForSeconds starts at 0")
    let v20 = d.sample(key: "cafe", now: t0.addingTimeInterval(20 * 60))
    expect(v20.isAway && abs(v20.awayForSeconds - 5 * 60) < 0.001,
           "away: awayForSeconds counts up while away")
}

// A usual key is never away, and returning to it clears "away".
do {
    var d = AwayDetector()
    d.config = AwayDetector.Configuration(
        usualMinDwellSeconds: 10, awayAfterMinutes: 15,
        offlineAwayAfterMinutes: 10, usualFingerprints: ["home"])
    let v = d.sample(key: "home", now: t0)
    expect(v.isUsual == true && v.isAway == false, "away: manual usual key -> not away")
    _ = d.sample(key: "cafe", now: t0.addingTimeInterval(30 * 60))  // -> away
    expect(d.sample(key: "home", now: t0.addingTimeInterval(31 * 60)).isAway == false,
           "away: returning to the usual network clears away")
}

// A network learned from dwell (not just the allowlist) is usual.
do {
    var d = AwayDetector()
    d.config = AwayDetector.Configuration(
        usualMinDwellSeconds: 100, awayAfterMinutes: 15,
        offlineAwayAfterMinutes: 10, usualFingerprints: [])
    d.load(dwell: ["mac:home": 150])
    let v = d.sample(key: "mac:home", now: t0)
    expect(v.isUsual && !v.isAway, "away: dwell-learned usual network -> not away")
}

// Offline backstop.
do {
    var d = AwayDetector()
    d.config = AwayDetector.Configuration(
        usualMinDwellSeconds: 10, awayAfterMinutes: 15,
        offlineAwayAfterMinutes: 10, usualFingerprints: ["home"])
    expect(d.sample(key: nil, now: t0).isAway == false, "away: offline before backstop -> not away")
    expect(d.sample(key: nil, now: t0.addingTimeInterval(9 * 60)).isAway == false,
           "away: 9 min offline -> not away")
    expect(d.sample(key: nil, now: t0.addingTimeInterval(10 * 60)).isAway == true,
           "away: 10 min offline -> away (backstop)")
}

// Coming back online resets the offline clock.
do {
    var d = AwayDetector()
    d.config = AwayDetector.Configuration(
        usualMinDwellSeconds: 10, awayAfterMinutes: 100,
        offlineAwayAfterMinutes: 5, usualFingerprints: ["home"])
    _ = d.sample(key: nil, now: t0)
    _ = d.sample(key: "cafe", now: t0.addingTimeInterval(6 * 60))   // online: clears offlineSince
    expect(d.sample(key: nil, now: t0.addingTimeInterval(7 * 60)).isAway == false,
           "away: reconnect resets the offline backstop")
}

// A suspend gap can never inflate dwell (the cap is applied on credit).
do {
    var d = AwayDetector()
    _ = d.sample(key: "home", now: t0)                       // lastTickAt = t0
    d.noteWillSleep(now: t0.addingTimeInterval(3600), capSeconds: 30)
    expect(d.dwell["home"] == 30, "away: will-sleep credits at most the cap")
    d.noteDidWake(now: t0.addingTimeInterval(3600))
    d.creditDwell(now: t0.addingTimeInterval(7200), capSeconds: 30)
    expect(d.dwell["home"] == 60, "away: the sleep gap is capped, not credited")
}

// A suspend while off-usual must not count as away time: after wake the away
// delay is re-armed, so the very next sample is not immediately away.
do {
    var d = AwayDetector()
    d.config = AwayDetector.Configuration(
        usualMinDwellSeconds: 7200, awayAfterMinutes: 15,
        offlineAwayAfterMinutes: 10, usualFingerprints: ["home"])
    expect(d.sample(key: "cafe", now: t0).isAway == false,
           "away(wake): just-arrived unusual -> not away")
    d.noteWillSleep(now: t0.addingTimeInterval(60), capSeconds: 30)
    d.noteDidWake(now: t0.addingTimeInterval(3 * 3600))
    let after = d.sample(key: "cafe", now: t0.addingTimeInterval(3 * 3600))
    expect(after.isAway == false, "away(wake): a 3h suspend never counts as away")
    expect(after.awayForSeconds == 0, "away(wake): awayFor resets after a suspend")
    expect(d.sample(key: "cafe", now: t0.addingTimeInterval(3 * 3600 + 15 * 60)).isAway == true,
           "away(wake): away fires again after the delay in awake time")
}

// The offline backstop is likewise re-armed across a suspend.
do {
    var d = AwayDetector()
    d.config = AwayDetector.Configuration(
        usualMinDwellSeconds: 7200, awayAfterMinutes: 15,
        offlineAwayAfterMinutes: 10, usualFingerprints: ["home"])
    _ = d.sample(key: nil, now: t0)          // offlineSince = t0
    d.noteWillSleep(now: t0.addingTimeInterval(60), capSeconds: 30)
    d.noteDidWake(now: t0.addingTimeInterval(3 * 3600))
    let after = d.sample(key: nil, now: t0.addingTimeInterval(3 * 3600))
    expect(after.isAway == false, "away(wake): offline backstop re-armed after a suspend")
}

// A VPN/tunnel is not a physical interface, so it never becomes a fingerprint.
do {
    expect(networkFingerprintIsPhysical("en0"), "fingerprint: en0 is physical")
    expect(networkFingerprintIsPhysical("en12"), "fingerprint: en12 is physical")
    expect(networkFingerprintIsPhysical("bridge0"), "fingerprint: bridge0 is physical")
    expect(networkFingerprintIsPhysical("eth0"), "fingerprint: eth0 is physical")
    expect(networkFingerprintIsPhysical("thunderbolt1"), "fingerprint: thunderbolt1 is physical")
    expect(!networkFingerprintIsPhysical("utun3"), "fingerprint: utun3 (VPN) excluded")
    expect(!networkFingerprintIsPhysical("ipsec0"), "fingerprint: ipsec0 (VPN) excluded")
    expect(!networkFingerprintIsPhysical("ppp0"), "fingerprint: ppp0 excluded")
    expect(!networkFingerprintIsPhysical("lo0"), "fingerprint: lo0 excluded")
}

// MARK: - Bag guard predicate

do {
    // Never fires while the machine is in active use.
    expect(!shouldAllowSleep(away: true, lidClosed: false, idle: false, screenLocked: false,
                             onBattery: true, requireBattery: false),
           "bag: away but active+unlocked -> never allow sleep")
    expect(!shouldAllowSleep(away: true, lidClosed: false, idle: false, screenLocked: false,
                             onBattery: false, requireBattery: true),
           "bag: active+unlocked stays awake regardless of power")
    expect(!shouldAllowSleep(away: false, lidClosed: true, idle: true, screenLocked: true,
                             onBattery: true, requireBattery: false),
           "bag: not away -> never allow sleep")
    // Each unattended signal alone is enough.
    expect(shouldAllowSleep(away: true, lidClosed: true, idle: false, screenLocked: false,
                            onBattery: true, requireBattery: true),
           "bag: lid closed -> allow")
    expect(shouldAllowSleep(away: true, lidClosed: false, idle: true, screenLocked: false,
                            onBattery: true, requireBattery: true),
           "bag: user idle -> allow")
    expect(shouldAllowSleep(away: true, lidClosed: false, idle: false, screenLocked: true,
                            onBattery: true, requireBattery: true),
           "bag: screen locked -> allow")
    // requireBattery is respected.
    expect(!shouldAllowSleep(away: true, lidClosed: true, idle: false, screenLocked: false,
                             onBattery: false, requireBattery: true),
           "bag: requireBattery blocks on AC")
    expect(shouldAllowSleep(away: true, lidClosed: true, idle: false, screenLocked: false,
                            onBattery: false, requireBattery: false),
           "bag: same state allows on AC when requireBattery is off")
}

// Exhaustive truth table over (away, lid, idle, locked, battery) x requireBattery.
do {
    for require in [false, true] {
        for mask in 0..<32 {
            let away = mask & 1 != 0
            let lid = mask & 2 != 0
            let idle = mask & 4 != 0
            let locked = mask & 8 != 0
            let batt = mask & 16 != 0
            let expected = away && (lid || idle || locked) && (!require || batt)
            let got = shouldAllowSleep(away: away, lidClosed: lid, idle: idle,
                                       screenLocked: locked, onBattery: batt, requireBattery: require)
            expect(got == expected, "bag truth table require=\(require) mask=\(mask)")
        }
    }
}

// MARK: - HelperManager pure parsers

do {
    let pmset = """
    System-wide power settings:
     SleepDisabled		1
    Currently in use:
     lidwake              1
    """
    expect(HelperManager.parseSleepDisabled(pmset) == true, "pmset: SleepDisabled 1 -> true")
    expect(HelperManager.parseSleepDisabled(" SleepDisabled 0\n") == false,
           "pmset: SleepDisabled 0 -> false")
    expect(HelperManager.parseSleepDisabled(" SleepDisabled 1\n") == true,
           "pmset: space-separated SleepDisabled 1 -> true")
    expect(HelperManager.parseSleepDisabled("Currently in use:\n lidwake 1\n") == nil,
           "pmset: missing SleepDisabled -> nil")
    expect(HelperManager.parseSleepDisabled("") == nil, "pmset: empty output -> nil")
}

do {
    func message(_ r: Result<Void, HelperError>) -> String? {
        if case .failure(let e) = r { return e.message }
        return nil
    }
    expect(message(HelperManager.parseReply("ok")) == nil, "reply: ok -> success")
    expect(message(HelperManager.parseReply("okfoo")) == "okfoo",
           "reply: 'okfoo' is not treated as success (exact match only)")
    expect(message(HelperManager.parseReply("err boom")) == "err boom", "reply: err ... -> its message")
    expect(message(HelperManager.parseReply("err")) == "err", "reply: bare err -> its message")
    expect(message(HelperManager.parseReply("unknown")) == "unknown",
           "reply: unrecognized line surfaced verbatim")
    expect(message(HelperManager.parseReply("")) == "no reply from helper",
           "reply: empty -> no-reply message")
}

// MARK: - Helper command dispatch

do {
    let ok: ([String]) -> (status: Int32, output: String) = { _ in (0, "") }

    expect(handleCommand("ping", runPmset: ok) == "ok", "helper: ping -> ok")
    expect(handleCommand("  ping  ", runPmset: ok) == "ok", "helper: trimmed ping -> ok")
    expect(handleCommand("set_disablesleep 1", runPmset: ok) == "err lease-required", "helper: legacy unbounded ON is rejected")
    expect(handleCommand("lease_disablesleep 1", runPmset: ok, enableLease: { "ok" }) == "ok", "helper: leased ON dispatched separately")
    expect(handleCommand("lease_disablesleep 0", runPmset: ok) == "err bad-args", "helper: lease opcode accepts only ON")
    expect(HelperManager.disablesleepCommand(true) == "lease_disablesleep 1", "client: distinct lease opcode prevents unsafe old-daemon fallback")
    expect(HelperManager.disablesleepCommand(false) == "set_disablesleep 0", "client: OFF remains old-daemon compatible")
    expect(handleCommand("set_disablesleep 0", runPmset: ok) == "ok", "helper: set_disablesleep 0 -> ok")
    expect(handleCommand("set_disablesleep", runPmset: ok) == "err bad-args",
           "helper: missing arg -> err bad-args")
    expect(handleCommand("set_disablesleep 2", runPmset: ok) == "err bad-args",
           "helper: non-whitelisted arg -> err bad-args")
    expect(handleCommand("set_disablesleep 1 extra", runPmset: ok) == "err bad-args",
           "helper: extra arg -> err bad-args")
    expect(handleCommand("", runPmset: ok) == "err empty-command", "helper: empty -> err empty-command")
    expect(handleCommand("   ", runPmset: ok) == "err empty-command",
           "helper: whitespace-only -> err empty-command")
    expect(handleCommand("frobnicate", runPmset: ok) == "err unknown-command",
           "helper: unknown command -> err unknown-command")
    expect(handleCommand("PING", runPmset: ok) == "err unknown-command",
           "helper: commands are case-sensitive")

    // A non-zero pmset status surfaces the code plus the trimmed output.
    let failing: ([String]) -> (status: Int32, output: String) = { _ in (1, "pmset: Operation not permitted\n") }
    expect(handleCommand("set_disablesleep 0", runPmset: failing) == "err rc=1 pmset: Operation not permitted",
           "helper: pmset failure -> err rc=<n> <output>")

    // Argument mapping and that ping never shells out.
    var seen: [String] = []
    _ = handleCommand("set_disablesleep 0", runPmset: { a in seen = a; return (0, "") })
    expect(seen == ["-a", "disablesleep", "0"], "helper: set_disablesleep maps to pmset args")

    var called = false
    _ = handleCommand("ping", runPmset: { _ in called = true; return (0, "") })
    expect(!called, "helper: ping does not invoke pmset")
}

// Energy Mode chooses one execution channel before writing (no real helper or authorization).
do {
    for mode in 0...2 {
        var commands: [String] = []
        var scripts: [String] = []
        let withoutHelper = HelperManager.setPowerMode(mode, helperFilesPresent: { false },
            request: { commands.append($0); return .success("ok") },
            authorize: { scripts.append($0); return .success(()) })
        if case .failure = withoutHelper { expect(false, "energy mode: absent helper permits one-shot authorization") }
        expect(commands.isEmpty && scripts == ["/usr/bin/pmset -a powermode \(mode)"],
               "energy mode: absent helper selects only one administrator write for \(mode)")

        commands = []; scripts = []
        let withHelper = HelperManager.setPowerMode(mode, helperFilesPresent: { true },
            request: { commands.append($0); return .success("ok") },
            authorize: { scripts.append($0); return .success(()) })
        if case .failure = withHelper { expect(false, "energy mode: healthy helper succeeds") }
        expect(commands == ["set_powermode \(mode)"] && scripts.isEmpty,
               "energy mode: installed helper selects only one RPC for \(mode)")
    }

    for failure in [
        HelperError(message: "error.helperNotRunning"),
        HelperError(message: "helper request timed out or invalid response"),
        HelperError(message: "err rc=1 Operation not permitted", status: 1),
        HelperError(message: "err unknown-command"),
        HelperError(message: "no reply from helper")
    ] {
        var commands: [String] = []
        var authorizationCount = 0
        let result = HelperManager.setPowerMode(1, helperFilesPresent: { true },
            request: { commands.append($0); return .failure(failure) },
            authorize: { _ in authorizationCount += 1; return .success(()) })
        if case .failure(let error) = result {
            expect(error.message == failure.message && error.status == failure.status,
                   "energy mode: helper failure is preserved: \(failure.message)")
        } else { expect(false, "energy mode: failed helper cannot report success") }
        expect(commands == ["set_powermode 1"] && authorizationCount == 0,
               "energy mode: unavailable, failed or uncertain helper never causes a second privileged write")
    }

    var authorizationCount = 0
    let cancelled = HelperManager.setPowerMode(2, helperFilesPresent: { false },
        request: { _ in expect(false, "energy mode: absent helper does not send RPC"); return .success("ok") },
        authorize: { _ in authorizationCount += 1; return .failure(HelperError(message: "User canceled (-128)", status: 1)) })
    if case .failure(let error) = cancelled {
        expect(error.message == "User canceled (-128)" && error.status == 1,
               "energy mode: administrator cancellation is preserved")
    } else { expect(false, "energy mode: cancelled authorization cannot report success") }
    expect(authorizationCount == 1, "energy mode: cancelled authorization is not repeated")

    for mode in [-1, 3] {
        var boundaryCalls = 0
        let invalid = HelperManager.setPowerMode(mode,
            helperFilesPresent: { boundaryCalls += 1; return false },
            request: { _ in boundaryCalls += 1; return .success("ok") },
            authorize: { _ in boundaryCalls += 1; return .success(()) })
        if case .failure(let error) = invalid {
            expect(error.message == "err bad-args", "energy mode: invalid request is rejected")
        } else { expect(false, "energy mode: invalid request cannot report success") }
        expect(boundaryCalls == 0, "energy mode: invalid request never reaches a system boundary")
    }
}

// Helper compatibility and privileged-script contract (no privileged execution).
do {
    var commands: [String] = []
    let oldDaemon: (String) -> Result<String, HelperError> = { command in
        commands.append(command)
        return .failure(HelperError(message: "err unknown-command"))
    }
    let result = HelperManager.setDisablesleep(true, request: oldDaemon)
    expect(commands == ["lease_disablesleep 1", "set_disablesleep 0"], "client: old daemon receives only lease attempt then safe cleanup OFF")
    if case .failure(let error) = result {
        expect(error.message.contains("outdated"), "client: incompatible daemon explains explicit upgrade path")
        expect(error.message.contains("Sleep reset failed"), "client: failed legacy cleanup stays visible")
    } else { expect(false, "client: old daemon cannot claim leased ON success") }
    var inheritedOn = true
    let legacyStateful: (String) -> Result<String, HelperError> = { command in
        if command == "set_disablesleep 0" { inheritedOn = false; return .success("ok") }
        return .failure(HelperError(message: "err unknown-command"))
    }
    _ = HelperManager.setDisablesleep(true, request: legacyStateful)
    expect(!inheritedOn, "client: incompatible old helper clears inherited permanent ON")
    let install = HelperManager.installationScript(helper: "/tmp/fixture's helper", sha256: "abcd")
    expect(install.contains("mktemp -d /Library/PrivilegedHelperTools/"), "install: stage is created under root-owned directory")
    expect(install.contains("[ \"$actual\" = 'abcd' ]"), "install: staged bytes must match selected digest")
    expect(install.contains("codesign --verify --strict --all-architectures \"$stage/helper\""), "install: staged signature verification fails closed")
    expect(!install.contains("if /usr/bin/codesign"), "install: failed signature cannot skip verification")
    expect(install.contains("<key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/com.coddle.helper</string>"), "install: fixed trusted launch path")
    expect(!install.contains("Resources/com.coddle.helper.plist"), "install: mutable bundled plist is not privileged input")
    expect(HelperManager.powerModeScript(2) == "/usr/bin/pmset -a powermode 2", "energy mode: privilege script only performs requested change")
    expect(HelperManager.powerModeScript(3) == nil, "energy mode: invalid mode has no script")
    let removal = HelperManager.uninstallationScript
    expect(removal.range(of: "pmset -a disablesleep 0")!.lowerBound < removal.range(of: "launchctl bootout")!.lowerBound,
           "uninstall: root OFF completes before removing watchdog")
    expect(removal.range(of: "launchctl bootout")!.lowerBound < removal.range(of: "pmset -a disablesleep 0", options: .backwards)!.lowerBound,
           "uninstall: final OFF follows stopped daemon so queued ON cannot overtake it")
    let start = BoundedIO.now
    let timed = BoundedIO.run("/bin/sleep", arguments: ["3"], timeout: 0.1)
    expect(timed.status == -1 && BoundedIO.now - start < 1, "process: timeout kills and reaps child within bound")
    let pendingStart = BoundedIO.now
    let pending = BoundedIO.run("/bin/sleep", arguments: ["0.15"], timeout: nil)
    expect(pending.status == 0 && BoundedIO.now - pendingStart >= 0.14,
           "process: explicitly unbounded authorization wait does not abandon running child")
    let output = BoundedIO.run("/bin/echo", arguments: ["fixture"], timeout: 1)
    expect(output.status == 0 && output.output == "fixture\n", "process: successful bounded output captured")
    expect(removal.contains("set -eu") && !removal.contains("|| true"), "uninstall: failures preserve non-success status")
}

// MARK: - Localizer

do {
    expect(Localizer.supported.count == 6, "localizer: six supported languages")
    for code in Localizer.supported {
        expect(Localizer.resolve(code) == code, "localizer: resolve(\(code)) is identity")
    }
    expect(Localizer.supported.contains(Localizer.resolve("system")),
           "localizer: resolve(system) -> a supported language")
    expect(Localizer.supported.contains(Localizer.resolve("klingon")),
           "localizer: resolve(unsupported) -> a supported language")

    // Pure system-language mapping, including the Traditional-Chinese cases.
    let sup = Localizer.supported
    expect(Localizer.resolve(systemPreferredLanguages: ["en-US"], supported: sup) == "en",
           "localizer: en-US -> en")
    expect(Localizer.resolve(systemPreferredLanguages: ["zh-Hans-CN"], supported: sup) == "zh-Hans",
           "localizer: zh-Hans-CN -> zh-Hans")
    expect(Localizer.resolve(systemPreferredLanguages: ["zh-CN"], supported: sup) == "zh-Hans",
           "localizer: zh-CN -> zh-Hans")
    expect(Localizer.resolve(systemPreferredLanguages: ["zh-Hant-TW"], supported: sup) == "zh-Hant",
           "localizer: zh-Hant-TW -> zh-Hant")
    expect(Localizer.resolve(systemPreferredLanguages: ["zh-TW"], supported: sup) == "zh-Hant",
           "localizer: zh-TW -> zh-Hant")
    expect(Localizer.resolve(systemPreferredLanguages: ["zh-HK"], supported: sup) == "zh-Hant",
           "localizer: zh-HK -> zh-Hant")
    expect(Localizer.resolve(systemPreferredLanguages: ["zh-TW"], supported: sup) != "zh-Hans",
           "localizer: zh-TW is Traditional, not Simplified")
    expect(Localizer.resolve(systemPreferredLanguages: ["ja-JP"], supported: sup) == "ja",
           "localizer: ja-JP -> ja")
    expect(Localizer.resolve(systemPreferredLanguages: ["ko-KR"], supported: sup) == "ko",
           "localizer: ko-KR -> ko")
    expect(Localizer.resolve(systemPreferredLanguages: ["es-419"], supported: sup) == "es",
           "localizer: es-419 -> es")
    expect(Localizer.resolve(systemPreferredLanguages: ["fr-FR"], supported: sup) == "en",
           "localizer: unsupported fr-FR -> en")
    expect(Localizer.resolve(systemPreferredLanguages: [], supported: sup) == "en",
           "localizer: empty preference list -> en")
    expect(Localizer.resolve(systemPreferredLanguages: ["fr-FR", "zh-Hant-HK"], supported: sup) == "zh-Hant",
           "localizer: first supported preference wins (skips fr-FR)")

    expect(Localizer.format("holding at {n}%", args: [85]) == "holding at 85%",
           "localizer: format substitutes {n}")
    expect(Localizer.format("{n}-{n}", args: [1, 2]) == "1-2",
           "localizer: format fills placeholders in order")
    expect(Localizer.format("no placeholder", args: [5]) == "no placeholder",
           "localizer: format leaves text without {n} untouched")
    expect(Localizer.format("{n}", args: [Int64(7)]) == "7", "localizer: format renders Int64")
    expect(Localizer.format("{n}", args: [2.5]) == "2.5", "localizer: format renders Double")
    expect(Localizer.format("{n}", args: ["hi"]) == "hi", "localizer: format renders a String arg")

    expect(Localizer.resolveValue(active: Localizer.missingSentinel, english: "Hello") == "Hello",
           "localizer: missing active value -> English")
    expect(Localizer.resolveValue(active: "Bonjour", english: "Hello") == "Bonjour",
           "localizer: present active value wins")
    expect(Localizer.resolveValue(active: Localizer.missingSentinel, english: "some.missing.key") == "some.missing.key",
           "localizer: missing everywhere -> the key itself")
}

// MARK: - i18n completeness

/// Absolute path of the app directory, derived from this file's compile-time
/// location so the checks work regardless of the process working directory.
func appDir() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // .../Coddle/tests
        .deletingLastPathComponent()   // .../Coddle
}

/// Keys declared in a generated `Localizable.strings` (`"key" = "value";`).
func stringsKeys(_ text: String) -> Set<String> {
    var keys = Set<String>()
    guard let regex = try? NSRegularExpression(pattern: "\"([^\"]*)\"\\s*=") else { return keys }
    let ns = text as NSString
    for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        if m.numberOfRanges >= 2 { keys.insert(ns.substring(with: m.range(at: 1))) }
    }
    return keys
}

/// All string literals that appear as arguments to a `tr( ... )` call.
func trLiterals(_ source: String) -> [String] {
    var out: [String] = []
    let chars = Array(source)
    var i = 0
    func isIdent(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
    while i < chars.count {
        if chars[i] == "t", i + 2 < chars.count, chars[i + 1] == "r", chars[i + 2] == "(",
           i == 0 || !isIdent(chars[i - 1]) {
            var j = i + 3
            var depth = 1
            var segment = ""
            while j < chars.count && depth > 0 {
                let c = chars[j]
                if c == "(" { depth += 1; segment.append(c) }
                else if c == ")" { depth -= 1; if depth > 0 { segment.append(c) } }
                else { segment.append(c) }
                j += 1
            }
            // Only the first argument names the translation key. Nested
            // format strings and subsequent replacement values are not keys.
            let seg = Array(segment)
            var k = 0
            var nesting = 0
            while k < seg.count {
                if seg[k] == "," && nesting == 0 { break }
                if seg[k] == "(" { nesting += 1 }
                if seg[k] == ")" { nesting -= 1 }
                if seg[k] == "\"" {
                    k += 1
                    var v = ""
                    while k < seg.count && seg[k] != "\"" {
                        if seg[k] == "\\", k + 1 < seg.count { v.append(seg[k + 1]); k += 2; continue }
                        v.append(seg[k]); k += 1
                    }
                    if nesting == 0 { out.append(v) }
                    k += 1
                } else {
                    k += 1
                }
            }
            i = j
        } else {
            i += 1
        }
    }
    return out
}

do {
    let langs = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es"]
    let catalogURL = appDir().appendingPathComponent("Resources/i18n/strings.json")
    let catalogData = (try? Data(contentsOf: catalogURL)) ?? Data()
    let catalog = (try? JSONSerialization.jsonObject(with: catalogData)) as? [String: [String: String]] ?? [:]
    expect(!catalog.isEmpty, "i18n: strings.json loads with keys")

    // Every catalog key is present in every shipped .lproj file.
    for lang in langs {
        let url = appDir().appendingPathComponent("Resources/\(lang).lproj/Localizable.strings")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let keys = stringsKeys(text)
        let missing = catalog.keys.filter { !keys.contains($0) }.sorted()
        expect(missing.isEmpty, "i18n: \(lang) has every catalog key (missing: \(missing))")
        expect(keys.count == catalog.count,
               "i18n: \(lang) has exactly \(catalog.count) keys (got \(keys.count))")
    }

    // Every catalog entry carries all six languages.
    for (key, byLang) in catalog {
        let missing = langs.filter { byLang[$0] == nil }
        expect(missing.isEmpty, "i18n: catalog '\(key)' has all six languages (missing: \(missing))")
    }

    // Every `tr("...")` literal in Sources exists in the catalog, and every
    // catalog key is referenced from Sources (no dead keys).
    let sourcesDir = appDir().appendingPathComponent("Sources")
    let files = (try? FileManager.default.contentsOfDirectory(at: sourcesDir, includingPropertiesForKeys: nil)) ?? []
    var literals = Set<String>()
    var allSource = ""
    for f in files where f.pathExtension == "swift" {
        let src = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
        allSource += src
        for lit in trLiterals(src) { literals.insert(lit) }
    }
    expect(!literals.isEmpty, "i18n: tr(...) literals found in Sources")
    let orphans = literals.filter { catalog[$0] == nil }.sorted()
    expect(orphans.isEmpty, "i18n: every tr(...) key exists in the catalog (orphans: \(orphans))")
    let unused = catalog.keys.filter { !allSource.contains("\"\($0)\"") }.sorted()
    expect(unused.isEmpty, "i18n: every catalog key is referenced in Sources (unused: \(unused))")
}

// MARK: - CoddleConfig

// Every field's default.
do {
    let d = CoddleConfig()
    expect(d.holdLimit == 80 && d.manualLimit == 80 && d.topupLimit == 100 && d.topupLeadHours == 2
           && d.minSamplesPerHour == 3 && d.refreshSeconds == 5,
           "config defaults: charge fields")
    expect(d.smartEnabled == false && d.iconOnly == false
           && d.showInDock == false && d.showMenuBarIcon == true,
           "config defaults: UI fields")
    expect(d.language == "system" && d.theme == "liquidGlass" && d.keepAwake == false && d.keepAwakeOnLidClosed == false,
           "config defaults: language + theme + keep-awake")
    expect(d.awayDetectionEnabled == true && d.networkSampleSeconds == 30
           && d.usualMinDwellSeconds == 7200 && d.awayAfterMinutes == 15
           && d.offlineAwayAfterMinutes == 10 && d.idleSeconds == 120,
           "config defaults: away fields")
    expect(d.requireBattery == true && d.lowBatteryWarnPercent == 20
           && d.keepDisplayAwake == false
           && d.usualFingerprints.isEmpty,
           "config defaults: agent-mode fields")
}

// Full encode -> decode round-trip.
do {
    var cfg = CoddleConfig()
    cfg.holdLimit = 65
    cfg.manualLimit = 85
    cfg.topupLimit = 95
    cfg.topupLeadHours = 3
    cfg.minSamplesPerHour = 5
    cfg.refreshSeconds = 10
    cfg.smartEnabled = true
    cfg.iconOnly = true
    cfg.showInDock = true
    cfg.showMenuBarIcon = false
    cfg.language = "ja"
    cfg.theme = "classic"
    cfg.keepAwake = true
    cfg.keepAwakeOnLidClosed = true
    cfg.awayDetectionEnabled = false
    cfg.networkSampleSeconds = 45
    cfg.usualMinDwellSeconds = 3600
    cfg.awayAfterMinutes = 20
    cfg.offlineAwayAfterMinutes = 5
    cfg.idleSeconds = 60
    cfg.requireBattery = false
    cfg.lowBatteryWarnPercent = 25
    cfg.keepDisplayAwake = true
    cfg.usualFingerprints = ["mac:aa", "mac:bb"]

    let encoded = try! JSONEncoder().encode(cfg)
    let back = try! JSONDecoder().decode(CoddleConfig.self, from: encoded)
    expect(sameConfig(cfg, back), "config: encode -> decode round-trips every field")

    let viaStore = ConfigStore.decode(encoded)
    expect(viaStore != nil && sameConfig(cfg, viaStore!),
           "config: ConfigStore.decode round-trips every field")
}

// Tolerant decode: missing keys fall back to defaults; present keys survive.
do {
    let json = #"{"holdLimit": 85, "smartEnabled": true, "language": "ja"}"#
    let cfg = try! JSONDecoder().decode(CoddleConfig.self, from: Data(json.utf8))
    expect(cfg.holdLimit == 85, "present holdLimit preserved")
    expect(cfg.manualLimit == 80, "missing manualLimit uses default 80")
    expect(cfg.smartEnabled == true, "present smartEnabled preserved")
    expect(cfg.language == "ja", "present language preserved")
    expect(cfg.theme == "liquidGlass", "missing theme uses default liquidGlass")
    expect(cfg.topupLimit == 100, "missing topupLimit uses default 100")
    expect(cfg.refreshSeconds == 5, "missing refreshSeconds uses default 5")
    expect(cfg.showMenuBarIcon == true, "missing showMenuBarIcon uses default true")
    expect(cfg.usualFingerprints.isEmpty, "missing usualFingerprints uses default []")

    // Present manualLimit is preserved
    let manualJson = #"{"manualLimit": 90}"#
    let manualCfg = try! JSONDecoder().decode(CoddleConfig.self, from: Data(manualJson.utf8))
    expect(manualCfg.manualLimit == 90, "present manualLimit preserved")
}

// Unknown fields are ignored; explicit null falls back to the default.
do {
    let unknown = ConfigStore.decode(Data(#"{"holdLimit": 70, "somethingNew": {"nested": 1}}"#.utf8))
    expect(unknown?.holdLimit == 70, "config: unknown field ignored, present key preserved")

    let nul = ConfigStore.decode(Data(#"{"holdLimit": null, "manualLimit": null, "language": null, "theme": null}"#.utf8))
    expect(nul?.holdLimit == 80 && nul?.manualLimit == 80 && nul?.language == "system" && nul?.theme == "liquidGlass", "config: explicit null -> default")
}

// Corrupt / wrong-typed JSON -> nil (so ConfigStore.load falls back to defaults).
do {
    expect(ConfigStore.decode(Data("not json at all".utf8)) == nil,
           "config: malformed JSON -> nil")
    expect(ConfigStore.decode(Data("{".utf8)) == nil,
           "config: truncated JSON -> nil")
    expect(ConfigStore.decode(Data(#"{"holdLimit": "eighty"}"#.utf8)) == nil,
           "config: wrong-typed field -> nil")
    let empty = ConfigStore.decode(Data("{}".utf8))
    expect(empty != nil && sameConfig(empty!, CoddleConfig()), "config: empty object -> all defaults")
}

// Mutual-exclusion safety net, as a pure function.
do {
    var both = CoddleConfig()
    both.showInDock = false
    both.showMenuBarIcon = false
    let fixed = both.sanitized()
    expect(fixed.showInDock == false, "sanitized keeps showInDock off")
    expect(fixed.showMenuBarIcon == true, "sanitized forces the menu bar back on")
    expect(sameConfig(fixed.sanitized(), fixed), "sanitized is idempotent")

    var dockOnly = CoddleConfig()
    dockOnly.showInDock = true
    dockOnly.showMenuBarIcon = false
    let kept = dockOnly.sanitized()
    expect(kept.showInDock == true && kept.showMenuBarIcon == false,
           "sanitized leaves a valid combination untouched")

    // sanitized() only touches the entry points.
    var custom = CoddleConfig()
    custom.showInDock = false
    custom.showMenuBarIcon = false
    custom.holdLimit = 55
    custom.language = "ko"
    custom.usualFingerprints = ["a"]
    let s = custom.sanitized()
    expect(s.holdLimit == 55 && s.language == "ko" && s.usualFingerprints == ["a"]
           && s.showMenuBarIcon == true, "sanitized only touches the entry points")

    // decode() applies sanitized() so a hand-edited both-off config is healed.
    let healed = ConfigStore.decode(Data(#"{"showInDock": false, "showMenuBarIcon": false}"#.utf8))
    expect(healed?.showMenuBarIcon == true, "config: decode() applies sanitized()")
}

// MARK: - Subagent Review Bug Fix Validations

// 1. SmartPolicy: 24/7 plugged-in user (p=1.0 for all hours) must NEVER predict midnight unplug.
do {
    let p = makeProfile(minSamples: 10, offACHours: [])
    expect(p.predictedUnplugHour(minSamples: 5) == nil,
           "smart: 24/7 plugged in user predicts nil (never tops up)")
    let policy = SmartPolicy()
    for h in 0..<24 {
        expect(policy.decide(hour: h, profile: p).target == 80,
               "smart: 24/7 plugged in user stays at holdLimit (80) at hour \(h)")
    }
}

// 2. SmartPolicy: Tie-breaker prefers hour with higher sample count (higher confidence).
do {
    var p = SmartPolicy.Profile()
    for h in 0..<24 {
        for _ in 0..<10 { p.observe(hour: h, onAC: true) }
    }
    // Both hour 8 and hour 18 have p = 0.2, but hour 18 has 50 samples vs 10 samples
    p.ac[8] = 2; p.total[8] = 10
    p.ac[18] = 10; p.total[18] = 50
    expect(p.predictedUnplugHour(minSamples: 5) == 18,
           "smart: equal lowest probability selects the hour with higher sample count")
}

// 3. SmartPolicy: Observation soft-decay prevents unbounded counter growth.
do {
    var p = SmartPolicy.Profile()
    for _ in 0..<1500 {
        p.observe(hour: 12, onAC: true)
    }
    expect(p.total[12] <= 1000, "smart: observation count caps/decays under maxObservationsPerBucket")
}

// 4. AwayDetector: Suspend while already away keeps isAway=true on wake (backpack sleep protection).
do {
    var d = AwayDetector()
    d.config = AwayDetector.Configuration(
        usualMinDwellSeconds: 7200, awayAfterMinutes: 15,
        offlineAwayAfterMinutes: 10, usualFingerprints: ["home"])
    // Reach isAway = true
    _ = d.sample(key: "cafe", now: t0)
    let awayStatus = d.sample(key: "cafe", now: t0.addingTimeInterval(16 * 60))
    expect(awayStatus.isAway == true, "away: reached away state after 16m")
    // Put to sleep
    d.noteWillSleep(now: t0.addingTimeInterval(17 * 60), capSeconds: 30)
    d.noteDidWake(now: t0.addingTimeInterval(3 * 3600))
    // Wake up still at cafe: must STAY away!
    let wakeStatus = d.sample(key: "cafe", now: t0.addingTimeInterval(3 * 3600))
    expect(wakeStatus.isAway == true, "away(wake): already away before sleep stays away after wake on strange network")
    // Return to home: clears away
    let homeStatus = d.sample(key: "home", now: t0.addingTimeInterval(3 * 3600 + 30))
    expect(homeStatus.isAway == false, "away: returning home clears away state")
}

// 5. HelperCommand: ping rejects extra arguments.
do {
    let ok: ([String]) -> (status: Int32, output: String) = { _ in (0, "") }
    expect(handleCommand("ping extra", runPmset: ok) == "err bad-args",
           "helper: ping with extra argument rejected")
    expect(handleCommand("ping 123", runPmset: ok) == "err bad-args",
           "helper: ping with trailing number rejected")
}

// 6. CoddleConfig: Sanitization bounds checks.
do {
    var outOfBounds = CoddleConfig()
    outOfBounds.holdLimit = 150
    outOfBounds.manualLimit = 150
    outOfBounds.topupLimit = -10
    outOfBounds.refreshSeconds = 0
    outOfBounds.networkSampleSeconds = 1
    outOfBounds.usualMinDwellSeconds = -50
    outOfBounds.awayAfterMinutes = 0
    outOfBounds.offlineAwayAfterMinutes = -5
    outOfBounds.idleSeconds = -100

    let sanitized = outOfBounds.sanitized()
    expect(sanitized.holdLimit == 100, "sanitized: holdLimit 150 clamped to 100")
    expect(sanitized.manualLimit == 100, "sanitized: manualLimit 150 clamped to 100")
    expect(sanitized.topupLimit == 100, "sanitized: topupLimit clamped to at least holdLimit (100)")
    expect(sanitized.refreshSeconds == 1, "sanitized: refreshSeconds 0 clamped to 1")
    expect(sanitized.networkSampleSeconds == 5, "sanitized: networkSampleSeconds 1 clamped to 5")
    expect(sanitized.usualMinDwellSeconds == 0, "sanitized: usualMinDwellSeconds -50 clamped to 0")
    expect(sanitized.awayAfterMinutes == 1, "sanitized: awayAfterMinutes 0 clamped to 1")
    expect(sanitized.offlineAwayAfterMinutes == 1, "sanitized: offlineAwayAfterMinutes -5 clamped to 1")
    expect(sanitized.idleSeconds == 0, "sanitized: idleSeconds -100 clamped to 0")

    var underLimit = CoddleConfig()
    underLimit.manualLimit = -10
    expect(underLimit.sanitized().manualLimit == 0, "sanitized: manualLimit -10 clamped to 0")

    var midLimit = CoddleConfig()
    midLimit.manualLimit = 50
    expect(midLimit.sanitized().manualLimit == 80, "sanitized: manualLimit 50 clamped to 80")

    var zeroLimit = CoddleConfig()
    zeroLimit.manualLimit = 0
    expect(zeroLimit.sanitized().manualLimit == 0, "sanitized: manualLimit 0 preserved as 0")

    var validLimit = CoddleConfig()
    validLimit.manualLimit = 85
    expect(validLimit.sanitized().manualLimit == 85, "sanitized: manualLimit 85 preserved as 85")
}

// 7. AwayDetector: shortHash consistency & manual short-hash allowlisting.
do {
    let raw = "mac:00:11:22:33:44:55"
    let hash = AwayDetector.shortHash(raw)
    expect(hash.count == 6, "shortHash: 6 hex chars (got \(hash))")
    expect(AwayDetector.shortHash(raw) == hash, "shortHash: deterministic")

    // Manual allowlist using the 6-hex short hash directly (as shown in the UI)
    var d = AwayDetector()
    d.config = AwayDetector.Configuration(
        usualMinDwellSeconds: 7200,
        awayAfterMinutes: 15,
        offlineAwayAfterMinutes: 10,
        usualFingerprints: [hash]
    )
    let verdict = d.sample(key: raw, now: Date())
    expect(verdict.isUsual == true, "shortHash: raw network recognized as usual when short hash is in config")
    expect(verdict.isAway == false, "shortHash: not away when short hash matches")
}

// 8. HelperCommand: tab and extra whitespace handling.
do {
    let ok: ([String]) -> (status: Int32, output: String) = { _ in (0, "") }
    expect(handleCommand("set_disablesleep\t0", runPmset: ok) == "ok",
           "helper: tab separator accepted")
    expect(handleCommand("  set_disablesleep   0  ", runPmset: ok) == "ok",
           "helper: leading/trailing and multi-space accepted")
}

// 9. Desktop Mac battery edge cases.
do {
    let desktop = battery(present: false, installed: false, charging: false, ac: false)
    expect(desktop.chargeStatus(limit: 80, enabled: true) == .noBattery,
           "desktop: no battery reports .noBattery status")
    expect(desktop.healthPercent == nil,
           "desktop: no health percentage reported")
}

// MARK: - Theme System Tests

// 1. CoddleTheme enumeration and case defaults
do {
    expect(CoddleTheme.allCases.count == 2, "theme: exactly 2 supported themes")
    expect(CoddleTheme.default == .liquidGlass, "theme: default theme is liquidGlass")
    expect(CoddleTheme.liquidGlass.rawValue == "liquidGlass", "theme: liquidGlass rawValue")
    expect(CoddleTheme.classic.rawValue == "classic", "theme: classic rawValue")
    expect(CoddleTheme.liquidGlass.id == "liquidGlass", "theme: liquidGlass id matches rawValue")
    expect(CoddleTheme.classic.id == "classic", "theme: classic id matches rawValue")

    // Key parsing & defaulting
    expect(CoddleTheme(key: "liquidGlass") == .liquidGlass, "theme(key: liquidGlass) parses correctly")
    expect(CoddleTheme(key: "classic") == .classic, "theme(key: classic) parses correctly")
    expect(CoddleTheme(key: "invalid") == .liquidGlass, "theme(key: invalid) falls back to default liquidGlass")
    expect(CoddleTheme(key: "") == .liquidGlass, "theme(key: empty) falls back to default liquidGlass")

    // Localization keys
    expect(CoddleTheme.liquidGlass.localizationKey == "theme.liquidGlass", "theme: liquidGlass localization key")
    expect(CoddleTheme.classic.localizationKey == "theme.classic", "theme: classic localization key")
}

// 2. CoddleConfig theme integration & activeTheme mapping
do {
    let cfgDefault = CoddleConfig()
    expect(cfgDefault.theme == "liquidGlass", "config: default theme is liquidGlass")
    expect(cfgDefault.activeTheme == .liquidGlass, "config: default activeTheme is .liquidGlass")

    var cfgClassic = CoddleConfig()
    cfgClassic.theme = "classic"
    expect(cfgClassic.activeTheme == .classic, "config: activeTheme reflects classic")

    var cfgBogus = CoddleConfig()
    cfgBogus.theme = "unknownTheme"
    expect(cfgBogus.activeTheme == .liquidGlass, "config: activeTheme falls back to .liquidGlass on unknown")
}

// 3. Theme serialization, deserialization, and invalid fallback
do {
    // Round-trip classic
    var cfgClassic = CoddleConfig()
    cfgClassic.theme = "classic"
    let encClassic = try! JSONEncoder().encode(cfgClassic)
    let decClassic = try! JSONDecoder().decode(CoddleConfig.self, from: encClassic)
    expect(decClassic.theme == "classic", "theme: JSON round-trip classic preserved")

    // Round-trip liquidGlass
    var cfgLiquid = CoddleConfig()
    cfgLiquid.theme = "liquidGlass"
    let encLiquid = try! JSONEncoder().encode(cfgLiquid)
    let decLiquid = try! JSONDecoder().decode(CoddleConfig.self, from: encLiquid)
    expect(decLiquid.theme == "liquidGlass", "theme: JSON round-trip liquidGlass preserved")

    // Sanitization: invalid theme string heals to liquidGlass
    var badTheme = CoddleConfig()
    badTheme.theme = "cyberpunk"
    let healed = badTheme.sanitized()
    expect(healed.theme == "liquidGlass", "sanitized: unknown theme heals to liquidGlass")

    var badThemeUpper = CoddleConfig()
    badThemeUpper.theme = "CLASSIC"
    expect(badThemeUpper.sanitized().theme == "liquidGlass", "sanitized: non-exact case heals to liquidGlass")

    var validClassicSanitized = CoddleConfig()
    validClassicSanitized.theme = "classic"
    expect(validClassicSanitized.sanitized().theme == "classic", "sanitized: valid classic preserved")

    var validLiquidSanitized = CoddleConfig()
    validLiquidSanitized.theme = "liquidGlass"
    expect(validLiquidSanitized.sanitized().theme == "liquidGlass", "sanitized: valid liquidGlass preserved")

    // ConfigStore.decode heals invalid theme
    let storeInvalid = ConfigStore.decode(Data(#"{"theme": "neonGlow"}"#.utf8))
    expect(storeInvalid?.theme == "liquidGlass", "ConfigStore.decode: invalid theme heals to liquidGlass")

    let storeClassic = ConfigStore.decode(Data(#"{"theme": "classic"}"#.utf8))
    expect(storeClassic?.theme == "classic", "ConfigStore.decode: valid classic theme loaded")

    let storeLiquid = ConfigStore.decode(Data(#"{"theme": "liquidGlass"}"#.utf8))
    expect(storeLiquid?.theme == "liquidGlass", "ConfigStore.decode: valid liquidGlass theme loaded")

    let storeNull = ConfigStore.decode(Data(#"{"theme": null}"#.utf8))
    expect(storeNull?.theme == "liquidGlass", "ConfigStore.decode: null theme falls back to liquidGlass")
}

// 4. Design tokens verification
do {
    let liquid = LiquidGlassTokens()
    expect(liquid.theme == .liquidGlass, "tokens: LiquidGlassTokens theme is .liquidGlass")
    expect(liquid.cornerRadius == 14, "tokens: LiquidGlassTokens cornerRadius is 14pt continuous squircle")
    expect(liquid.strokeWidth == 0.75, "tokens: LiquidGlassTokens strokeWidth is 0.75pt hairline")
    expect(liquid.badgeStrokeWidth == 0.75, "tokens: LiquidGlassTokens badgeStrokeWidth is 0.75pt")

    let classic = ClassicTokens()
    expect(classic.theme == .classic, "tokens: ClassicTokens theme is .classic")
    expect(classic.cornerRadius == 10, "tokens: ClassicTokens cornerRadius is 10pt")
    expect(classic.strokeWidth == 1.0, "tokens: ClassicTokens strokeWidth is 1.0pt")
    expect(classic.badgeStrokeWidth == 1.0, "tokens: ClassicTokens badgeStrokeWidth is 1.0pt")

    // Test token functions callable under dark and light schemes
    _ = liquid.cardFill(colorScheme: .dark, reduceTransparency: false)
    _ = liquid.cardFill(colorScheme: .light, reduceTransparency: false)
    _ = liquid.cardFill(colorScheme: .dark, reduceTransparency: true)
    _ = liquid.cardStroke(colorScheme: .dark, reduceTransparency: false)
    _ = liquid.cardStroke(colorScheme: .light, reduceTransparency: false)
    _ = liquid.cardStroke(colorScheme: .dark, reduceTransparency: true)

    _ = classic.cardFill(colorScheme: .dark, reduceTransparency: false)
    _ = classic.cardFill(colorScheme: .dark, reduceTransparency: true)
    _ = classic.cardStroke(colorScheme: .dark, reduceTransparency: false)
}

// 5. SmartPolicy transition drop unplug prediction
do {
    var p = SmartPolicy.Profile()
    // 00:00 to 08:00 plugged in (p = 1.0)
    for h in 0...8 {
        for _ in 0..<10 { p.observe(hour: h, onAC: true) }
    }
    // 09:00: unplug transition (1 onAC, 9 offAC -> p = 0.1, drop = 0.9 from h=8)
    p.observe(hour: 9, onAC: true)
    for _ in 0..<9 { p.observe(hour: 9, onAC: false) }

    // 10:00 to 17:00: continues unplugged with 0 onAC (p = 0.0, drop = 0.1 or 0.0)
    for h in 10...17 {
        for _ in 0..<10 { p.observe(hour: h, onAC: false) }
    }
    // 18:00 to 23:00: plugged back in
    for h in 18...23 {
        for _ in 0..<10 { p.observe(hour: h, onAC: true) }
    }

    // Prediction must identify hour 9 (the transition moment) rather than hour 14 (which had p=0.0)
    let predicted = p.predictedUnplugHour(minSamples: 5)
    expect(predicted == 9, "smart: transition drop identifies hour 9 as unplug time, not later hours")
}

// 6. BatteryReader: top-level capacity fallback (Intel Mac) and percent clamping
do {
    let bag: [String: Any] = [
        "BatteryInstalled": true,
        "ExternalConnected": true,
        "DesignCapacity": 6000,
        "MaxCapacity": 5400,
        "CurrentCapacity": 5500, // Slightly over MaxCapacity during calibration
    ]
    let b = parseSmartBattery(bag)
    expect(b.designCapacity == 6000, "battery: top-level DesignCapacity read when BatteryData is absent")
    expect(b.fullChargeCapacity == 5400, "battery: top-level MaxCapacity read as fullChargeCapacity")
    expect(b.healthPercent == 90.0, "battery: health calculated as 5400/6000 == 90.0%")
    expect(b.percent == 100, "battery: percent clamped to 100% when CurrentCapacity > MaxCapacity")
}

// 7. Config sanitization ensures app cannot become an unreachable ghost process
do {
    var bad = CoddleConfig()
    bad.showInDock = false
    bad.showMenuBarIcon = false
    let fixed = bad.sanitized()
    expect(fixed.showMenuBarIcon == true, "config.sanitized: preserves menuBarIcon when both are false")
}

// 8. EnergyMode parsing and HelperCommand set_powermode dispatch
do {
    expect(HelperManager.parsePowerMode(" powermode\t\t0\n") == .automatic, "pmset: powermode 0 -> automatic")
    expect(HelperManager.parsePowerMode(" powermode\t\t1\n") == .lowPower, "pmset: powermode 1 -> lowPower")
    expect(HelperManager.parsePowerMode(" powermode\t\t2\n") == .highPower, "pmset: powermode 2 -> highPower")
    expect(HelperManager.parsePowerMode(" lowpowermode\t\t1\n") == .lowPower, "pmset: lowpowermode 1 fallback -> lowPower")
    expect(HelperManager.parsePowerMode(" lowpowermode\t\t0\n") == .automatic, "pmset: lowpowermode 0 fallback -> automatic")

    var argsSeen: [String] = []
    let ok: ([String]) -> (status: Int32, output: String) = { a in argsSeen = a; return (0, "") }
    expect(handleCommand("set_powermode 0", runPmset: ok) == "ok" && argsSeen == ["-a", "powermode", "0"],
           "helper: set_powermode 0 -> pmset -a powermode 0")
    expect(handleCommand("set_powermode 1", runPmset: ok) == "ok" && argsSeen == ["-a", "powermode", "1"],
           "helper: set_powermode 1 -> pmset -a powermode 1")
    expect(handleCommand("set_powermode 2", runPmset: ok) == "ok" && argsSeen == ["-a", "powermode", "2"],
           "helper: set_powermode 2 -> pmset -a powermode 2")
    expect(handleCommand("set_powermode 3", runPmset: ok) == "err bad-args",
           "helper: set_powermode 3 rejected")
}

// MARK: - Summary

print("coddle-tests: \(checks) checks passed")
exit(0)
