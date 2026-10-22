import Foundation
import AppKit
import SystemConfiguration

/// A snapshot of the away engine's state, consumed by the UI / `AppModel`.
///
/// `isAway` is only true when the current network has *not* been "usual" for at
/// least `awayAfterMinutes` (or the Mac has been offline for
/// `offlineAwayAfterMinutes`). It never flips simply because a VPN came up.
struct AwayStatus: Equatable {
    /// Short, stable hash of the current fingerprint (nil while offline/unknown).
    var fingerprint: String? = nil
    /// The current network has not been usual for long enough.
    var isAway: Bool = false
    /// Seconds since `isAway` became true (0 when not away).
    var awayForSeconds: TimeInterval = 0
    /// A tunnel owns the global default route.
    var vpnActive: Bool = false
    /// The current network is in the learned/manual "usual" set.
    var isUsual: Bool = false
    var protectionReady = false
    var learningRemainingSeconds: TimeInterval = 0
    var waitingRemainingSeconds: TimeInterval = 0
    /// A cached verdict must not drive a new guard transition until a sample
    /// has been accepted under the current configuration.
    var configurationSamplePending = false
}

/// Reads the SystemConfiguration `NetworkSignature` for the *physical* service.
///
/// The value is already computed by macOS and carries the router IP plus the
/// gateway MAC (`IPv4.RouterHardwareAddress`), which is a stable "which network
/// am I on" signal. `NetworkSignatureHash` (20-byte Data) is the fallback key.
enum NetworkFingerprintReader {
    private static let queue = DispatchQueue(label: "com.coddle.network-sampling", qos: .utility)

    static func readAsync(preferredPhysicalKey: String? = nil) async -> NetworkFingerprint {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: read(preferredPhysicalKey: preferredPhysicalKey)) }
        }
    }

    private static func createStore() -> SCDynamicStore? {
        SCDynamicStoreCreate(nil, "Coddle" as CFString, nil, nil)
    }

    private static func read(preferredPhysicalKey: String? = nil) -> NetworkFingerprint {
        guard let ds = createStore() else { return NetworkFingerprint() }

        func primary(_ family: String) -> String? {
            let global = SCDynamicStoreCopyValue(ds, "State:/Network/Global/\(family)" as CFString) as? [String: Any]
            return global?["PrimaryInterface"] as? String
        }
        func services(_ family: String) -> [[String: Any]] {
            let pattern = "State:/Network/Service/.*/\(family)" as CFString
            let keys = SCDynamicStoreCopyKeyList(ds, pattern) as? [String] ?? []
            return keys.sorted().compactMap {
                SCDynamicStoreCopyValue(ds, $0 as CFString) as? [String: Any]
            }
        }

        // Absence of IPv4 must not short-circuit an IPv6-only connection.
        return NetworkFingerprintParser.parse(
            ipv4Primary: primary("IPv4"), ipv4Services: services("IPv4"),
            ipv6Primary: primary("IPv6"), ipv6Services: services("IPv6"),
            preferredPhysicalKey: preferredPhysicalKey)
    }

    /// Deterministic 6-hex-char hash of a full key, for compact UI display.
    static func shortHash(_ s: String) -> String {
        AwayDetector.shortHash(s)
    }
}

/// Persistence for the learned dwell model. Kept in UserDefaults (not in
/// config.json) so hand-editing the config never wipes what the app learned —
/// the same split the app already uses for `profile.ac/total`.
private enum DwellStore {
    static let key = "away.dwell"
    private static let queue = DispatchQueue(label: "com.coddle.away-persistence", qos: .utility)
    // Accessed only on queue; encode and persistence never delay a UI event.
    private static var lastSavedDwell: [String: Double]? = nil

