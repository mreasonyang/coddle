import Foundation

/// Persisted, user-editable configuration.
///
/// Stored at `~/Library/Application Support/Coddle/config.json` so it can be
/// edited by hand as well as from the app panel. All fields have safe defaults
/// and the decoder is *tolerant*: missing keys fall back to their default
/// without resetting keys that are present. This keeps old config files working
/// when new fields are added.
struct CoddleConfig: Sendable {
    /// Charge limit held while the Mac is expected to stay plugged in (%).
    var holdLimit: Int = 80
    /// Target charge limit when smart charging is disabled (0 means off/disabled, otherwise 80...100).
    var manualLimit: Int = 80
    /// Charge limit allowed in the pre-unplug window (%).
    var topupLimit: Int = 100
    /// How many hours before the predicted unplug time to start topping up.
    var topupLeadHours: Int = 2
    /// Minimum observed samples per hour before a usage pattern is trusted.
    var minSamplesPerHour: Int = 3
    /// Battery/limit refresh interval, seconds.
    var refreshSeconds: Int = 5
    /// Smart charging enabled.
    var smartEnabled: Bool = false
    /// Menu bar shows only the icon (no percentage).
    var iconOnly: Bool = false
    /// Also show the app in the Dock (a normal, activatable app).
    var showInDock: Bool = false
    /// Show the menu-bar status item. At least one of this / showInDock is kept on.
    var showMenuBarIcon: Bool = true
    /// UI language: "system" or one of en, zh-Hans, zh-Hant, ja, ko, es.
    var language: String = "system"
    /// Visual theme: "liquidGlass" (default) or "classic".
    var theme: String = "liquidGlass"
    /// Master keep-awake intent; display and lid options require this to be on.
    var keepAwake: Bool = false
    /// Saved lid preference, retained while keepAwake is OFF (needs the helper).
    var keepAwakeOnLidClosed: Bool = false

    // MARK: Agent Mode part 2 — away detection / bag guard / low battery / display

    /// Master switch for away detection (the "away guard").
    var awayDetectionEnabled: Bool = true
    /// Network fingerprint poll interval, seconds.
    var networkSampleSeconds: Int = 30
    /// Cumulative awake dwell before a network counts as "usual", seconds.
    var usualMinDwellSeconds: Int = 7200
    /// How long off the usual network before `isAway`, minutes.
    var awayAfterMinutes: Int = 15
    /// Continuous offline before `isAway` (backstop), minutes.
    var offlineAwayAfterMinutes: Int = 10
    /// HID idle threshold for the bag-guard predicate, seconds.
    var idleSeconds: Int = 120
    /// Only allow sleep (bag guard) when on battery, not on AC.
    var requireBattery: Bool = true
    /// Warn (notification only) when on battery at or below this percent.
    var lowBatteryWarnPercent: Int = 20
    /// nil is an unmigrated old configuration, never permission to send.
    var lowBatteryReminder: ReminderIntent? = nil
    /// Saved display preference, retained while keepAwake is OFF.
    var keepDisplayAwake: Bool = false
    /// Manual allowlist of fingerprints to always treat as "usual".
    var usualFingerprints: [String] = []
}

