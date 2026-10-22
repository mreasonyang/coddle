import Foundation
import Combine
import AppKit
import CoreGraphics
import ServiceManagement
import UserNotifications

/// App state: battery display + native charge-limit control + smart mode.
@MainActor
final class AppModel: ObservableObject {
    /// Shared instance so the AppDelegate can host a control-panel window for
    /// Dock mode without re-creating state.
    static let shared = AppModel()

    @Published private(set) var startupLoading = true
    private(set) var startupTask: Task<Void, Never>?
    private(set) var configSaveTask: Task<Bool, Never>?
    private(set) var configReloadTask: Task<Void, Never>?
    private(set) var taskStopTask: Task<Void, Never>?
    private var configRevision: UInt64 = 0
    private var configErrorRevision: UInt64?
    private var taskStopConfigRevision: UInt64?
    private var configReloadGeneration: UInt64 = 0
    private var configurationLoaded = false
    private var setupActionGeneration: UInt64 = 0
    private var reminderGeneration: UInt64 = 0
    @Published var onboarding: OnboardingCoordinator?
    private var onboardingObservation: AnyCancellable?
    @Published private(set) var taskStopStatus = ""
    @Published private(set) var taskStopBusy = false
    @Published private(set) var taskStopOrdinary: SetupResult = .idle
    @Published private(set) var taskStopLid: SetupResult = .idle
    private var setupChargeEnabled = true
    private var setupAwakeEnabled = true
    private var setupLidEnabled = true
    var hardwareReady: Bool { hasHardwareSnapshot }
    var setupRequired: Bool { onboarding?.requiresSetup == true }
    var setupAllowsCharge: Bool { setupChargeEnabled }
    var setupAllowsAwake: Bool { setupAwakeEnabled }

    @Published var battery = BatteryInfo()
    @Published var mclSupported = false
    @Published private(set) var temporaryFullChargeSupported = false
    @Published private(set) var refreshBusy = false
    @Published private(set) var chargeLimitBusy = false
    @Published var availableLimits: [Int] = []
    @Published var currentLimit: Int? = nil
    @Published var limitEnabled = false
    /// Whether macOS is overriding the charge limit to charge to 100%, and how
    /// that was established (see `ChargeOverrideSignal`). Purely informational:
    /// it never rewrites the limit, and the underlying `ChargeStatus` is
    /// unchanged. The debounced detector owns the transition, so a single
    /// refresh cannot flip it on a normal charge tail.
    @Published var chargeOverrideSignal: ChargeOverrideSignal = .none

    /// True while an override is detected, whatever its evidence.
    var chargeOverrideActive: Bool { chargeOverrideSignal.isActive }

    /// Whether the panel and menu bar should present the calibration override.
    ///
    /// Detection (`chargeOverrideActive`) is independent of AC, but the override
    /// is *presented* only on AC: a charging claim is false on battery, and the
    /// menu-bar glyph is already AC-gated, so this keeps the badge truthful in
    /// the unplugged case and keeps the panel and the menu bar agreeing.
    var chargeOverridePresented: Bool { chargeOverrideActive && battery.externalConnected }

