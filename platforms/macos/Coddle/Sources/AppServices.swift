import AppKit
import Foundation
import ServiceManagement

/// Blocking helper operations can run outside the UI actor. Keeping this
/// boundary explicit also lets lifecycle tests hold an installation in flight.
struct HelperOperations: Sendable {
    var isInstalled: @Sendable () -> Bool
    var setDisablesleep: @Sendable (Bool) -> Result<Void, HelperError>
    var setPowerMode: @Sendable (Int) -> Result<Void, HelperError>
    var install: @Sendable () -> Result<Void, HelperError>
    var waitForHelper: @Sendable () -> Bool
    var uninstall: @Sendable () -> Result<Void, HelperError>

    var filesPresent: @Sendable () -> Bool = { false }
    var inspectCapabilities: @Sendable () -> HelperReadiness = { .absent }
    var readSleepDisabled: @Sendable () -> Bool? = { nil }

    static let live = HelperOperations(
        isInstalled: { HelperManager.isInstalled() },
        setDisablesleep: { HelperManager.setDisablesleep($0) },
        setPowerMode: { HelperManager.setPowerMode($0) },
        install: { HelperManager.install() },
        waitForHelper: { HelperManager.waitForHelper() },
        uninstall: { HelperManager.uninstall() }, filesPresent: { HelperManager.filesPresent() },
        inspectCapabilities: { HelperManager.inspectCapabilities() },
        readSleepDisabled: { HelperManager.sleepDisabledFromPmset() })
}

/// System boundaries for the real AppModel. Tests supply isolated stores and
/// hardware doubles; they execute the same model and event handlers as the app.
@MainActor
struct AppServices {
    var loadConfig: () async throws -> CoddleConfig
    var saveConfig: (CoddleConfig) async throws -> Void
    var defaults: UserDefaults
    var readHardware: () async -> Result<HardwareSnapshot, HardwareFailure>
    var subscribeHardwareRecovery: (@escaping @MainActor () -> Void) -> Void
    var idleSeconds: () -> TimeInterval
    var screenLocked: () -> Bool
    var now: () -> TimeInterval
    var chargeOverrideState: () -> UInt64?
    var subscribeChargeOverride: (@escaping () -> Void) -> Void
    var setLimit: (Int) async -> HardwareFailure?
    var disableLimit: () async -> HardwareFailure?
    var chargeToFullNow: () async -> HardwareFailure?
    var readSignificantEnergyApps: () async -> [SignificantEnergyApp]
    var setSystemAwake: (Bool) async -> Bool
    var setDisplayAwake: (Bool) async -> Bool
    var configureAway: (AwayEngine.Configuration) -> AwayStatus
    var subscribeAway: (@escaping (AwayStatus) -> Void) -> Void
    var stopAway: () -> Void
    var helper: HelperOperations
    var showDockIcon: (Bool) -> Void
    var setLanguage: (String) -> Void
    var translate: (String) -> String
    var notifyLowBattery: (Int) -> Void
    var loginStatus: () async -> SMAppService.Status
    var setLogin: (Bool) async throws -> Void
    var workspaceNotifications: NotificationCenter
    var applicationNotifications: NotificationCenter
    var scheduleTimers: Bool
    var energySampleStatus: () -> String = { "energySample.ready" }
    var notificationStatus: () async -> String = { "notification.unknown" }
    var testNotification: () async -> String = { "notification.unknown" }
    var requestNotification: () async -> String = { "notification.unavailable" }
    var setReminderIntent: (ReminderIntent) -> Void = { _ in }
    var systemAssertionActive: () async -> Bool? = { nil }
    var displayAssertionActive: () async -> Bool? = { nil }
    var sleepDisplays: () async -> DisplaySleepResult = { .failed }
    var openDisplaySettings: () -> Bool = { false }
    var currentNetworkFingerprint: () async -> String? = { nil }
    var openLoginSettings: () -> Bool = { false }
    var openNotificationSettings: () -> Bool = { false }

