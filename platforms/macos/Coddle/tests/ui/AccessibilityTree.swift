import AppKit
import ApplicationServices
import Foundation

/// SwiftUI can leave `NSView.accessibilityChildren` empty until HIServices
/// queries the process. GitHub's macOS 15 runner hits that case: the review
/// window is key and active, but no control identifier is published in-process.
/// A same-process accessibility query both forces that tree to materialize and
/// provides a readable fallback. It does not require an Accessibility permission.
enum CoddleAccessibilityTree {
    static func nodes(in view: NSView, native: () -> [NSObject],
                      hasIdentifier: (NSObject) -> Bool) -> [NSObject] {
        let forceSystemTree = ProcessInfo.processInfo.environment["CODDLE_UI_AX_SOURCE"] == "ax"
        if !forceSystemTree {
            let published = native()
            if published.contains(where: hasIdentifier) { return published }
        }
        prime(view.window)
        if !forceSystemTree {
            let refreshed = native()
            if refreshed.contains(where: hasIdentifier) { return refreshed }
        }
        let systemNodes = systemNodes(in: view)
        // The explicit test mode must fail if the system tree is unavailable;
        // falling back would hide a broken adapter on a developer machine.
        if forceSystemTree { return systemNodes }
        return systemNodes.isEmpty ? native() : systemNodes
    }

    static func diagnostic(for window: NSWindow?) -> String {
        let application = AXUIElementCreateApplication(pid_t(ProcessInfo.processInfo.processIdentifier))
        AXUIElementSetMessagingTimeout(application, 1)
        var raw: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw)
        let windows = elements(in: raw)
        let identifiers = windows.flatMap { identifiers(in: $0, depth: 0) }
        let sample = identifiers.prefix(8).joined(separator: ", ")
        return "axError=\(result.rawValue) axWindows=\(windows.count) axIdentifiers=\(identifiers.count) [\(sample)]"
    }

    private static func prime(_ window: NSWindow?) {
        _ = diagnostic(for: window)
    }

    private static func systemNodes(in view: NSView) -> [NSObject] {
        guard let window = view.window else { return [] }
        let application = AXUIElementCreateApplication(pid_t(ProcessInfo.processInfo.processIdentifier))
        AXUIElementSetMessagingTimeout(application, 1)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw) == .success else {
            return []
        }
        let windows = elements(in: raw)
        guard let element = windows.first(where: { stringAttribute($0, kAXTitleAttribute) == window.title }) else {
            return []
        }
        var nodes: [NSObject] = []
        func walk(_ element: AXUIElement, _ depth: Int) {
            guard depth < 24 else { return }
            let node = SystemAccessibilityNode(element)
            nodes.append(node)
            for child in node.childElements { walk(child, depth + 1) }
        }
        walk(element, 0)
        return nodes
    }

    private static func identifiers(in element: AXUIElement, depth: Int) -> [String] {
        guard depth < 24 else { return [] }
        var found: [String] = []
        if let identifier = stringAttribute(element, kAXIdentifierAttribute) { found.append(identifier) }
        for child in elements(in: copied(element, kAXChildrenAttribute)) {
            found.append(contentsOf: identifiers(in: child, depth: depth + 1))
        }
        return found
    }

    fileprivate static func elements(in value: CFTypeRef?) -> [AXUIElement] {
        guard let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = value as! CFArray
        var elements: [AXUIElement] = []
        for index in 0..<CFArrayGetCount(array) {
            let item = CFArrayGetValueAtIndex(array, index)
            elements.append(unsafeBitCast(item, to: AXUIElement.self))
        }
        return elements
    }

    fileprivate static func copied(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    fileprivate static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copied(element, attribute), CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        let string = value as! String
        return string.isEmpty ? nil : string
    }
}

private final class SystemAccessibilityNode: NSObject {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
        super.init()
    }

    var childElements: [AXUIElement] {
        CoddleAccessibilityTree.elements(in: CoddleAccessibilityTree.copied(element, kAXChildrenAttribute))
    }

    override func responds(to selector: Selector!) -> Bool {
        switch NSStringFromSelector(selector) {
        case "accessibilityIdentifier", "accessibilityLabel", "accessibilityTitle", "accessibilityValue",
             "accessibilityRole", "accessibilityHelp", "accessibilityFrame", "accessibilityChildren",
             "accessibilityEnabled", "isAccessibilityEnabled", "accessibilityFocused", "isAccessibilityFocused",
             "accessibilityPerformPress":
            return true
        default:
            return super.responds(to: selector)
        }
    }

    override func value(forKey key: String) -> Any? {
        switch key {
        case "accessibilityChildren":
            return childElements.map(SystemAccessibilityNode.init)
        case "accessibilityFrame":
            return frame.map(NSValue.init(rect:))
        case "accessibilityEnabled":
            return numberAttribute(kAXEnabledAttribute)
        case "accessibilityFocused":
            return numberAttribute(kAXFocusedAttribute)
        case "accessibilityIdentifier":
            return CoddleAccessibilityTree.stringAttribute(element, kAXIdentifierAttribute)
        case "accessibilityLabel":
            return CoddleAccessibilityTree.stringAttribute(element, kAXDescriptionAttribute)
                ?? CoddleAccessibilityTree.stringAttribute(element, kAXTitleAttribute)
        case "accessibilityTitle":
            return CoddleAccessibilityTree.stringAttribute(element, kAXTitleAttribute)
        case "accessibilityRole":
            return CoddleAccessibilityTree.stringAttribute(element, kAXRoleAttribute)
        case "accessibilityHelp":
            return CoddleAccessibilityTree.stringAttribute(element, kAXHelpAttribute)
        case "accessibilityValue":
            return attributeValue(kAXValueAttribute)
        default:
            return nil
        }
    }

    @objc func accessibilityPerformPress() -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private var frame: NSRect? {
        let raw: NSRect?
        if let rect = rectAttribute("AXFrame") {
            raw = rect
        } else if let origin = pointAttribute(kAXPositionAttribute), let size = sizeAttribute(kAXSizeAttribute) {
            raw = NSRect(origin: origin, size: size)
        } else {
            raw = nil
        }
        // Accessibility frames use the primary display's top-left origin.
        // AppKit screen frames use its bottom-left origin.
        guard var rect = raw, let screen = NSScreen.screens.first else { return raw }
        rect.origin.y = screen.frame.maxY - rect.maxY
        return rect
    }

    private func attributeValue(_ attribute: String) -> Any? {
        guard let value = CoddleAccessibilityTree.copied(element, attribute) else { return nil }
        let type = CFGetTypeID(value)
        if type == CFStringGetTypeID() {
            return value as! String
        }
        if type == CFBooleanGetTypeID() || type == CFNumberGetTypeID() {
            return value as! NSNumber
        }
        return nil
    }

    private func numberAttribute(_ attribute: String) -> NSNumber? {
        attributeValue(attribute) as? NSNumber
    }

    private func rectAttribute(_ attribute: String) -> NSRect? {
        guard let axValue = axValue(attribute), AXValueGetType(axValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private func pointAttribute(_ attribute: String) -> NSPoint? {
        guard let axValue = axValue(attribute), AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(_ attribute: String) -> NSSize? {
        guard let axValue = axValue(attribute), AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private func axValue(_ attribute: String) -> AXValue? {
        guard let value = CoddleAccessibilityTree.copied(element, attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXValue.self)
    }
}
