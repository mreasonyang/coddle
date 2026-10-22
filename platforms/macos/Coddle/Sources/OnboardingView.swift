import SwiftUI

struct OnboardingView: View {
    @ObservedObject var flow: OnboardingCoordinator
    @ObservedObject var model: AppModel
    @ObservedObject var l10n: Localizer
    var close: () -> Void
    var openPanel: () -> Void
    @State private var confirmDowngrade = false
    @AccessibilityFocusState private var headingFocused: Bool
    @FocusState private var focusedChoice: String?
    @Environment(\.colorScheme) private var colorScheme

    private func t(_ key: String) -> String { l10n.tr(key) }
    private var phase: Int { flow.record.step < 2 ? 0 : flow.record.step < 4 ? 1 : 2 }

    var body: some View {
        VStack(spacing: 0) {
            if flow.record.step < 5 {
                HStack(spacing: 4) {
                    ForEach(0..<3) { i in
                        HStack(spacing: 5) {
                            Image(systemName: i < phase ? "checkmark.circle.fill" : "\(i + 1).circle.fill")
                            Text(t(["onboarding.phase.choose", "onboarding.phase.prepare", "onboarding.phase.apply"][i]))
                        }
                        .font(.system(size: 11, weight: i == phase ? .semibold : .regular))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .coddleSecondaryForeground(i == phase ? Color.primary : Color.primary.opacity(0.8), when: i != phase)
                        .background(i == phase ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                    }
                }.padding(14)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(l10n.tr("onboarding.phaseLabel", phase + 1, 3))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = flow.storageError {
                        statusCard(l10n.tr(error), symbol: "externaldrive.badge.exclamationmark")
                        Button(t("onboarding.retrySave")) { Task { await flow.retryStorage() } }.accessibilityIdentifier("onboarding.retryStorage")
                    }
                    if let error = flow.error {
                        statusCard(l10n.tr(error), symbol: "exclamationmark.triangle")
                    }
                    if flow.checking { ProgressView(t("onboarding.checking")).controlSize(.small) }
                    page
                }.padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().opacity(0.4)
            HStack(spacing: 8) {
                if flow.record.step == 5 {
                    Spacer()
                    if flow.stopNeedsRetry || model.taskStopBusy {
                        Button(t("onboarding.enterPanel"), action: openPanel).accessibilityIdentifier("onboarding.finish")
                        Button(t(model.taskStopBusy ? "onboarding.stopping" : "onboarding.retryStop")) { model.restoreSystemDefaults() }
                            .buttonStyle(.borderedProminent).disabled(model.taskStopBusy)
                            .accessibilityIdentifier("onboarding.retryStop")
                    } else {
                        Button(t("onboarding.enterPanel"), action: openPanel).buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("onboarding.finish")
                    }
                } else {
                    Button(t("onboarding.later"), action: close).buttonStyle(.plain).coddleSecondaryForeground(Color.primary.opacity(0.8))
                        .accessibilityIdentifier("onboarding.later")
                    Spacer(minLength: 4)
                    if flow.record.step > 0 && !flow.record.hasApplicationAttempt {
                        Button(t("onboarding.back")) { flow.back() }.disabled(flow.busy)
                            .accessibilityIdentifier("onboarding.back")
                    }
                    if flow.record.step == 4 && flow.requiresLimitSelection && !model.taskStopBusy && !flow.stopNeedsRetry {
                        Button(t(flow.record.hasApplicationAttempt ? "onboarding.keepCurrentChargeState" : "onboarding.chooseAvailableLimit")) {
                            if flow.record.hasApplicationAttempt { flow.keepCurrentChargeSetup() }
                            else { flow.returnToLimitSelection() }
                        }.buttonStyle(.borderedProminent).disabled(flow.busy || flow.checking)
                            .accessibilityIdentifier("onboarding.repairLimit")
                    } else if flow.record.step == 4 && needsPreparationRepair && !model.taskStopBusy && !flow.stopNeedsRetry {
                        Button(t("onboarding.repairPreparation")) { flow.returnToPreparation() }
                            .buttonStyle(.borderedProminent).disabled(flow.busy || flow.checking)
                            .accessibilityIdentifier("onboarding.repairPreparation")
                    } else {
                        Button(primaryLabel) {
                            if flow.record.step == 4 && flow.stopNeedsRetry { model.restoreSystemDefaults() }
                            else if flow.record.step == 4 { Task { await flow.apply() } }
                            else { flow.next() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(flow.record.step == 4 && (flow.stopNeedsRetry || model.taskStopBusy) ? model.taskStopBusy || flow.busy : !flow.canAdvance)
                        .accessibilityIdentifier("onboarding.next")
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .font(.system(size: 12)).controlSize(.regular).padding(14)
        }
        .frame(minWidth: 440, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .background { CoddlePanelBackdrop() }
        .environment(\.coddleTheme, model.activeTheme)
        .task { await flow.refresh(); focusCurrentChoice() }
        .onChange(of: flow.record.step) { _ in headingFocused = true; focusCurrentChoice() }
        .onChange(of: flow.error) { value in if let value { announce(l10n.tr(value)) } }
        .onChange(of: flow.storageError) { value in if let value { announce(l10n.tr(value)) } }
        .alert(t("onboarding.downgradeTitle"), isPresented: $confirmDowngrade) {
            Button(t("onboarding.downgrade")) { flow.skipHelper(downgrade: true) }
            Button(t("onboarding.cancel"), role: .cancel) {}
        } message: { Text(t("onboarding.downgradeBody")) }
    }

    private var primaryLabel: String {
        if flow.record.step == 4 && (flow.stopNeedsRetry || model.taskStopBusy) { return t(model.taskStopBusy ? "onboarding.stopping" : "onboarding.retryStop") }
        if flow.busy { return t("onboarding.working") }
        if flow.record.step != 4 { return t("onboarding.next") }
        if [flow.record.charge, flow.record.ordinary, flow.record.lid].contains(.unknown) { return t("onboarding.checkResults") }
        if flow.record.hasApplicationAttempt { return t("onboarding.retryFailed") }
        if flow.record.task != .none { return t(flow.chargeChosen ? "onboarding.applyBoth" : "onboarding.applyAwake") }
        return t(flow.chargeChosen ? "onboarding.applyCharge" : "onboarding.finishSetup")
    }
    private var needsPreparationRepair: Bool { !flow.helperResolved || !flow.loginResolved || !flow.notificationResolved }
    private func announce(_ message: String) {
        guard let window = NSApplication.shared.keyWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
    private func focusCurrentChoice() {
        if flow.record.step == 0 { focusedChoice = "onboarding.habit." + flow.record.habit.rawValue }
        else if flow.record.step == 1 { focusedChoice = "onboarding.task." + flow.record.task.rawValue }
        else { focusedChoice = nil }
    }

    @ViewBuilder private var page: some View {
        switch flow.record.step {
        case 0: habitPage
        case 1: taskPage
        case 2: helperPage
        case 3: continuityPage
        case 4: confirmationPage
        default: completionPage
        }
    }
    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t(title)).font(.system(size: 19, weight: .semibold)).accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused)
            Text(t(detail)).font(.system(size: 11.5)).coddleSecondaryForeground(Color.primary.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 4).padding(.bottom, 4)
    }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(13).frame(maxWidth: .infinity, alignment: .leading).coddleCard(theme: model.activeTheme)
    }
    private func note(_ key: String, symbol: String = "info.circle") -> some View {
        Label(t(key), systemImage: symbol).font(.system(size: 11)).coddleSecondaryForeground(Color.primary.opacity(0.8))
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
    }
    private func statusCard(_ text: String, symbol: String) -> some View {
        card { Label(text, systemImage: symbol).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true) }
    }
    private func choice(_ title: String, _ detail: String, icon: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: { focusedChoice = id; action() }) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 24)).foregroundStyle(selected ? Color.accentColor : Color.secondary).frame(width: 32)
                VStack(alignment: .leading, spacing: 5) {
                    Text(t(title)).font(.system(size: 13, weight: .semibold))
                    Text(t(detail)).font(.system(size: 11)).coddleSecondaryForeground(Color.primary.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }.padding(13).frame(minHeight: 76).coddleCard(theme: model.activeTheme)
                .overlay(RoundedRectangle(cornerRadius: model.activeTheme == .classic ? 10 : 14, style: .continuous).stroke(selected && focusedChoice != id ? Color.accentColor : .clear, lineWidth: 1.2))
        }.buttonStyle(.plain)
            .contentShape(.focusEffect, RoundedRectangle(cornerRadius: model.activeTheme == .classic ? 10 : 14, style: .continuous))
            .focusable().focused($focusedChoice, equals: id)
            .disabled(flow.busy || flow.record.hasApplicationAttempt)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier(id)
    }