    static func load() async -> [String: Double] {
        await withCheckedContinuation { continuation in
            queue.async {
                let map: [String: Double]
                if let data = UserDefaults.standard.data(forKey: key),
                   let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
                    map = decoded
                } else { map = [:] }
                lastSavedDwell = map
                continuation.resume(returning: map)
            }
        }
    }

    static func save(_ map: [String: Double]) {
        queue.async {
            if let last = lastSavedDwell, last == map { return }
            guard let data = try? JSONEncoder().encode(map) else { return }
            UserDefaults.standard.set(data, forKey: key)
            lastSavedDwell = map
        }
    }
}

/// Samples the network fingerprint on a timer, learns which networks are
/// "usual" by cumulative awake dwell, and publishes an `AwayStatus`.
///
/// The engine owns its own timer and observes sleep/wake so a suspend gap can
/// never inflate dwell or the away timer. All state transitions are computed on
/// the main thread. SystemConfiguration snapshots are collected off that actor;
/// a result only applies to the configuration/sleep generation that requested it.
@MainActor
final class AwayEngine: NSObject {
    struct Configuration {
        var enabled = true
        var sampleSeconds = 30
        var usualMinDwellSeconds = 7200
        var awayAfterMinutes = 15
        var offlineAwayAfterMinutes = 10
        var usualFingerprints: [String] = []
    }

    private(set) var status = AwayStatus()
    /// Called on the main thread whenever `status` changes.
    var onUpdate: ((AwayStatus) -> Void)?

    private var config = Configuration()
    private var timer: Timer?
    /// Pure decision core (dwell model + away timers). The engine only supplies
    /// the clock and the fingerprint.
    private var detector = AwayDetector()
    private var lastPhysicalKey: String?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private let notifications: NotificationCenter
    private let readFingerprint: @Sendable (String?) async -> NetworkFingerprint
    private let loadDwell: @Sendable () async -> [String: Double]
    private var dwellLoaded = false
    private let saveDwell: ([String: Double]) -> Void
    private let scheduleTimers: Bool
    private var samplingTask: Task<Void, Never>?
    private var sampleRequested = false
    private var generation: UInt64 = 0
    private var sleeping = false
    private var stopped = false

