import SwiftUI

/// Keep daily controls visible and put durable rules in one accessible help group.
struct KeepAwakeControlsView: View {
    var compact = false
    var expansion: Binding<Bool>?
    var feedbackExpansion: Binding<Bool>?
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var l10n: Localizer
    @Environment(\.coddleOpenAwakeSettings) private var openAwakeSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var expanded: Bool { !compact || expansion?.wrappedValue == true }
    private var stopNeedsRecovery: Bool {
        model.onboarding?.record.stopPending == true ||
            ["onboarding.stopPartial", "onboarding.stopSaveFailed"].contains(model.taskStopStatus)
    }
    private var masterBinding: Binding<Bool> {
        Binding(get: { model.keepAwake }, set: { enabled in
            model.setKeepAwakeEnabled(enabled)
            // A rejected ON must not make the panel look like it started.
            if model.keepAwake == enabled { setExpanded(enabled) }
        })
    }
    private func setExpanded(_ value: Bool) {
        guard compact, expansion?.wrappedValue != value else { return }
        // Keep the structural update out of the switch's animation transaction.
        // Animating this binding makes every card below it relayout each frame,
        // including the self-sizing popover and AppKit-backed controls.
        withTransaction(Transaction(animation: nil)) {
            expansion?.wrappedValue = value
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 0 : 8) {
            if compact {
                menuHeader
                if !expanded { menuException }
            } else {
                CoddleToggleRow(l10n.tr("keepAwake.title"), isOn: masterBinding,
                                help: l10n.tr("keepAwake.desc"))
                    .disabled(model.taskStopBusy || (!model.keepAwake && stopNeedsRecovery))
                    .accessibilityIdentifier("keep-awake-master")
            }
            if expanded {
                details
                    .transition(.identity)
                    .padding(.bottom, compact ? 8 : 0)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("keep-awake-options")
            }
        }
        .onChange(of: model.keepAwake) { enabled in setExpanded(enabled) }
    }

    private var menuHeader: some View {
        HStack(spacing: 0) {
            Button { setExpanded(!expanded) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "cup.and.saucer")
                        .frame(width: 14)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(l10n.tr("awakeMenu.title"))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: expanded)
                        .accessibilityHidden(true)
                    Spacer(minLength: 8)
                }
                .font(CoddleTypography.controlLabel)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(l10n.tr("awakeMenu.help"))
            .accessibilityLabel(l10n.tr("awakeMenu.title"))
            .accessibilityValue(l10n.tr(expanded ? "awakeMenu.collapse" : "awakeMenu.expand"))
            .accessibilityHint(l10n.tr("awakeMenu.help"))
            .accessibilityIdentifier("keep-awake-menu-entry")

