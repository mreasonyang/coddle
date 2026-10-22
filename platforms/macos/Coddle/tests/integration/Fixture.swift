import AppKit
import Foundation
import ServiceManagement

/// The daemon is the only dependency touched from a background executor.
final class FixtureHelper: @unchecked Sendable {
    private let lock = NSLock()
    private var installedValue = false
    private var writesValue: [Bool] = []
    var filesRemain = false
    var readinessOverride: HelperReadiness?
    private var sleepDisabledValue: Bool? = false
    var sleepDisabled: Bool? {
        get { lock.lock(); defer { lock.unlock() }; return sleepDisabledValue }
        set { lock.lock(); sleepDisabledValue = newValue; lock.unlock() }
    }
    var installGate: DispatchSemaphore?
    var installError: HelperError?
    var writeGate: DispatchSemaphore?
    var writeError: HelperError?
    var uninstallError: HelperError?
    var powerModeError: HelperError?
    private var powerModeWritesValue: [Int] = []
    private var powerModeValue = 0
    var powerMode: Int {
        get { lock.lock(); defer { lock.unlock() }; return powerModeValue }
        set { lock.lock(); powerModeValue = newValue; lock.unlock() }
    }
    var powerModeWrites: [Int] { lock.lock(); defer { lock.unlock() }; return powerModeWritesValue }
    var powerModeDidWrite: (@Sendable (Int) -> Void)?
    func writePowerMode(_ mode: Int) -> Result<Void, HelperError> {
        lock.lock()
        powerModeWritesValue.append(mode)
        let error = powerModeError
        if error == nil { powerModeValue = mode }
        lock.unlock()
        if let error { return .failure(error) }
        powerModeDidWrite?(mode)
        return .success(())
    }
    var installed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return installedValue }
        set { lock.lock(); defer { lock.unlock() }; installedValue = newValue }
    }
    var writes: [Bool] { lock.lock(); defer { lock.unlock() }; return writesValue }
    func write(_ on: Bool) -> Result<Void, HelperError> {
        if on { writeGate?.wait() }
        lock.lock(); defer { lock.unlock() }
        writesValue.append(on)
        if writeError == nil { sleepDisabledValue = on }
        return writeError.map { .failure($0) } ?? .success(())
    }
    var operations: HelperOperations {
        HelperOperations(isInstalled: { self.installed }, setDisablesleep: { self.write($0) },
            setPowerMode: { self.writePowerMode($0) },
            install: { self.installGate?.wait(); return self.installError.map { .failure($0) } ?? .success(()) },
            waitForHelper: { self.installed = true; return true },
            uninstall: { if let error = self.uninstallError { return .failure(error) }; self.installed = false; return .success(()) }, filesPresent: { self.installed || self.filesRemain },
            inspectCapabilities: { self.readinessOverride ?? (self.installed ? .ready(HelperCapabilities.parse(HelperCapabilities.response)!) : .absent) },
            readSleepDisabled: { self.sleepDisabled })
    }
}

@MainActor
final class ModelFixture {
    let suite = "coddle.integration.\(UUID().uuidString)"
    let defaults: UserDefaults
    let workspace = NotificationCenter()
    let application = NotificationCenter()
    let helper = FixtureHelper()
    var config = CoddleConfig()
    var saved: [CoddleConfig] = []
    var configSaveError: Error?
    var battery = BatteryInfo(present: true, installed: true, percent: 80, externalConnected: false)
    var clamshell: (closed: Bool, causesSleep: Bool)? = (false, true)
    var idle = 1000.0
    /// Monotonic clock handed to AppModel for the override debounce window.
    var now: TimeInterval = 10_000
    var locked = false
    var away = AwayStatus()
    var awayCallback: ((AwayStatus) -> Void)?
    var displaySleepRequests = 0
    var displaySleepResult = DisplaySleepResult.requested
    var displaySettingsRequests = 0
    var dockCalls: [Bool] = []
    var systemAssertions: [Bool] = []
    var displayAssertions: [Bool] = []
    var notifications: [Int] = []
    var supportsLimit = false
    var availableLimits = [80, 85, 90, 95, 100]
    var notificationState = "notification.unknown"
    var authorizationResult = "notification.ready"
    var notificationRequests = 0
    var testNotifications = 0
    var reminderIntents: [ReminderIntent] = []
    var networkFingerprint: String? = "abcdef"
    var assertionFailure = false
    var supportsTemporaryFullCharge = true
    var hardwareReadDelay: Duration = .zero
    var hardwareReadError: HardwareFailure?
    var hardwareReads = 0
    var hardwareRecoveryCallback: (@MainActor () -> Void)?
    var preserveLimitDuringTemporaryFull = false
    var limitWriteDelay: Duration = .zero
    var nextLoginError: Error?
    var hardwareLimit = (limit: 80, enabled: true)
    var limitWrites: [Int] = []
    var chargeToFullNowCalls = 0
    var nextLimitError: String?
    var nextTemporaryFullError: HardwareFailure?
    var chargeOverrideState: UInt64? = 0
    var chargeOverrideCallback: (() -> Void)?
    var availableEnergyModes: [EnergyMode] = [.automatic, .lowPower, .highPower]
    var energyMode: EnergyMode = .automatic { didSet { helper.powerMode = energyMode.rawValue } }
    var significantEnergyApps: [SignificantEnergyApp] = []
    var login = SMAppService.Status.notRegistered
    var language = "system"