    @ViewBuilder private var habitPage: some View {
        if !flow.hardwareKnown {
            heading("onboarding.deviceTitle", "onboarding.deviceUnknown")
            Button(t("onboarding.recheck")) { Task { await flow.refresh() } }.disabled(flow.checking)
        } else if !flow.canCharge {
            heading("onboarding.deviceTitle", "onboarding.chargeUnsupported")
            note("onboarding.helperNotHardware")
        } else {
            heading("onboarding.habitTitle", "onboarding.habitBody")
            choice("onboarding.desk", "onboarding.deskBody", icon: "desktopcomputer", selected: flow.record.habit == .desk, id: "onboarding.habit.desk") { flow.chooseHabit(.desk) }
                .onMoveCommand { direction in
                    if direction == .down || direction == .right { flow.chooseHabit(.mobile); focusCurrentChoice() }
                }
            choice("onboarding.mobile", "onboarding.mobileBody", icon: "bag", selected: flow.record.habit == .mobile, id: "onboarding.habit.mobile") { flow.chooseHabit(.mobile) }
                .onMoveCommand { direction in
                    if direction == .up || direction == .left { flow.chooseHabit(.desk); focusCurrentChoice() }
                }
            card {
                if let limit = flow.selectedLimit {
                    Text(t(limit == 80 ? "onboarding.recommended" : "onboarding.selectedLimit")).font(.system(size: 10)).coddleSecondaryForeground(Color.primary.opacity(0.8))
                    Label(l10n.tr("onboarding.dailyLimit", limit), systemImage: "battery.75percent").font(.system(size: 12, weight: .medium))
                    if flow.record.habit == .mobile { Text(smartText).font(.system(size: 11)).coddleSecondaryForeground(Color.primary.opacity(0.8)) }
                    else { Text(t("onboarding.deskRecommendation")).font(.system(size: 11)).coddleSecondaryForeground(Color.primary.opacity(0.8)) }
                } else {
                    Text(t("onboarding.chooseAvailableLimit")).font(.system(size: 12, weight: .medium))
                }
                if !flow.limits.contains(80) || flow.requiresLimitSelection {
                    Text(t(flow.limits.contains(80) ? "onboarding.chooseAvailableLimit" : "onboarding.limitUnavailable")).font(.system(size: 11))
                    Picker(t("onboarding.availableLimits"), selection: Binding<Int?>(get: { flow.selectedLimit }, set: { if let value = $0 { flow.chooseLimit(value) } })) {
                        Text(t("onboarding.chooseAvailableLimit")).tag(Optional<Int>.none)
                        ForEach(flow.limits, id: \.self) { Text("\($0)%").tag(Optional($0)) }
                    }
                    .accessibilityIdentifier("onboarding.availableLimits")
                }
            }
            Button(t("onboarding.chargeSkip")) { flow.chooseHabit(.unchanged); flow.next() }.buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.system(size: 11))
                .accessibilityIdentifier("onboarding.chargeSkip")
        }
    }
    private var taskPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("onboarding.taskTitle", "onboarding.taskBody")
            choice("onboarding.taskNone", "onboarding.taskNoneBody", icon: "moon", selected: flow.record.task == .none, id: "onboarding.task.none") { flow.chooseTask(.none) }
            choice(flow.hasLid ? "onboarding.taskOpen" : "onboarding.taskDesktop", "onboarding.taskOpenBody", icon: "play", selected: flow.record.task == .open, id: "onboarding.task.open") { flow.chooseTask(.open) }
            if flow.hasLid { choice("onboarding.taskLid", "onboarding.taskLidBody", icon: "laptopcomputer", selected: flow.record.task == .lid, id: "onboarding.task.lid") { flow.chooseTask(.lid) } }
            if flow.record.task != .none {
                note("onboarding.persistentAwake")
                if flow.hasBattery { note("onboarding.bagAdvice", symbol: "shield") }
            }
        }
        .onMoveCommand { direction in
            let tasks: [OnboardingTask] = flow.hasLid ? [.none, .open, .lid] : [.none, .open]
            guard let index = tasks.firstIndex(of: flow.record.task) else { return }
            if direction == .down || direction == .right { flow.chooseTask(tasks[min(tasks.count - 1, index + 1)]) }
            if direction == .up || direction == .left { flow.chooseTask(tasks[max(0, index - 1)]) }
            focusCurrentChoice()
        }
    }
    private var helperStatusKey: String {
        if flow.helperReady { return "onboarding.helperReady" }
        switch flow.helperState { case .absent: return "onboarding.helperAbsent"; case .unavailable: return "onboarding.helperUnavailable"; case .outdated, .ready: return "onboarding.helperOutdated" }
    }
    private var helperPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(flow.record.task == .lid ? "onboarding.helperLidTitle" : "onboarding.helperTitle", "onboarding.helperBody")
            card {
                Image(systemName: flow.helperReady ? "checkmark.circle" : "power").font(.system(size: 29)).foregroundStyle(Color.accentColor).frame(maxWidth: .infinity)
                Text(t(flow.helperReady ? "onboarding.helperReady" : "onboarding.helperName")).font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity)
                if flow.hasLid { Label(t("onboarding.helperLidBenefit"), systemImage: "laptopcomputer").font(.system(size: 12)) }
                if model.availableEnergyModes.count > 1 { Label(t("onboarding.helperEnergyBenefit"), systemImage: "bolt").font(.system(size: 12)) }
                Text(t(helperStatusKey)).font(.system(size: 11)).coddleSecondaryForeground(Color.primary.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                if !flow.helperReady {
                    Button(t(flow.helperState == .outdated ? "onboarding.updateHelper" : "onboarding.installHelper")) { Task { await flow.installHelper() } }
                        .buttonStyle(.borderedProminent).disabled(flow.busy || flow.checking || flow.storageError != nil).frame(maxWidth: .infinity)
                        .accessibilityIdentifier("onboarding.installHelper")
                    Button(t("onboarding.recheck")) { Task { await flow.refresh() } }.disabled(flow.busy || flow.checking)
                }
            }
            if flow.helperState == .unavailable {
                note("onboarding.helperRecovery")
                Button(t("onboarding.loginSettings")) { Task { await flow.openSettings(notification: false) } }
            }
            note("onboarding.helperPrivacy")
            if flow.busy { ProgressView(t("onboarding.installing")).controlSize(.small) }
            if !flow.helperReady {
                Button(t(flow.record.task == .lid ? "onboarding.downgrade" : "onboarding.skipHelper")) {
                    if flow.record.task == .lid { confirmDowngrade = true } else { flow.skipHelper() }
                }.buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.system(size: 11)).disabled(flow.busy)
                if flow.record.helper == .skipped { note("onboarding.helperSkipped") }
            }
        }
    }
    private var continuityPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("onboarding.continuityTitle", "onboarding.continuityBody")
            card {
                Label(t("onboarding.loginTitle"), systemImage: "power").font(.system(size: 12, weight: .semibold))
                Text(t(flow.record.task != .none ? "onboarding.loginAwakeBody" : flow.chargeChosen ? "onboarding.loginBody" : "onboarding.loginStatusBody")).font(.system(size: 11)).coddleSecondaryForeground(Color.primary.opacity(0.8))
                Text(flow.record.login == .skipped && flow.loginResolved ? t("onboarding.manualLogin") : l10n.tr(flow.loginState == "login.notFound" && flow.record.loginRegistration == .idle ? "login.off" : flow.loginState)).font(.system(size: 11))
                if flow.loginState != "login.enabled" && flow.record.login != .skipped {
                    HStack {
                        Button(t(flow.loginState == "login.requiresApproval" ? "onboarding.loginSettings" : "onboarding.enableLogin")) {
                            if flow.loginState == "login.requiresApproval" { Task { await flow.openSettings(notification: false) } }
                            else { Task { await flow.chooseLogin(true) } }
                        }.buttonStyle(.borderedProminent)
                        Spacer(minLength: 4)
                        Button(t("onboarding.skipLogin")) { Task { await flow.chooseLogin(false) } }.buttonStyle(.plain)
                    }.font(.system(size: 11))
                } else if flow.record.login == .skipped {
                    Button(t("onboarding.enableLogin")) { Task { await flow.chooseLogin(true) } }
                }
                if flow.loginState == "login.notFound" && flow.record.loginRegistration != .idle { Text(t("onboarding.installLocation")).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true) }
            }
            if flow.hasBattery {
                card {
                    Label(t("onboarding.notificationTitle"), systemImage: "bell").font(.system(size: 12, weight: .semibold))
                    Text(t("onboarding.notificationBody")).font(.system(size: 11)).coddleSecondaryForeground(Color.primary.opacity(0.8))
                    Text(flow.record.reminder == .disabled ? t("onboarding.reminderDisabled") : l10n.tr(flow.notificationState)).font(.system(size: 11))
                    if flow.record.reminder == .enabled && flow.notificationState == "notification.ready" {
                        Button(t("onboarding.testNotification")) { Task { await flow.testNotification() } }
                        if let state = flow.testState { Text(l10n.tr(state)).font(.system(size: 11)).coddleSecondaryForeground(Color.primary.opacity(0.8)) }
                    } else {
                        HStack {
                            Button(t(["notification.denied", "notification.alertsOff"].contains(flow.notificationState) ? "onboarding.notificationSettings" : "onboarding.allowNotification")) {
                                if ["notification.denied", "notification.alertsOff"].contains(flow.notificationState) { Task { await flow.openSettings(notification: true) } }
                                else { Task { await flow.chooseReminder(true) } }
                            }.buttonStyle(.borderedProminent)
                            Spacer(minLength: 4)
                            if flow.record.reminder != .disabled { Button(t("onboarding.skipNotification")) { Task { await flow.chooseReminder(false) } }.buttonStyle(.plain) }
                        }.font(.system(size: 11))
                    }
                }
            }
            Button(t("onboarding.recheck")) { Task { await flow.refresh() } }.font(.system(size: 11)).disabled(flow.busy || flow.checking)
            note("onboarding.returnToCheck")
        }.disabled(flow.busy || flow.storageError != nil)
    }
    private func resultRow(_ label: String, _ result: SetupResult) -> some View {
        HStack(alignment: .top) {
            Text(t(label)); Spacer()
            HStack(spacing: 4) {
                if result == .confirmed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true) }
                Text(t(result.localizationKey))
            }
        }.font(.system(size: 11)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(label)
    }
    private var results: some View {
        card {
            if flow.chargeChosen { resultRow("onboarding.chargeResult", flow.requiresLimitSelection ? .unknown : flow.record.charge) }
            if !flow.hasStopResult && flow.record.task != .none { resultRow("onboarding.ordinaryResult", flow.record.ordinary) }
            if !flow.hasStopResult && flow.record.task == .lid { resultRow("onboarding.lidResult", flow.record.lid) }
        }
    }
    private var confirmationPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            if flow.hasStopResult {
                card { TaskStopView(model: model, l10n: l10n) }
                    .accessibilityElement(children: .contain).accessibilityIdentifier("onboarding.currentStopStatus")
            }
            if !flow.hasStopResult {
                heading(flow.chargeChosen || flow.record.task != .none ? "onboarding.confirmTitle" : "onboarding.confirmNoChangesTitle",
                        flow.chargeChosen || flow.record.task != .none ? "onboarding.confirmBody" : "onboarding.confirmNoChangesBody")
            }
            if flow.requiresLimitSelection {
                statusCard(t("onboarding.chooseAvailableLimit"), symbol: "exclamationmark.triangle")
            }
            if flow.record.hasApplicationAttempt {
                if flow.chargeChosen || !flow.hasStopResult { results }
            }
            else {
                if flow.chargeChosen && !flow.requiresLimitSelection {
                    card {
                        Label(l10n.tr("onboarding.dailyLimit", flow.record.targetLimit), systemImage: "battery.75percent").font(.system(size: 12, weight: .medium))
                        Text(l10n.tr("onboarding.limitChange", flow.currentLimit.map(String.init) ?? "—", flow.record.targetLimit)).font(.system(size: 11)).coddleSecondaryForeground(Color.primary.opacity(0.8))
                        if flow.record.habit == .mobile { Text(smartText).font(.system(size: 11)).coddleSecondaryForeground(Color.primary.opacity(0.8)) }
                    }
                }
                if flow.record.task != .none { card { Label(t(flow.record.task == .lid ? "onboarding.lidPlan" : "onboarding.openPlan"), systemImage: "play"); note("onboarding.persistentAwake") }.font(.system(size: 12)) }
                if !flow.chargeChosen && flow.record.task == .none { note("onboarding.noChanges") }
            }
            card {
                if needsPreparationRepair { note("onboarding.preparationNeedsAttention", symbol: "exclamationmark.triangle") }
                summary("onboarding.helperName", !flow.helperUseful ? "onboarding.notNeeded" : flow.helperReady ? "onboarding.helperReady" : flow.helperResolved ? "onboarding.helperSkippedShort" : helperStatusKey)
                if !flow.helperResolved { preparationRepair("onboarding.repairHelper") }
                summary("onboarding.loginTitle", flow.loginSummaryKey)
                if !flow.loginResolved { preparationRepair("onboarding.repairLogin") }
                if flow.hasBattery {
                    summary("onboarding.notificationTitle", flow.notificationSummaryKey)
                    if !flow.notificationResolved { preparationRepair("onboarding.repairNotification") }
                }
            }
            if flow.hasBattery && flow.record.task != .none {
                card {
                    Label(t("onboarding.networkTitle"), systemImage: "wifi").font(.system(size: 12, weight: .medium))
                    Text(t(flow.networkRemembered ? "onboarding.networkRemembered" : "onboarding.networkBody")).font(.system(size: 11)).coddleSecondaryForeground(Color.primary.opacity(0.8))
                    if !flow.networkRemembered { Button(t("onboarding.rememberNetwork")) { Task { await flow.rememberNetwork() } }.disabled(!flow.networkAvailable || flow.busy) }
                }
            }
            if !flow.hasStopResult && flow.record.hasApplicationAttempt && flow.record.task != .none { TaskStopView(model: model, l10n: l10n) }
        }
    }
    private func preparationRepair(_ id: String) -> some View {
        Button(t("onboarding.repairPreparation")) { flow.returnToPreparation(step: id == "onboarding.repairHelper" ? 2 : 3) }
            .font(.system(size: 11)).disabled(flow.busy || flow.checking).accessibilityIdentifier(id)
    }
    private func summary(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(t(label)); Spacer(); Text(t(value)).coddleSecondaryForeground(Color.primary.opacity(0.8)).multilineTextAlignment(.trailing) }.font(.system(size: 11))
    }
    private var smartText: String {
        if let hour = flow.predictedHour { return l10n.tr("onboarding.smartPrediction", hour) }
        return t("onboarding.smartLearning")
    }
    private var completionPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            if flow.hasStopResult {
                Text(t("onboarding.stopTask")).font(.system(size: 19, weight: .semibold)).accessibilityAddTraits(.isHeader)
                card { TaskStopView(model: model, l10n: l10n) }
                    .accessibilityElement(children: .contain).accessibilityIdentifier("onboarding.currentStopStatus")
            } else {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green).padding(.top, 12)
                heading(flow.record.task != .none ? "onboarding.awakeStarted" : flow.chargeChosen ? "onboarding.chargeStarted" : "onboarding.readyTitle", "onboarding.resultsBody")
            }
            if flow.chargeChosen || (!flow.hasStopResult && flow.record.task != .none) { results }
            if flow.record.habit == .mobile { Text(smartText).font(.system(size: 11)).coddleSecondaryForeground(Color.primary.opacity(0.8)) }
            if flow.record.task != .none && !flow.hasStopResult { note("onboarding.awakeActiveBody") }
            card {
                summary("onboarding.loginTitle", flow.loginSummaryKey)
                if flow.hasBattery { summary("onboarding.notificationTitle", flow.notificationSummaryKey) }
                if flow.record.helper == .skipped { summary("onboarding.helperName", "onboarding.helperSkippedShort") }
            }
            card {
                Text(t("onboarding.firstAction")).font(.system(size: 12, weight: .semibold))
                Text(t(flow.record.task != .none ? "onboarding.firstStop" : flow.temporaryFullAvailable ? "onboarding.firstFull" : !flow.pluggedIn && flow.chargeChosen ? "onboarding.firstConnect" : "onboarding.firstStatus"))
                    .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                Text(t("onboarding.tutorialOptional")).font(.system(size: 10)).coddleSecondaryForeground(Color.primary.opacity(0.8))
            }
            note("onboarding.findMenu", symbol: "menubar.rectangle")
        }
    }
}