    /// Whether the override is corroborated by `powerd`'s own signal, as opposed
    /// to inferred from the pack alone. Only a confirmed signal licenses the
    /// causal wording ("macOS is charging to 100% for calibration"); the inferred
    /// case may state the observable fact but not the cause.
    var chargeOverrideConfirmed: Bool { chargeOverrideSignal == .confirmed }
    @Published var lastError: String? = nil {
        didSet { lastErrorRevision &+= 1; lastErrorDomain = nil }
    }
    private var lastErrorDomain: FeedbackDomain?
    private var lastErrorRevision: UInt64 = 0
    private var hardwareRefreshErrorRevision: UInt64?
    @Published private(set) var chargeFeedbackError: String?
    @Published private(set) var energyFeedbackError: String?
    @Published private(set) var awakeFeedbackError: String?
    var panelGlobalError: String? {
        globalError(excluding: [.charging, .energy, .awake])
    }
    /// Suppression follows the publishing operation, never coincidentally equal text.
    func globalError(excluding representedDomains: Set<FeedbackDomain>) -> String? {
        let local: [(FeedbackDomain, String?)] = [(.charging, chargeFeedbackError),
            (.energy, energyFeedbackError), (.awake, awakeFeedbackError)]
        var messages = local.compactMap { domain, error in representedDomains.contains(domain) ? nil : error }
        if let lastError, lastErrorDomain == nil ||
            !local.contains(where: { $0.0 == lastErrorDomain && $0.1 != nil }) {
            messages.append(lastError)
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
    func hasPersistentGlobalError(excluding representedDomains: Set<FeedbackDomain>) -> Bool {
        let local: [(FeedbackDomain, String?)] = [(.charging, chargeFeedbackError),
            (.energy, energyFeedbackError), (.awake, awakeFeedbackError)]
        return local.contains { domain, error in error != nil && !representedDomains.contains(domain) }
    }
    private func publishError(_ message: String?, domain: FeedbackDomain) {
        lastError = message
        lastErrorDomain = message == nil ? nil : domain
    }
    @Published private(set) var configError: String?
    private var configLoadBlocked = false
    var configCanRetrySave: Bool { !configLoadBlocked && configError != nil }
    var awakeOwnsConfigError: Bool {
        guard !configLoadBlocked, configError != nil, let revision = configErrorRevision else { return false }
        return revision == taskStopConfigRevision && awakeStopNeedsRecovery
    }
    @Published private(set) var dockIconActive = false
    var dockRestartPending: Bool { dockIconActive != showInDock }
    @Published private(set) var systemAwakeApplied = false
    @Published private(set) var displayAwakeApplied = false
    @Published private(set) var lidAwakeApplied = false
    var lidStateUnconfirmed: Bool { lidWriteNeedsRetry && helperStatus != nil }
    @Published private(set) var helperFilesPresent = false
    @Published private(set) var energySampleStatus = "energySample.unavailable"
    @Published private(set) var notificationStatus = "notification.unknown"
    @Published private(set) var notificationBusy = false
    @Published private(set) var lastGuardEvent: String?
    @Published private(set) var lastGuardEventDate: Date?

    var chargeDisplaySelection: Int {
        chargeLimitBusy || pendingChargeRecovery != nil || lastLimitAttemptFailed ? registeredTarget : selection
    }
    var chargeOperationTarget: Int { pendingChargeRecovery == .temporaryFull ? 100 : registeredTarget }
    var chargeOperationStatus: String? {
        if chargeLimitBusy { return "charge.applying" }
        if pendingChargeRecovery != nil { return "charge.waitingRecovery" }
        if lastLimitAttemptFailed && !temporaryFullChargeActive { return "charge.retrying" }
        return nil
    }
    var predictedUnplugHour: Int? { profile.predictedUnplugHour(minSamples: minSamplesPerHour) }
    var smartPlanKey: String {
        if topupLeadHours == 0 { return "smart.topupOff" }
        guard predictedUnplugHour != nil else { return "smart.learning" }
        return registeredTarget == topupLimit ? "smart.toppingUp" : "smart.plan"
    }

    /// True when the user explicitly clicked "Charge to Full Now" until unplugged, full, or resumed.
    @Published private(set) var temporaryFullChargeActive = false
    /// Supported macOS Energy Modes on this host (`Automatic`, `Low Power`, `High Power`).
    @Published private(set) var availableEnergyModes: [EnergyMode] = [.automatic, .lowPower, .highPower]
    /// Last observed macOS Energy Mode for the active power source (`pmset -g`).
    @Published private(set) var energyMode: EnergyMode = .automatic
    /// True while an Energy Mode change is executing.
    @Published private(set) var energyModeBusy = false
    /// Running applications currently using significant energy.
    @Published private(set) var significantEnergyApps: [SignificantEnergyApp] = []

    private let services: AppServices
    private var isBatchUpdating = false
    private var isShuttingDown = false
    // Protective pauses also invalidate an unissued one-shot display request.
    private var awakeIntentRevision: UInt64 = 0
    // Protective pauses and edits to inactive child preferences do not supersede OFF.
    private var awakePreferenceRevision: UInt64 = 0
    private var rejectingAwakeEnable = false
    private var displaySleepTask: Task<Void, Never>?
    private var displayReturnRevision: UInt64 = 0
    @Published private(set) var displaySleepBusy = false
    @Published private(set) var displaySleepStatus: String?
    @Published private(set) var taskStopDisplay: SetupResult = .idle
    @Published private(set) var assertionsApplying = false
    private var assertionsTask: Task<Void, Never>?
    private var assertionsRevision: UInt64 = 0
    private var observedSystemAwake = false
    private var observedDisplayAwake = false
    private var energySampleTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var loginRevision: UInt64 = 0
    @Published private(set) var loginBusy = false
    private var lidWriteNeedsRetry = false
    // Keep ownership after an intent is cleared, until its OFF is confirmed.
    // Discovery retries alone do not imply ownership of the global lid flag.
    private var lidCleanupRequired = false
    private var hasLidCleanupResponsibility: Bool {
        lidCleanupRequired || (keepAwake && keepAwakeOnLidClosed) || lidAwakeApplied ||
            lidStateUnconfirmed || helperInstalled || helperFilesPresent ||
            (onboarding?.record.stopPending == true && onboarding?.record.stopLidRequired != false)
    }
    private var hasPendingAwakeStop: Bool {
        taskStopBusy || onboarding?.record.stopPending == true ||
            ["onboarding.stopPartial", "onboarding.stopSaveFailed"].contains(taskStopStatus)
    }
    var awakeStopNeedsRecovery: Bool { hasPendingAwakeStop }
    var awakeLidControlPending: Bool { helperTask != nil }
    /// Presentation ownership only. Keep the conservative control/cleanup
    /// predicates unchanged when an optional installation itself fails.
    var awakeHasLidControlResponsibility: Bool {
        lidCleanupRequired || (keepAwake && keepAwakeOnLidClosed) || lidAwakeApplied ||
            helperInstalled || helperFilesPresent ||
            (onboarding?.record.stopPending == true && onboarding?.record.stopLidRequired != false)
    }

    /// Retry the current intent without changing preferences or installing a helper.
    func retryAwakeFeedback() {
        guard !isShuttingDown else { return }
        if hasPendingAwakeStop || !keepAwake { restoreSystemDefaults() }
        else { applyKeepAwake(); applyLidClosedSleep() }
    }
    private var hasHardwareSnapshot = false
    private var clamshellSnapshot: (closed: Bool, causesSleep: Bool)?
    private var refreshRequested = false
    private var refreshTask: Task<Void, Never>?
    private var chargeTask: Task<Void, Never>?
    private var energyGeneration: UInt64 = 0
    private var chargeGeneration: UInt64 = 0
    private enum ChargeRecovery { case limit, temporaryFull }
    private var pendingChargeRecovery: ChargeRecovery?
    private var hardwareRecoveryTask: Task<Void, Never>?
    private var helperTask: Task<Void, Never>?
    private var helperGeneration: UInt64 = 0
    private var helperRemovalInProgress = false
    private var leaseTimer: AnyCancellable?
    private let helperIO = HardwareIO(label: "com.coddle.helper-client")
    /// Accumulates the pack-only override evidence across refreshes so a normal
    /// charge tail cannot flash the calibration banner (see `ChargeOverrideDebouncer`).
    private var chargeOverrideDebouncer = ChargeOverrideDebouncer()

    private func notifyConfigChange() {
        guard !isBatchUpdating else { return }
        saveConfig()
    }

    // MARK: Persisted config (backed by ~/Library/Application Support/Coddle/config.json)
    @Published var smartEnabled: Bool {
        didSet {
            notifyConfigChange()
            if !isBatchUpdating { chargeIntentChanged() }
        }
    }
    @Published var manualLimit: Int {
        didSet {
            notifyConfigChange()
            if !isBatchUpdating { chargeIntentChanged() }
        }
    }
    @Published var iconOnly: Bool { didSet { notifyConfigChange() } }
    @Published var holdLimit: Int { didSet { notifyConfigChange(); if !isBatchUpdating { chargeIntentChanged() } } }
    @Published var topupLimit: Int { didSet { notifyConfigChange(); if !isBatchUpdating { chargeIntentChanged() } } }
    @Published var topupLeadHours: Int { didSet { notifyConfigChange(); if !isBatchUpdating { chargeIntentChanged() } } }
    @Published var minSamplesPerHour: Int { didSet { notifyConfigChange(); if !isBatchUpdating { chargeIntentChanged() } } }
    @Published var refreshSeconds: Int {
        didSet {
            notifyConfigChange()
            if !isBatchUpdating { restartTimer() }
        }
    }
    @Published var showInDock: Bool { didSet { notifyConfigChange() } }
    @Published var showMenuBarIcon: Bool { didSet { notifyConfigChange() } }
    @Published var language: String {
        didSet {
            notifyConfigChange()
            services.setLanguage(language)
        }
    }
    @Published var theme: String { didSet { notifyConfigChange() } }

    var activeTheme: CoddleTheme { CoddleTheme(key: theme) }

    /// Whether this machine physically has a clamshell lid (false on Mac mini / Studio / Pro / iMac).
    var hasClamshell: Bool { clamshellSnapshot != nil }

    // MARK: Keep-awake (Agent Mode part 1)
    /// Master intent. Display and lid options can only operate beneath it.
    @Published var keepAwake: Bool {
        didSet {
            // @Published invokes this observer again when a rejected ON is
            // rolled back. That rollback is not a new preference or operation.
            guard !rejectingAwakeEnable else { return }
            if keepAwake && hasPendingAwakeStop {
                rejectingAwakeEnable = true
                keepAwake = false
                rejectingAwakeEnable = false
                return
            }
            if keepAwake != oldValue {
                awakeIntentRevision &+= 1
                awakePreferenceRevision &+= 1
                displaySleepStatus = nil
            }
            if !isBatchUpdating && !keepAwake {
                restoreSystemDefaults()
                return
            }
            if !isBatchUpdating { clearTaskStopResultForSetup() }
            notifyConfigChange()
            if !isBatchUpdating {
                applyKeepAwake()
                applyLidClosedSleep()
            }
        }
    }
    /// Saved lid preference; it can take effect only while the master is ON.
    @Published var keepAwakeOnLidClosed: Bool {
        didSet {
            if keepAwake && keepAwakeOnLidClosed { lidCleanupRequired = true }
            if keepAwakeOnLidClosed != oldValue {
                awakeIntentRevision &+= 1
                if keepAwake { awakePreferenceRevision &+= 1 }
                displaySleepStatus = nil
            }
            if !isBatchUpdating { clearTaskStopResultForSetup() }
            notifyConfigChange()
            if !isBatchUpdating { applyLidClosedSleep() }
        }
    }

    // MARK: Agent Mode part 2 — away guard / low battery / display
    /// Master switch for away detection; display controls are independent.
    @Published var awayDetectionEnabled: Bool {
        didSet {
            notifyConfigChange()
            if !isBatchUpdating { configureAwayEngine() }
        }
    }
    /// Network fingerprint poll interval, seconds.
    @Published var networkSampleSeconds: Int {
        didSet {
            notifyConfigChange()
            if !isBatchUpdating { configureAwayEngine() }
        }
    }
    /// Cumulative awake dwell before a network counts as "usual", seconds.
    @Published var usualMinDwellSeconds: Int {
        didSet {
            notifyConfigChange()
            if !isBatchUpdating { configureAwayEngine() }
        }
    }
    /// How long off the usual network before `isAway`, minutes.
    @Published var awayAfterMinutes: Int {
        didSet {
            notifyConfigChange()
            if !isBatchUpdating { configureAwayEngine() }
        }
    }
    /// Continuous offline before `isAway` (backstop), minutes.
    @Published var offlineAwayAfterMinutes: Int {
        didSet {
            notifyConfigChange()
            if !isBatchUpdating { configureAwayEngine() }
        }
    }
    /// HID idle threshold for the bag-guard predicate, seconds.
    @Published var idleSeconds: Int { didSet { notifyConfigChange() } }
    /// Only allow sleep (bag guard) when on battery.
    @Published var requireBattery: Bool { didSet { notifyConfigChange() } }
    /// Warn (notification only) when on battery at or below this percent.
    @Published var lowBatteryWarnPercent: Int { didSet { notifyConfigChange() } }
    @Published var lowBatteryReminder: ReminderIntent? {
        didSet { services.setReminderIntent(lowBatteryReminder ?? .undecided); notifyConfigChange() }
    }
    /// Saved display preference; its assertion requires the master to be ON.
    @Published var keepDisplayAwake: Bool {
        didSet {
            if keepDisplayAwake != oldValue {
                awakeIntentRevision &+= 1
                if keepAwake { awakePreferenceRevision &+= 1 }
                displaySleepStatus = nil
            }
            if !isBatchUpdating { clearTaskStopResultForSetup() }
            notifyConfigChange()
            if !isBatchUpdating { applyAssertions() }
        }
    }
    /// Manual allowlist of fingerprints treated as "usual".
    @Published var usualFingerprints: [String] {
        didSet {
            notifyConfigChange()
            if !isBatchUpdating { configureAwayEngine() }
        }
    }

    /// Live away-detection state, mirrored from the engine for the UI.
    @Published var awayStatus = AwayStatus()
    /// True while the bag guard has released keep-awake (away + unattended).
    @Published var bagGuardActive = false {
        didSet {
            guard bagGuardActive != oldValue else { return }
            if displaySleepStatus == "display.requested" { displaySleepStatus = nil }
            if bagGuardActive {
                awakeIntentRevision &+= 1
                if displaySleepBusy { displaySleepStatus = "display.protected" }
            }
        }
    }

    /// The privileged helper is installed and answering.
    @Published var helperInstalled = false
    /// Last helper error (raw text) / status to show; nil when fine.
    @Published var helperStatus: String? = nil
    /// An install/uninstall admin prompt is in progress.
    @Published var helperBusy = false

    /// One-shot latch so low-battery warns once per discharge episode.
    private var lowBatteryNotified = false

    // MARK: Login item
    @Published var launchAtLogin = false
    /// An i18n key (see strings.json `login.*`), translated in the view.
    @Published var launchAtLoginStatus = "login.unknown"

    /// 0 means "off / disabled"; otherwise the target percentage.
    @Published var selection: Int = 0

    private var timer: AnyCancellable?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Last target limit successfully applied to hardware.
    private var lastRegisteredTarget: Int? = nil
    private var lastLimitAttemptTarget: Int? = nil
    private var lastLimitAttemptTime: TimeInterval = 0
    private var lastLimitAttemptFailed: Bool = false
    private var profile = SmartPolicy.Profile()
    /// Wall-clock time of the last profile sample, so the (minute-resolution)
    /// usage model is not re-sampled on every 5 s refresh tick.
    private var lastProfileSampleAt: Date? = nil

    /// Policy derived from the current config.
    private var policy: SmartPolicy {
        var p = SmartPolicy()
        p.defaultLimit = holdLimit
        p.topupLimit = topupLimit
        p.topupLeadHours = topupLeadHours
        p.minSamplesPerHour = minSamplesPerHour
        return p
    }

    init(services: AppServices? = nil, startup: OnboardingStartup? = nil, onboardingStore: OnboardingStore? = nil) {
        let store = onboardingStore ?? (services == nil ? .live : nil)
        let services = services ?? AppServices.live()
        self.services = services
        let cfg = CoddleConfig().sanitized()
        smartEnabled = cfg.smartEnabled
        manualLimit = cfg.manualLimit
        iconOnly = cfg.iconOnly
        holdLimit = cfg.holdLimit
        topupLimit = cfg.topupLimit
        topupLeadHours = cfg.topupLeadHours
        minSamplesPerHour = cfg.minSamplesPerHour
        refreshSeconds = cfg.refreshSeconds
        showInDock = cfg.showInDock
        showMenuBarIcon = cfg.showMenuBarIcon
        language = cfg.language
        theme = cfg.theme
        keepAwake = cfg.keepAwake
        keepAwakeOnLidClosed = cfg.keepAwakeOnLidClosed
        awayDetectionEnabled = cfg.awayDetectionEnabled
        networkSampleSeconds = cfg.networkSampleSeconds
        usualMinDwellSeconds = cfg.usualMinDwellSeconds
        awayAfterMinutes = cfg.awayAfterMinutes
        offlineAwayAfterMinutes = cfg.offlineAwayAfterMinutes
        idleSeconds = cfg.idleSeconds
        requireBattery = cfg.requireBattery
        lowBatteryWarnPercent = cfg.lowBatteryWarnPercent
        lowBatteryReminder = cfg.lowBatteryReminder
        keepDisplayAwake = cfg.keepDisplayAwake
        usualFingerprints = cfg.usualFingerprints
        selection = cfg.smartEnabled ? 0 : cfg.manualLimit
        dockIconActive = cfg.showInDock
        // No timer, hardware write or persisted default is allowed before the
        // launch configuration and recovery journal have been read off-actor.
        setupChargeEnabled = false; setupAwakeEnabled = false; setupLidEnabled = false
        startupTask = Task { [weak self] in
            guard let self else { return }
            let state: OnboardingStartup?
            if let startup { state = startup }
            else if let store { state = await store.bootstrapAsync() }
            else { state = nil }
            let loaded: Result<CoddleConfig, Error>
            do { loaded = .success(try await services.loadConfig().sanitized()) }
            catch { loaded = .failure(error) }
            await self.finishStartup(loaded: loaded, startup: state, store: store)
            self.startupLoading = false
            self.startupTask = nil
        }
    }

    func waitForStartup() async { await startupTask?.value }

    private func finishStartup(loaded: Result<CoddleConfig, Error>, startup: OnboardingStartup?, store: OnboardingStore?) async {
        guard !isShuttingDown else { return }
        if startup?.record.stopPending == true && startup?.record.stopLidRequired != false {
            lidCleanupRequired = true
        }
        if case .success(let cfg) = loaded {
            configurationLoaded = true
            isBatchUpdating = true
            var startupConfig = cfg
            if startup?.record.stopPending == true { startupConfig.keepAwake = false }
            config = startupConfig
            isBatchUpdating = false
            selection = cfg.smartEnabled ? 0 : cfg.manualLimit
            dockIconActive = cfg.showInDock
            services.setLanguage(cfg.language)
            setupChargeEnabled = true; setupAwakeEnabled = true; setupLidEnabled = true
        }
        if let startup, startup.requiresSetup && !startup.record.existingUser {
            setupChargeEnabled = startup.error == nil && startup.record.charge == .confirmed
            setupAwakeEnabled = startup.error == nil && startup.record.ordinary == .confirmed
            setupLidEnabled = startup.error == nil && startup.record.lid == .confirmed
        }
        if startup?.record.stopPending == true {
            isBatchUpdating = true
            keepAwake = false
            isBatchUpdating = false
        }
        if case .failure = loaded {
            configLoadBlocked = true
            configError = services.translate("config.loadFailed")
            configErrorRevision = nil
            setupChargeEnabled = false; setupAwakeEnabled = false; setupLidEnabled = false
        }
        if startup?.error != nil {
            setupChargeEnabled = false; setupAwakeEnabled = false; setupLidEnabled = false
        }
        services.setReminderIntent(lowBatteryReminder ?? .undecided)
        if let store, let startup {
            onboarding = OnboardingCoordinator(model: self, services: services, store: store, startup: startup)
            onboardingObservation = onboarding?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }

        services.subscribeHardwareRecovery { [weak self] in self?.recoverHardwareOperations() }
        helperIO.onRecovery { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyLidClosedSleep()
            }
        }
        loadProfile()
        guard !isShuttingDown else { return }
        refreshFromHardware()
        refreshLaunchAtLogin()
        restartTimer()
        if services.scheduleTimers {
            leaseTimer = Timer.publish(every: HelperManager.leaseRenewalInterval, on: .main, in: .common).autoconnect()
                .sink { [weak self] _ in
                    guard let self, self.keepAwake, self.keepAwakeOnLidClosed, !self.isShuttingDown else { return }
                    self.applyLidClosedSleep()
                }
        }

        // Agent Mode: reflect the persisted keep-awake intent and run the
        // disablesleep safety reconcile. Neither of these ever prompts for an
        // admin password (the helper must already be installed to act).
        // Agent Mode part 2: away engine + display + crash recovery.
        services.subscribeAway { [weak self] status in
            Task { @MainActor in
                guard let self, !self.isShuttingDown else { return }
                self.awayStatus = status
                self.evaluateBagGuard()
            }
        }
        // Re-evaluate as soon as the OS reports a change, so the honest state
        // appears without waiting for the next refresh tick.
        services.subscribeChargeOverride { [weak self] in
            Task { @MainActor in
                guard let self, !self.isShuttingDown else { return }
                self.refresh()
            }
        }
        if setupAwakeEnabled { configureAwayEngine() }
        applyKeepAwake()
        applyLidClosedSleep()
        if startup?.record.stopPending == true { restoreSystemDefaults() }

        observe(services.applicationNotifications, NSApplication.didBecomeActiveNotification) {
            $0.clearDisplaySleepAcknowledgement()
            $0.refreshLaunchAtLogin()
            $0.refreshNotificationStatus()
            $0.refreshHelperInstalled()
        }
        refreshNotificationStatus()
        observe(services.applicationNotifications, .NSProcessInfoPowerStateDidChange) {
            $0.refresh()
        }
        observe(services.workspaceNotifications, NSWorkspace.didWakeNotification) { model in
            model.clearDisplaySleepAcknowledgement()
            model.refreshFromHardware()
        }
        observe(services.workspaceNotifications, NSWorkspace.screensDidWakeNotification) {
            $0.clearDisplaySleepAcknowledgement()
            $0.refreshFromHardware()
        }
        observe(services.applicationNotifications, NSApplication.didChangeScreenParametersNotification) {
            $0.refreshFromHardware()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (AppModel) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isShuttingDown else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
    }

    var menuBarText: String {
        guard let p = battery.percent else { return "—" }
        return "\(p)%"
    }

    /// The reason-aware status, cross-checked with the native limit.
    var chargeStatus: ChargeStatus {
        battery.chargeStatus(limit: currentLimit, enabled: limitEnabled)
    }

    // MARK: - Config persistence

    var config: CoddleConfig {
        get {
            CoddleConfig(
                holdLimit: holdLimit,
                manualLimit: manualLimit,
                topupLimit: topupLimit,
                topupLeadHours: topupLeadHours,
                minSamplesPerHour: minSamplesPerHour,
                refreshSeconds: refreshSeconds,
                smartEnabled: smartEnabled,
                iconOnly: iconOnly,
                showInDock: showInDock,
                showMenuBarIcon: showMenuBarIcon,
                language: language,
                theme: theme,
                keepAwake: keepAwake,
                keepAwakeOnLidClosed: keepAwakeOnLidClosed,
                awayDetectionEnabled: awayDetectionEnabled,
                networkSampleSeconds: networkSampleSeconds,
                usualMinDwellSeconds: usualMinDwellSeconds,
                awayAfterMinutes: awayAfterMinutes,
                offlineAwayAfterMinutes: offlineAwayAfterMinutes,
                idleSeconds: idleSeconds,
                requireBattery: requireBattery,
                lowBatteryWarnPercent: lowBatteryWarnPercent,
                lowBatteryReminder: lowBatteryReminder,
                keepDisplayAwake: keepDisplayAwake,
                usualFingerprints: usualFingerprints
            )
        }
        set {
            let sanitized = newValue.sanitized()
            let needsAwakeStop = !sanitized.keepAwake && keepAwake
            let chargeChanged = sanitized.manualLimit != manualLimit || sanitized.smartEnabled != smartEnabled ||
                sanitized.holdLimit != holdLimit || sanitized.topupLimit != topupLimit ||
                sanitized.topupLeadHours != topupLeadHours || sanitized.minSamplesPerHour != minSamplesPerHour
            if chargeChanged {
                chargeGeneration &+= 1
                pendingChargeRecovery = nil
                temporaryFullChargeActive = false
            }
            let wasBatch = isBatchUpdating
            isBatchUpdating = true
            defer {
                isBatchUpdating = wasBatch
                if !isBatchUpdating {
                    if needsAwakeStop { restoreSystemDefaults() }
                    else { saveConfig() }
                    restartTimer()
                    services.setLanguage(language)
                    configureAwayEngine()
                    applyKeepAwake()
                    applyLidClosedSleep()
                    reconcileLimitIfNeeded()
                }
            }
            holdLimit = sanitized.holdLimit
            manualLimit = sanitized.manualLimit
            topupLimit = sanitized.topupLimit
            topupLeadHours = sanitized.topupLeadHours
            minSamplesPerHour = sanitized.minSamplesPerHour
            refreshSeconds = sanitized.refreshSeconds
            smartEnabled = sanitized.smartEnabled
            iconOnly = sanitized.iconOnly
            if sanitized.showInDock { services.showDockIcon(true); dockIconActive = true }
            showInDock = sanitized.showInDock
            showMenuBarIcon = sanitized.showMenuBarIcon
            language = sanitized.language
            theme = sanitized.theme
            keepAwake = sanitized.keepAwake
            keepAwakeOnLidClosed = sanitized.keepAwakeOnLidClosed
            awayDetectionEnabled = sanitized.awayDetectionEnabled
            networkSampleSeconds = sanitized.networkSampleSeconds
            usualMinDwellSeconds = sanitized.usualMinDwellSeconds
            awayAfterMinutes = sanitized.awayAfterMinutes
            offlineAwayAfterMinutes = sanitized.offlineAwayAfterMinutes
            idleSeconds = sanitized.idleSeconds
            requireBattery = sanitized.requireBattery
            lowBatteryWarnPercent = sanitized.lowBatteryWarnPercent
            lowBatteryReminder = sanitized.lowBatteryReminder
            keepDisplayAwake = sanitized.keepDisplayAwake
            usualFingerprints = sanitized.usualFingerprints
        }
    }

    @discardableResult func saveConfig() -> Task<Bool, Never> {
        guard configurationLoaded, !configLoadBlocked else { return Task { false } }
        let snapshot = config
        configRevision &+= 1
        let revision = configRevision
        let previous = configSaveTask
        let task = Task { [weak self] in
            _ = await previous?.value
            guard let self else { return false }
            let saved: Bool
            do { try await self.services.saveConfig(snapshot); saved = true }
            catch { saved = false }
            if revision == self.configRevision {
                self.configError = saved ? nil : self.services.translate("config.saveFailed")
                self.configErrorRevision = saved ? nil : revision
                self.configSaveTask = nil
            }
            return saved
        }
        configSaveTask = task
        return task
    }

    /// Re-read the config file (e.g. after editing it by hand).
    func reloadConfig() {
        guard !isShuttingDown else { return }
        configReloadTask?.cancel()
        configReloadGeneration &+= 1
        let reloadGeneration = configReloadGeneration
        let revision = configRevision
        let precedingSave = configSaveTask
        configReloadTask = Task { [weak self] in
            _ = await precedingSave?.value
            guard let self else { return }
            defer { if reloadGeneration == self.configReloadGeneration { self.configReloadTask = nil } }
            guard !Task.isCancelled, !self.isShuttingDown else { return }
            do {
                let loaded = try await self.services.loadConfig()
                guard !Task.isCancelled, !self.isShuttingDown, revision == self.configRevision else { return }
                self.configurationLoaded = true
                self.configLoadBlocked = false
                self.configError = nil
                self.configErrorRevision = nil
                let record = self.onboarding?.record
                let running = record == nil || record?.completed == true || record?.existingUser == true
                self.setupChargeEnabled = running || record?.charge == .confirmed
                self.setupAwakeEnabled = running || record?.ordinary == .confirmed
                self.setupLidEnabled = running || record?.lid == .confirmed
                if record?.stopPending == true { self.setupAwakeEnabled = false; self.setupLidEnabled = false }
                self.config = loaded
            } catch {
                guard !Task.isCancelled, !self.isShuttingDown, revision == self.configRevision else { return }
                self.configLoadBlocked = true
                self.configError = self.services.translate("config.loadFailed")
                self.configErrorRevision = nil
            }
        }
    }

    func restoreSetupAfterStorageRecovery(_ state: OnboardingStartup) async {
        guard !isShuttingDown else { return }
        // A journal read alone does not authorize the previously loaded intent.
        // The separate configuration read can still fail or be superseded.
        setupChargeEnabled = false; setupAwakeEnabled = false; setupLidEnabled = false
        reloadConfig()
        await configReloadTask?.value
        guard !isShuttingDown, configurationLoaded, !configLoadBlocked else { return }
        if state.record.stopPending { restoreSystemDefaults() }
    }

    private func restartTimer() {
        timer?.cancel()
        guard services.scheduleTimers, !isShuttingDown else { return }
        let secs = max(1, refreshSeconds)
        timer = Timer.publish(every: Double(secs), on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    // MARK: - Entry points (Dock / menu bar)

    /// Toggle the Dock icon. Never allows both entry points to be hidden; the
    /// policy is applied at launch (restart hinted in the UI), with promotion
    /// applied live since it is reliable.
    func setShowInDock(_ on: Bool) {
        guard on != showInDock else { return }
        if !on && !showMenuBarIcon {
            // Refuse to hide both: keep the menu-bar icon as the fallback.
            showMenuBarIcon = true
        }
        showInDock = on
        if on { services.showDockIcon(true); dockIconActive = true }
    }

    /// Toggle the menu-bar item. If hiding it while the Dock icon is off, turn
    /// the Dock icon on so the app stays reachable.
    func setShowMenuBarIcon(_ on: Bool) {
        guard on != showMenuBarIcon else { return }
        if !on && !showInDock {
            showInDock = true
            services.showDockIcon(true)
            dockIconActive = true
        }
        showMenuBarIcon = on
    }

    func setLanguage(_ code: String) {
        language = code      // didSet persists + pushes to Localizer (live switch)
    }

    // MARK: - Refresh

    /// Coalesce timer, notification and user refreshes. Hardware reads and writes
    /// use the same async boundary in production and fixtures.
    func refresh() {
        guard !isShuttingDown else { return }
        refreshRequested = true
        guard refreshTask == nil else { return }
        refreshBusy = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while self.refreshRequested && !self.isShuttingDown {
                self.refreshRequested = false
                while let charge = self.chargeTask { await charge.value }
                let generation = self.chargeGeneration
                let energyGeneration = self.energyGeneration
                let result = await self.services.readHardware()
                guard !self.isShuttingDown else { break }
                guard generation == self.chargeGeneration, energyGeneration == self.energyGeneration else {
                    self.refreshRequested = true
                    continue
                }
                switch result {
                case .failure(let error):
                    self.lastError = self.services.translate(error.message)
                    self.hardwareRefreshErrorRevision = self.lastErrorRevision
                case .success(let snapshot):
                    // A recovered read can retire only the error it published.
                    // A newer error, even with identical text, has another owner.
                    if self.hardwareRefreshErrorRevision == self.lastErrorRevision {
                        self.lastError = nil
                    }
                    self.hardwareRefreshErrorRevision = nil
                    self.acceptHardware(snapshot)
                }
            }
            self.refreshBusy = false
            self.refreshTask = nil
        }
    }

    private func acceptHardware(_ snapshot: HardwareSnapshot) {
        let firstSnapshot = !hasHardwareSnapshot
        hasHardwareSnapshot = true
        battery = snapshot.battery
        clamshellSnapshot = snapshot.clamshellClosed.map {
            (closed: $0, causesSleep: snapshot.clamshellCausesSleep ?? true)
        }
        mclSupported = snapshot.supportsLimit
        availableLimits = snapshot.availableLimits
        temporaryFullChargeSupported = snapshot.supportsTemporaryFullCharge
        availableEnergyModes = snapshot.availableEnergyModes
        if !energyModeBusy, let mode = snapshot.energyMode { energyMode = mode }
        refreshEnergyApps()
        let restoreAfterTemporaryCharge = cancelIneligibleTemporaryCharge()
        if setupChargeEnabled { observeProfile() }
        currentLimit = snapshot.currentLimit
        limitEnabled = snapshot.limitEnabled
        if setupChargeEnabled, mclSupported, let limit = snapshot.currentLimit,
           !temporaryFullChargeActive && pendingChargeRecovery == nil && !smartEnabled && snapshot.limitEnabled && limit > 0 && limit != manualLimit,
           (!lastLimitAttemptFailed || lastLimitAttemptTarget != manualLimit) {
            lastRegisteredTarget = limit
            selection = limit
            isBatchUpdating = true
            manualLimit = limit
            isBatchUpdating = false
            saveConfig()
        }
        chargeOverrideSignal = chargeOverrideDebouncer.update(ChargeOverrideInputs(
            darwinState: services.chargeOverrideState(),
            limit: currentLimit, limitEnabled: limitEnabled,
            externalConnected: battery.externalConnected,
            isCharging: battery.isCharging,
            percent: battery.percent), at: services.now())
        reconcileLimitIfNeeded(force: restoreAfterTemporaryCharge)
        evaluateBagGuard()
        if firstSnapshot {
            applyKeepAwake()
            applyLidClosedSleep()
        } else if helperTask == nil {
            // A read-only poll must not renew the lease or supersede an in-flight
            // explicit action. Only check controls this app is responsible for.
            if lidWriteNeedsRetry { applyLidClosedSleep() }
            else if (keepAwake && keepAwakeOnLidClosed) || lidAwakeApplied || lidStateUnconfirmed {
                applyLidClosedSleep(verifyOnly: true)
            }
        }
        checkLowBattery()
    }

    func refreshFromHardware() { refresh() }

    /// Wait only for the helper OFF requested by shutdown. The application
    /// delegate separately bounds its quit grace period; an unrelated admin
    /// dialog or charge operation must not delay termination.
    func waitForHelperCleanup() async {
        while let task = helperTask { await task.value }
    }

    func waitForAssertions() async {
        while let task = assertionsTask { await task.value }
    }

    /// Include ordinary and display assertions in the quit grace
    /// period, without waiting for unrelated administrator dialogs or reads.
    func waitForShutdownCleanup() async {
        await startupTask?.value
        await waitForHelperCleanup()
        await waitForAssertions()
        await displaySleepTask?.value
        _ = await configSaveTask?.value
        await onboarding?.waitForPersistence()
    }

    /// Await observable work, including tasks scheduled by earlier completions.
    /// This is also useful to callers that must wait for shutdown cleanup.
    func waitForPendingOperations() async {
        await startupTask?.value
        while refreshTask != nil || chargeTask != nil || helperTask != nil || hardwareRecoveryTask != nil || helperBusy || energyModeBusy || assertionsTask != nil || energySampleTask != nil || loginTask != nil || configSaveTask != nil || configReloadTask != nil || taskStopTask != nil || displaySleepTask != nil {
            let refresh = refreshTask, charge = chargeTask, helper = helperTask
            await refresh?.value
            await charge?.value
            await helper?.value
            await hardwareRecoveryTask?.value
            await assertionsTask?.value
            await energySampleTask?.value
            await loginTask?.value
            _ = await configSaveTask?.value
            await configReloadTask?.value
            await taskStopTask?.value
            await displaySleepTask?.value
            if helperBusy || energyModeBusy { try? await Task.sleep(for: .milliseconds(10)) }
        }
        await onboarding?.waitForPersistence()
    }

    private func refreshEnergyApps() {
        guard !isShuttingDown, energySampleTask == nil else { return }
        energySampleTask = Task { [weak self] in
            guard let self else { return }
            let apps = await self.services.readSignificantEnergyApps()
            if !self.isShuttingDown {
                self.significantEnergyApps = apps
                self.energySampleStatus = self.services.energySampleStatus()
            }
            self.energySampleTask = nil
        }
    }

    /// A private API cannot be safely killed in-process. Keep the newest user
    /// intent after a timeout and retry only once the serialized executor has
    /// actually recovered; never let a stale read adopt the uncertain old write.
    private func recoverHardwareOperations() {
        guard !isShuttingDown, hardwareRecoveryTask == nil else { return }
        hardwareRecoveryTask = Task { [weak self] in
            guard let self else { return }
            while let charge = self.chargeTask { await charge.value }
            guard !self.isShuttingDown else { self.hardwareRecoveryTask = nil; return }
            switch self.pendingChargeRecovery {
            case .limit: self.reconcileLimitIfNeeded(force: true)
            case .temporaryFull: self.chargeToFullNow()
            case nil: break
            }
            self.refresh()
            self.hardwareRecoveryTask = nil
        }
    }

    func applyLimit(_ value: Int) {
        guard !isShuttingDown else { return }
        chargeGeneration &+= 1
        pendingChargeRecovery = nil
        temporaryFullChargeActive = false
        isBatchUpdating = true
        if smartEnabled {
            smartEnabled = false
        }
        manualLimit = value
        isBatchUpdating = false
        saveConfig()
        lastError = nil
        lastLimitAttemptFailed = false
        lastLimitAttemptTarget = nil
        reconcileLimitIfNeeded(force: true)
        refreshFromHardware()
    }

    private var canTemporarilyChargeToFull: Bool {
        mclSupported && temporaryFullChargeSupported && battery.present && battery.installed &&
            battery.externalConnected && !battery.fullyCharged && (battery.percent ?? 0) < 100
    }

    /// An uncertain temporary operation may have succeeded after its timeout.
    /// Preserve the configured target and explicitly restore it when that
    /// temporary request no longer applies, even if readback still matches.
    @discardableResult
    private func cancelIneligibleTemporaryCharge() -> Bool {
        guard !canTemporarilyChargeToFull,
              temporaryFullChargeActive || pendingChargeRecovery == .temporaryFull else { return false }
        chargeGeneration &+= 1
        temporaryFullChargeActive = false
        pendingChargeRecovery = .limit
        return true
    }

    /// Temporarily bypass the charge limit and charge to 100% now (Control Center behavior).
    func chargeToFullNow() {
        guard !isShuttingDown else { return }
        guard canTemporarilyChargeToFull else {
            if cancelIneligibleTemporaryCharge() { reconcileLimitIfNeeded(force: true) }
            return
        }
        chargeGeneration &+= 1
        let generation = chargeGeneration
        pendingChargeRecovery = .temporaryFull
        enqueueChargeOperation(showPendingState: true) { model in
            guard generation == model.chargeGeneration, !model.isShuttingDown else { return }
            let error = await model.services.chargeToFullNow()
            guard generation == model.chargeGeneration, !model.isShuttingDown else { return }
            model.publishError(error.map { model.services.translate($0.message) }, domain: .charging)
            model.chargeFeedbackError = model.lastError
            model.pendingChargeRecovery = error?.awaitingRecovery == true ? .temporaryFull : nil
            if error == nil { model.temporaryFullChargeActive = true }
            model.refresh()
        }
    }

    /// A resume is an explicit write even if the configured native target has
    /// not changed: temporary overrides can preserve that target in readback.
    func resumeChargeLimit() {
        guard !isShuttingDown else { return }
        chargeGeneration &+= 1
        pendingChargeRecovery = nil
        temporaryFullChargeActive = false
        lastError = nil
        reconcileLimitIfNeeded(force: true)
        refreshFromHardware()
    }

    func setEnergyMode(_ mode: EnergyMode) {
        guard !energyModeBusy, !helperBusy, !isShuttingDown,
              availableEnergyModes.contains(mode) else { return }
        energyGeneration &+= 1
        energyModeBusy = true
        let helper = services.helper
        Task.detached {
            let result = helper.setPowerMode(mode.rawValue)
            let installed = helper.isInstalled()
            let files = helper.filesPresent() || installed
            await MainActor.run {
                self.energyGeneration &+= 1
                self.energyModeBusy = false
                guard !self.isShuttingDown else { return }
                self.helperInstalled = installed
                self.helperFilesPresent = files
                switch result {
                case .success:
                    self.lastError = nil
                    self.energyFeedbackError = nil
                case .failure(let error):
                    if !(error.status == 1 && (error.message.contains("User canceled") || error.message.contains("-128"))) {
                        self.publishError(error.message, domain: .energy)
                        self.energyFeedbackError = error.message
                    }
                }
                // Always read back the active source, including canceled/failed
                // commands whose side effects might have reached the OS.
                self.refresh()
                self.applyLidClosedSleep()
            }
        }
    }

    // MARK: - Launch at login

    /// Re-read the system login-item status for this app.
    func refreshLaunchAtLogin() {
        guard !isShuttingDown else { return }
        let previous = loginTask
        loginRevision &+= 1
        let revision = loginRevision
        loginTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let status = await self.services.loginStatus()
            guard revision == self.loginRevision else { return }
            self.acceptLoginStatus(status)
            self.loginBusy = false
            self.loginTask = nil
        }
    }

    func refreshLaunchAtLoginAndWait() async {
        refreshLaunchAtLogin()
        while let task = loginTask { await task.value }
    }

    private func acceptLoginStatus(_ status: SMAppService.Status) {
        switch status {
        case .enabled:
            launchAtLogin = true
            launchAtLoginStatus = "login.enabled"
        case .notRegistered:
            launchAtLogin = false
            launchAtLoginStatus = "login.off"
        case .requiresApproval:
            launchAtLogin = false
            launchAtLoginStatus = "login.requiresApproval"
        case .notFound:
            launchAtLogin = false
            launchAtLoginStatus = "login.notFound"
        @unknown default:
            launchAtLogin = false
            launchAtLoginStatus = "login.unknown"
        }
    }

    /// Register/unregister this app as a login item (macOS 13+ SMAppService).
    func setLaunchAtLogin(_ on: Bool) {
        guard !isShuttingDown else { return }
        let previous = loginTask
        loginRevision &+= 1
        let revision = loginRevision
        loginBusy = true
        loginTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try await self.services.setLogin(on)
                if revision == self.loginRevision { self.lastError = nil }
            } catch {
                if revision == self.loginRevision { self.lastError = error.localizedDescription }
            }
            let status = await self.services.loginStatus()
            guard revision == self.loginRevision else { return }
            self.acceptLoginStatus(status)
            self.loginBusy = false
            self.loginTask = nil
        }
    }

