import AppKit
import SwiftUI

/// The same failure feedback stays visible on both dashboard and Settings.
struct CoddleErrorBanner: View {
    let message: String
    let dismissLabel: String
    var dismiss: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let crimson = CoddleSemanticColor.crimson(for: colorScheme)
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(crimson)
                .accessibilityHidden(true)
            Text(message)
                .font(CoddleTypography.microMeta)
                .foregroundStyle(crimson)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("coddle-error-message")
            Spacer()
            if let dismiss {
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.80)) {
                        dismiss()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(CoddleScaleButtonStyle())
                .help(dismissLabel)
                .accessibilityLabel(dismissLabel)
                .accessibilityIdentifier("dismiss-error")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(crimson.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(crimson.opacity(0.28), lineWidth: 0.75))
        .onAppear(perform: announce)
        .onChange(of: message) { _ in announce() }
    }

    private func announce() {
        guard let window = NSApplication.shared.keyWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue
        ])
    }
}