struct TaskStopView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var l10n: Localizer
    var recoveryOnly = false
    private var retryRequired: Bool {
        model.onboarding?.record.stopPending == true || ["onboarding.stopPartial", "onboarding.stopSaveFailed"].contains(model.taskStopStatus)
    }
    private func stoppedKey(_ result: SetupResult) -> String {
        result == .confirmed ? "onboarding.stopConfirmed" : result == .requested ? "onboarding.stopping" : "onboarding.stopUnconfirmed"
    }
    private var statusKey: String {
        model.taskStopBusy ? "onboarding.stopping" : model.taskStopStatus.isEmpty ? "onboarding.stopPartial" : model.taskStopStatus
    }
    var body: some View {
        if !recoveryOnly || model.taskStopBusy || retryRequired {
            VStack(alignment: .leading, spacing: 6) {
                Button { model.restoreSystemDefaults() } label: {
                    Label(l10n.tr(model.taskStopBusy ? "onboarding.stopping" : retryRequired ? "onboarding.retryStop" : "onboarding.stopTask"), systemImage: "arrow.counterclockwise")
                        .font(CoddleTypography.microMeta)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .disabled(model.taskStopBusy)
                    .accessibilityIdentifier(recoveryOnly || retryRequired ? "retry-stop-keep-awake" : "stop-keep-awake")
                    .help(l10n.tr("display.restoreHelp"))
                    .accessibilityHint(l10n.tr("display.restoreHelp"))
                if !model.taskStopStatus.isEmpty || model.taskStopBusy || retryRequired {
                    HStack { Text(l10n.tr("onboarding.ordinaryResult")); Spacer(); Text(l10n.tr(model.onboarding?.ordinaryResultKey ?? stoppedKey(model.taskStopOrdinary))) }.font(.system(size: 11))
                    HStack { Text(l10n.tr("display.keepAwake")); Spacer(); Text(l10n.tr(stoppedKey(model.taskStopDisplay))) }.font(.system(size: 11))
                    HStack { Text(l10n.tr("onboarding.lidResult")); Spacer(); Text(l10n.tr(model.onboarding?.lidResultKey ?? stoppedKey(model.taskStopLid))) }.font(.system(size: 11))
                    Text(l10n.tr(statusKey)).font(.system(size: 11)).coddleSecondaryForeground(Color.primary.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct OnboardingMenuView: View {
    @ObservedObject var flow: OnboardingCoordinator
    @ObservedObject var model: AppModel
    @ObservedObject var l10n: Localizer
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.tr("onboarding.welcome")).font(.headline)
            Text(l10n.tr("onboarding.menuBody")).font(.system(size: 12)).coddleSecondaryForeground(Color.primary.opacity(0.8))
            Button(l10n.tr("onboarding.continueSetup")) { NotificationCenter.default.post(name: .coddleShowOnboarding, object: nil) }.buttonStyle(.borderedProminent)
            TaskStopView(model: model, l10n: l10n)
        }.padding(16).frame(width: 340)
    }
}