    // MARK: - Smart profile

    /// Sample the hourly AC-usage profile at most once per minute. The profile is
    /// a per-hour model, so the 5 s refresh tick must not inflate the sample
    /// counts (which made `minSamplesPerHour` meaningless and rewrote
    /// UserDefaults far too often).
    private func observeProfile() {
        let now = Date()
        if let last = lastProfileSampleAt, now.timeIntervalSince(last) < 60 { return }
        lastProfileSampleAt = now
        let hour = Calendar.current.component(.hour, from: now)
        profile.observe(hour: hour, onAC: battery.externalConnected)
        saveProfile()
    }

    // MARK: - Charge Limit Reconciliation

    /// Target charge limit dictated by either smart policy (when smart mode is active)
    /// or manual limit setting. 0 means off / disabled.
    var registeredTarget: Int {
        if smartEnabled {
            let hour = Calendar.current.component(.hour, from: Date())
            return policy.decide(hour: hour, profile: profile).target
        } else {
            return manualLimit
        }
    }

    /// Whether current hardware limit matches the registered target.
    private func hardwareMatches(target: Int) -> Bool {
        guard let currentLimit else { return false }
        if target == 0 {
            return !limitEnabled
        } else if target == 100 {
            return currentLimit == 100
        } else {
            return limitEnabled && currentLimit == target
        }
    }

