import SwiftUI

/// All tabs keep the same type size and weight. Selection changes color and
/// the parent pill, never text metrics; concise localized labels fit intact.
struct SettingsTabLabel: View {
    let tab: CoddleSettingsTab
    let isSelected: Bool
    @EnvironmentObject private var l10n: Localizer
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.iconName)
                .font(CoddleTypography.settingsTab)
                .frame(width: 14, height: 14)
                .coddleSecondaryForeground(isSelected ? CoddleSemanticColor.electricBlue(for: colorScheme) : .secondary,
                                           when: !isSelected)
                .accessibilityHidden(true)
            Text(l10n.tr(tab.compactLocalizationKey))
                .font(CoddleTypography.settingsTab)
                .coddleSecondaryForeground(isSelected ? .primary : .secondary, when: !isSelected)
                .lineLimit(1)
                .fixedSize()
        }
        .fixedSize()
    }
}
