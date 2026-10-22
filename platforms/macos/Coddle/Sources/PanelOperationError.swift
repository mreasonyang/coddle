import SwiftUI
import AppKit

/// Local feedback persists until the owning operation resolves it.
struct PanelOperationError: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(CoddleTypography.microMeta)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("panel-operation-error")
            .onAppear { announce() }
            .onChange(of: message) { _ in announce() }
    }

    private func announce() {
        guard let window = NSApplication.shared.keyWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: message,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
