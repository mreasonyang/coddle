import SwiftUI

/// Small explanations reuse the established typography, spacing and colors.
struct ConfigFeedbackView: View {
    var suppressAwakeOwnedError = false
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var l10n: Localizer
    var body: some View {
        if let error = model.configError, !(suppressAwakeOwnedError && model.awakeOwnsConfigError) {
            VStack(alignment: .leading, spacing: 4) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("config-error")
                if model.configCanRetrySave {
                    Button(l10n.tr("config.retrySave")) { model.saveConfig() }
                        .accessibilityIdentifier("retry-config-save")
                }
            }
            .font(CoddleTypography.microMeta)
            .foregroundStyle(.primary)
            .onAppear { announce(error) }
            .onChange(of: error) { announce($0) }
        }
    }
    private func announce(_ message: String) {
        guard let window = NSApplication.shared.keyWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

struct ChargeFeedbackView: View {
    var compact = false
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var l10n: Localizer
    private func target(_ value: Int) -> String { value == 0 ? l10n.tr("limit.off") : "\(value)%" }
    private func statusKey(_ state: String) -> String {
        guard compact else { return state }
        switch state {
        case "charge.applying": return "panel.charge.applying"
        case "charge.waitingRecovery": return "panel.charge.waitingRecovery"
        case "charge.retrying": return "panel.charge.retrying"
        default: return state
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let state = model.chargeOperationStatus {
                Text(l10n.tr(statusKey(state),
                             target(model.chargeOperationTarget),
                             model.currentLimit.map(target) ?? l10n.tr("power.unavailable")))
                    .accessibilityIdentifier("charge-operation-status")
            }
            if let error = model.chargeFeedbackError {
                PanelOperationError(message: error)
            }
            if model.temporaryFullChargeActive && (!compact || model.chargeOperationStatus == nil) {
                Text(l10n.tr(compact ? "panel.charge.temporary" : "charge.temporary", target(model.registeredTarget)))
                    .help(l10n.tr("charge.temporary", target(model.registeredTarget)))
                    .accessibilityHint(l10n.tr("charge.temporary", target(model.registeredTarget)))
                    .accessibilityIdentifier("temporary-charge-intent")
            }
        }
        .font(CoddleTypography.microMeta)
        .coddleSecondaryForeground(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SmartPlanView: View {
    var compact: Bool
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var l10n: Localizer
    var body: some View {
        let hour = model.predictedUnplugHour ?? 0
        let start = (hour + 24 - model.topupLeadHours) % 24
        let plan = model.predictedUnplugHour == nil || model.topupLeadHours == 0
            ? l10n.tr(model.smartPlanKey, model.holdLimit)
            : l10n.tr(model.smartPlanKey, model.holdLimit, String(format: "%02d:00", hour), String(format: "%02d:00", start), model.topupLimit)
        let summary = model.topupLeadHours == 0
            ? l10n.tr("panel.smart.topupOff")
            : model.predictedUnplugHour == nil
                ? l10n.tr("panel.smart.learning")
                : model.smartPlanKey == "smart.toppingUp"
                    ? l10n.tr("panel.smart.topupWindow")
                    : l10n.tr("panel.smart.plan", String(format: "%02d:00", start))
        Text(compact ? summary : plan)
            .font(CoddleTypography.microMeta)
            .coddleSecondaryForeground(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("smart-charge-plan")
            .help(plan + "\n" + l10n.tr("smart.planDetail"))
            .accessibilityHint(plan + "\n" + l10n.tr("smart.planDetail"))
    }
}

struct AwakeFeedbackView: View {
    var showsDetails = true
    var compact = false
    var exceptionsOnly = false
    var showsGuardStatus = true
    var detailsExpansion: Binding<Bool>? = nil
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var l10n: Localizer
    @Environment(\.coddleOpenAwakeSettings) private var openAwakeSettings
    @State private var localDetailsExpanded = false
    private var detailsBinding: Binding<Bool> { detailsExpansion ?? $localDetailsExpanded }

    private var issues: [AwakeFeedbackIssue] {
        model.awakeFeedbackIssues.filter {
            (showsGuardStatus || $0.id != .protection) && (compact || $0.id != .component)
        }
    }
    private var diagnostics: [String] { issues.flatMap(\.diagnostics) }
    private func hasAction(_ action: AwakeFeedbackIssue.Action) -> Bool {
        issues.contains { $0.action == action }
    }
    private func state(_ active: Bool, pending: Bool) -> String {
        l10n.tr(pending ? "awake.pending" : active ? "awake.on" : "awake.off")
    }
    private func stopState(_ result: SetupResult) -> String {
        l10n.tr(result == .confirmed ? "onboarding.stopConfirmed" :
            result == .requested ? "onboarding.stopping" : "onboarding.stopUnconfirmed")
    }
    private var currentStates: String {
        l10n.tr("awake.summary",
            state(model.systemAwakeApplied, pending: model.assertionsApplying || model.awakeFeedbackError != nil),
            state(model.displayAwakeApplied, pending: model.assertionsApplying || model.awakeFeedbackError != nil),
            state(model.lidAwakeApplied, pending: model.lidStateUnconfirmed || model.awakeLidControlPending))
    }

    var body: some View {
        if !issues.isEmpty || !exceptionsOnly {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            ForEach(issues) { issue in
                Text(l10n.tr(issue.summaryKey))
                    .accessibilityIdentifier("awake-feedback-" + issue.id.rawValue)
            }
            if hasAction(.install) {
                Text(l10n.tr("helper.installApproval"))
                Button(l10n.tr(model.helperBusy ? "helper.installing" :
                    model.helperFilesPresent ? "helper.repair" : "helper.install")) { model.installHelper() }
                    .disabled(model.helperBusy || model.energyModeBusy)
                    .accessibilityIdentifier("install-keep-awake-component")
            }
            if hasAction(.retryStop) {
                Button(l10n.tr("onboarding.retryStop")) { model.restoreSystemDefaults() }
                    .disabled(model.taskStopBusy)
                    .accessibilityIdentifier("retry-stop-keep-awake")
            } else if hasAction(.retry) {
                Button(l10n.tr("awakeFeedback.retry")) { model.retryAwakeFeedback() }
                    .disabled(model.assertionsApplying || model.awakeLidControlPending || model.helperBusy)
                    .accessibilityIdentifier("retry-keep-awake")
            }
            if hasAction(.protection) {
                Button(l10n.tr("awakeFeedback.configureProtection")) { openAwakeSettings() }
                    .accessibilityIdentifier("review-away-protection")
            }
            if hasAction(.component) {
                Button(l10n.tr("helper.manage")) { openAwakeSettings() }
                    .accessibilityIdentifier("review-system-component")
            }
            if hasAction(.retryDisplay) {
                Button(l10n.tr("awakeFeedback.retry")) { model.sleepDisplayNow() }
                    .disabled(!model.canSleepDisplayNow)
                    .accessibilityIdentifier("retry-display-sleep")
            }
            if hasAction(.retrySettings) {
                Button(l10n.tr("awakeFeedback.retry")) { model.openDisplayTimeoutSettings() }
                    .accessibilityIdentifier("retry-display-settings")
            }
            if showsDetails && (!issues.isEmpty || !exceptionsOnly) {
                DisclosureGroup(isExpanded: detailsBinding) {
                    VStack(alignment: .leading, spacing: 4) {
                        if model.awakeStopNeedsRecovery {
                            HStack { Text(l10n.tr("onboarding.ordinaryResult")); Spacer(); Text(stopState(model.taskStopOrdinary)) }
                            HStack { Text(l10n.tr("display.keepAwake")); Spacer(); Text(stopState(model.taskStopDisplay)) }
                            HStack { Text(l10n.tr("onboarding.lidResult")); Spacer(); Text(stopState(model.taskStopLid)) }
                        } else {
                            Text(currentStates)
                        }
                        if showsGuardStatus && model.keepAwake && model.keepAwakeOnLidClosed {
                            Text(model.guardStatusText(l10n))
                                .accessibilityIdentifier("guard-readiness")
                        }
                        ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, message in
                            Text(l10n.tr(message)).textSelection(.enabled)
                        }
                    }
                    .padding(.top, 3)
                } label: {
                    Text(l10n.tr("awakeFeedback.details"))
                        .accessibilityIdentifier("awake-feedback-details")
                }
            }
        }
        .font(CoddleTypography.microMeta)
        .coddleSecondaryForeground(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        // Consume the container identifier without replacing each action's ID.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("awake-summary")
        }
    }
}

extension AppModel {
    func guardStatusText(_ l10n: Localizer) -> String {
        if bagGuardActive && keepAwake {
            return l10n.tr(isGuardPauseConfirmed ? "awakeFeedback.paused" : "awakeFeedback.pauseUnconfirmed")
        }
        if !awayDetectionEnabled { return l10n.tr("guard.disabled") }
        if !battery.present || !battery.installed { return l10n.tr("guard.noBattery") }
        if !awayStatus.protectionReady {
            return l10n.tr("guard.learning", Int(ceil(awayStatus.learningRemainingSeconds / 60)))
        }
        if requireBattery && battery.externalConnected { return l10n.tr("guard.waitBattery") }
        if awayStatus.isAway { return l10n.tr("guard.waitIdle") }
        if !awayStatus.isUsual {
            return l10n.tr(awayStatus.fingerprint == nil ? "guard.waitOffline" : "guard.waitNetwork",
                           Int(ceil(awayStatus.waitingRemainingSeconds / 60)))
        }
        return l10n.tr("guard.ready")
    }
}

/// One persistent document host, measured in the same layout pass as the
/// viewport. No preference/state round trip can leave the old viewport height
/// centering the newly shorter panel for one frame.
@MainActor
private struct PanelScrollViewport<Content: View>: NSViewRepresentable {
    let maximumHeight: CGFloat
    let content: Content
    @Environment(\.self) private var environment

    @MainActor final class Coordinator {
        let host: NSHostingView<AnyView>
        init(root: AnyView) {
            host = NSHostingView(rootView: root)
            host.sizingOptions = [.intrinsicContentSize]
        }
    }

    private var root: AnyView {
        AnyView(content.fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.self, environment))
    }
    func makeCoordinator() -> Coordinator { Coordinator(root: root) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false
        // A menu panel must not rubber-band when its content already fits,
        // or pull the document away from the viewport's fixed backdrop.
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = context.coordinator.host
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.host.rootView = root
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView,
                      context: Context) -> CGSize? {
        let host = context.coordinator.host
        let fitted = host.intrinsicContentSize
        let height = fitted.height.isFinite && fitted.height > 0 ? fitted.height : maximumHeight
        host.setFrameSize(NSSize(width: 340, height: height))
        scroll.hasVerticalScroller = height > maximumHeight
        if !scroll.hasVerticalScroller && scroll.contentView.bounds.origin != .zero {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        return CGSize(width: 340, height: min(height, maximumHeight))
    }
}

/// Preserve the normal self-sized popover; only overflow needs scrolling.
struct PopoverControlPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var l10n: Localizer
    @StateObject private var navigation = CoddlePanelNavigation()
    var maximumHeight: CGFloat = min(680, (NSScreen.main?.visibleFrame.height ?? 800) - 60)

    var body: some View {
        PanelScrollViewport(maximumHeight: maximumHeight,
            content: ControlPanel(drawsBackdrop: false, navigation: navigation)
                .environmentObject(model)
                .environmentObject(l10n))
        .frame(width: 340)
        .background(CoddlePanelBackdrop())
        .environment(\.coddleTheme, model.activeTheme)
        .onDisappear {
            navigation.keepAwakeExpanded = false
            navigation.keepAwakeFeedbackExpanded = false
        }
    }
}