    /// Verifies hardware limit against the registered target and restores it if wiped or diverged.
    ///
    /// Writes to hardware ONLY when:
    /// - The target changed (e.g. smart policy window changed, or manual mode limit changed).
    /// - The hardware limit actually diverged (!st.enabled when target > 0, or st.limit != target,
    ///   or st.enabled when target == 0), e.g. after a reboot, wake reset, or external change.
    /// Strictly NEVER writes on battery percentage changes (hysteresis dead-band).
    /// Failed attempts are debounced to avoid rapid repeated write loops.
    private func enqueueChargeOperation(showPendingState: Bool, _ operation: @escaping @MainActor (AppModel) async -> Void) {
        let previous = chargeTask
        if showPendingState { chargeLimitBusy = true }
        let token = UUID()
        chargeTaskID = token
        chargeTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await operation(self)
            if self.chargeTaskID == token {
                self.chargeTask = nil
                if self.chargeLimitBusy { self.chargeLimitBusy = false }
            }
        }
    }
    private var chargeTaskID: UUID?

    private func chargeIntentChanged() {
        chargeGeneration &+= 1
        pendingChargeRecovery = nil
        temporaryFullChargeActive = false
        reconcileLimitIfNeeded()
    }

    private func reconcileLimitIfNeeded(force: Bool = false) {
        guard setupChargeEnabled else { return }
        let generation = chargeGeneration
        // A polling reconciliation is queued even when there is nothing to write.
        // Do not insert a transient "Applying" row merely because it was queued.
        // Explicit forced operations still expose pending intent immediately.
        enqueueChargeOperation(showPendingState: force) { model in
            guard generation == model.chargeGeneration, !model.isShuttingDown else { return }
            await model.performLimitReconciliation(force: force, generation: generation)
        }
    }

    private func performLimitReconciliation(force: Bool, generation: UInt64) async {
        guard setupChargeEnabled, mclSupported, currentLimit != nil else { return }
        let shouldForce = force || pendingChargeRecovery == .limit
        if !shouldForce && (temporaryFullChargeActive || pendingChargeRecovery == .temporaryFull) { return }
        let target = registeredTarget
        let targetChanged = lastRegisteredTarget != nil && target != lastRegisteredTarget
        let hardwareDiverged = !hardwareMatches(target: target)

        guard shouldForce || targetChanged || hardwareDiverged else {
            lastRegisteredTarget = target
            selection = target
            if let error = chargeFeedbackError, lastError == error { lastError = nil }
            chargeFeedbackError = nil
            lastLimitAttemptFailed = false
            return
        }

        let now = services.now()
        if !shouldForce && lastLimitAttemptFailed && lastLimitAttemptTarget == target {
            if now - lastLimitAttemptTime < Double(max(1, refreshSeconds)) {
                return
            }
        }

        lastLimitAttemptTarget = target
        lastLimitAttemptTime = now

        chargeLimitBusy = true
        let err = target == 0 ? await services.disableLimit() : await services.setLimit(target)
        guard generation == chargeGeneration, !isShuttingDown else { return }
        publishError(err.map { services.translate($0.message) }, domain: .charging)
        chargeFeedbackError = lastError
        pendingChargeRecovery = err?.awaitingRecovery == true ? .limit : nil

        if err == nil {
            lastLimitAttemptFailed = false
            lastRegisteredTarget = target
            self.currentLimit = target
            self.limitEnabled = target > 0
            self.selection = target
        } else {
            lastLimitAttemptFailed = true
        }
    }

    // MARK: - Profile persistence (usage data, not config)

    private func saveProfile() {
        services.defaults.set(profile.ac.map(String.init).joined(separator: ","), forKey: "profile.ac")
        services.defaults.set(profile.total.map(String.init).joined(separator: ","), forKey: "profile.total")
    }

    private func loadProfile() {
        func parse(_ key: String) -> [Int]? {
            guard let s = services.defaults.string(forKey: key) else { return nil }
            let v = s.split(separator: ",").compactMap { Int($0) }
            return v.count == 24 ? v : nil
        }
        if let ac = parse("profile.ac"), let total = parse("profile.total") {
            profile.ac = ac
            profile.total = total
        }
    }

    // MARK: - Keep-awake / privileged helper

    /// Re-read whether the privileged helper is installed and answering.
    func refreshHelperInstalled() {
        applyLidClosedSleep()
    }

    /// Apply the user-space assertions to match the current keep-awake intent.
    ///
    /// Both assertions are owned solely by `KeepAwakeController`:
    /// - system-idle is held for `keepAwake`;
    /// - display-idle is held only for `keepDisplayAwake`.
    /// While the bag guard is engaged (away + unattended) everything is
    /// released so the Mac can actually sleep.
    private func applyKeepAwake() {
        applyAssertions()
    }

    /// UI callbacks must re-check admission when delivered, including events
    /// queued while a checkbox was enabled. Internal config/restore paths can
    /// still load saved child preferences independently of the master.
    var canEditKeepAwakeOptions: Bool {
        keepAwake && !hasPendingAwakeStop && !isShuttingDown
    }

    func setKeepDisplayAwake(_ enabled: Bool) {
        guard canEditKeepAwakeOptions, keepDisplayAwake != enabled else { return }
        keepDisplayAwake = enabled
    }

    func setKeepAwakeOnLidClosed(_ enabled: Bool) {
        guard canEditKeepAwakeOptions, keepAwakeOnLidClosed != enabled else { return }
        keepAwakeOnLidClosed = enabled
    }

    /// The master controls effects; saved child preferences survive OFF and resume on ON.
    func setKeepAwakeEnabled(_ enabled: Bool) {
        guard !isShuttingDown else { return }
        guard enabled else { restoreSystemDefaults(); return }
        guard !hasPendingAwakeStop,
              configurationLoaded, !configLoadBlocked, setupAwakeEnabled else { return }
        guard !keepAwake else { return }
        clearTaskStopResultForSetup()
        isBatchUpdating = true
        keepAwake = true
        isBatchUpdating = false
        saveConfig()
        configureAwayEngine()
        applyKeepAwake()
        applyLidClosedSleep()
    }

    private func applyAssertions() {
        assertionsApplying = true
        assertionsRevision &+= 1
        guard assertionsTask == nil else { return }
        assertionsTask = Task { [weak self] in
            guard let self else { return }
            while true {
                let revision = self.assertionsRevision
                let wantSystem = self.setupAwakeEnabled && self.keepAwake && self.hasHardwareSnapshot && !self.bagGuardActive && !self.isShuttingDown
                let wantDisplay = self.setupAwakeEnabled && self.keepAwake && self.keepDisplayAwake && self.hasHardwareSnapshot && !self.bagGuardActive && !self.isShuttingDown
                let systemOK = await self.services.setSystemAwake(wantSystem)
                if systemOK { self.observedSystemAwake = wantSystem }
                guard revision == self.assertionsRevision else { continue }
                let displayOK = await self.services.setDisplayAwake(wantDisplay)
                if displayOK { self.observedDisplayAwake = wantDisplay }
                // Finish old writes before acting on a newer OFF. Never publish
                // an old success/error as confirmation of the newest intent.
                guard revision == self.assertionsRevision else { continue }
                self.systemAwakeApplied = self.observedSystemAwake
                self.displayAwakeApplied = self.observedDisplayAwake
                let failed = !systemOK || !displayOK
                let message = self.services.translate("error.assertionFailed")
                self.awakeFeedbackError = failed ? message : nil
                if failed { self.publishError(message, domain: .awake) }
                else if self.lastError == message { self.lastError = nil }
                self.assertionsApplying = false
                self.assertionsTask = nil
                return
            }
        }
    }

    /// Apply the lid-closed intent to the helper, honoring the bag guard.
    /// Never triggers an install prompt: if the helper is missing we just leave
    /// the config desire set and let the panel offer the Install button.
    private func applyLidClosedSleep(explicitSetup: Bool = false, verifyOnly: Bool = false) {
        guard setupLidEnabled || explicitSetup || isShuttingDown else { return }
        helperGeneration &+= 1
        let generation = helperGeneration
        let previous = helperTask
        let helper = services.helper
        let want = keepAwake && keepAwakeOnLidClosed && hasHardwareSnapshot && !bagGuardActive && !isShuttingDown && !helperRemovalInProgress
        let hadResponsibility = hasLidCleanupResponsibility
        helperTask = Task { [weak self] in
            await previous?.value
            guard let self, generation == self.helperGeneration else { return }
            let response = await self.helperIO.run {
                let installed = helper.isInstalled()
                let files = helper.filesPresent() || installed
                let shouldConfirm = installed || files || hadResponsibility
                let result: Result<Void, HelperError> = installed
                    ? (verifyOnly ? .success(()) : helper.setDisablesleep(want))
                    : .failure(HelperError(message: "error.helperNotRunning"))
                // An RPC acknowledgement (including lease renewal) does not
                // establish the current global flag. Read after the write on
                // the same serialized worker, including when the write fails.
                let actual = shouldConfirm ? helper.readSleepDisabled() : nil
                return (installed, files, result, actual, shouldConfirm)
            }
            guard generation == self.helperGeneration else { return }
            switch response {
            case .success(let (installed, files, result, actual, shouldConfirm)):
                self.helperInstalled = installed
                self.helperFilesPresent = files
                if !shouldConfirm {
                    // An absent optional helper with no prior control is not
                    // ours to reconcile, including other apps' global state.
                    self.lidAwakeApplied = false
                    // Continue the existing quiet helper discovery so a daemon
                    // that becomes available later still receives startup OFF.
                    self.lidWriteNeedsRetry = true
                    self.helperStatus = nil
                } else {
                    self.lidCleanupRequired = true
                    self.lidAwakeApplied = actual == true
                    switch result {
                    case .success:
                        self.lidWriteNeedsRetry = actual != want
                        self.helperStatus = actual == want ? nil : "helper.lidStateUnconfirmed"
                        if !want && actual == false { self.lidCleanupRequired = false }
                    case .failure(let error):
                        self.lidWriteNeedsRetry = true
                        self.helperStatus = error.message
                    }
                }
            case .failure(let error):
                self.lidAwakeApplied = false
                self.lidWriteNeedsRetry = true
                self.helperStatus = error.message
            }
            self.helperTask = nil
        }
    }

    // MARK: - Away guard (bag guard)

    /// Push the config into the away engine (restarts its sampling timer).
    private func configureAwayEngine() {
        guard !isShuttingDown else { return }
        guard setupAwakeEnabled else { return }
        awayStatus = services.configureAway(AwayEngine.Configuration(
            enabled: awayDetectionEnabled,
            sampleSeconds: networkSampleSeconds,
            usualMinDwellSeconds: usualMinDwellSeconds,
            awayAfterMinutes: awayAfterMinutes,
            offlineAwayAfterMinutes: offlineAwayAfterMinutes,
            usualFingerprints: usualFingerprints))
        evaluateBagGuard()
    }

    /// The bag guard. Predicate (exact):
    ///
    ///     shouldAllowSleep = isAway
    ///                     && (lidClosed || userIsIdle || screenLocked)
    ///                     && (!requireBattery || onBattery)
    ///
    /// `isAway` is the away engine's verdict, which already applies the
    /// `awayAfterMinutes` delay (and the offline backstop), so it must be tested
    /// directly — re-testing `awayForSeconds >= awayAfterSeconds` here would
    /// double the effective wait.
    ///
    /// When it first becomes true we release every keep-awake and (if the
    /// lid-closed helper was active) drop `disablesleep` so the lid-close sleep
    /// can happen. We act ONCE per transition — no flapping — and re-arm as soon
    /// as the Mac is no longer away. An actively-used machine (lid open AND not
    /// idle AND unlocked) can never satisfy the predicate, so we never release
    /// keep-awake under someone's hands.
    private func evaluateBagGuard() {
        guard !isShuttingDown, setupAwakeEnabled else { return }
        guard awayDetectionEnabled else {
            if bagGuardActive {
                bagGuardActive = false
                applyKeepAwake()
                applyLidClosedSleep()
            }
            return
        }
        // A configuration change (including re-enabling detection) needs a new
        // network sample. Preserve the current guard state until it arrives:
        // an old away verdict must not release newly enabled keep-awake, while
        // an already active bag guard must not be temporarily lifted either.
        guard !awayStatus.configurationSamplePending else { return }

        let clamshell = clamshellSnapshot
        // If external displays are present and driving clamshell mode (causesSleep == false),
        // the laptop is in active desktop use, NOT in a bag.
        let lidClosed = (clamshell?.closed ?? false) && (clamshell?.causesSleep ?? true)
        let idle = services.idleSeconds() >= Double(max(0, idleSeconds))
        let screenLocked = services.screenLocked()
        let hasBattery = battery.present && battery.installed
        let onBattery = hasBattery && !battery.externalConnected

        // On desktop Macs with no battery, BagGuard should never release keep-awake based on battery assertions.
        if !hasBattery {
            if bagGuardActive {
                bagGuardActive = false
                applyKeepAwake()
                applyLidClosedSleep()
            }
            return
        }

        // AwayStatus.isAway already applies awayAfterMinutes; testing the delay
        // again here would double the effective wait, so use the engine verdict.
        let allowSleep = shouldAllowSleep(
            away: awayStatus.isAway,
            lidClosed: lidClosed,
            idle: idle,
            screenLocked: screenLocked,
            onBattery: onBattery,
            requireBattery: requireBattery)

        guard allowSleep != bagGuardActive else { return }
        bagGuardActive = allowSleep
        if allowSleep {
            lastGuardEvent = screenLocked ? "guard.eventLocked" : (lidClosed ? "guard.eventLid" : "guard.eventIdle")
            lastGuardEventDate = Date()
        }
        applyKeepAwake()
        applyLidClosedSleep()
    }

    var canSleepDisplayNow: Bool {
        !isShuttingDown && !displaySleepBusy && !taskStopBusy && hardwareReady &&
            setupAwakeEnabled && onboarding?.record.stopPending != true &&
            keepAwake && !keepDisplayAwake && !bagGuardActive
    }

    /// A one-shot request using the current choices; it never changes or saves them.
    func sleepDisplayNow() {
        guard !isShuttingDown, !displaySleepBusy, !taskStopBusy else { return }
        guard hardwareReady && setupAwakeEnabled && onboarding?.record.stopPending != true else { displaySleepStatus = "display.notReady"; return }
        guard keepAwake && !keepDisplayAwake else { displaySleepStatus = "display.requiresRunning"; return }
        guard !bagGuardActive else { displaySleepStatus = "display.protected"; return }
        let revision = awakeIntentRevision
        let returnRevision = displayReturnRevision
        displaySleepBusy = true
        displaySleepStatus = "display.preparing"
        displaySleepTask = Task { [weak self] in
            guard let self else { return }
            defer { self.displaySleepBusy = false; self.displaySleepTask = nil }
            await self.waitForAssertions()
            guard self.canFinishDisplaySleep(revision) else { return }
            let system = await self.services.systemAssertionActive()
            let display = await self.services.displayAssertionActive()
            guard self.canFinishDisplaySleep(revision) else { return }
            guard system == true && display == false else {
                self.displaySleepStatus = "display.assertionFailed"; return
            }
            let result = await self.services.sleepDisplays()
            guard self.canFinishDisplaySleep(revision) else { return }
            self.displaySleepStatus = result == .requested && returnRevision != self.displayReturnRevision ? nil : result.statusKey
        }
    }

    private func clearDisplaySleepAcknowledgement() {
        displayReturnRevision &+= 1
        if displaySleepStatus == "display.requested" { displaySleepStatus = nil }
    }

    private func canFinishDisplaySleep(_ revision: UInt64) -> Bool {
        guard !isShuttingDown, revision == awakeIntentRevision, keepAwake, !keepDisplayAwake else { return false }
        guard !bagGuardActive else { displaySleepStatus = "display.protected"; return false }
        return true
    }

    func openDisplayTimeoutSettings() {
        if !services.openDisplaySettings() { displaySleepStatus = "display.settingsFailed" }
        else if displaySleepStatus == "display.settingsFailed" { displaySleepStatus = nil }
    }

    func refreshNotificationStatus() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.notificationStatus = await self.services.notificationStatus()
            if self.lowBatteryReminder == nil {
                self.lowBatteryReminder = self.notificationStatus == "notification.ready" || self.notificationStatus == "notification.alertsOff" ? .enabled : self.notificationStatus == "notification.denied" ? .disabled : .undecided
            }
        }
    }

    func testLowBatteryNotification() {
        guard !notificationBusy, lowBatteryReminder == .enabled else { return }
        notificationBusy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.notificationStatus = await self.services.testNotification()
            self.notificationBusy = false
        }
    }

    // MARK: - Low battery (notify only)

    /// Post ONE notification per discharge episode when on battery at/below the
    /// threshold. Never changes power state. Re-arms on AC or once the battery
    /// climbs back to threshold + 5.
    private func checkLowBattery() {
        guard lowBatteryReminder == .enabled, !setupRequired,
              battery.present, battery.installed, let percent = battery.percent else { return }
        let threshold = max(1, min(100, lowBatteryWarnPercent))
        if battery.externalConnected || percent >= threshold + 5 {
            lowBatteryNotified = false
            return
        }
        guard !lowBatteryNotified, percent <= threshold else { return }
        lowBatteryNotified = true
        services.notifyLowBattery(percent)
    }

    /// Explicit user action: install the root daemon (one admin prompt).
    func installHelper() {
        guard !helperBusy, !energyModeBusy, !isShuttingDown else { return }
        helperBusy = true
        let helper = services.helper
        Task.detached {
            let result = helper.install()
            let installed: Bool
            if case .success = result {
                installed = helper.waitForHelper()
            } else {
                installed = false
            }
            let files = helper.filesPresent() || installed
            await MainActor.run {
                self.helperBusy = false
                self.helperFilesPresent = files
                switch result {
                case .success:
                    self.helperInstalled = installed
                    self.helperFilesPresent = files
                    self.helperStatus = installed ? nil : "helper.startFailed"
                    if self.helperInstalled {
                        self.evaluateBagGuard()
                        self.applyLidClosedSleep()
                    }
                case .failure(let error):
                    if error.status == 1 && (error.message.contains("User canceled") || error.message.contains("-128")) {
                        self.helperStatus = nil
                    } else {
                        self.helperStatus = error.message
                    }
                }
            }
        }
    }

    /// Explicit user action: remove the root daemon.
    func removeHelper() {
        guard !helperBusy, !energyModeBusy, !isShuttingDown else { return }
        helperBusy = true
        helperRemovalInProgress = true
        applyLidClosedSleep()
        let preceding = helperTask
        let helper = services.helper
        Task.detached {
            await preceding?.value
            if helper.isInstalled() {
                _ = helper.setDisablesleep(false)
            }
            let result = helper.uninstall()
            await MainActor.run {
                self.helperRemovalInProgress = false
                self.helperBusy = false
                switch result {
                case .success:
                    self.helperInstalled = false
                    self.helperFilesPresent = false
                    self.lidAwakeApplied = false
                    self.helperStatus = nil
                case .failure(let error):
                    if error.status == 1 && (error.message.contains("User canceled") || error.message.contains("-128")) {
                        self.helperStatus = nil
                    } else {
                        self.helperStatus = error.message
                    }
                    self.evaluateBagGuard()
                    self.applyLidClosedSleep()
                }
            }
        }
    }

    /// Readback for setup never derives success from a command acknowledgement.
    func inspectSetupHardware() async -> Bool {
        switch await services.readHardware() {
        case .success(let snapshot): acceptHardware(snapshot); return true
        case .failure(let error): lastError = services.translate(error.message); return false
        }
    }

    func setupChargeMatches(_ target: Int) -> Bool { hardwareMatches(target: target) }
    var setupPredictionHour: Int? { profile.predictedUnplugHour(minSamples: minSamplesPerHour) }

    /// A separate preparation path does not mutate the user's draft or start ON.
    func prepareSetupHelper() async -> Result<Void, HelperError> {
        guard !helperBusy, !energyModeBusy, !isShuttingDown else { return .failure(HelperError(message: "onboarding.busy")) }
        helperBusy = true
        defer { helperBusy = false }
        let helper = services.helper
        let result = await Task.detached {
            let result = helper.install()
            if case .success = result { _ = helper.waitForHelper() }
            return result
        }.value
        helperInstalled = await Task.detached { helper.isInstalled() }.value
        helperFilesPresent = await Task.detached { helper.filesPresent() }.value
        return result
    }

    func setSetupReminder(_ intent: ReminderIntent) async -> Bool {
        reminderGeneration &+= 1
        let generation = reminderGeneration
        let old = lowBatteryReminder
        isBatchUpdating = true; lowBatteryReminder = intent; isBatchUpdating = false
        let save = saveConfig()
        let revision = configRevision
        guard await save.value else {
            if generation == reminderGeneration, revision == configRevision, lowBatteryReminder == intent {
                isBatchUpdating = true; lowBatteryReminder = old; isBatchUpdating = false
            }
            return false
        }
        lowBatteryNotified = false
        return true
    }

    func requestLowBatteryPermission() {
        guard !notificationBusy else { return }
        notificationBusy = true
        Task { [weak self] in
            guard let self else { return }
            let result = await self.services.requestNotification()
            self.notificationStatus = result
            _ = await self.setSetupReminder(result == "notification.denied" ? .disabled : ["notification.ready", "notification.alertsOff"].contains(result) ? .enabled : .undecided)
            self.notificationBusy = false
        }
    }

    func openLowBatterySettings() { if !services.openNotificationSettings() { lastError = services.translate("onboarding.settingsFailed") } }

    func applySetupCharge(habit: OnboardingHabit, target: Int) async -> SetupResult {
        guard !isShuttingDown, hardwareReady, mclSupported, availableLimits.contains(target) else { return .failed }
        let setupGeneration = setupActionGeneration
        setupChargeEnabled = false
        chargeGeneration &+= 1
        await chargeTask?.value
        isBatchUpdating = true
        smartEnabled = habit == .mobile
        manualLimit = target; holdLimit = target
        isBatchUpdating = false
        guard await saveConfig().value, setupGeneration == setupActionGeneration, !isShuttingDown else { return .failed }
        // Apply the current policy target, including an already available prediction.
        let desired = registeredTarget
        let error = await services.setLimit(desired)
        chargeFeedbackError = error.map { services.translate($0.message) }
        guard await inspectSetupHardware() else { return .unknown }
        if setupChargeMatches(desired) {
            lastRegisteredTarget = desired; selection = desired
            return .confirmed
        }
        return error?.awaitingRecovery == true ? .unknown : .failed
    }

    func confirmSetupCharge() { setupChargeEnabled = true }

    func applySetupAwake(_ task: OnboardingTask, applyOrdinary: Bool = true, applyLid: Bool = true) async -> (SetupResult, SetupResult) {
        guard !isShuttingDown, hardwareReady else { return (.failed, .idle) }
        if task == .none {
            restoreSystemDefaults()
            await taskStopTask?.value
            return (taskStopOrdinary, taskStopLid)
        }
        guard !hasPendingAwakeStop else { return (.failed, task == .lid ? .failed : .idle) }
        let setupGeneration = setupActionGeneration
        isBatchUpdating = true
        keepAwake = task != .none
        keepAwakeOnLidClosed = task == .lid
        // Applying a new setup plan explicitly replaces the saved child choices.
        keepDisplayAwake = false
        isBatchUpdating = false
        guard await saveConfig().value, setupGeneration == setupActionGeneration, !isShuttingDown else { return (.failed, task == .lid ? .failed : .idle) }
        setupAwakeEnabled = true
        configureAwayEngine()
        if applyOrdinary { applyKeepAwake() }
        if task == .lid && applyLid {
            applyLidClosedSleep(explicitSetup: true)
            await waitForHelperCleanup()
        }
        // Stop can arrive while the helper ON is in flight. Its OFF/readback
        // owns the queue now; the superseded apply must not compete with it.
        guard keepAwake, task != .lid || keepAwakeOnLidClosed else { return (.failed, .idle) }
        await waitForAssertions()
        let assertion = await services.systemAssertionActive()
        let ordinary: SetupResult = assertion == true ? .confirmed : assertion == false ? .failed : .unknown
        guard task == .lid else { return (ordinary, .idle) }
        let readback = await inspectSetupLid()
        let lid: SetupResult = readback == true
            ? (lidStateUnconfirmed ? .unknown : .confirmed)
            : readback == false ? .failed : .unknown
        return (ordinary, lid)
    }

    func inspectSetupLid() async -> Bool? {
        let helper = services.helper
        guard case .success(let value) = await helperIO.run({ helper.readSleepDisabled() }) else { return nil }
        return value
    }
    func inspectSetupAssertion() async -> Bool? {
        await waitForAssertions()
        return await services.systemAssertionActive()
    }
    func confirmSetupLid() { setupLidEnabled = true }

    func completeSetup() async {
        setupChargeEnabled = true; setupAwakeEnabled = true; setupLidEnabled = true
        // Adopt current native state when the user chose not to change charging.
        if onboarding?.record.existingUser != true && (onboarding?.record.habit == .unchanged || !mclSupported) {
            isBatchUpdating = true
            smartEnabled = false
            manualLimit = limitEnabled ? (currentLimit ?? 0) : 0
            isBatchUpdating = false
            guard await saveConfig().value else { return }
        }
        configureAwayEngine()
        refresh()
    }

    func rememberCurrentNetwork() async -> Bool {
        guard !isShuttingDown, let fingerprint = await services.currentNetworkFingerprint(), !isShuttingDown else { return false }
        isBatchUpdating = true
        if !usualFingerprints.contains(fingerprint) { usualFingerprints.append(fingerprint) }
        isBatchUpdating = false
        guard await saveConfig().value, !isShuttingDown else { return false }
        // Sampling remains read-only with respect to power state.
        awayStatus = services.configureAway(AwayEngine.Configuration(enabled: true,
            sampleSeconds: networkSampleSeconds, usualMinDwellSeconds: usualMinDwellSeconds,
            awayAfterMinutes: awayAfterMinutes, offlineAwayAfterMinutes: offlineAwayAfterMinutes,
            usualFingerprints: usualFingerprints))
        return true
    }

    /// A new, explicit setup application supersedes the prior stop presentation.
    func clearTaskStopResultForSetup() {
        guard !hasPendingAwakeStop else { return }
        taskStopStatus = ""
        taskStopOrdinary = .idle; taskStopLid = .idle; taskStopDisplay = .idle
    }

    /// Stop every effect and verify release, retaining the user's child preferences.
    func restoreSystemDefaults() {
        guard !taskStopBusy else { return }
        setupActionGeneration &+= 1
        taskStopBusy = true
        displaySleepStatus = nil
        taskStopStatus = "onboarding.stopping"
        taskStopOrdinary = .requested; taskStopLid = .requested; taskStopDisplay = .requested
        let hadLidResponsibility = hasLidCleanupResponsibility
        let journalSave = onboarding?.recordStopRequested(lidRequired: hadLidResponsibility)
        isBatchUpdating = true
        keepAwake = false
        isBatchUpdating = false
        let preferenceRevision = awakePreferenceRevision
        let precedingConfigRevision = configRevision
        let configSave = saveConfig()
        taskStopConfigRevision = configRevision == precedingConfigRevision ? nil : configRevision
        setupAwakeEnabled = true; setupLidEnabled = true
        applyKeepAwake()
        applyLidClosedSleep(explicitSetup: true)
        taskStopTask = Task { [weak self] in
            guard let self else { return }
            defer { self.taskStopBusy = false; self.taskStopTask = nil }
            var journalSaved = await journalSave?.value ?? true
            let configSaved = await configSave.value
            // OFF is the safety action even if persistence failed. Retain the
            // recovery obligation and report the save failure until retried.
            await self.waitForAssertions()
            let ordinary = await self.services.systemAssertionActive()
            let display = await self.services.displayAssertionActive()
            while true {
                await self.waitForHelperCleanup()
                guard preferenceRevision == self.awakePreferenceRevision, !self.isShuttingDown else { self.taskStopStatus = ""; return }
                let helperRevision = self.helperGeneration
                let requiresLidStop = hadLidResponsibility || self.hasLidCleanupResponsibility
                if requiresLidStop, let flow = self.onboarding, flow.record.stopLidRequired != true {
                    // Discovery can establish ownership during any preceding
                    // await. Keep its responsibility durable before confirming.
                    let saved = await flow.recordStopRequested(lidRequired: true).value
                    journalSaved = journalSaved && saved
                }
                let lid: Bool? = requiresLidStop ? await self.inspectSetupLid() : nil
                guard preferenceRevision == self.awakePreferenceRevision, !self.isShuttingDown else { self.taskStopStatus = ""; return }
                // A newly queued helper operation must finish and be read back
                // before this stop can clear its recovery journal.
                guard helperRevision == self.helperGeneration else { continue }
                let lidStopped = !requiresLidStop || (lid == false && !self.lidStateUnconfirmed)
                let stopped = lidStopped && ordinary == false && display == false
                self.taskStopDisplay = display == false ? .confirmed : display == true ? .failed : .unknown
                self.taskStopOrdinary = ordinary == false ? .confirmed : ordinary == true ? .failed : .unknown
                self.taskStopLid = lidStopped ? .confirmed : lid == true ? .failed : .unknown
                self.taskStopStatus = !configSaved || !journalSaved ? "onboarding.stopSaveFailed" : stopped ? "onboarding.stopped" : "onboarding.stopPartial"
                if stopped && configSaved && journalSaved,
                   let flow = self.onboarding, !(await flow.recordStopConfirmed()) {
                    self.taskStopStatus = "onboarding.stopSaveFailed"
                }
                return
            }
        }
    }

    /// Quit hook: release our assertions and make sure we never leave the
    /// system stuck with `disablesleep=1`. The app owns that flag, so if the app
    /// is going away nothing should keep the lid-closed behavior — always revert
    /// to 0 (only when the helper is already installed; never prompts).
    func shutdownKeepAwake() {
        isShuttingDown = true
        configReloadTask?.cancel()
        configReloadTask = nil
        timer?.cancel()
        leaseTimer?.cancel()
        chargeGeneration &+= 1
        refreshRequested = false
        applyAssertions()
        services.stopAway()
        applyLidClosedSleep()
    }
}

