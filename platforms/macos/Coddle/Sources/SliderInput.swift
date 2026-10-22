import AppKit
import SwiftUI

/// Native keyboard and accessibility semantics for the custom slider artwork.
/// The view never handles pointer hits: SwiftUI's existing drag gesture owns
/// preview/commit, while keyboard and AX adjustments use the same value callback.
struct CoddleSliderInput: NSViewRepresentable {
    let value: Double
    let range: ClosedRange<Double>
    let label: String
    var identifier: String = ""
    var helpText: String? = nil
    var onFocusChange: (Bool) -> Void = { _ in }
    var valueDescription: (Double) -> String = { "\(Int($0.rounded()))%" }
    var nextValue: (Double, Int) -> Double = { $0 + Double($1) }
    let onCommit: (Double) -> Void

    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> CoddleSemanticSlider {
        let slider = CoddleSemanticSlider()
        slider.isContinuous = false
        slider.focusRingType = .none
        updateNSView(slider, context: context)
        return slider
    }

    func updateNSView(_ slider: CoddleSemanticSlider, context: Context) {
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.isEnabled = isEnabled
        slider.setAccessibilityLabel(label)
        slider.setAccessibilityIdentifier(identifier)
        slider.setAccessibilityHelp(helpText)
        slider.onFocusChange = onFocusChange
        slider.describeValue = valueDescription
        slider.nextValue = nextValue
        slider.onCommit = onCommit
        slider.needsDisplay = true
    }
}

/// NSSlider supplies a real AXSlider role and key-view participation on macOS 13.
/// Only the focus outline is drawn here; the visual rail/thumb remain SwiftUI.
final class CoddleSemanticSlider: NSSlider {
    var describeValue: (Double) -> String = { "\(Int($0.rounded()))%" }
    var nextValue: (Double, Int) -> Double = { $0 + Double($1) }
    var onCommit: (Double) -> Void = { _ in }
    var onFocusChange: (Bool) -> Void = { _ in }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool {
        isEnabled && !isHiddenOrHasHiddenAncestor && window != nil
    }

    // NSSlider normally exposes its cell as the AXSlider. This control owns
    // its actions in the view, so expose one semantic element here instead of
    // leaving assistive technology to invoke the cell's unrelated target/action.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityValue() -> Any? { NSNumber(value: doubleValue) }
    override func accessibilityMinValue() -> Any? { NSNumber(value: minValue) }
    override func accessibilityMaxValue() -> Any? { NSNumber(value: maxValue) }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange(true) }
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange(false) }
        needsDisplay = true
        return accepted
    }

    override func draw(_ dirtyRect: NSRect) {
        guard window?.firstResponder === self else { return }
        NSColor.keyboardFocusIndicatorColor.setStroke()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        outline.lineWidth = 2
        outline.stroke()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 125: adjust(-1) // Left / Down
        case 124, 126: adjust(1)  // Right / Up
        case 115: commit(minValue) // Home
        case 119: commit(maxValue) // End
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityValueDescription() -> String? { describeValue(doubleValue) }

    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled else { return false }
        adjust(1)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled else { return false }
        adjust(-1)
        return true
    }

    override func setAccessibilityValue(_ value: Any?) {
        guard isEnabled, let number = value as? NSNumber else { return }
        commit(number.doubleValue)
    }

    private func adjust(_ direction: Int) {
        commit(nextValue(doubleValue, direction))
    }

    private func commit(_ proposed: Double) {
        guard isEnabled, proposed.isFinite else { return }
        let value = min(maxValue, max(minValue, proposed))
        guard value != doubleValue else { return }
        doubleValue = value
        onCommit(value)
        NSAccessibility.post(element: self, notification: .valueChanged)
        needsDisplay = true
    }
}