    init() { defaults = UserDefaults(suiteName: suite)! }
    func clean() { defaults.removePersistentDomain(forName: suite) }

    func services() -> AppServices {
        AppServices(loadConfig: { self.config }, saveConfig: { if let error = self.configSaveError { throw error }; self.config = $0; self.saved.append($0) },
            defaults: defaults,
            readHardware: {
                self.hardwareReads += 1
                let snapshot = HardwareSnapshot(battery: self.battery,
                    clamshellClosed: self.clamshell?.closed, clamshellCausesSleep: self.clamshell?.causesSleep,
                    supportsLimit: self.supportsLimit, availableLimits: self.availableLimits,
                    currentLimit: self.hardwareLimit.limit, limitEnabled: self.hardwareLimit.enabled,
                    supportsTemporaryFullCharge: self.supportsTemporaryFullCharge,
                    availableEnergyModes: self.availableEnergyModes, energyMode: EnergyMode(rawValue: self.helper.powerMode) ?? .automatic)
                try? await Task.sleep(for: self.hardwareReadDelay)
                if let error = self.hardwareReadError { return .failure(error) }
                return .success(snapshot)
            },
            subscribeHardwareRecovery: { self.hardwareRecoveryCallback = $0 },
            idleSeconds: { self.idle }, screenLocked: { self.locked }, now: { self.now },
            chargeOverrideState: { self.chargeOverrideState },
            subscribeChargeOverride: { self.chargeOverrideCallback = $0 },
            setLimit: { value in
                try? await Task.sleep(for: self.limitWriteDelay)
                self.limitWrites.append(value)
                if let error = self.nextLimitError { return HardwareFailure(message: error) }
                self.hardwareLimit = (value, value < 100)
                return nil
            },
            disableLimit: { self.limitWrites.append(0); self.hardwareLimit = (100, false); return nil },
            chargeToFullNow: {
                self.chargeToFullNowCalls += 1
                if let error = self.nextTemporaryFullError { return error }
                if let error = self.nextLimitError { return HardwareFailure(message: error) }
                if !self.preserveLimitDuringTemporaryFull { self.hardwareLimit = (100, false) }
                return nil
            },
            readSignificantEnergyApps: { self.significantEnergyApps },
            setSystemAwake: { if self.assertionFailure { return false }; self.systemAssertions.append($0); return true },
            setDisplayAwake: { self.displayAssertions.append($0); return true },
            configureAway: { _ in self.away }, subscribeAway: { self.awayCallback = $0 }, stopAway: {},
            helper: helper.operations, showDockIcon: { self.dockCalls.append($0) },
            setLanguage: { self.language = $0 }, translate: { $0 },
            notifyLowBattery: { self.notifications.append($0) },
            loginStatus: { self.login }, setLogin: { if let error = self.nextLoginError { throw error }; self.login = $0 ? .enabled : .notRegistered },
            workspaceNotifications: workspace, applicationNotifications: application, scheduleTimers: false,
            notificationStatus: { self.notificationState },
            testNotification: { self.testNotifications += 1; return "notification.sent" },
            requestNotification: { self.notificationRequests += 1; self.notificationState = self.authorizationResult; return self.notificationState },
            setReminderIntent: { self.reminderIntents.append($0) },
            systemAssertionActive: { self.systemAssertions.last ?? false },
            displayAssertionActive: { self.displayAssertions.last ?? false },
            sleepDisplays: { self.displaySleepRequests += 1; return self.displaySleepResult },
            openDisplaySettings: { self.displaySettingsRequests += 1; return true },
            currentNetworkFingerprint: { self.networkFingerprint },
            openLoginSettings: { true }, openNotificationSettings: { true })
    }
}