// MARK: - Idle / screen-lock signals (no permissions required)

/// Seconds since ANY HID input (keyboard/mouse/trackpad). `IOPMGetUserIdleTime`
/// does not exist on this SDK, so we use CoreGraphics. `kCGAnyInputEventType` is
/// a C macro Swift does not import; `~0` is its value (and a known `CGEventType`
/// case), but we guard the conversion rather than force-unwrapping it.
///
/// Fail-closed on the "unattended" signal: if the event source is unavailable
/// (non-finite or absurd value) we report 0 seconds since input, i.e. treat the
/// Mac as *attended*, so the bag guard never releases keep-awake on a missing
/// signal. This matches `isScreenLocked()`'s "unknown → not locked" direction.
func secondsSinceUserInput() -> TimeInterval {
    guard let anyInput = CGEventType(rawValue: UInt32.max) else { return 0 }
    let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    guard seconds.isFinite, seconds >= 0, seconds <= 60 * 60 * 24 * 30 else { return 0 }
    return seconds
}

/// Screen locked / fast-user-switched away?
func isScreenLocked() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    if let locked = dict["CGSSessionScreenIsLocked"] as? Bool { return locked }
    if let num = dict["CGSSessionScreenIsLocked"] as? NSNumber { return num.boolValue }
    return false
}