    init(readFingerprint: @escaping @Sendable (String?) async -> NetworkFingerprint = {
             await NetworkFingerprintReader.readAsync(preferredPhysicalKey: $0)
         },
         loadDwell: @escaping @Sendable () async -> [String: Double] = { await DwellStore.load() },
         saveDwell: @escaping ([String: Double]) -> Void = { DwellStore.save($0) },
         notifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         scheduleTimers: Bool = true) {
        self.readFingerprint = readFingerprint
        self.loadDwell = loadDwell
        self.saveDwell = saveDwell
        self.notifications = notifications
        self.scheduleTimers = scheduleTimers
        super.init()
        sleepObserver = notifications.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWillSleep() }
        }
        wakeObserver = notifications.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDidWake() }
        }
    }

    isolated deinit {
        timer?.invalidate()
        if let s = sleepObserver { notifications.removeObserver(s) }
        if let w = wakeObserver { notifications.removeObserver(w) }
    }

    /// Apply new config: restart the timer and re-evaluate immediately.
    func update(config: Configuration) {
        generation &+= 1
        stopped = false
        sampleRequested = false
        self.config = config
        status.configurationSamplePending = config.enabled
        detector.config = AwayDetector.Configuration(
            usualMinDwellSeconds: config.usualMinDwellSeconds,
            awayAfterMinutes: config.awayAfterMinutes,
            offlineAwayAfterMinutes: config.offlineAwayAfterMinutes,
            usualFingerprints: config.usualFingerprints)
        restartTimer()
        tick()
    }

    /// Stop the timer (used when away detection is disabled or on quit).
    func stop() {
        stopped = true
        generation &+= 1
        sampleRequested = false
        timer?.invalidate()
        timer = nil
    }

    /// Lets callers/tests await accepted sampling without performing a live read.
    func waitForPendingSample() async {
        while let task = samplingTask { await task.value }
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard config.enabled, !stopped, scheduleTimers else { return }
        let seconds = Double(max(5, config.sampleSeconds))
        let t = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// One sampling step. `dt` is capped to the sample interval so a missed
    /// timer or a suspend/resume can never inflate dwell or the away timer.
    private func tick() {
        guard config.enabled, !stopped, !sleeping else { return }
        sampleRequested = true
        guard samplingTask == nil else { return }
        sampleRequested = false
        let requestedGeneration = generation
        let preferredKey = lastPhysicalKey
        let read = readFingerprint
        let load = loadDwell
        let needsLoad = !dwellLoaded
        samplingTask = Task { [weak self] in
            let loadedDwell: [String: Double]? = needsLoad ? await load() : nil
            guard let self else { return }
            // The persisted model belongs to this engine, not to a configuration
            // generation. Keep it if configuration changed during the async load.
            if let loadedDwell {
                self.detector.load(dwell: loadedDwell)
                self.dwellLoaded = true
            }
            guard self.generation == requestedGeneration, self.config.enabled, !self.stopped, !self.sleeping else {
                self.samplingTask = nil
                if self.sampleRequested { self.tick() }
                return
            }
            let fp = await read(preferredKey)
            self.samplingTask = nil
            if self.generation == requestedGeneration, self.config.enabled, !self.stopped, !self.sleeping {
                self.accept(fp)
            }
            if self.sampleRequested { self.tick() }
        }
    }

    private func accept(_ fp: NetworkFingerprint) {
        let now = Date()
        lastPhysicalKey = fp.key
        let cap = Double(max(5, config.sampleSeconds))

        // 1. Account dwell for the previous segment (awake time only).
        detector.creditDwell(now: now, capSeconds: cap)

        // 2. Learn "usual" + decide away (in the pure core).
        let verdict = detector.sample(key: fp.key, now: now)

        var next = AwayStatus()
        next.fingerprint = verdict.key.map(NetworkFingerprintReader.shortHash)
        next.isAway = verdict.isAway
        next.awayForSeconds = verdict.awayForSeconds
        next.vpnActive = fp.vpnActive
        next.isUsual = verdict.isUsual
        next.protectionReady = verdict.protectionReady
        next.learningRemainingSeconds = verdict.learningRemainingSeconds
        next.waitingRemainingSeconds = verdict.waitingRemainingSeconds

        // Publish only when a UI-visible value changes. `awayForSeconds` keeps
        // ticking while away, so compare it at the displayed (whole-minute)
        // resolution — comparing exact seconds would look "changed" every sample
        // and churn the UI and the bag-guard on every tick.
        let changed = next.configurationSamplePending != status.configurationSamplePending
            || next.fingerprint != status.fingerprint
            || next.isAway != status.isAway
            || next.vpnActive != status.vpnActive
            || next.isUsual != status.isUsual
            || next.protectionReady != status.protectionReady
            || Int(next.learningRemainingSeconds / 60) != Int(status.learningRemainingSeconds / 60)
            || Int(next.waitingRemainingSeconds / 60) != Int(status.waitingRemainingSeconds / 60)
            || Int(next.awayForSeconds / 60) != Int(status.awayForSeconds / 60)
        status = next
        saveDwell(detector.dwell)
        if changed { onUpdate?(next) }
    }

    // MARK: - Sleep / wake

    @objc private func handleWillSleep() {
        generation &+= 1
        sleeping = true
        sampleRequested = false
        // Never overwrite persisted learning with the empty startup detector
        // while its initial read is still in flight.
        guard dwellLoaded else { return }
        // Flush the current segment, then stop crediting time until wake.
        detector.noteWillSleep(now: Date(), capSeconds: Double(max(5, config.sampleSeconds)))
        saveDwell(detector.dwell)
    }

    @objc private func handleDidWake() {
        sleeping = false
        detector.noteDidWake(now: Date())
        tick()
    }
}
