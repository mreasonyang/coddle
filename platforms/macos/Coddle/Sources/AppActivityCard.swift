import SwiftUI
import AppKit

/// A live sample may cross the activity threshold or change rank every refresh.
/// Reserve the existing three-row capacity so telemetry never resizes the panel.
struct AppActivityCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: Localizer
    @Environment(\.coddleOpenActivityMonitor) private var openActivityMonitor
    @State private var hoveredAppPID: pid_t?

    // Existing row geometry: 15 pt icon/text + 5 pt padding, 2 pt between rows.
    private var listHeight: CGFloat {
        CGFloat(SignificantEnergyApp.displayLimit) * 20 + CGFloat(SignificantEnergyApp.displayLimit - 1) * 2
    }

    var body: some View {
        SectionCard(
            title: l10n.tr("section.significantEnergy"),
            systemImage: "flame"
        ) {
            Group {
                if model.significantEnergyApps.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: model.energySampleStatus == "energySample.unavailable" ? "questionmark.circle" : "minus.circle")
                            .font(.system(size: 11, weight: .medium))
                            .coddleSecondaryForeground(.secondary)
                        Text(l10n.tr(model.energySampleStatus == "energySample.unavailable" ? "energySample.unavailable" : "significantEnergy.none"))
                            .font(CoddleTypography.microMeta)
                            .coddleSecondaryForeground(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 1.5)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.significantEnergyApps.prefix(SignificantEnergyApp.displayLimit)) { app in
                            let isHovered = hoveredAppPID == app.id
                            Button {
                                openActivityMonitor(app)
                            } label: {
                                HStack(spacing: 7) {
                                    if let icon = app.icon {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .interpolation(.high)
                                            .frame(width: 15, height: 15)
                                    } else {
                                        Image(systemName: "app.fill")
                                            .font(.system(size: 12))
                                            .coddleSecondaryForeground(.secondary)
                                            .frame(width: 15, height: 15)
                                    }
                                    Text(app.name)
                                        .font(CoddleTypography.controlLabel)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        .coddleSecondaryForeground(.tertiary)
                                        .opacity(isHovered ? 1 : 0.65)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2.5)
                                .background {
                                    if isHovered {
                                        CoddleControlPillSurface(cornerRadius: 6, isHovered: true)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("energy-app-\(app.id)")
                            .onHover { hovering in
                                hoveredAppPID = hovering ? app.id : nil
                            }
                        }
                    }
                }
            }
            .frame(minHeight: listHeight, alignment: .topLeading)
        }
        .help(l10n.tr("energySample.explain"))
        .accessibilityHint(l10n.tr("energySample.explain"))
        // Sampling must not inherit springs from simultaneous control updates.
        .transaction { $0.animation = nil }
    }
}
