import SwiftUI
import AppKit

/// A reusable card container for grouping related controls in the control panel.
/// Uses monochrome `.secondary` header iconography for a restrained "Precision Instrument" aesthetic.
struct SectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    var trailingText: String? = nil
    var theme: CoddleTheme? = nil
    @ViewBuilder let content: () -> Content

    @Environment(\.coddleTheme) private var envTheme

    private var effectiveTheme: CoddleTheme {
        theme ?? envTheme
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5.5) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5, weight: .semibold))
                    .coddleSecondaryForeground(.secondary)
                    .frame(width: 13, alignment: .center)
                Text(title)
                    .font(CoddleTypography.sectionHeader)
                    .coddleSecondaryForeground(.secondary)
                Spacer()
                if let trailingText {
                    Text(trailingText)
                        .font(CoddleTypography.microMeta)
                        .coddleSecondaryForeground(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            content()
        }
        .padding(CoddleGeometry.cardContentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .coddleCard(theme: effectiveTheme)
    }
}

/// Settings Window tabs for the dedicated Settings surface.
enum CoddleSettingsTab: String, CaseIterable, Identifiable {
    case charging
    case awake
    case general

    var id: String { rawValue }

    var compactLocalizationKey: String {
        switch self {
        case .charging: return "tab.compact.charging"
        case .awake:    return "tab.compact.awake"
        case .general:  return "tab.compact.general"
        }
    }

    var localizationKey: String {
        switch self {
        case .charging: return "tab.charging"
        case .awake:    return "tab.awake"
        case .general:  return "tab.general"
        }
    }

    var iconName: String {
        switch self {
        case .charging: return "bolt.badge.clock"
        case .awake:    return "cup.and.saucer"
        case .general:  return "slider.horizontal.3"
        }
    }
}

/// Shared only by the Settings host and its view; no persisted preference.
final class CoddleSettingsNavigation: ObservableObject {
    @Published var tab: CoddleSettingsTab = .charging
}

final class CoddlePanelNavigation: ObservableObject {
    @Published var keepAwakeExpanded = false
    @Published var keepAwakeFeedbackExpanded = false
}

/// The backdrop belongs to the viewport, not the scroll document. Short
/// dashboards must still cover the entire window; long dashboards still scroll.
struct DockDashboardView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var navigation: CoddlePanelNavigation

    var body: some View {
        ScrollView(.vertical) {
            ControlPanel(drawsBackdrop: false, navigation: navigation)
        }
        .scrollContentBackground(.hidden)
        .frame(width: 340)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(CoddlePanelBackdrop())
        .environment(\.coddleTheme, model.activeTheme)
        .onDisappear {
            navigation.keepAwakeExpanded = false
            navigation.keepAwakeFeedbackExpanded = false
        }
    }
}

/// The zero-scroll Menu Bar Popover aligned with macOS's native Battery menu,
/// enriched with Coddle's hardware telemetry, Charge Limit slider + "Charge to Full Now",
/// Energy Mode selector, Quick Toggles, and "Using Significant Energy" app list.
///
/// Low-frequency configuration lives in `SettingsWindowView` (opened via Settings...).
struct ControlPanel: View {
    var showsSettingsButton = true
    var drawsBackdrop = true
    @ObservedObject var navigation = CoddlePanelNavigation()

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var l10n: Localizer
    @Environment(\.coddleOpenConfig) private var openConfig
    @Environment(\.coddleOpenSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.coddleReduceTransparency) private var reduceTransparency

    @Namespace private var energyModeNamespace
    @State private var isSettingsFooterHovered = false
    @State private var isQuitHovered = false
    @State private var isChargeNowHovered = false
    @FocusState private var focusedEnergyMode: EnergyMode?

