import Foundation

/// Explainable smart-charging policy for macOS.
///
/// The OS-native limit only accepts 80-100%, so "smart" here means: hold 80%
/// while the Mac is expected to stay plugged in, and top up to 100% in the
/// hours before the predicted unplug time. The hourly AC-usage profile is
/// persisted in UserDefaults.
struct SmartPolicy {
    /// Charge targets are only meaningful from 0 (off) to 100 (full); config
    /// values outside that range are normalized before use.
    static let minLimit = 0
    static let maxLimit = 100

    var defaultLimit = 80
    var topupLimit = 100
    var topupLeadHours = 2
    var minSamplesPerHour = 3

    struct Decision {
        var target: Int
    }

    struct Profile {
        /// Maximum AC probability for an hour to qualify as an unplug hour.
        /// If the machine is always plugged in (e.g. desktop or permanently docked),
        /// no unplug is predicted so the battery is held at the default limit.
        static let maxUnplugACProbability: Double = 0.85
        /// Cap observations per bucket so older habits don't permanently overpower
        /// recent schedule shifts, and to prevent unbounded growth.
        static let maxObservationsPerBucket: Int = 1000

        var ac = [Int](repeating: 0, count: 24)
        var total = [Int](repeating: 0, count: 24)

        func probability(_ hour: Int) -> Double? {
            let h = ((hour % 24) + 24) % 24
            guard total[h] > 0 else { return nil }
            return Double(ac[h]) / Double(total[h])
        }

        /// Predicted unplug hour. Prioritizes the transition moment from AC to battery
        /// (the hour with the steepest drop in AC probability from the preceding hour,
        /// provided it qualifies as an unplug hour). If transitions are similar or
        /// unobserved, falls back to the lowest AC probability with higher confidence.
        func predictedUnplugHour(minSamples: Int) -> Int? {
            struct Candidate {
                let hour: Int
                let p: Double
                let total: Int
                let drop: Double? // p(h-1) - p(h), only when both buckets are trusted
            }

            var candidates: [Candidate] = []
            let requiredSamples = max(1, minSamples)
            for h in 0..<24 where total[h] >= requiredSamples {
                guard let p = probability(h) else { continue }
                guard p <= Self.maxUnplugACProbability else { continue }

                let prevH = (h + 23) % 24
                // Sleeping or quitting the app leaves holes in the profile. Missing
                // or sparse history cannot establish that the Mac was previously on AC.
                let prevP = total[prevH] >= requiredSamples ? probability(prevH) : nil
                let drop = prevP.map { $0 - p }
                candidates.append(Candidate(hour: h, p: p, total: total[h], drop: drop))
            }

            guard !candidates.isEmpty else { return nil }

            let maxDrop = candidates.compactMap(\.drop).max() ?? 0
            if maxDrop >= 0.25 {
                // Focus on candidates that represent a significant unplug transition
                let topTransitions = candidates.filter { candidate in
                    candidate.drop.map { $0 >= maxDrop - 0.05 } ?? false
                }
                return topTransitions.min { a, b in
                    if abs(a.p - b.p) > 0.0001 { return a.p < b.p }
                    if a.total != b.total { return a.total > b.total }
                    return a.hour < b.hour
                }?.hour
            }

            // Fallback: lowest probability, then highest sample count, then lowest hour
            return candidates.min { a, b in
                if abs(a.p - b.p) > 0.0001 { return a.p < b.p }
                if a.total != b.total { return a.total > b.total }
                return a.hour < b.hour
            }?.hour
        }

        mutating func observe(hour: Int, onAC: Bool) {
            let h = ((hour % 24) + 24) % 24
            if total[h] >= Self.maxObservationsPerBucket {
                // Soft decay: halve counts to preserve relative distribution while
                // letting new schedule shifts take effect.
                total[h] /= 2
                ac[h] /= 2
            }
            total[h] += 1
            if onAC { ac[h] += 1 }
        }
    }

    /// Clamp a charge target into `minLimit...maxLimit`, tolerating invalid
    /// (e.g. hand-edited) config values.
    private func clamp(_ value: Int) -> Int {
        min(max(value, SmartPolicy.minLimit), SmartPolicy.maxLimit)
    }

    func decide(hour: Int, profile: Profile) -> Decision {
        let h = ((hour % 24) + 24) % 24
        guard let unplug = profile.predictedUnplugHour(minSamples: minSamplesPerHour) else {
            return Decision(target: clamp(defaultLimit))
        }
        let lead = min(23, max(0, topupLeadHours))
        var inTopup = false
        if lead > 0 {
            // Top up strictly *before* the predicted unplug hour; the unplug hour
            // itself is never included in the window.
            inTopup = (1...lead).contains { k in ((unplug + 24 - k) % 24) == h }
        }
        if inTopup {
            return Decision(target: clamp(topupLimit))
        }
        return Decision(target: clamp(defaultLimit))
    }
}
