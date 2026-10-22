import Foundation

enum ReminderIntent: String, Codable, Sendable { case undecided, enabled, disabled }
enum OnboardingHabit: String, Codable, CaseIterable, Sendable { case desk, mobile, unchanged }
enum OnboardingTask: String, Codable, CaseIterable, Sendable { case none, open, lid }
enum SetupDecision: String, Codable, Sendable { case undecided, enabled, skipped }
enum SetupResult: String, Codable, Sendable {
    case idle, requested, confirmed, failed, unknown
    var localizationKey: String {
        switch self {
        case .idle: return "onboarding.result.idle"
        case .requested: return "onboarding.result.requested"
        case .confirmed: return "onboarding.result.confirmed"
        case .failed: return "onboarding.result.failed"
        case .unknown: return "onboarding.result.unknown"
        }
    }
}

/// A journal is durable before the corresponding external operation starts.
/// A requested operation surviving a process exit must be inspected, not replayed.
struct OnboardingRecord: Codable, Sendable {
    var schemaVersion = 1
    var flowVersion = 4
    var completed = false
    var existingUser = false
    var step = 0
    var habit: OnboardingHabit = .desk
    var task: OnboardingTask = .none
    var targetLimit = 80
    var helper: SetupDecision = .undecided
    var login: SetupDecision = .undecided
    var reminder: ReminderIntent = .undecided
    var charge: SetupResult = .idle
    var ordinary: SetupResult = .idle
    var lid: SetupResult = .idle
    var helperInstall: SetupResult = .idle
    var loginRegistration: SetupResult = .idle
    var notificationRequest: SetupResult = .idle
    var stopPending = false
    /// Nil preserves the conservative recovery contract for older stop journals.
    var stopLidRequired: Bool?
    var id = UUID()
    var generation: UInt64 = 0

    var hasApplicationAttempt: Bool { charge != .idle || ordinary != .idle || lid != .idle }
    mutating func recoverInterruptedRequests() {
        if charge == .requested { charge = .unknown }
        if ordinary == .requested { ordinary = .unknown }
        if lid == .requested { lid = .unknown }
        if helperInstall == .requested { helperInstall = .unknown }
        if loginRegistration == .requested { loginRegistration = .unknown }
        if notificationRequest == .requested { notificationRequest = .unknown }
    }
}

struct OnboardingStartup: Sendable {
    var record: OnboardingRecord
    var error: String?
    var requiresSetup: Bool { error != nil || !record.completed }
}

/// No singleton model, defaults mutation or localization is needed to classify a launch.
struct OnboardingStore: Sendable {
    let directory: URL
    var writeData: @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    var url: URL { directory.appendingPathComponent("onboarding.json") }
    var configURL: URL { directory.appendingPathComponent("config.json") }
    static var live: OnboardingStore { OnboardingStore(directory: ConfigStore.url.deletingLastPathComponent()) }

    func saveAsync(_ record: OnboardingRecord) async throws {
        try await PersistenceIO.shared.run { try save(record) }
    }

    func bootstrapAsync() async -> OnboardingStartup {
        // bootstrap reports storage errors in its value and preserves bad files.
        try! await PersistenceIO.shared.run { bootstrap() }
    }

    func save(_ record: OnboardingRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try writeData(encoder.encode(record), url)
    }

    func bootstrap() -> OnboardingStartup {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                var record = try JSONDecoder().decode(OnboardingRecord.self, from: Data(contentsOf: url))
                guard record.schemaVersion == 1, record.flowVersion <= 4 else {
                    return OnboardingStartup(record: record, error: "onboarding.storageUnsupported")
                }
                record.recoverInterruptedRequests()
                // Validate the config too. Never overwrite malformed user data.
                if FileManager.default.fileExists(atPath: configURL.path) { _ = try ConfigStore.read(at: configURL) }
                try save(record)
                return OnboardingStartup(record: record)
            }
            var record = OnboardingRecord()
            if FileManager.default.fileExists(atPath: configURL.path) {
                _ = try ConfigStore.read(at: configURL)
                record.existingUser = true
                record.completed = true
            }
            try save(record)
            return OnboardingStartup(record: record)
        } catch {
            return OnboardingStartup(record: OnboardingRecord(), error: "onboarding.storageFailed")
        }
    }
}