    static func live() -> AppServices {
        #if CODDLE_TESTING
        preconditionFailure("Tests must inject AppServices; live hardware is forbidden.")
        #else
        let io = HardwareIO(label: "com.coddle.hardware")
        let assertions = KeepAwakeWorker()
        let login = LoginItemWorker()
        let away = AwayEngine()
        let override = ChargeOverrideMonitor()
        let notifications = LowBatteryNotifier()
        return AppServices(
            loadConfig: { try await ConfigStore.readAsync() }, saveConfig: { try await ConfigStore.saveAsync($0) },
            defaults: .standard,
            readHardware: {
                await io.run {
                    let supported = PowerUI.isSupported
                    let limit = supported ? PowerUI.current() : nil
                    let lid = readClamshellState()
                    return HardwareSnapshot(battery: systemBatterySnapshot(),
                        clamshellClosed: lid?.closed, clamshellCausesSleep: lid?.causesSleep,
                        supportsLimit: supported, availableLimits: supported ? PowerUI.availableLimits() : [],
                        currentLimit: limit?.limit, limitEnabled: limit?.enabled ?? false,
                        supportsTemporaryFullCharge: supported && PowerUI.supportsTemporaryFullCharge,
                        availableEnergyModes: HelperManager.availableEnergyModes(),
                        energyMode: HelperManager.powerModeFromPmset())
                }
            },
            subscribeHardwareRecovery: { handler in
                io.onRecovery { Task { @MainActor in handler() } }
            },
            idleSeconds: { secondsSinceUserInput() }, screenLocked: { isScreenLocked() },
            now: { ProcessInfo.processInfo.systemUptime },
            chargeOverrideState: { override.state() },
            subscribeChargeOverride: { override.onChange = $0 },
            setLimit: { value in
                switch await io.run({ PowerUI.set(value) }) {
                case .success(let error): return error.map { HardwareFailure(message: $0) }
                case .failure(let error): return error
                }
            },
            disableLimit: {
                switch await io.run({ PowerUI.disable() }) {
                case .success(let error): return error.map { HardwareFailure(message: $0) }
                case .failure(let error): return error
                }
            },
            chargeToFullNow: {
                switch await io.run({ PowerUI.chargeToFullNow() }) {
                case .success(let error): return error.map { HardwareFailure(message: $0) }
                case .failure(let error): return error
                }
            },
            readSignificantEnergyApps: { await EnergyAppMonitor.shared.sampleTopApps() },
            setSystemAwake: { await assertions.setSystemAwake($0) },
            setDisplayAwake: { await assertions.setDisplayAwake($0) },
            configureAway: { away.update(config: $0); return away.status },
            subscribeAway: { away.onUpdate = $0 }, stopAway: { away.stop() },
            helper: .live, showDockIcon: { AppDelegate.applyActivationPolicy(showDockIcon: $0) },
            setLanguage: { Localizer.shared.language = $0 },
            translate: { Localizer.shared.tr($0) },
            notifyLowBattery: { percent in
                notifications.notifyLowBattery(title: Localizer.shared.tr("notify.lowBattery.title"),
                    body: Localizer.shared.tr("notify.lowBattery.body", percent))
            },
            loginStatus: { await login.status() },
            setLogin: { try await login.setEnabled($0) },
            workspaceNotifications: NSWorkspace.shared.notificationCenter,
            applicationNotifications: .default, scheduleTimers: true,
            energySampleStatus: { EnergyAppMonitor.shared.statusKey },
            notificationStatus: { await notifications.status() },
            testNotification: { await notifications.test() },
            requestNotification: { await notifications.requestAuthorization() },
            setReminderIntent: { notifications.setIntent($0) },
            systemAssertionActive: { await assertions.systemIsActive() },
            displayAssertionActive: { await assertions.displayIsActive() },
            sleepDisplays: { await DisplaySleep.request() },
            openDisplaySettings: {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")!)
            },
            currentNetworkFingerprint: { await NetworkFingerprintReader.readAsync().key.map(NetworkFingerprintReader.shortHash) },
            openLoginSettings: { SMAppService.openSystemSettingsLoginItems(); return true },
            openNotificationSettings: {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "com.coddle.app")")!)
            })
        #endif
    }
}

// Disambiguate the free function from AppServices.readBattery in its factory.
private func systemBatterySnapshot() -> BatteryInfo { readBattery() }

/// ServiceManagement can synchronously talk to system services. Keep both reads
/// and registration changes ordered on one worker, including onboarding callers.
final class LoginItemWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.coddle.login-item", qos: .utility)
    private let readStatus: @Sendable () -> SMAppService.Status
    private let update: @Sendable (Bool) throws -> Void

    init(readStatus: @escaping @Sendable () -> SMAppService.Status = { SMAppService.mainApp.status },
         update: @escaping @Sendable (Bool) throws -> Void = { enabled in
             if enabled { try SMAppService.mainApp.register() }
             else { try SMAppService.mainApp.unregister() }
         }) {
        self.readStatus = readStatus; self.update = update
    }

    func status() async -> SMAppService.Status {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.readStatus()) }
        }
    }

    func setEnabled(_ enabled: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try self.update(enabled); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