    private var sectionExpandTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.97, anchor: .top))
                .combined(with: .offset(y: -4)),
            removal: .opacity
                .combined(with: .scale(scale: 0.97, anchor: .top))
        )
    }

    var body: some View {
        mainMenu
            .background { if drawsBackdrop { CoddlePanelBackdrop() } }
            .environment(\.coddleTheme, currentTheme)
    }

    private var mainMenu: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
                .padding(.horizontal, 12)
            ConfigFeedbackView(suppressAwakeOwnedError: true).padding(.horizontal, 12)

            if let err = model.globalError(excluding: menuFeedbackDomains) {
                CoddleErrorBanner(message: err, dismissLabel: l10n.tr("action.dismiss"),
                                  dismiss: model.hasPersistentGlobalError(excluding: menuFeedbackDomains)
                                    ? nil : { model.lastError = nil })
                    .padding(.horizontal, 12)
                    .transition(sectionExpandTransition)
            }

            if currentTheme == .classic {
                Divider().opacity(0.45)
                    .padding(.horizontal, 12)
            }

            VStack(alignment: .leading, spacing: 6) {
                if let flow = model.battery.powerFlow, flow.hasData {
                    powerFlowSection(flow)
                }

                if model.mclSupported {
                    chargeLimitPopoverCard
                } else {
                    SectionCard(title: l10n.tr("section.chargeLimit"), systemImage: "bolt.slash.fill") {
                        Text(l10n.tr("msg.noNativeLimit"))
                            .font(CoddleTypography.controlLabel)
                            .coddleSecondaryForeground(.secondary)
                    }
                }

                if model.availableEnergyModes.count > 1 {
                    energyModeCard
                }

                keepAwakeMenuEntry

                significantEnergyCard
            }
            .padding(.horizontal, 12)

            Rectangle()
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.075))
                .frame(height: 0.75)
                .padding(.horizontal, 14)
                .padding(.top, 2)

            footer
                .padding(.horizontal, 10)
        }
        .padding(.top, 9)
        .padding(.bottom, 6)
        .frame(width: 340)
        .animation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.82), value: currentTheme)
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.82), value: model.temporaryFullChargeActive)
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.82), value: model.energyMode)
    }

    private var menuFeedbackDomains: Set<FeedbackDomain> {
        var domains: Set<FeedbackDomain> = [.awake]
        if model.mclSupported { domains.insert(.charging) }
        if model.availableEnergyModes.count > 1 { domains.insert(.energy) }
        return domains
    }

    private var currentTheme: CoddleTheme {
        model.activeTheme
    }

    private var recessedFill: Color {
        if currentTheme == .liquidGlass {
            return colorScheme == .dark
                ? Color.black.opacity(0.28)
                : Color(red: 0.08, green: 0.16, blue: 0.30).opacity(0.065)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.038)
    }

    private var recessedStroke: Color {
        if currentTheme == .liquidGlass {
            return colorScheme == .dark
                ? Color.white.opacity(0.16)
                : Color.white.opacity(0.48)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.095 : 0.065)
    }

    // MARK: - Header (Aligned with macOS Native Battery Header + Liquid Gauge)

    private var statusText: String {
        if model.temporaryFullChargeActive && model.battery.externalConnected && model.battery.isCharging {
            return l10n.tr("state.chargingToFull")
        }
        if model.chargeOverridePresented {
            return l10n.tr(model.chargeOverrideConfirmed
                ? "state.chargingToFull" : "state.chargingPastLimit")
        }
        switch model.chargeStatus {
        case .noBattery:      return l10n.tr("state.noBattery")
        case .charging:       return l10n.tr("state.charging")
        case .charged:        return l10n.tr("state.charged")
        case .holding(let n): return l10n.tr("state.holding", n)
        case .notCharging:    return l10n.tr("state.notCharging")
        case .discharging:    return l10n.tr("state.discharging")
        case .onBattery:      return l10n.tr("state.onBattery")
        }
    }

    private var powerSourceLine: String {
        if model.battery.externalConnected {
            if let watts = model.battery.powerFlow?.adapterWatts, watts > 0 {
                return l10n.tr("source.powerAdapterWatts", watts)
            }
            return l10n.tr("source.powerAdapter")
        }
        return l10n.tr("source.battery")
    }

    private var batteryIconName: String {
        guard model.battery.present && model.battery.installed else {
            return "desktopcomputer"
        }
        guard let p = model.battery.percent else { return "battery.0" }
        if model.battery.externalConnected {
            if model.chargeOverridePresented || (model.temporaryFullChargeActive && model.battery.isCharging) { return "battery.100.bolt" }
            switch model.chargeStatus {
            case .charging:
                return "battery.100.bolt"
            case .holding:
                return "bolt.badge.clock.fill"
            default:
                return "powerplug.fill"
            }
        }
        if p >= 75 { return "battery.100" }
        if p >= 50 { return "battery.75" }
        if p >= 25 { return "battery.50" }
        return "battery.25"
    }

    private var stateAccentColor: Color {
        if model.chargeOverridePresented { return CoddleSemanticColor.amber(for: colorScheme) }
        if model.temporaryFullChargeActive && model.battery.externalConnected && model.battery.isCharging {
            return CoddleSemanticColor.emerald(for: colorScheme)
        }
        if model.battery.externalConnected {
            switch model.chargeStatus {
            case .charging: return CoddleSemanticColor.emerald(for: colorScheme)
            case .holding:  return CoddleSemanticColor.electricBlue(for: colorScheme)
            case .charged:  return CoddleSemanticColor.emerald(for: colorScheme)
            default:        return .secondary
            }
        }
        guard let p = model.battery.percent else { return .secondary }
        if p <= model.lowBatteryWarnPercent { return CoddleSemanticColor.crimson(for: colorScheme) }
        if p <= 20 { return CoddleSemanticColor.amber(for: colorScheme) }
        return .primary
    }

    private var statusBadgeColor: Color {
        if model.chargeOverridePresented { return CoddleSemanticColor.amber(for: colorScheme) }
        if model.temporaryFullChargeActive && model.battery.externalConnected && model.battery.isCharging {
            return CoddleSemanticColor.emerald(for: colorScheme)
        }
        switch model.chargeStatus {
        case .charging: return CoddleSemanticColor.emerald(for: colorScheme)
        case .holding:  return CoddleSemanticColor.electricBlue(for: colorScheme)
        case .charged:  return CoddleSemanticColor.emerald(for: colorScheme)
        case .discharging:
            if let p = model.battery.percent, p <= model.lowBatteryWarnPercent {
                return CoddleSemanticColor.crimson(for: colorScheme)
            }
            return CoddleSemanticColor.amber(for: colorScheme)
        case .onBattery: return .secondary
        default: return .secondary
        }
    }

    private var statusBadge: some View {
        let acText = "\(l10n.tr("label.onAC")): \(model.battery.externalConnected ? l10n.tr("label.yes") : l10n.tr("label.no"))"
        let tooltip: String = {
            if case .holding(let limit) = model.chargeStatus,
               let percent = model.battery.percent, percent < limit {
                return "\(acText)\n\(l10n.tr("state.holdingBelow", limit, percent))"
            }
            if let limit = model.currentLimit, model.limitEnabled,
               let percent = model.battery.percent, percent > limit {
                return "\(acText)\n\(l10n.tr("state.aboveLimit", percent, limit))"
            }
            return acText
        }()
        return StatusPillBadge(
            text: statusText,
            color: statusBadgeColor,
            theme: currentTheme
        )
        .help(tooltip)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Row 1: Hero Percentage + Status Pill
            HStack(alignment: .center, spacing: 7) {
                Image(systemName: batteryIconName)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(stateAccentColor)
                Text(model.battery.percent.map { "\($0)%" } ?? "—")
                    .font(CoddleTypography.heroMetric)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer(minLength: 4)
                statusBadge
            }

            // Row 2: Native macOS Power Source subtitle (Power Adapter / Battery)
            HStack(spacing: 5) {
                Image(systemName: model.battery.externalConnected ? "powerplug.fill" : "battery.100")
                    .font(.system(size: 10, weight: .medium))
                    .coddleSecondaryForeground(.secondary)
                Text(powerSourceLine)
                    .font(CoddleTypography.microMeta)
                    .coddleSecondaryForeground(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(model.registeredTarget == 0 ? l10n.tr("limit.off") : l10n.tr(model.smartEnabled ? "charge.smartTarget" : "charge.fixedTarget", model.registeredTarget))
                    .font(CoddleTypography.microMeta)
                    .foregroundStyle(.primary)
                    .fixedSize()
                    .accessibilityIdentifier("charge-policy-summary")
            }

            // Row 3: Visual Battery Gauge with Target Limit Marker Pin
            if let percent = model.battery.percent {
                batteryGaugeBar(percent: percent)
            }

            // Row 4: Symmetric 2x2 Precision Telemetry Grid
            telemetryGrid
                .help(l10n.tr("telemetry.explain"))

            // Row 5: Contextual Calibration Override Banner (only when active)
            if model.chargeOverridePresented {
                let key = model.chargeOverrideConfirmed
                    ? "state.chargingToFullDetail" : "state.chargingPastLimitDetail"
                let note = l10n.tr(key, model.currentLimit ?? 100)
                let amber = CoddleSemanticColor.amber(for: colorScheme)
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "battery.100.bolt")
                        .font(.caption2)
                        .foregroundStyle(amber)
                    Text(note)
                        .font(CoddleTypography.microMeta)
                        .foregroundStyle(amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if currentTheme == .liquidGlass && !reduceTransparency {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(amber.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(amber.opacity(0.32), lineWidth: 0.75)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(amber.opacity(0.10))
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(note)
                .accessibilityValue(note)
            }
        }
        .padding(.horizontal, 2)
    }

    private func batteryGaugeBar(percent: Int) -> some View {
        let clamped = max(0, min(100, percent))
        let fillFraction = CGFloat(clamped) / 100.0
        let activeLimit: Int? = {
            guard !model.temporaryFullChargeActive,
                  model.limitEnabled,
                  let l = model.currentLimit, l > 0, l < 100 else { return nil }
            return l
        }()
        let fillColor = stateAccentColor == .primary ? Color.primary.opacity(0.75) : stateAccentColor

        return GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                CoddleRecessedGlassSurface(isCapsule: true)
                    .frame(height: 8.5)

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: currentTheme == .liquidGlass
                                ? [fillColor.opacity(0.78), fillColor.opacity(0.95)]
                                : [fillColor, fillColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .overlay(
                        Group {
                            if currentTheme == .liquidGlass {
                                Capsule(style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.white.opacity(0.46), Color.white.opacity(0.08), .clear],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                            }
                        }
                    )
                    .overlay(
                        Group {
                            if currentTheme == .liquidGlass {
                                Capsule(style: .continuous)
                                    .stroke(Color.white.opacity(0.36), lineWidth: 0.5)
                            }
                        }
                    )
                    .shadow(
                        color: currentTheme == .liquidGlass ? fillColor.opacity(0.32) : .clear,
                        radius: 3.5,
                        x: 0,
                        y: 1
                    )
                    .frame(width: max(8.5, w * fillFraction), height: 8.5)
                    .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.82), value: clamped)

                if let limit = activeLimit {
                    let pinX = max(4, min(w - 4, w * (CGFloat(limit) / 100.0)))
                    Capsule(style: .continuous)
                        .fill(Color.primary)
                        .frame(width: 3, height: 12)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 0.75)
                        )
                        .offset(x: pinX - 1.5)
                        .transition(.scale.combined(with: .opacity))
                        .animation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.78), value: limit)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.80), value: activeLimit)
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }

    private var telemetryGrid: some View {
        let hasPackRow = model.battery.hardwarePercent != nil || model.battery.temperatureCelsius != nil

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                telemetryCell(
                    title: l10n.tr("label.health"),
                    value: model.battery.healthPercent.map { String(format: "%.1f%%", $0) } ?? "—",
                    icon: "heart"
                )
                Rectangle()
                    .fill(recessedStroke)
                    .frame(width: 0.75, height: 16)
                telemetryCell(
                    title: l10n.tr("label.cycles"),
                    value: model.battery.cycleCount.map(String.init) ?? "—",
                    icon: "arrow.triangle.2.circlepath"
                )
            }

            if hasPackRow {
                Rectangle()
                    .fill(recessedStroke)
                    .frame(height: 0.75)

                HStack(spacing: 0) {
                    if let hw = model.battery.hardwarePercent {
                        telemetryCell(
                            title: l10n.tr("label.hardwarePercent"),
                            value: String(format: "%.1f%%", hw),
                            icon: "gauge"
                        )
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(l10n.tr("label.hardwarePercent"))
                        .accessibilityValue(String(format: "%.1f%%", hw))
                    } else {
                        Spacer().frame(maxWidth: .infinity)
                    }

                    Rectangle()
                        .fill(recessedStroke)
                        .frame(width: 0.75, height: 16)

                    if let temp = model.battery.temperatureCelsius {
                        telemetryCell(
                            title: l10n.tr("label.temperature"),
                            value: String(format: "%.1f °C", temp),
                            icon: "thermometer.medium"
                        )
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(l10n.tr("label.temperature"))
                        .accessibilityValue(String(format: "%.1f °C", temp))
                    } else {
                        Spacer().frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .coddleCard(theme: currentTheme)
    }

    private func telemetryCell(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .coddleSecondaryForeground(.secondary)
                .frame(width: 12, alignment: .center)
            Text(title)
                .font(CoddleTypography.microMeta)
                .coddleSecondaryForeground(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text(value)
                .font(CoddleTypography.controlValue)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Power Flow (3-Column Horizontal Energy Flow Instrument)

    private func powerFlowSection(_ flow: PowerFlow) -> some View {
        SectionCard(
            title: l10n.tr("section.powerFlow"),
            systemImage: "bolt",
            trailingText: PowerFlowPresentation.batteryFlowStateText(
                watts: flow.batteryPowerWatts,
                externalConnected: model.battery.externalConnected,
                tr: l10n.tr
            )
        ) {
            HStack(spacing: 0) {
                powerFlowCell(
                    label: l10n.tr("power.input"),
                    value: inputPowerShortText(flow),
                    accessibilityValue: inputPowerText(flow),
                    icon: "powerplug",
                    dotColor: model.battery.externalConnected ? CoddleSemanticColor.emerald(for: colorScheme) : nil,
                    identifier: "power-flow-input"
                )
                Rectangle()
                    .fill(recessedStroke)
                    .frame(width: 0.75, height: 24)
                powerFlowCell(
                    label: l10n.tr("power.system"),
                    value: systemLoadText(flow),
                    accessibilityValue: systemLoadText(flow),
                    icon: "cpu",
                    dotColor: nil,
                    identifier: "power-flow-system"
                )
                Rectangle()
                    .fill(recessedStroke)
                    .frame(width: 0.75, height: 24)
                powerFlowCell(
                    label: l10n.tr("power.battery"),
                    value: PowerFlowPresentation.batteryFlowWattsText(watts: flow.batteryPowerWatts),
                    accessibilityValue: batteryFlowText(flow),
                    icon: batteryFlowIcon(flow),
                    dotColor: batteryFlowColor(flow),
                    identifier: "power-flow-battery"
                )
            }
            .padding(.vertical, 3)
            .background(CoddleRecessedGlassSurface(cornerRadius: CoddleGeometry.contentRadius(for: currentTheme, classic: 8.5)))
        }
    }

    private func inputPowerShortText(_ flow: PowerFlow) -> String {
        flow.systemPowerInWatts.map { String(format: "%.1f W", $0) } ?? "—"
    }

    private func inputPowerText(_ flow: PowerFlow) -> String {
        flow.systemPowerInWatts.map { String(format: "%.1f W", $0) } ?? l10n.tr("power.unavailable")
    }

    private func systemLoadText(_ flow: PowerFlow) -> String {
        guard let load = flow.systemLoadWatts else { return "—" }
        return String(format: "%.1f W", load)
    }

    private func batteryFlowText(_ flow: PowerFlow) -> String {
        PowerFlowPresentation.batteryFlowText(
            watts: flow.batteryPowerWatts,
            externalConnected: model.battery.externalConnected,
            tr: l10n.tr
        )
    }

    private func batteryFlowIcon(_ flow: PowerFlow) -> String {
        PowerFlowPresentation.batteryFlowIcon(
            watts: flow.batteryPowerWatts,
            externalConnected: model.battery.externalConnected
        )
    }

    private func batteryFlowColor(_ flow: PowerFlow) -> Color? {
        guard let bw = flow.batteryPowerWatts else { return nil }
        if bw > 0.05 {
            return CoddleSemanticColor.emerald(for: colorScheme)
        } else if bw < -0.05 {
            return CoddleSemanticColor.amber(for: colorScheme)
        } else if model.battery.externalConnected {
            return CoddleSemanticColor.electricBlue(for: colorScheme)
        } else {
            return nil
        }
    }

    private func powerFlowCell(
        label: String,
        value: String,
        accessibilityValue: String,
        icon: String,
        dotColor: Color?,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .medium))
                    .coddleSecondaryForeground(.secondary)
                Text(label)
                    .font(.system(size: 10.5, weight: .regular))
                    .coddleSecondaryForeground(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                if let dot = dotColor {
                    Circle()
                        .fill(dot)
                        .shadow(color: currentTheme == .liquidGlass ? dot.opacity(0.6) : .clear, radius: 2)
                        .frame(width: 5, height: 5)
                }
                Text(value)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier(identifier)
        .help(accessibilityValue)
    }

    // MARK: - Charge Limit & "Charge to Full Now" (Menu Bar Popover Card)

    private var limitOptions: [Int] {
        let base = model.availableLimits.isEmpty ? [80, 85, 90, 95, 100] : model.availableLimits
        return [0] + Set(base).sorted()
    }

    private func label(for value: Int) -> String {
        value == 0 ? l10n.tr("limit.off") : "\(value)%"
    }

    private var canShowChargeToFullNow: Bool {
        guard model.mclSupported, model.temporaryFullChargeSupported,
              model.battery.externalConnected else { return false }
        let limit = model.selection > 0 ? model.selection : (model.currentLimit ?? 100)
        let pct = model.battery.percent ?? 100
        return (model.limitEnabled || (model.selection > 0 && model.selection < 100)) && limit < 100 && pct < 100
    }

    private var chargeLimitPopoverCard: some View {
        VStack(alignment: .leading, spacing: 5.5) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.badge.clock")
                    .font(.system(size: 10.5, weight: .semibold))
                    .coddleSecondaryForeground(.secondary)
                    .frame(width: 13, alignment: .center)
                Text(l10n.tr("panel.charge.title"))
                    .font(CoddleTypography.sectionHeader)
                    .coddleSecondaryForeground(.secondary)
                Spacer()

                if model.temporaryFullChargeActive {
                    let resumeTarget = model.registeredTarget > 0 ? model.registeredTarget : 80
                    Button {
                        model.resumeChargeLimit()
                    } label: {
                        HStack(spacing: 3.5) {
                            Image(systemName: "arrow.uturn.backward.circle.fill")
                                .font(.system(size: 10, weight: .semibold))
                            Text(l10n.tr("action.resumeLimit", resumeTarget))
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(CoddleSemanticColor.electricBlue(for: colorScheme))
                        .padding(.horizontal, 7.5)
                        .padding(.vertical, 2)
                        .background(CoddleControlPillSurface(cornerRadius: 6, isHovered: isChargeNowHovered, isHighlighted: true))
                    }
                    .buttonStyle(CoddleScaleButtonStyle())
                    .disabled(model.chargeLimitBusy)
                    .accessibilityIdentifier("resume-charge-limit")
                    .onHover { isChargeNowHovered = $0 }
                } else if canShowChargeToFullNow {
                    Button {
                        model.chargeToFullNow()
                    } label: {
                        HStack(spacing: 3.5) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text(l10n.tr("action.chargeToFullNow"))
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(CoddleSemanticColor.electricBlue(for: colorScheme))
                        .padding(.horizontal, 7.5)
                        .padding(.vertical, 2)
                        .background(CoddleControlPillSurface(cornerRadius: 6, isHovered: isChargeNowHovered))
                    }
                    .buttonStyle(CoddleScaleButtonStyle())
                    .disabled(model.chargeLimitBusy)
                    .accessibilityIdentifier("charge-to-full-now")
                    .onHover { isChargeNowHovered = $0 }
                }
            }

            segmentedLimitBar
            ChargeFeedbackView(compact: true)
            Divider().opacity(0.28)
            CoddleToggleRow(
                l10n.tr("smart.title"),
                systemImage: "sparkles",
                isOn: $model.smartEnabled,
                help: l10n.tr("smart.desc")
            )
            .accessibilityIdentifier("smart-charging-master")
            if model.smartEnabled { SmartPlanView(compact: true) }
        }
        .padding(CoddleGeometry.cardContentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .coddleCard(theme: currentTheme)
    }

    private var segmentedLimitBar: some View {
        let items = limitOptions.map { v in
            CoddleDropdownOption(v, label: label(for: v))
        }
        return CoddleDetentSlider(
            options: items,
            selection: model.chargeDisplaySelection,
            accentColor: CoddleSemanticColor.electricBlue(for: colorScheme),
            treatsFirstOptionAsOff: true,
            valueFormatter: { label(for: $0) },
            helpText: model.smartEnabled ? l10n.tr("panel.charge.manualHint") : nil,
            accessibilityLabel: l10n.tr("panel.charge.title")
        ) { newValue in
            model.applyLimit(newValue)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .padding(.bottom, 3)
        .background(CoddleRecessedGlassSurface(cornerRadius: CoddleGeometry.contentRadius(for: currentTheme, classic: 11)))
    }

    // MARK: - Energy Mode (Aligned with macOS Native Battery Menu)

    private var energyModeCard: some View {
        energyModeContent.help(l10n.tr("energyMode.scope"))
            .accessibilityHint(l10n.tr("energyMode.scope"))
    }

    private var energyModeContent: some View {
        SectionCard(
            title: l10n.tr("panel.energy.title"),
            systemImage: "bolt.circle"
        ) {
            HStack(spacing: 4) {
                ForEach(model.availableEnergyModes) { mode in
                    let isSelected = model.energyMode == mode
                    Button {
                        model.setEnergyMode(mode)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: mode.iconName)
                                .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(energyModeIconColor(mode, isSelected: isSelected))
                            Text(l10n.tr(mode.localizationKey))
                                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                .coddleSecondaryForeground(isSelected ? .primary : .secondary, when: !isSelected)
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                        .background {
                            if isSelected {
                                CoddleLiquidSelectionLens(cornerRadius: currentTheme == .liquidGlass ? CoddleGeometry.glassSegmentRadius : 7)
                                    .matchedGeometryEffect(id: "energyModePill", in: energyModeNamespace)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focused($focusedEnergyMode, equals: mode)
                    .disabled(model.energyModeBusy)
                    .help(l10n.tr("energyMode.scope"))
                    .accessibilityHint(l10n.tr("energyMode.scope"))
                    .accessibilityIdentifier("energy-mode-\(mode.rawValue)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(CoddleGeometry.segmentedInset)
            .background(CoddleRecessedGlassSurface(cornerRadius: CoddleGeometry.contentRadius(for: currentTheme, classic: 9)))
            .overlay(alignment: .top) {
                if focusedEnergyMode != nil {
                    Text(l10n.tr("energyMode.scope"))
                        .font(CoddleTypography.microMeta)
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(y: -28)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            if model.energyModeBusy {
                Text(l10n.tr("panel.energy.applying")).font(CoddleTypography.microMeta)
                    .coddleSecondaryForeground(.secondary)
            }
            if let error = model.energyFeedbackError { PanelOperationError(message: error) }
        }
    }

    private func energyModeIconColor(_ mode: EnergyMode, isSelected: Bool) -> Color {
        guard isSelected else { return .secondary }
        switch mode {
        case .automatic: return CoddleSemanticColor.electricBlue(for: colorScheme)
        case .lowPower:  return CoddleSemanticColor.amber(for: colorScheme)
        case .highPower: return CoddleSemanticColor.emerald(for: colorScheme)
        }
    }

    // MARK: - Sleep Prevention

    private var keepAwakeMenuEntry: some View {
        KeepAwakeControlsView(compact: true, expansion: $navigation.keepAwakeExpanded,
                             feedbackExpansion: $navigation.keepAwakeFeedbackExpanded)
            .padding(.horizontal, CoddleGeometry.cardContentInset)
            .padding(.vertical, 2)
            .coddleCard(theme: currentTheme)
    }

    // MARK: - Using Significant Energy (Aligned with macOS Native Battery Menu)

    private var significantEnergyCard: some View { AppActivityCard() }

    // MARK: - Footer (macOS HIG / Raycast Borderless Utility Bar)

    private var footer: some View {
        let crimson = CoddleSemanticColor.crimson(for: colorScheme)
        return HStack(spacing: 0) {
            if showsSettingsButton {
                Button(action: openSettings) {
                    HStack(spacing: 5.5) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 11, weight: .medium))
                            .coddleSecondaryForeground(isSettingsFooterHovered ? .primary : .secondary, when: !isSettingsFooterHovered)
                        Text(l10n.tr("menu.preferences"))
                            .font(.system(size: 11.5, weight: .medium))
                            .coddleSecondaryForeground(isSettingsFooterHovered ? .primary : .secondary, when: !isSettingsFooterHovered)
                        Text("⌘,")
                            .font(.system(size: 10.5, weight: .regular))
                            .coddleSecondaryForeground(.tertiary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background {
                        if isSettingsFooterHovered {
                            CoddleControlPillSurface(cornerRadius: 6, isHovered: true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(",", modifiers: .command)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.12)) {
                        isSettingsFooterHovered = hovering
                    }
                }
                .help("\(l10n.tr("menu.preferences")) (⌘,)")
                .accessibilityLabel(l10n.tr("menu.preferences"))
                .accessibilityIdentifier("open-settings")
            }

            Spacer()

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack(spacing: 5) {
                    Text(l10n.tr("action.quit"))
                        .font(.system(size: 11.5, weight: .medium))
                        .coddleSecondaryForeground(isQuitHovered ? crimson : .secondary, when: !isQuitHovered)
                    Text("⌘Q")
                        .font(.system(size: 10.5, weight: .regular))
                        .coddleSecondaryForeground(isQuitHovered ? AnyShapeStyle(crimson.opacity(0.75)) : AnyShapeStyle(.tertiary), when: !isQuitHovered)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background {
                    if isQuitHovered {
                        if currentTheme == .liquidGlass && !reduceTransparency {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(crimson.opacity(0.16))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(crimson.opacity(0.32), lineWidth: 0.65)
                                )
                        } else {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(crimson.opacity(0.12))
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isQuitHovered = hovering
                }
            }
            .help(l10n.tr("action.quitEffect"))
            .accessibilityLabel(l10n.tr("action.quit"))
        }
    }
}

// MARK: - Dedicated Settings Window (3-Tab Configuration Surface)

/// Hosted in the Settings / Dock window (`AppDelegate.showMainWindow()`).
/// Houses all detailed parameters and low-frequency settings removed from the
/// zero-scroll Menu Bar Popover.
struct SettingsWindowView: View {
    @ObservedObject var navigation = CoddleSettingsNavigation()
    @ObservedObject var updates = UpdateController()
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var l10n: Localizer
    @Environment(\.coddleOpenConfig) private var openConfig
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.coddleReduceTransparency) private var reduceTransparency

    @Namespace private var tabNamespace
    @State private var activeDropdownID: String? = nil
    @State private var showingRemoveConfirmation = false
    @State private var isOpenConfigHovered = false
    @State private var isReloadConfigHovered = false
    @State private var reloadSpinDegrees: Double = 0
    @State private var showingSmartHelp = false
    @State private var showingSmartAdvanced = false
    @State private var showingAwayDetails = false
    @State private var showingAwayAdvanced = false
    @State private var showingComponentManagement = false
    @State private var showingGeneralAdvanced = false
    @State private var entryConstraintAttempted = false
    @State private var notificationAuthorizationRequested = false

    private var sectionExpandTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.97, anchor: .top))
                .combined(with: .offset(y: -4)),
            removal: .opacity
                .combined(with: .scale(scale: 0.97, anchor: .top))
        )
    }

    private var currentTheme: CoddleTheme {
        model.activeTheme
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ConfigFeedbackView(suppressAwakeOwnedError: navigation.tab == .awake).padding(.horizontal, 14)
                .padding(.top, model.configError != nil && !(navigation.tab == .awake && model.awakeOwnsConfigError) ? 10 : 0)
            if let error = model.globalError(excluding: locallyRepresentedFeedback) {
                CoddleErrorBanner(message: error, dismissLabel: l10n.tr("action.dismiss"),
                                  dismiss: model.hasPersistentGlobalError(excluding: locallyRepresentedFeedback)
                                    ? nil : { model.lastError = nil })
                .padding(.horizontal, 14)
                .padding(.top, 10)
            }
            tabBar
                .padding(.horizontal, 14)
                .padding(.top, 12)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    switch navigation.tab {
                    case .charging:
                        chargingTabContent
                    case .awake:
                        awakeTabContent
                    case .general:
                        generalTabContent
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 2)
                .padding(.bottom, 14)
                .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82), value: model.smartEnabled)
                .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82), value: model.keepAwakeOnLidClosed)
                .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82), value: model.awayDetectionEnabled)
                .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82), value: model.showInDock)
                .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82), value: model.showMenuBarIcon)
                .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82), value: activeDropdownID)
            }
        }
        .frame(minWidth: 440, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .background { panelBackdrop.ignoresSafeArea() }
        .environment(\.coddleTheme, currentTheme)
        .onAppear {
            model.refreshLaunchAtLogin()
            model.refreshNotificationStatus()
        }
        .onChange(of: navigation.tab) { _ in entryConstraintAttempted = false }
    }

    private var locallyRepresentedFeedback: Set<FeedbackDomain> {
        switch navigation.tab {
        case .charging: return model.mclSupported ? [.charging] : []
        case .awake: return [.awake]
        case .general: return []
        }
    }

    @ViewBuilder
    private var panelBackdrop: some View {
        if currentTheme == .liquidGlass && !reduceTransparency {
            CoddleLiquidGlassBackdrop()
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    private var recessedFill: Color {
        if currentTheme == .liquidGlass {
            return colorScheme == .dark
                ? Color.black.opacity(0.28)
                : Color(red: 0.08, green: 0.16, blue: 0.30).opacity(0.065)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.038)
    }

    private var recessedStroke: Color {
        if currentTheme == .liquidGlass {
            return colorScheme == .dark
                ? Color.white.opacity(0.15)
                : Color(red: 0.10, green: 0.20, blue: 0.38).opacity(0.09)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.095 : 0.065)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(CoddleSettingsTab.allCases) { tab in
                let isSelected = navigation.tab == tab
                Button {
                    activeDropdownID = nil
                    if reduceMotion {
                        navigation.tab = tab
                    } else {
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                            navigation.tab = tab
                        }
                    }
                } label: {
                    SettingsTabLabel(tab: tab, isSelected: isSelected)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .padding(.horizontal, 8)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: currentTheme == .liquidGlass ? CoddleGeometry.tabSelectionRadius : 8, style: .continuous)
                                .fill(
                                    colorScheme == .dark
                                        ? Color.white.opacity(0.14)
                                        : Color.white.opacity(0.96)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: currentTheme == .liquidGlass ? CoddleGeometry.tabSelectionRadius : 8, style: .continuous)
                                        .stroke(
                                            colorScheme == .dark
                                                ? Color.white.opacity(0.22)
                                                : Color.black.opacity(0.08),
                                            lineWidth: 0.75
                                        )
                                )
                                .shadow(
                                    color: Color.black.opacity(colorScheme == .dark ? 0.32 : 0.08),
                                    radius: 3,
                                    x: 0,
                                    y: 1
                                )
                                .matchedGeometryEffect(id: "settingsTabPill", in: tabNamespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(l10n.tr(tab.localizationKey))
                .accessibilityLabel(l10n.tr(tab.compactLocalizationKey))
                .accessibilityHint(l10n.tr(tab.localizationKey))
                .accessibilityIdentifier("settings-tab-" + tab.rawValue)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(CoddleGeometry.tabBarInset)
        .background(
            RoundedRectangle(cornerRadius: CoddleGeometry.tabBarRadius, style: .continuous)
                .fill(recessedFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CoddleGeometry.tabBarRadius, style: .continuous)
                .stroke(recessedStroke, lineWidth: 0.75)
        )
    }

    // MARK: - Tab 1: Charging & Battery

    private var limitOptions: [Int] {
        let base = model.availableLimits.isEmpty ? [80, 85, 90, 95, 100] : model.availableLimits
        return [0] + Set(base).sorted()
    }

    private func label(for value: Int) -> String {
        value == 0 ? l10n.tr("limit.off") : "\(value)%"
    }

    private var holdOptions: [Int] {
        var set = Set(model.availableLimits.filter { $0 < model.topupLimit })
        if set.isEmpty { set = [70, 80, 90] }
        set.insert(model.holdLimit)
        return set.sorted()
    }

    private var topupLeadOptions: [Int] {
        var set = Set([0, 1, 2, 3, 4, 6])
        set.insert(model.topupLeadHours)
        return set.sorted()
    }

    private var minSamplesOptions: [Int] {
        var set = Set([1, 2, 3, 5, 8, 12])
        set.insert(model.minSamplesPerHour)
        return set.sorted()
    }

    private var lowBatteryOptions: [Int] {
        [10, 15, 20, 25, 30]
    }

    @ViewBuilder
    private var chargingTabContent: some View {
        if model.mclSupported {
            SectionCard(
                title: l10n.tr("section.chargeLimit"),
                systemImage: "bolt.badge.clock",
                trailingText: label(for: model.selection)
            ) {
                ChargeFeedbackView()
                let items = limitOptions.map { CoddleDropdownOption($0, label: label(for: $0)) }
                CoddleDetentSlider(
                    options: items,
                    selection: model.chargeDisplaySelection,
                    accentColor: CoddleSemanticColor.electricBlue(for: colorScheme),
                    treatsFirstOptionAsOff: true,
                    valueFormatter: { label(for: $0) },
                    helpText: model.smartEnabled ? l10n.tr("panel.charge.manualHint") : nil,
                    accessibilityLabel: l10n.tr("section.chargeLimit")
                ) { newValue in
                    model.applyLimit(newValue)
                }
                .padding(.horizontal, 4)
                .padding(.top, 4)
                .padding(.bottom, 5)
                .background(
                    RoundedRectangle(cornerRadius: CoddleGeometry.contentRadius(for: currentTheme, classic: 11), style: .continuous)
                        .fill(recessedFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CoddleGeometry.contentRadius(for: currentTheme, classic: 11), style: .continuous)
                        .stroke(recessedStroke, lineWidth: 0.75)
                )

                Divider().opacity(0.30)

                CoddleToggleRow(
                    l10n.tr("smart.title"),
                    isOn: $model.smartEnabled,
                    help: l10n.tr("smart.desc")
                )

                if model.smartEnabled {
                    SmartPlanView(compact: false)
                    VStack(alignment: .leading, spacing: 6) {
                        CoddleDropdownRow(
                            id: "holdLimit",
                            l10n.tr("smart.holdLimit"),
                            selection: model.holdLimit,
                            options: holdOptions.map { CoddleDropdownOption($0, label: "\($0)%") },
                            minPillWidth: 66,
                            activeDropdownID: $activeDropdownID
                        ) { selected in
                            model.holdLimit = selected
                        }

                        CoddleDropdownRow(
                            id: "topupLead",
                            l10n.tr("smart.topupLeadLabel"),
                            selection: model.topupLeadHours,
                            options: topupLeadOptions.map { CoddleDropdownOption($0, label: $0 == 0 ? l10n.tr("limit.off") : l10n.tr("unit.hours", $0)) },
                            minPillWidth: 66,
                            activeDropdownID: $activeDropdownID
                        ) { hours in
                            model.topupLeadHours = hours
                        }

                        DisclosureGroup(isExpanded: $showingSmartAdvanced) {
                            CoddleDropdownRow(
                                id: "minSamples",
                                l10n.tr("smart.minSamplesLabel"),
                                selection: model.minSamplesPerHour,
                                options: minSamplesOptions.map { CoddleDropdownOption($0, label: "\($0)") },
                                minPillWidth: 66,
                                activeDropdownID: $activeDropdownID
                            ) { samples in
                                model.minSamplesPerHour = samples
                            }
                        } label: {
                            Text(l10n.tr("settings.advanced"))
                                .accessibilityIdentifier("smart-charge-advanced")
                        }
                        .font(CoddleTypography.controlLabel)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: CoddleGeometry.contentRadius(for: currentTheme, classic: 9), style: .continuous)
                            .fill(recessedFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CoddleGeometry.contentRadius(for: currentTheme, classic: 9), style: .continuous)
                            .stroke(recessedStroke, lineWidth: 0.75)
                    )
                    .transition(sectionExpandTransition)
                }

                DisclosureGroup(isExpanded: $showingSmartHelp) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(l10n.tr("smart.desc"))
                        Text(l10n.tr("panel.charge.manualHint"))
                        Text(l10n.tr("smart.planDetail"))
                    }
                    .font(CoddleTypography.microMeta)
                    .coddleSecondaryForeground(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } label: {
                    Text(l10n.tr("smart.learnMore"))
                        .accessibilityIdentifier("smart-charge-help")
                }
                .font(CoddleTypography.controlLabel)
            }
        } else {
            SectionCard(title: l10n.tr("section.chargeLimit"), systemImage: "bolt.slash.fill") {
                Text(l10n.tr("msg.noNativeLimit"))
                    .font(CoddleTypography.controlLabel)
                    .coddleSecondaryForeground(.secondary)
            }
        }

        SectionCard(
            title: l10n.tr("section.lowBattery"),
            systemImage: "battery.25",
            trailingText: l10n.tr("lowBattery.warn", model.lowBatteryWarnPercent)
        ) {
            let items = lowBatteryOptions.map { CoddleDropdownOption($0, label: "\($0)%") }
            CoddleDetentSlider(
                options: items,
                selection: model.lowBatteryWarnPercent,
                accentColor: CoddleSemanticColor.electricBlue(for: colorScheme),
                treatsFirstOptionAsOff: false,
                valueFormatter: { "\($0)%" },
                accessibilityLabel: l10n.tr("lowBattery.warn", model.lowBatteryWarnPercent)
            ) { pct in
                model.lowBatteryWarnPercent = pct
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .padding(.bottom, 5)
            .background(
                RoundedRectangle(cornerRadius: CoddleGeometry.contentRadius(for: currentTheme, classic: 11), style: .continuous)
                    .fill(recessedFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CoddleGeometry.contentRadius(for: currentTheme, classic: 11), style: .continuous)
                    .stroke(recessedStroke, lineWidth: 0.75)
            )

            HStack {
                Toggle(l10n.tr("onboarding.notificationTitle"), isOn: Binding(
                    get: { model.lowBatteryReminder == .enabled },
                    set: { value in
                        notificationAuthorizationRequested = value
                        if value { model.requestLowBatteryPermission() }
                        else { Task { _ = await model.setSetupReminder(.disabled) } }
                    }))
                    .font(CoddleTypography.controlLabel)
                    .disabled(model.notificationBusy)
                    .help(l10n.tr("lowBattery.desc"))
                Spacer()
                Button(l10n.tr("notification.test")) { model.testLowBatteryNotification() }
                    .disabled(model.notificationBusy || model.lowBatteryReminder != .enabled)
                    .accessibilityIdentifier("test-notification")
            }
            if let status = notificationFeedbackKey {
                Text(l10n.tr(status))
                    .font(CoddleTypography.microMeta)
                    .coddleSecondaryForeground(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("notification-feedback")
            }
            if let status = notificationFeedbackKey, ["notification.denied", "notification.alertsOff"].contains(status) {
                Button(l10n.tr("onboarding.notificationSettings")) { model.openLowBatterySettings() }
            }
        }
    }

    private var notificationFeedbackKey: String? {
        switch model.notificationStatus {
        case "notification.ready", "notification.disabled":
            return nil
        case "notification.unknown", "notification.denied", "notification.alertsOff":
            return model.lowBatteryReminder != .disabled || notificationAuthorizationRequested
                ? model.notificationStatus : nil
        default:
            // Preserve failures and the result of an explicitly requested test.
            return model.notificationStatus
        }
    }

    // MARK: - Tab 2: Awake & Guards

    private var awayStatusLine: String {
        let s = model.awayStatus
        var parts: [String] = []
        if let fingerprint = s.fingerprint {
            parts.append(l10n.tr("awayGuard.network", fingerprint))
        } else {
            parts.append(l10n.tr("awayGuard.offline"))
        }
        if s.isAway {
            parts.append(l10n.tr("awayGuard.awayFor", Int(s.awayForSeconds / 60)))
        } else if s.isUsual {
            parts.append(l10n.tr("awayGuard.usual"))
        }
        if s.vpnActive { parts.append(l10n.tr("awayGuard.vpn")) }
        return parts.joined(separator: " · ")
    }

    private func integerOptions(_ values: [Int], including current: Int) -> [Int] {
        Set(values + [current]).sorted()
    }

    private var awayProtectionNeedsAttention: Bool {
        let needsProtection = model.keepAwake && model.keepAwakeOnLidClosed
        let pauseUnconfirmed = model.bagGuardActive && model.keepAwake && !model.isGuardPauseConfirmed
        return pauseUnconfirmed || (needsProtection &&
            (!model.awayDetectionEnabled || !model.awayStatus.protectionReady))
    }

    @ViewBuilder
    private var awakeTabContent: some View {
        VStack(alignment: .leading, spacing: 5.5) {
            KeepAwakeControlsView()
        }
        .padding(CoddleGeometry.cardContentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .coddleCard(theme: currentTheme)

        VStack(alignment: .leading, spacing: 5.5) {
            CoddleToggleRow(
                l10n.tr("awayGuard.title"),
                isOn: $model.awayDetectionEnabled,
                help: l10n.tr("awayGuard.desc")
            )

            if model.awayDetectionEnabled || (model.keepAwake && model.keepAwakeOnLidClosed) || model.bagGuardActive {
                Text(model.guardStatusText(l10n))
                    .font(CoddleTypography.microMeta)
                    .coddleSecondaryForeground(
                        awayProtectionNeedsAttention ? CoddleSemanticColor.amber(for: colorScheme) : Color.secondary,
                        when: !awayProtectionNeedsAttention
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("guard-readiness")
            }

            if model.awayDetectionEnabled {
                CoddleDropdownRow(
                    id: "awayAfter",
                    l10n.tr("awayGuard.awayAfterLabel"),
                    selection: model.awayAfterMinutes,
                    options: integerOptions([5, 10, 15, 20, 30, 60], including: model.awayAfterMinutes)
                        .map { CoddleDropdownOption($0, label: l10n.tr("unit.minutes", $0)) },
                    activeDropdownID: $activeDropdownID
                ) { model.awayAfterMinutes = $0 }

                CoddleDropdownRow(
                    id: "offlineAwayAfter",
                    l10n.tr("awayGuard.offlineAfterLabel"),
                    selection: model.offlineAwayAfterMinutes,
                    options: integerOptions([5, 10, 15, 20, 30, 60], including: model.offlineAwayAfterMinutes)
                        .map { CoddleDropdownOption($0, label: l10n.tr("unit.minutes", $0)) },
                    activeDropdownID: $activeDropdownID
                ) { model.offlineAwayAfterMinutes = $0 }

                CoddleToggleRow(l10n.tr("awayGuard.requireBattery"), isOn: $model.requireBattery)
            }

            DisclosureGroup(isExpanded: $showingAwayDetails) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(l10n.tr("awayGuard.desc"))
                    Text(l10n.tr("guard.conditions", model.awayAfterMinutes, model.offlineAwayAfterMinutes, model.idleSeconds))
                    if model.awayDetectionEnabled {
                        Text(awayStatusLine).monospacedDigit()
                        if let event = model.lastGuardEvent, let date = model.lastGuardEventDate {
                            Text(l10n.tr(event) + " · " + date.formatted(date: .omitted, time: .shortened))
                        }
                    }
                }
                .font(CoddleTypography.microMeta)
                .coddleSecondaryForeground(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } label: {
                Text(l10n.tr("awayGuard.details"))
                    .accessibilityIdentifier("away-detection-details")
            }
            .font(CoddleTypography.controlLabel)

            if model.awayDetectionEnabled {
                DisclosureGroup(isExpanded: $showingAwayAdvanced) {
                    VStack(alignment: .leading, spacing: 6) {
                        CoddleDropdownRow(
                            id: "networkSample",
                            l10n.tr("awayGuard.networkSampleLabel"),
                            selection: model.networkSampleSeconds,
                            options: integerOptions([15, 30, 60, 120], including: model.networkSampleSeconds)
                                .map { CoddleDropdownOption($0, label: l10n.tr("unit.seconds", $0)) },
                            activeDropdownID: $activeDropdownID
                        ) { model.networkSampleSeconds = $0 }

                        CoddleDropdownRow(
                            id: "usualDwell",
                            l10n.tr("awayGuard.usualDwellLabel"),
                            selection: model.usualMinDwellSeconds,
                            options: integerOptions([1800, 3600, 7200, 14400], including: model.usualMinDwellSeconds)
                                .map { CoddleDropdownOption($0, label: $0.isMultiple(of: 60)
                                    ? l10n.tr("unit.minutes", $0 / 60) : l10n.tr("unit.seconds", $0)) },
                            activeDropdownID: $activeDropdownID
                        ) { model.usualMinDwellSeconds = $0 }

                        CoddleDropdownRow(
                            id: "guardIdle",
                            l10n.tr("awayGuard.idleLabel"),
                            selection: model.idleSeconds,
                            options: integerOptions([30, 60, 120, 300, 600], including: model.idleSeconds)
                                .map { CoddleDropdownOption($0, label: l10n.tr("unit.seconds", $0)) },
                            activeDropdownID: $activeDropdownID
                        ) { model.idleSeconds = $0 }
                    }
                } label: {
                    Text(l10n.tr("settings.advanced"))
                        .accessibilityIdentifier("away-advanced")
                }
                .font(CoddleTypography.controlLabel)
            }
        }
        .padding(CoddleGeometry.cardContentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .coddleCard(theme: currentTheme)

        systemComponentSection
    }

    private var systemComponentSection: some View {
        DisclosureGroup(isExpanded: $showingComponentManagement) {
            VStack(alignment: .leading, spacing: 6) {
                if let status = componentDiagnostic {
                    Text(l10n.tr(status))
                        .font(CoddleTypography.microMeta)
                        .coddleSecondaryForeground(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("system-component-diagnostic")
                }
                Text(l10n.tr("helper.explain"))
                    .font(CoddleTypography.microMeta)
                    .coddleSecondaryForeground(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !model.helperInstalled {
                    Text(l10n.tr("helper.installApproval"))
                        .font(CoddleTypography.microMeta)
                        .coddleSecondaryForeground(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    if !model.helperInstalled {
                        Button {
                            model.installHelper()
                        } label: {
                            Text(l10n.tr(model.helperBusy ? "helper.installing" :
                                (model.helperFilesPresent ? "helper.repair" : "helper.install")))
                                .font(CoddleTypography.controlLabel)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(CoddleControlPillSurface(cornerRadius: 6, isHighlighted: true))
                        }
                        .buttonStyle(CoddleScaleButtonStyle())
                        .disabled(model.helperBusy || model.energyModeBusy)
                        .accessibilityIdentifier("install-system-component")
                    }
                    if model.helperFilesPresent {
                        Button {
                            showingRemoveConfirmation = true
                        } label: {
                            Text(l10n.tr("helper.remove"))
                                .font(CoddleTypography.controlLabel)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(CoddleControlPillSurface(cornerRadius: 6))
                        }
                        .buttonStyle(CoddleScaleButtonStyle())
                        .disabled(model.helperBusy || model.energyModeBusy)
                        .accessibilityIdentifier("remove-system-component")
                        .confirmationDialog(
                            l10n.tr("helper.removeConfirmTitle"),
                            isPresented: $showingRemoveConfirmation,
                            actions: {
                                Button(l10n.tr("helper.remove"), role: .destructive) { model.removeHelper() }
                                Button(l10n.tr("action.cancel"), role: .cancel) {}
                            },
                            message: { Text(l10n.tr("helper.removeConfirmMessage")) }
                        )
                    }
                }
            }
            .padding(.top, 5)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Label(l10n.tr("onboarding.helperName"), systemImage: "gearshape.2")
                        .font(CoddleTypography.sectionHeader)
                    Spacer(minLength: 4)
                    if model.helperBusy { ProgressView().controlSize(.small) }
                    Text(l10n.tr(model.helperInstalled ? "helper.installed" :
                        (model.helperFilesPresent ? "helper.unavailable" : "helper.notInstalled")))
                        .font(CoddleTypography.microMeta)
                        .coddleSecondaryForeground(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(l10n.tr("helper.manage"))
                        .font(CoddleTypography.controlLabel)
                }
                if componentDiagnostic != nil {
                    Label(l10n.tr("awakeFeedback.componentUnavailable"), systemImage: "exclamationmark.triangle")
                        .font(CoddleTypography.microMeta)
                        .foregroundStyle(CoddleSemanticColor.amber(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("system-component-attention")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("system-component-management")
        }
        .padding(CoddleGeometry.cardContentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .coddleCard(theme: currentTheme)
    }

    private var componentDiagnostic: String? {
        model.awakeRepresentsHelperStatus ? nil : model.helperStatus
    }

    // MARK: - Tab 3: General & Appearance

    private var refreshOptions: [Int] {
        var set = Set([2, 5, 10, 30, 60])
        set.insert(model.refreshSeconds)
        return set.sorted()
    }

    private var languageOptions: [CoddleDropdownOption<String>] {
        [
            CoddleDropdownOption("system", label: l10n.tr("language.systemDefault")),
            CoddleDropdownOption("en", label: l10n.tr("language.en")),
            CoddleDropdownOption("zh-Hans", label: l10n.tr("language.zhHans")),
            CoddleDropdownOption("zh-Hant", label: l10n.tr("language.zhHant")),
            CoddleDropdownOption("ja", label: l10n.tr("language.ja")),
            CoddleDropdownOption("ko", label: l10n.tr("language.ko")),
            CoddleDropdownOption("es", label: l10n.tr("language.es"))
        ]
    }

    private var themeOptions: [CoddleDropdownOption<String>] {
        [
            CoddleDropdownOption(CoddleTheme.liquidGlass.rawValue, label: l10n.tr("theme.liquidGlass")),
            CoddleDropdownOption(CoddleTheme.classic.rawValue, label: l10n.tr("theme.classic"))
        ]
    }

    @ViewBuilder
    private var generalTabContent: some View {
        SectionCard(title: l10n.tr("section.settings"), systemImage: "slider.horizontal.3") {
            if model.onboarding != nil {
                Button(l10n.tr(model.setupRequired ? "onboarding.continueSetup" : "onboarding.menuTitle")) {
                    NotificationCenter.default.post(name: .coddleShowOnboarding, object: nil)
                }.accessibilityIdentifier("open-onboarding")
            }
            CoddleToggleRow(l10n.tr("settings.iconOnly"), isOn: $model.iconOnly)

            CoddleToggleRow(
                l10n.tr("settings.showMenuBarIcon"),
                isOn: Binding(
                    get: { model.showMenuBarIcon },
                    set: { value in
                        entryConstraintAttempted = !value && !model.showInDock
                        model.setShowMenuBarIcon(value)
                    }
                )
            )

            CoddleToggleRow(
                l10n.tr("settings.showInDock"),
                isOn: Binding(
                    get: { model.showInDock },
                    set: { value in
                        entryConstraintAttempted = !value && !model.showMenuBarIcon
                        model.setShowInDock(value)
                    }
                )
            )

            if model.dockRestartPending {
                Text(l10n.tr("settings.restartToApply"))
                    .font(CoddleTypography.microMeta)
                    .coddleSecondaryForeground(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(sectionExpandTransition)
            }
            if entryConstraintAttempted {
                Text(l10n.tr("settings.keepOne"))
                    .font(CoddleTypography.microMeta)
                    .coddleSecondaryForeground(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(sectionExpandTransition)
            }

            CoddleToggleRow(
                l10n.tr("settings.launchAtLogin"),
                isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                )
            )
            .disabled(model.loginBusy)

            if model.launchAtLoginStatus != "login.off" && model.launchAtLoginStatus != "login.enabled" {
                Text(l10n.tr(model.launchAtLoginStatus))
                    .font(CoddleTypography.microMeta)
                    .coddleSecondaryForeground(.secondary)
                    .transition(sectionExpandTransition)
            }

            Divider().opacity(0.28)

            CoddleDropdownRow(
                id: "language",
                l10n.tr("settings.language"),
                selection: model.language,
                options: languageOptions,
                activeDropdownID: $activeDropdownID
            ) { code in
                if reduceMotion {
                    model.setLanguage(code)
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        model.setLanguage(code)
                    }
                }
            }

            CoddleDropdownRow(
                id: "theme",
                l10n.tr("theme.title"),
                selection: CoddleTheme(key: model.theme).rawValue,
                options: themeOptions,
                activeDropdownID: $activeDropdownID
            ) { rawTheme in
                if reduceMotion {
                    model.theme = rawTheme
                } else {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.80)) {
                        model.theme = rawTheme
                    }
                }
            }

            Divider().opacity(0.28)

            DisclosureGroup(isExpanded: $showingGeneralAdvanced) {
                CoddleDropdownRow(
                    id: "refreshInterval",
                    l10n.tr("settings.refresh"),
                    selection: model.refreshSeconds,
                    options: refreshOptions.map { CoddleDropdownOption($0, label: l10n.tr("unit.seconds", $0)) },
                    activeDropdownID: $activeDropdownID
                ) { secs in
                    model.refreshSeconds = secs
                }

                configurationActions
            } label: {
                Text(l10n.tr("settings.advanced"))
                    .accessibilityIdentifier("general-advanced")
            }
            .font(CoddleTypography.controlLabel)
        }
        updateSettingsCard
    }

    private var updateSettingsCard: some View {
        SectionCard(title: l10n.tr("updates.title"), systemImage: "arrow.triangle.2.circlepath") {
            Button(l10n.tr("updates.check")) { updates.checkForUpdates() }
                .disabled(!updates.isAvailable || !updates.state.canCheckForUpdates)
                .accessibilityIdentifier("updates-check")
            CoddleToggleRow(l10n.tr("updates.automaticChecks"), isOn: Binding(
                get: { updates.state.automaticallyChecksForUpdates },
                set: { updates.setAutomaticallyChecksForUpdates($0) }
            ))
            .disabled(!updates.isAvailable)
            .accessibilityIdentifier("updates-automatic-checks")
            CoddleToggleRow(l10n.tr("updates.automaticDownloads"), isOn: Binding(
                get: { updates.state.automaticallyDownloadsUpdates },
                set: { updates.setAutomaticallyDownloadsUpdates($0) }
            ))
            .disabled(!updates.isAvailable || !updates.state.automaticallyChecksForUpdates)
            .accessibilityIdentifier("updates-automatic-downloads")
            Text(l10n.tr(updates.isAvailable ? "updates.detail" : "updates.unavailable"))
                .font(CoddleTypography.microMeta)
                .coddleSecondaryForeground(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("updates-settings")
    }

    private var configurationActions: some View {
        HStack(spacing: 8) {
            Button {
                openConfig()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10.5, weight: .medium))
                    Text(l10n.tr("action.openConfig"))
                        .font(CoddleTypography.microMeta)
                }
                .coddleSecondaryForeground(isOpenConfigHovered ? .primary : .secondary, when: !isOpenConfigHovered)
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(CoddleControlPillSurface(cornerRadius: 6.5, isHovered: isOpenConfigHovered))
            }
            .buttonStyle(CoddleScaleButtonStyle())
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.14)) {
                    isOpenConfigHovered = hovering
                }
            }

            Button {
                if !reduceMotion {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.74)) {
                        reloadSpinDegrees -= 360
                    }
                }
                model.reloadConfig()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10.5, weight: .medium))
                        .rotationEffect(.degrees(reloadSpinDegrees))
                    Text(l10n.tr("action.reloadConfig"))
                        .font(CoddleTypography.microMeta)
                }
                .coddleSecondaryForeground(isReloadConfigHovered ? .primary : .secondary, when: !isReloadConfigHovered)
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(CoddleControlPillSurface(cornerRadius: 6.5, isHovered: isReloadConfigHovered))
            }
            .buttonStyle(CoddleScaleButtonStyle())
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.14)) {
                    isReloadConfigHovered = hovering
                }
            }
            .help(l10n.tr("action.reloadConfig"))
            .accessibilityLabel(l10n.tr("action.reloadConfig"))

            Spacer()
        }
    }
}