            Toggle(isOn: masterBinding) { EmptyView() }
                .toggleStyle(CoddleSwitchToggleStyle())
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 32)
                .help(l10n.tr("keepAwake.desc"))
                .accessibilityRepresentation {
                    Toggle(l10n.tr("awakeMenu.master"), isOn: masterBinding)
                        .toggleStyle(.switch)
                        // Keep the native semantic switch within the custom
                        // switch's bounds; its label remains available to AX.
                        .labelsHidden()
                        .accessibilityHint(l10n.tr("keepAwake.desc"))
                }
                .disabled(model.taskStopBusy || (!model.keepAwake && stopNeedsRecovery))
                .accessibilityIdentifier("keep-awake-master")
        }
    }

    @ViewBuilder private var menuException: some View {
        let state = model.keepAwakeMenuState
        if state.hasException {
            let keys = model.awakeCollapsedFeedbackKeys
            let summary = (keys.isEmpty ? [state.localizationKey] : keys)
                .map { l10n.tr($0) }.joined(separator: "\n")
            Button { setExpanded(true) } label: {
                Label(summary, systemImage: state == .attention ? "exclamationmark.triangle" : "info.circle")
                    .font(CoddleTypography.microMeta)
                    .foregroundStyle(state == .attention ? CoddleSemanticColor.amber(for: colorScheme) : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 20)
            .padding(.bottom, 5)
            .help(l10n.tr("awakeMenu.expand"))
            .accessibilityHint(l10n.tr("awakeMenu.expand"))
            .accessibilityIdentifier("keep-awake-menu-status")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if compact { Divider().opacity(0.28).padding(.leading, 20) }

            if !compact && !model.hasAwakeFeedback {
                Text(l10n.tr("keepAwake.summary"))
                    .font(CoddleTypography.microMeta)
                    .coddleSecondaryForeground(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("keep-awake-description")
            }

            VStack(alignment: .leading, spacing: 10) {
                if !compact { Divider().opacity(0.28) }
                option(
                    title: compact ? "awakeMenu.display" : "display.keepAwake",
                    help: "display.keepAwakeDesc", identifier: "keep-display-awake",
                    isOn: Binding(get: { model.keepDisplayAwake },
                                  set: { model.setKeepDisplayAwake($0) })
                )
                if model.hasClamshell {
                    option(
                        title: compact ? "awakeMenu.lid" : "keepAwake.lidClosed",
                        help: "keepAwake.lidClosedDesc", identifier: "keep-awake-lid",
                        isOn: Binding(get: { model.keepAwakeOnLidClosed },
                                      set: { model.setKeepAwakeOnLidClosed($0) })
                    )
                }
            }
            .disabled(!model.canEditKeepAwakeOptions)
            .padding(.leading, 20)

            if !compact {
                if model.keepAwake && !model.keepDisplayAwake {
                    sleepDisplayButton.padding(.leading, 20)
                }
            }
            if model.lidAwakeApplied && model.keepAwake && !model.taskStopBusy &&
                !model.bagGuardActive && !model.lidStateUnconfirmed {
                Text(l10n.tr("keepAwake.manualSleep"))
                    .font(CoddleTypography.microMeta)
                    .coddleSecondaryForeground(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("keep-awake-manual-sleep")
            }
            AwakeFeedbackView(showsDetails: true, compact: compact, exceptionsOnly: true,
                              showsGuardStatus: compact, detailsExpansion: feedbackExpansion)
            if !compact { groupHelp }
            if compact {
                HStack(spacing: 8) {
                    if model.keepAwake && !model.keepDisplayAwake { sleepDisplayButton }
                    Spacer(minLength: 4)
                    Button(l10n.tr("awakeMenu.moreSettings"), action: openAwakeSettings)
                        .font(CoddleTypography.microMeta)
                        .buttonStyle(.plain)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("keep-awake-more-settings")
                }
                .padding(.leading, 20)
            }
        }
    }

    private var groupHelp: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text(l10n.tr("keepAwake.helpPreferences"))
                Text(l10n.tr("keepAwake.helpDisplay"))
                if model.hasClamshell { Text(l10n.tr("keepAwake.helpLid")) }
                Button(l10n.tr("display.systemSettings")) { model.openDisplayTimeoutSettings() }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("display-system-settings")
            }
            .coddleSecondaryForeground(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
        } label: {
            Text(l10n.tr("keepAwake.learnMore"))
                .accessibilityIdentifier("keep-awake-help")
        }
        .font(CoddleTypography.microMeta)
    }

    private var sleepDisplayButton: some View {
        Button { model.sleepDisplayNow() } label: {
            Label(l10n.tr("display.sleepNow"), systemImage: "moon")
                .font(.system(size: 11.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(CoddleControlPillSurface(cornerRadius: 7))
        }
        .buttonStyle(CoddleScaleButtonStyle())
        .disabled(!model.canSleepDisplayNow)
        .help(l10n.tr("display.sleepNowHelp"))
        .accessibilityHint(l10n.tr("display.sleepNowHelp"))
        .accessibilityIdentifier("sleep-display-now")
    }

    private func option(title: String, help: String, identifier: String,
                        isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: isOn) {
                Text(l10n.tr(title))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .disabled(!model.canEditKeepAwakeOptions)
            .allowsHitTesting(model.canEditKeepAwakeOptions)
            .font(CoddleTypography.controlLabel)
            .help(l10n.tr(help))
            .accessibilityLabel(l10n.tr(title))
            .accessibilityHint(l10n.tr(help))
            .accessibilityIdentifier(identifier)
        }
    }
}
