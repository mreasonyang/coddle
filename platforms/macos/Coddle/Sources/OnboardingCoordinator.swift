import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class OnboardingCoordinator: ObservableObject {
    @Published private(set) var record: OnboardingRecord
    @Published private(set) var storageError: String?
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var checking = false
    @Published private(set) var hardwareKnown = false
    @Published private(set) var helperState: HelperReadiness = .absent
    @Published private(set) var notificationState = "notification.unknown"
    @Published private(set) var loginState = "login.unknown"
    @Published private(set) var testState: String?
    @Published private(set) var networkAvailable = false
    @Published private(set) var networkRemembered = false
    private weak var model: AppModel?
    private let services: AppServices
    private let store: OnboardingStore
    private var bootstrapBlocked: Bool
    private var refreshGeneration: UInt64 = 0
    private var observer: NSObjectProtocol?
    private var persistenceTask: Task<Bool, Never>?
    private var persistenceRevision: UInt64 = 0

    init(model: AppModel, services: AppServices, store: OnboardingStore, startup: OnboardingStartup) {
        self.model = model; self.services = services; self.store = store
        record = startup.record; storageError = startup.error
        bootstrapBlocked = startup.error != nil
        observer = services.applicationNotifications.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
    }

    isolated deinit { if let observer { services.applicationNotifications.removeObserver(observer) } }
    // Revisiting the guide must not lock an existing user's normal panel.
    // The draft is still resumable from Usage guide, without a forced wizard.
    var requiresSetup: Bool { !record.completed && !record.existingUser || storageError != nil }
    var hasBattery: Bool { hardwareKnown && model?.battery.present == true && model?.battery.installed == true }
    var hasLid: Bool { hardwareKnown && model?.hasClamshell == true }
    var canCharge: Bool { hasBattery && model?.mclSupported == true }
    var chargeChosen: Bool { canCharge && record.habit != .unchanged }
    var helperUseful: Bool { hasLid || (model?.availableEnergyModes.count ?? 0) > 1 }
    var helperReady: Bool {
        helperState.capabilities?.supports(lid: hasLid, energy: (model?.availableEnergyModes.count ?? 0) > 1) == true
    }
    var helperResolved: Bool { !helperUseful || helperReady || (record.helper == .skipped && record.task != .lid) }
    var loginResolved: Bool { record.login == .skipped && loginState == "login.off" || record.login == .enabled && loginState == "login.enabled" }
    var notificationResolved: Bool { !hasBattery || model?.lowBatteryReminder == record.reminder && (record.reminder == .disabled || record.reminder == .enabled && notificationState == "notification.ready") }
    /// Summaries describe the latest service readback, not the user's intent.
    /// A previously allowed permission can be revoked outside Coddle.
    var loginSummaryKey: String {
        if loginState == "login.enabled" { return "onboarding.loginReady" }
        if record.login == .skipped && loginState == "login.off" { return "onboarding.loginManualShort" }
        return loginState
    }
    var notificationSummaryKey: String {
        if record.reminder != .undecided && model?.lowBatteryReminder != record.reminder { return "config.saveFailed" }
        if record.reminder == .disabled { return "onboarding.reminderOffShort" }
        if record.reminder == .enabled && notificationState == "notification.ready" { return "onboarding.notificationReady" }
        return notificationState
    }
    /// Keep an unavailable draft value for recovery, but never present it as a
    /// recommendation or silently replace it with the nearest supported value.
    var selectedLimit: Int? { limits.contains(record.targetLimit) ? record.targetLimit : nil }
    var requiresLimitSelection: Bool { chargeChosen && selectedLimit == nil }
    var prerequisitesReady: Bool { hardwareKnown && helperResolved && loginResolved && notificationResolved && !requiresLimitSelection && !record.stopPending && model?.taskStopBusy != true }
    /// Current OFF/readback results take precedence over the earlier ON journal.
    /// stopPending also covers a process restart before readback has completed.
    var hasStopResult: Bool { record.stopPending || model?.taskStopStatus.isEmpty == false }
    var stopNeedsRetry: Bool {
        guard model?.taskStopBusy != true else { return false }
        return record.stopPending || ["onboarding.stopPartial", "onboarding.stopSaveFailed"].contains(model?.taskStopStatus ?? "")
    }
    var ordinaryResultKey: String { currentAwakeResult(record.ordinary, stop: model?.taskStopOrdinary) }
    var lidResultKey: String { currentAwakeResult(record.lid, stop: model?.taskStopLid) }
    private func currentAwakeResult(_ applied: SetupResult, stop: SetupResult?) -> String {
        guard hasStopResult else { return applied.localizationKey }
        switch stop {
        case .confirmed: return "onboarding.stopConfirmed"
        case .requested: return "onboarding.stopping"
        default: return "onboarding.stopUnconfirmed"
        }
    }
    var canAdvance: Bool {
        guard !busy, !checking, storageError == nil, hardwareKnown else { return false }
        switch record.step {
        case 0: return !requiresLimitSelection
        case 2: return helperResolved
        case 3: return loginResolved && notificationResolved
        case 4: return prerequisitesReady
        default: return true
        }
    }
    var currentLimit: Int? { model?.currentLimit }
    var limits: [Int] { (model?.availableLimits ?? []).filter { $0 > 0 } }
    var predictedHour: Int? { model?.setupPredictionHour }
    var temporaryFullAvailable: Bool {
        chargeChosen && model?.temporaryFullChargeSupported == true && model?.battery.externalConnected == true && (model?.battery.percent ?? 100) < 100 && (model?.currentLimit ?? 100) < 100 && model?.limitEnabled == true
    }
    var pluggedIn: Bool { model?.battery.externalConnected == true }

    @discardableResult private func persist() -> Task<Bool, Never> {
        guard !bootstrapBlocked else { return Task { false } }
        let snapshot = record
        let previous = persistenceTask
        persistenceRevision &+= 1
        let revision = persistenceRevision
        let task = Task { [weak self] in
            _ = await previous?.value
            guard let self else { return false }
            let saved: Bool
            do { try await self.store.saveAsync(snapshot); saved = true }
            catch { saved = false }
            if revision == self.persistenceRevision {
                self.storageError = saved ? nil : "onboarding.storageFailed"
                self.persistenceTask = nil
            }
            return saved
        }
        persistenceTask = task
        return task
    }

    func waitForPersistence() async {
        while let task = persistenceTask { _ = await task.value }
    }

    func retryStorage() async {
        guard !busy, !checking else { return }
        busy = true
        if bootstrapBlocked {
            let state = await store.bootstrapAsync()
            guard state.error == nil else { storageError = state.error; busy = false; return }
            record = state.record; bootstrapBlocked = false
            await model?.restoreSetupAfterStorageRecovery(state)
        }
        _ = await persist().value
        busy = false
        await refresh()
    }

    func beginReview() {
        guard record.completed, !busy, !record.stopPending, model?.taskStopBusy != true else { return }
        record = OnboardingRecord()
        record.existingUser = true
        record.habit = .unchanged
        record.reminder = model?.lowBatteryReminder ?? .undecided
        model?.clearTaskStopResultForSetup()
        _ = persist()
    }

    func chooseHabit(_ value: OnboardingHabit) { edit { $0.habit = value } }
    func chooseTask(_ value: OnboardingTask) { guard value != .lid || hasLid else { return }; edit { $0.task = value } }
    func chooseLimit(_ value: Int) { guard limits.contains(value) else { return }; edit { $0.targetLimit = value } }
    private func edit(_ change: (inout OnboardingRecord) -> Void) {
        guard !busy, !record.hasApplicationAttempt else { return }
        change(&record); record.generation &+= 1; error = nil; _ = persist()
    }
    func back() { guard !busy, !record.hasApplicationAttempt else { return }; record.step = max(0, record.step - 1); _ = persist() }
    func returnToPreparation(step: Int? = nil) {
        guard !busy, step == nil || step == 2 || step == 3 else { return }
        record.step = step ?? (!helperResolved ? 2 : 3)
        _ = persist()
    }
    func returnToLimitSelection() {
        guard !busy, !checking, !record.hasApplicationAttempt else { return }
        record.step = 0
        _ = persist()
    }
    /// Explicitly abandon only the unavailable charging plan. The current
    /// hardware state is adopted by completeSetup; this action never writes it.
    func keepCurrentChargeSetup() {
        guard !busy, !checking, requiresLimitSelection else { return }
        record.habit = .unchanged; record.charge = .idle
        record.generation &+= 1; error = nil
        _ = persist()
    }
    func next() {
        guard canAdvance else { return }
        record.step += 1
        if record.step == 2 && (!helperUseful || helperReady) { record.step += 1 }
        if record.step == 3 && loginResolved && notificationResolved { record.step += 1 }
        _ = persist()
    }
    func skipHelper(downgrade: Bool = false) {
        guard !busy, !record.hasApplicationAttempt, record.task != .lid || downgrade else { return }
        if downgrade { record.task = .open }
        record.helper = .skipped; record.generation &+= 1; _ = persist()
    }

    func refresh() async {
        guard !busy, !checking, !bootstrapBlocked, let model else { return }
        checking = true
        refreshGeneration &+= 1
        let token = refreshGeneration
        let helper = services.helper
        async let helperRead = Task.detached { helper.inspectCapabilities() }.value
        async let notificationRead = services.notificationStatus()
        hardwareKnown = await model.inspectSetupHardware()
        let newHelper = await helperRead
        let newNotification = await notificationRead
        guard token == refreshGeneration else { checking = false; return }
        helperState = newHelper; notificationState = newNotification
        await model.refreshLaunchAtLoginAndWait(); loginState = model.launchAtLoginStatus
        let fingerprint = await services.currentNetworkFingerprint()
        networkAvailable = fingerprint != nil
        networkRemembered = fingerprint.map { model.usualFingerprints.contains($0) } ?? false
        if helperReady { record.helper = .enabled }
        if loginState == "login.enabled", record.login == .undecided { record.login = .enabled }
        if record.reminder == .undecided {
            if model.lowBatteryReminder == .enabled && newNotification == "notification.ready" { record.reminder = .enabled }
            if newNotification == "notification.denied" { record.reminder = .disabled; _ = await model.setSetupReminder(.disabled) }
        } else if record.reminder == .enabled && newNotification == "notification.ready" {
            if model.lowBatteryReminder != .enabled, !(await model.setSetupReminder(.enabled)) { error = "config.saveFailed" }
        }
        if hardwareKnown && !hasBattery && record.step == 0 { record.habit = .unchanged; record.step = 1 }
        if hardwareKnown && !canCharge { record.habit = .unchanged }
        if record.helperInstall == .unknown { record.helperInstall = helperReady ? .confirmed : .failed }
        if record.loginRegistration == .unknown { record.loginRegistration = loginState == "login.enabled" ? .confirmed : .failed }
        if record.notificationRequest == .unknown && !["notification.unknown", "notification.unavailable"].contains(newNotification) {
            record.notificationRequest = .confirmed
            // An interrupted first request can be denied while Coddle is closed.
            // Treat that response exactly like the live callback. A later OS
            // revocation of an already confirmed preference does not enter here.
            if newNotification == "notification.denied" {
                record.reminder = .disabled
                if !(await model.setSetupReminder(.disabled)) { error = "config.saveFailed" }
            }
        }
        _ = await persist().value
        checking = false
    }

    func installHelper() async {
        guard !busy, !checking, storageError == nil, let model else { return }
        busy = true; error = nil
        defer { busy = false }
        record.helperInstall = .requested
        guard await persist().value else { return }
        let result = await model.prepareSetupHelper()
        let helper = services.helper
        helperState = await Task.detached { helper.inspectCapabilities() }.value
        record.helperInstall = helperReady ? .confirmed : .failed
        if helperReady { record.helper = .enabled }
        if case .failure(let failure) = result {
            error = failure.message.contains("-128") || failure.message.contains("User canceled") ? "onboarding.installCanceled" : "onboarding.installFailed"
        } else if !helperReady { error = "onboarding.helperNotReady" }
        _ = await persist().value
    }

    func chooseLogin(_ enabled: Bool) async {
        guard !busy, !checking, storageError == nil else { return }
        busy = true
        defer { busy = false }
        record.loginRegistration = .requested
        guard await persist().value else { return }
        error = nil
        do {
            try await services.setLogin(enabled)
            await model?.refreshLaunchAtLoginAndWait(); loginState = model?.launchAtLoginStatus ?? "login.unknown"
            record.login = enabled ? .enabled : .skipped
            record.loginRegistration = enabled ? (loginState == "login.enabled" ? .confirmed : .unknown) : (loginState == "login.off" ? .confirmed : .unknown)
            if loginState == "login.notFound" { error = "onboarding.installLocation" }
        } catch { self.error = "onboarding.loginFailed"; record.loginRegistration = .failed }
        _ = await persist().value
    }

    func chooseReminder(_ enabled: Bool) async {
        guard !busy, !checking, storageError == nil, let model else { return }
        busy = true; error = nil
        defer { busy = false }
        record.reminder = enabled ? .enabled : .disabled
        record.notificationRequest = enabled ? .requested : .confirmed
        guard await persist().value else { return }
        if enabled {
            notificationState = await services.requestNotification()
            if notificationState == "notification.denied" { record.reminder = .disabled }
            if notificationState == "notification.unknown" || notificationState == "notification.unavailable" {
                record.notificationRequest = .unknown
                error = "onboarding.notificationFailed"
            } else { record.notificationRequest = .confirmed }
        }
        if !(await model.setSetupReminder(record.reminder)) { error = "config.saveFailed" }
        _ = await persist().value
    }

    func openSettings(notification: Bool) async {
        guard !busy, storageError == nil else { return }
        busy = true
        defer { busy = false }
        if notification { record.reminder = .enabled }
        guard await persist().value else { return }
        if !(notification ? services.openNotificationSettings() : services.openLoginSettings()) { error = "onboarding.settingsFailed" }
    }
    func testNotification() async {
        guard !busy, record.reminder == .enabled, notificationState == "notification.ready" else { return }
        busy = true; testState = await services.testNotification(); busy = false
    }
    func rememberNetwork() async {
        guard !busy, storageError == nil, let model else { return }
        busy = true
        defer { busy = false }
        guard await persist().value, await model.rememberCurrentNetwork() else { error = "onboarding.networkUnavailable"; return }
        networkRemembered = true
    }

    /// Unknown operations are inspected on a separate attempt. No fallthrough
    /// from an unsuccessful readback to a repeated write in the same click.
    func apply() async {
        guard !busy, !checking, storageError == nil, let model else { return }
        await refresh()
        guard prerequisitesReady else { error = "onboarding.prerequisitesChanged"; return }
        busy = true; error = nil
        defer { busy = false }
        let intentGeneration = record.generation
        if chargeChosen {
            let expectedTarget = record.habit == .desk ? record.targetLimit : model.registeredTarget
            if record.charge == .unknown || record.charge == .requested {
                record.charge = model.setupChargeMatches(expectedTarget) ? .confirmed : .failed
                guard await persist().value else { return }
                if record.charge != .confirmed { error = "onboarding.chargeFailed"; return }
            }
            if record.charge == .confirmed && !model.setupChargeMatches(expectedTarget) {
                record.charge = .failed; _ = await persist().value; error = "onboarding.chargeChanged"; return
            }
            if record.charge != .confirmed {
                record.charge = .requested
                guard await persist().value, intentGeneration == record.generation else { return }
                record.charge = await model.applySetupCharge(habit: record.habit, target: record.targetLimit)
                guard await persist().value else { return }
                guard intentGeneration == record.generation else { return }
                guard record.charge == .confirmed else { error = "onboarding.chargeFailed"; return }
            }
            model.confirmSetupCharge()
        }
        if record.task != .none {
            model.clearTaskStopResultForSetup()
            if record.ordinary == .confirmed, await model.inspectSetupAssertion() != true { record.ordinary = .failed }
            if record.task == .lid && record.lid == .confirmed {
                if await model.inspectSetupLid() != true { record.lid = .unknown }
            }
            if record.ordinary == .unknown || record.lid == .unknown || record.ordinary == .requested || record.lid == .requested {
                let ordinary = await model.inspectSetupAssertion()
                record.ordinary = ordinary == true ? .confirmed : ordinary == false ? .failed : .unknown
                if record.task == .lid {
                    let lid = await model.inspectSetupLid()
                    record.lid = lid == true ? .confirmed : lid == false ? .failed : .unknown
                }
                guard await persist().value else { return }
                guard record.ordinary == .confirmed && (record.task != .lid || record.lid == .confirmed) else { error = "onboarding.awakeFailed"; return }
            }
            if record.ordinary != .confirmed || record.task == .lid && record.lid != .confirmed {
                let applyOrdinary = record.ordinary != .confirmed
                let applyLid = record.task == .lid && record.lid != .confirmed
                if applyOrdinary { record.ordinary = .requested }
                if applyLid { record.lid = .requested }
                guard await persist().value, intentGeneration == record.generation else { return }
                let results = await model.applySetupAwake(record.task, applyOrdinary: applyOrdinary, applyLid: applyLid)
                guard intentGeneration == record.generation else { return }
                (record.ordinary, record.lid) = results
                guard await persist().value else { return }
                guard record.ordinary == .confirmed && (record.task != .lid || record.lid == .confirmed) else { error = "onboarding.awakeFailed"; return }
            }
            if record.task == .lid { model.confirmSetupLid() }
        }
        guard intentGeneration == record.generation else { return }
        await model.completeSetup()
        guard intentGeneration == record.generation else { return }
        guard model.configError == nil else { error = "config.saveFailed"; return }
        record.completed = true; record.step = 5
        if !(await persist().value) { record.completed = false; record.step = 4 }
    }

    @discardableResult func recordStopRequested(lidRequired: Bool) -> Task<Bool, Never> {
        record.stopPending = true
        record.stopLidRequired = lidRequired
        record.generation &+= 1
        return persist()
    }
    @discardableResult func recordStopConfirmed() async -> Bool {
        let pending = record
        record.stopPending = false
        record.stopLidRequired = nil
        record.task = .none; record.ordinary = .idle; record.lid = .idle
        let saved = await persist().value
        if !saved, record.generation == pending.generation { record = pending }
        return saved
    }
}
