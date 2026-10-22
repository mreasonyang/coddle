import Foundation

/// Pure, testable core of the away detector.
///
/// `AwayEngine` (NetworkWatch.swift) owns the timer, the SystemConfiguration
/// reads and the sleep/wake notifications; *all* of the decision logic lives
/// here so it can be exercised without a network, a clock or a run loop:
///
///   * learning which networks are "usual" from cumulative awake dwell,
///   * the `awayAfterMinutes` delay before a new network counts as "away",
///   * the offline backstop (`offlineAwayAfterMinutes`),
///   * never declaring away while there is no model at all (warm-up).
///
/// A VPN/tunnel is deliberately *not* part of a fingerprint (see
/// `networkFingerprintIsPhysical`), so a tunnel can never become — or displace —
/// the "usual" network.
struct AwayDetector {
    struct Configuration {
        var usualMinDwellSeconds = 7200
        var awayAfterMinutes = 15
        var offlineAwayAfterMinutes = 10
        var usualFingerprints: [String] = []
    }

    /// One decision, in the shape the engine publishes (fingerprint still raw).
    struct Verdict {
        var key: String?
        var isAway = false
        var isUsual = false
        var awayForSeconds: TimeInterval = 0
        var protectionReady = false
        var learningRemainingSeconds: TimeInterval = 0
        var waitingRemainingSeconds: TimeInterval = 0
    }

    var config = Configuration()

    /// Cumulative awake seconds per fingerprint. Persisted by the engine.
    private(set) var dwell: [String: Double] = [:]

    /// The previous published verdict, used as the seed for the offline case.
    private(set) var isAway = false

    private var lastKey: String?
    private var lastTickAt: Date?
    private var currentUnusualSince: Date?
    private var offlineSince: Date?
    private var awaySince: Date?

    init() {}

    /// Deterministic 6-hex-char hash of a full key, for compact UI display and matching.
    static func shortHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325   // FNV-1a 64
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01b3
        }
        return String(format: "%06x", UInt32(truncatingIfNeeded: h) & 0xFF_FFFF)
    }

    /// The learned "usual" set: any fingerprint with at least `minDwellSeconds`
    /// of cumulative dwell, plus the manual allowlist.
    ///
    /// Manual entries can be either raw keys (e.g. "mac:00:11:22:33:44:55") or
    /// the compact 6-character short hash displayed in the UI (e.g. "a3f89b").
    static func usualKeys(
        dwell: [String: Double],
        minDwellSeconds: Int,
        manual: [String]
    ) -> Set<String> {
        let min = Double(max(0, minDwellSeconds))
        var usual = Set<String>()
        for (key, seconds) in dwell where seconds >= min { usual.insert(key) }
        for key in manual {
            usual.insert(key)
            usual.insert(key.lowercased())
        }
        return usual
    }

    func usualSet() -> Set<String> {
        AwayDetector.usualKeys(
            dwell: dwell,
            minDwellSeconds: config.usualMinDwellSeconds,
            manual: config.usualFingerprints)
    }

    /// Seed the persisted dwell model (called once at engine start).
    mutating func load(dwell: [String: Double]) {
        self.dwell = dwell
    }

    /// Credit the segment that just ended to the previous key. `dt` is capped so
    /// a missed timer or a suspend/resume can never inflate dwell.
    mutating func creditDwell(now: Date, capSeconds: Double) {
        guard let key = lastKey, let tickAt = lastTickAt else { return }
        let dt = max(0, min(now.timeIntervalSince(tickAt), capSeconds))
        dwell[key, default: 0] += dt
        lastTickAt = now
    }

    /// One sampling step for the given fingerprint (`nil` == offline). Mirrors
    /// the engine's original `tick()` decision exactly.
    mutating func sample(key rawKey: String?, now: Date) -> Verdict {
        let usual = usualSet()
        let hasModel = !usual.isEmpty

        var away = isAway
        if let key = rawKey {
            offlineSince = nil
            let isUsualKey = usual.contains(key) || usual.contains(Self.shortHash(key))
            if isUsualKey {
                away = false
                currentUnusualSince = nil
            } else {
                if !away {
                    currentUnusualSince = currentUnusualSince ?? now
                    if let since = currentUnusualSince {
                        away = now.timeIntervalSince(since) >= Double(max(0, config.awayAfterMinutes)) * 60
                    }
                }
            }
        } else {
            // Offline: drop any partial "unusual" clock so the away timer cannot
            // straddle the whole offline window and fire the instant we reconnect.
            currentUnusualSince = nil
            // Keep the previous answer until the grace window expires.
            if !away {
                offlineSince = offlineSince ?? now
                if let since = offlineSince,
                   now.timeIntervalSince(since) >= Double(max(0, config.offlineAwayAfterMinutes)) * 60 {
                    away = true
                }
            }
        }

        // Warm-up: with no learned or manual usual network, never declare away.
        if !hasModel { away = false }

        if away && awaySince == nil { awaySince = now }
        if !away { awaySince = nil }

        lastKey = rawKey
        lastTickAt = now
        isAway = away

        let isUsual = rawKey.map { usual.contains($0) || usual.contains(Self.shortHash($0)) } ?? false

        return Verdict(
            key: rawKey,
            isAway: away,
            isUsual: isUsual,
            awayForSeconds: away ? now.timeIntervalSince(awaySince ?? now) : 0,
            protectionReady: hasModel,
            learningRemainingSeconds: max(0, Double(config.usualMinDwellSeconds) - (dwell.values.max() ?? 0)),
            waitingRemainingSeconds: away || isUsual ? 0 : max(0,
                Double(rawKey == nil ? config.offlineAwayAfterMinutes : config.awayAfterMinutes) * 60 -
                now.timeIntervalSince((rawKey == nil ? offlineSince : currentUnusualSince) ?? now)))
    }

    /// Flush the current segment, then stop crediting time until wake.
    ///
    /// In-progress timers (while not yet away) are dropped so sleep time is not
    /// credited towards the away delay. If already away, that state is preserved
    /// across sleep and DarkWake cycles so bag guard does not flap.
    mutating func noteWillSleep(now: Date, capSeconds: Double) {
        creditDwell(now: now, capSeconds: capSeconds)
        lastTickAt = nil
        resetAwayClocks()
    }

    /// Resume crediting from now (the next sample starts a fresh segment), and
    /// drop any in-progress away/offline clock so a suspend gap cannot make
    /// `isAway` fire prematurely.
    mutating func noteDidWake(now: Date) {
        lastTickAt = now
        resetAwayClocks()
    }

    /// Forget in-progress away/offline transition timers so sleep time is never
    /// counted towards the delay. If already away, keep isAway true so DarkWake
    /// or periodic maintenance wake does not re-enable keep-awake/disablesleep.
    private mutating func resetAwayClocks() {
        currentUnusualSince = nil
        offlineSince = nil
        if !isAway {
            awaySince = nil
        }
    }
}

/// Physical network interfaces only. Tunnels (utun/ipsec/ppp) are ignored on
/// purpose, so a VPN can never become part of — or replace — the network
/// fingerprint used for "usual" learning. Extracted from
/// `NetworkFingerprintReader.isPhysical` so it is unit-testable.
func networkFingerprintIsPhysical(_ name: String) -> Bool {
    name.hasPrefix("en") || name.hasPrefix("bridge")
        || name.hasPrefix("eth") || name.hasPrefix("thunderbolt")
}