extension CoddleConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case holdLimit, manualLimit, topupLimit, topupLeadHours, minSamplesPerHour
        case refreshSeconds, smartEnabled, iconOnly
        case showInDock, showMenuBarIcon, language, theme
        case keepAwake, keepAwakeOnLidClosed, keepDisplayAwake
        case awayDetectionEnabled, networkSampleSeconds, usualMinDwellSeconds
        case awayAfterMinutes, offlineAwayAfterMinutes, idleSeconds
        case requireBattery, lowBatteryWarnPercent, lowBatteryReminder
        case usualFingerprints
    }

    /// Tolerant decode: every field is optional and falls back to its default,
    /// so an older/partial config file never resets sibling keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CoddleConfig()
        holdLimit = try c.decodeIfPresent(Int.self, forKey: .holdLimit) ?? d.holdLimit
        manualLimit = try c.decodeIfPresent(Int.self, forKey: .manualLimit) ?? d.manualLimit
        topupLimit = try c.decodeIfPresent(Int.self, forKey: .topupLimit) ?? d.topupLimit
        topupLeadHours = try c.decodeIfPresent(Int.self, forKey: .topupLeadHours) ?? d.topupLeadHours
        minSamplesPerHour = try c.decodeIfPresent(Int.self, forKey: .minSamplesPerHour) ?? d.minSamplesPerHour
        refreshSeconds = try c.decodeIfPresent(Int.self, forKey: .refreshSeconds) ?? d.refreshSeconds
        smartEnabled = try c.decodeIfPresent(Bool.self, forKey: .smartEnabled) ?? d.smartEnabled
        iconOnly = try c.decodeIfPresent(Bool.self, forKey: .iconOnly) ?? d.iconOnly
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? d.showInDock
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? d.showMenuBarIcon
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? d.theme
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? d.keepAwake
        keepAwakeOnLidClosed = try c.decodeIfPresent(Bool.self, forKey: .keepAwakeOnLidClosed) ?? d.keepAwakeOnLidClosed
        awayDetectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .awayDetectionEnabled) ?? d.awayDetectionEnabled
        networkSampleSeconds = try c.decodeIfPresent(Int.self, forKey: .networkSampleSeconds) ?? d.networkSampleSeconds
        usualMinDwellSeconds = try c.decodeIfPresent(Int.self, forKey: .usualMinDwellSeconds) ?? d.usualMinDwellSeconds
        awayAfterMinutes = try c.decodeIfPresent(Int.self, forKey: .awayAfterMinutes) ?? d.awayAfterMinutes
        offlineAwayAfterMinutes = try c.decodeIfPresent(Int.self, forKey: .offlineAwayAfterMinutes) ?? d.offlineAwayAfterMinutes
        idleSeconds = try c.decodeIfPresent(Int.self, forKey: .idleSeconds) ?? d.idleSeconds
        requireBattery = try c.decodeIfPresent(Bool.self, forKey: .requireBattery) ?? d.requireBattery
        lowBatteryWarnPercent = try c.decodeIfPresent(Int.self, forKey: .lowBatteryWarnPercent) ?? d.lowBatteryWarnPercent
        lowBatteryReminder = try c.decodeIfPresent(ReminderIntent.self, forKey: .lowBatteryReminder)
        keepDisplayAwake = try c.decodeIfPresent(Bool.self, forKey: .keepDisplayAwake) ?? d.keepDisplayAwake
        usualFingerprints = try c.decodeIfPresent([String].self, forKey: .usualFingerprints) ?? d.usualFingerprints
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(holdLimit, forKey: .holdLimit)
        try c.encode(manualLimit, forKey: .manualLimit)
        try c.encode(topupLimit, forKey: .topupLimit)
        try c.encode(topupLeadHours, forKey: .topupLeadHours)
        try c.encode(minSamplesPerHour, forKey: .minSamplesPerHour)
        try c.encode(refreshSeconds, forKey: .refreshSeconds)
        try c.encode(smartEnabled, forKey: .smartEnabled)
        try c.encode(iconOnly, forKey: .iconOnly)
        try c.encode(showInDock, forKey: .showInDock)
        try c.encode(showMenuBarIcon, forKey: .showMenuBarIcon)
        try c.encode(language, forKey: .language)
        try c.encode(theme, forKey: .theme)
        try c.encode(keepAwake, forKey: .keepAwake)
        try c.encode(keepAwakeOnLidClosed, forKey: .keepAwakeOnLidClosed)
        try c.encode(awayDetectionEnabled, forKey: .awayDetectionEnabled)
        try c.encode(networkSampleSeconds, forKey: .networkSampleSeconds)
        try c.encode(usualMinDwellSeconds, forKey: .usualMinDwellSeconds)
        try c.encode(awayAfterMinutes, forKey: .awayAfterMinutes)
        try c.encode(offlineAwayAfterMinutes, forKey: .offlineAwayAfterMinutes)
        try c.encode(idleSeconds, forKey: .idleSeconds)
        try c.encode(requireBattery, forKey: .requireBattery)
        try c.encode(lowBatteryWarnPercent, forKey: .lowBatteryWarnPercent)
        try c.encodeIfPresent(lowBatteryReminder, forKey: .lowBatteryReminder)
        try c.encode(keepDisplayAwake, forKey: .keepDisplayAwake)
        try c.encode(usualFingerprints, forKey: .usualFingerprints)
    }
}