// MARK: - Low battery notification

/// Every send rechecks system authorization and the current app preference.
/// Background work never requests permission or selects another sender.
@MainActor
final class LowBatteryNotifier {
    private var intent: ReminderIntent = .undecided
    private var generation: UInt64 = 0

    func setIntent(_ value: ReminderIntent) {
        intent = value
        generation &+= 1
        guard value != .enabled, Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["coddle.low-battery"])
    }

    func status() async -> String {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return "notification.unavailable" }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return settings.alertSetting == .enabled ? "notification.ready" : "notification.alertsOff"
        case .denied: return "notification.denied"
        case .notDetermined: return "notification.unknown"
        @unknown default: return "notification.unavailable"
        }
    }

    func requestAuthorization() async -> String {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return "notification.unavailable" }
        if await status() == "notification.unknown" {
            do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
            catch { return "notification.unavailable" }
        }
        return await status()
    }

    func test() async -> String {
        guard intent == .enabled else { return "notification.disabled" }
        let token = generation
        let state = await status()
        guard state == "notification.ready", intent == .enabled, generation == token else { return state }
        return await send(id: "coddle.test", title: Localizer.shared.tr("notification.testTitle"),
                          body: Localizer.shared.tr("notification.testBody"), token: token)
    }

    func notifyLowBattery(title: String, body: String) {
        guard intent == .enabled else { return }
        let token = generation
        Task { [weak self] in
            guard let self, await self.status() == "notification.ready",
                  self.intent == .enabled, self.generation == token else { return }
            _ = await self.send(id: "coddle.low-battery", title: title, body: body, token: token)
        }
    }

    private func send(id: String, title: String, body: String, token: UInt64) async -> String {
        guard intent == .enabled, generation == token else { return "notification.disabled" }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            if intent != .enabled || generation != token {
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
                return "notification.disabled"
            }
            return "notification.sent"
        } catch { return "notification.unavailable" }
    }
}