private struct CoddleOpenConfigKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {
        #if CODDLE_TESTING
        preconditionFailure("UI tests must inject the Open Config action.")
        #else
        NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.url])
        #endif
    }
}

struct CoddleOpenSettingsKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {
        #if CODDLE_TESTING
        preconditionFailure("UI tests must inject the Open Settings action.")
        #else
        NotificationCenter.default.post(name: .coddleShowSettings, object: nil)
        #endif
    }
}

struct CoddleOpenAwakeSettingsKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {
        #if CODDLE_TESTING
        preconditionFailure("UI tests must inject the Open Awake Settings action.")
        #else
        NotificationCenter.default.post(name: .coddleShowSettings, object: nil,
                                        userInfo: ["tab": CoddleSettingsTab.awake.rawValue])
        #endif
    }
}

private struct CoddleOpenActivityMonitorKey: EnvironmentKey {
    static let defaultValue: @MainActor (SignificantEnergyApp) -> Void = { app in
        #if CODDLE_TESTING
        preconditionFailure("UI tests must inject the Activity Monitor action.")
        #else
        EnergyAppMonitor.openInActivityMonitor(app)
        #endif
    }
}

extension Notification.Name {
    static let coddleShowSettings = Notification.Name("com.coddle.showSettings")
    static let coddleShowOnboarding = Notification.Name("com.coddle.showOnboarding")
}

extension EnvironmentValues {
    var coddleOpenConfig: @MainActor () -> Void {
        get { self[CoddleOpenConfigKey.self] }
        set { self[CoddleOpenConfigKey.self] = newValue }
    }

    var coddleOpenSettings: @MainActor () -> Void {
        get { self[CoddleOpenSettingsKey.self] }
        set { self[CoddleOpenSettingsKey.self] = newValue }
    }

    var coddleOpenAwakeSettings: @MainActor () -> Void {
        get { self[CoddleOpenAwakeSettingsKey.self] }
        set { self[CoddleOpenAwakeSettingsKey.self] = newValue }
    }

    var coddleOpenActivityMonitor: @MainActor (SignificantEnergyApp) -> Void {
        get { self[CoddleOpenActivityMonitorKey.self] }
        set { self[CoddleOpenActivityMonitorKey.self] = newValue }
    }
}