extension CoddleConfig {
    /// Safety net for hand-edited configs: never allow both entry points
    /// (`showInDock` / `showMenuBarIcon`) to be off at once, and normalize
    /// numeric fields into valid ranges. Pure — no disk access — so it can be
    /// unit-tested; `ConfigStore.load()` calls it after decoding.
    func sanitized() -> CoddleConfig {
        var c = self
        if !c.showInDock && !c.showMenuBarIcon { c.showMenuBarIcon = true }
        if c.manualLimit <= 0 {
            c.manualLimit = 0
        } else {
            c.manualLimit = min(100, max(80, c.manualLimit))
        }
        c.holdLimit = min(100, max(0, c.holdLimit))
        c.topupLimit = min(100, max(c.holdLimit, c.topupLimit))
        c.topupLeadHours = min(23, max(0, c.topupLeadHours))
        c.minSamplesPerHour = max(1, c.minSamplesPerHour)
        c.refreshSeconds = max(1, c.refreshSeconds)
        c.networkSampleSeconds = max(5, c.networkSampleSeconds)
        c.usualMinDwellSeconds = max(0, c.usualMinDwellSeconds)
        c.lowBatteryWarnPercent = min(100, max(1, c.lowBatteryWarnPercent))
        c.idleSeconds = max(0, c.idleSeconds)
        c.awayAfterMinutes = max(1, c.awayAfterMinutes)
        c.offlineAwayAfterMinutes = max(1, c.offlineAwayAfterMinutes)
        if c.theme != "liquidGlass" && c.theme != "classic" {
            c.theme = "liquidGlass"
        }
        return c
    }
}

enum ConfigStore {
    static func readAsync(at location: URL = url) async throws -> CoddleConfig {
        try await PersistenceIO.shared.run { try read(at: location) }
    }

    static func saveAsync(_ cfg: CoddleConfig, at location: URL = url) async throws {
        try await PersistenceIO.shared.run { try save(cfg, at: location) }
    }
    static var url: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Coddle", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    /// Pure decode used by `load()`: returns nil when the bytes are not valid
    /// JSON (or a field has the wrong type) so the caller can fall back to a
    /// default config. Unknown fields are ignored; missing fields take their
    /// defaults (see `init(from:)`).
    static func decode(_ data: Data) -> CoddleConfig? {
        (try? JSONDecoder().decode(CoddleConfig.self, from: data))?.sanitized()
    }

    /// Read without mutating an existing file, including when it is invalid.
    static func read(at location: URL = url) throws -> CoddleConfig {
        guard FileManager.default.fileExists(atPath: location.path) else {
            return CoddleConfig().sanitized()
        }
        return try JSONDecoder().decode(CoddleConfig.self, from: Data(contentsOf: location)).sanitized()
    }

    /// Used only to choose the initial localization, before AppModel reports errors.
    static func load() -> CoddleConfig { (try? read()) ?? CoddleConfig().sanitized() }

    static func save(_ cfg: CoddleConfig, at location: URL = url) throws {
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try enc.encode(cfg)
        data.append(0x0a)
        try data.write(to: location, options: .atomic)
    }
}

/// Configuration and setup journals share one ordered executor. Blocking file
/// operations never occupy the UI actor, and a completed await means the atomic
/// replacement finished before a caller may apply its associated system effect.
final class PersistenceIO: @unchecked Sendable {
    static let shared = PersistenceIO()
    private let queue = DispatchQueue(label: "com.coddle.persistence", qos: .utility)

    func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }
}
