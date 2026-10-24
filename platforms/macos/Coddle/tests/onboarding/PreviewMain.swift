import AppKit
import Foundation
import SwiftUI

@MainActor private final class SetupReview: NSObject, NSApplicationDelegate {
    let output: URL
    let arguments: [String]
    var window: NSWindow!
    var rows: [[String: Any]] = []
    var scenarioRows: [[String: Any]] = []
    var currentModel: AppModel?
    var currentFixture: ModelFixture?
    var currentLocalizer: Localizer?
    var panelOpenCount = 0
    var currentCase = "launch"
    struct Scene {
        let name: String
        let step: Int
        var language = "zh-Hans"
        var theme = "liquidGlass"
        var dark = false
        var size = NSSize(width: 440, height: 520)
        var label: String { "\(name)-\(language)-\(theme)-\(dark ? "dark" : "light")" }
    }
    var reviewScenes: [Scene] = []
    var selectedScene = 0
    static let regressionScenes: [(String, Int)] = [
        ("revoked", 4), ("stop-failed", 4), ("no-80", 0),
        ("focus-habit", 0), ("focus-task", 1), ("no-change", 4), ("complete", 5),
        ("completion-stop-failed", 5), ("changed-limits", 4)
    ]
    init(output: URL, arguments: [String]) { self.output = output; self.arguments = arguments }
    func option(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                if arguments.contains("--review") {
                    try await beginNativeReview()
                    return
                }
                try await run()
                let report: [String: Any] = ["passed": true, "matrixCount": rows.count, "rows": rows,
                    "regressionCount": scenarioRows.count, "regressions": scenarioRows,
                    "evidence": "Production SwiftUI + AppModel + injected external services. AX text, action, frame checks and native keyboard events. Cached images do not prove native glass compositing or live system authorization."]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("report.json"))
                print("onboarding-ui: \(rows.count) layout cases, \(scenarioRows.count) regression scenes, and AX flow passed")
            } catch {
                try? error.localizedDescription.write(to: output.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
                print("FAIL: \(error)")
            }
            NSApp.terminate(nil)
        }
    }
    func beginNativeReview() async throws {
        for theme in ["liquidGlass", "classic"] {
            for dark in [false, true] {
                for language in Localizer.supported {
                    for (name, step) in Self.regressionScenes {
                        reviewScenes.append(Scene(name: name, step: step, language: language, theme: theme, dark: dark))
                    }
                }
            }
        }
        let main = NSMenu()
        let application = NSMenu(); let applicationItem = NSMenuItem(); applicationItem.submenu = application
        application.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(applicationItem)
        let review = NSMenu(title: "Review")
        let reviewItem = NSMenuItem(title: "Review", action: nil, keyEquivalent: ""); reviewItem.submenu = review; main.addItem(reviewItem)
        let next = NSMenuItem(title: "Next scene", action: #selector(nextScene), keyEquivalent: "n"); next.target = self; review.addItem(next)
        review.addItem(.separator())
        for (index, scene) in reviewScenes.enumerated() {
            let item = NSMenuItem(title: scene.label, action: #selector(selectScene(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; review.addItem(item)
        }
        NSApp.mainMenu = main
        selectedScene = reviewScenes.firstIndex {
            $0.name == (option("--scene") ?? "revoked") && $0.language == (option("--language") ?? "zh-Hans") &&
            $0.theme == (option("--theme") ?? "liquidGlass") && $0.dark == arguments.contains("--dark")
        } ?? 0
        try await mountReviewScene()
        NSApp.activate(ignoringOtherApps: true)
        print("READY: \(reviewScenes.count) isolated native scenes; select Review menu or Command-N. No live power, login, or notification services are used.")
        fflush(stdout)
    }
    @objc func selectScene(_ sender: NSMenuItem) { selectedScene = sender.tag; changeReviewScene() }
    @objc func nextScene() { selectedScene = (selectedScene + 1) % reviewScenes.count; changeReviewScene() }
    func changeReviewScene() {
        Task {
            do { try await mountReviewScene() }
            catch { print("FAIL changing review scene: \(error)"); fflush(stdout) }
        }
    }
    func mountReviewScene() async throws {
        let scene = reviewScenes[selectedScene]
        try await mount(step: scene.step, language: scene.language, theme: scene.theme, dark: scene.dark, size: scene.size, scenario: scene.name)
        window.title = "Coddle Review: " + scene.label
        try saveAX(scene.label)
    }
    func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "SetupReview", code: 1, userInfo: [NSLocalizedDescriptionKey: "[\(currentCase)] \(message)"]) }
    }
    func nodes(_ node: NSObject, depth: Int = 0) -> [NSObject] {
        if depth == 0, let view = node as? NSView {
            return CoddleAccessibilityTree.nodes(in: view, native: { nativeNodes(view) }) {
                attribute($0, "accessibilityIdentifier") != nil
            }
        }
        return nativeNodes(node, depth: depth)
    }
    func nativeNodes(_ node: NSObject, depth: Int = 0) -> [NSObject] {
        guard depth < 30 else { return [] }
        guard node.responds(to: NSSelectorFromString("accessibilityChildren")), let children = node.value(forKey: "accessibilityChildren") as? [NSObject] else { return [node] }
        return [node] + children.flatMap { nativeNodes($0, depth: depth + 1) }
    }
    func attribute(_ node: NSObject, _ key: String) -> String? {
        let getter = key == "accessibilityEnabled" ? "isAccessibilityEnabled" : key == "accessibilityFocused" ? "isAccessibilityFocused" : key
        guard node.responds(to: NSSelectorFromString(getter)) else { return nil }
        return node.value(forKey: key).map { String(describing: $0) }
    }
    func node(_ identifier: String) -> NSObject? {
        nodes(window.contentView!).first { attribute($0, "accessibilityIdentifier") == identifier }
    }
    func labels() -> [String] {
        nodes(window.contentView!).flatMap { object in
            [attribute(object, "accessibilityLabel"), attribute(object, "accessibilityValue")].compactMap { $0 }
        }
    }
    func containsText(_ text: String) -> Bool { labels().contains { $0 == text || $0.contains(text) } }
    func requireText(_ key: String, present: Bool = true) throws {
        let text = currentLocalizer!.tr(key)
        try require(containsText(text) == present, "\(present ? "Missing" : "Unexpected") rendered text \(key): \(text)")
    }
    func requireVisible(_ identifier: String) throws {
        guard let object = node(identifier), let frame = object.value(forKey: "accessibilityFrame") as? NSValue else {
            try require(false, "Missing framed control \(identifier)"); return
        }
        let safe = window.convertToScreen(window.contentLayoutRect).insetBy(dx: -1, dy: -1)
        try require(frame.rectValue.width > 0 && frame.rectValue.height > 0 && safe.contains(frame.rectValue), "Control outside first viewport: \(identifier), frame=\(frame.rectValue), viewport=\(safe)")
    }
    func requireButtonLabel(_ identifier: String, key: String) throws {
        guard let object = node(identifier) else { try require(false, "Missing \(identifier)"); return }
        let text = currentLocalizer!.tr(key)
        let rendered = [attribute(object, "accessibilityLabel"), attribute(object, "accessibilityTitle")].compactMap { $0 }
        try require(rendered.contains(text), "\(identifier) must be labelled \(text), got \(rendered)")
    }
    func saveAX(_ name: String) throws {
        let rows: [[String: String]] = nodes(window.contentView!).map { object in
            var row: [String: String] = [:]
            for attributeName in ["accessibilityIdentifier", "accessibilityRole", "accessibilityLabel", "accessibilityValue", "accessibilityEnabled", "accessibilityFocused", "accessibilityFrame"] {
                if let value = attribute(object, attributeName) { row[attributeName] = value }
            }
            return row
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name + "-ax.json"))
    }
    func press(_ identifier: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            let flow = currentModel!.onboarding!
            let enabled = node(identifier).flatMap { attribute($0, "accessibilityEnabled") }
            if !flow.busy && !flow.checking && !currentModel!.taskStopBusy && enabled == "1" { break }
            try require(ContinuousClock.now < deadline,
                "Timed out waiting for enabled AX control \(identifier): step=\(flow.record.step), canAdvance=\(flow.canAdvance), busy=\(flow.busy), checking=\(flow.checking), AXEnabled=\(enabled ?? "missing")")
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let object = node(identifier) else { try require(false, "Missing control \(identifier)"); return }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard let implementation = object.method(for: selector) else { try require(false, "No AX press \(identifier)"); return }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        try require(unsafeBitCast(implementation, to: Press.self)(object, selector), "AX press failed \(identifier) at step \(currentModel!.onboarding!.record.step), canAdvance=\(currentModel!.onboarding!.canAdvance), busy=\(currentModel!.onboarding!.busy), checking=\(currentModel!.onboarding!.checking)")
    }
    func settle() async throws {
        // OnboardingView.task starts a coordinator refresh after mounting. That
        // refresh is not part of AppModel's pending task list, so draining the
        // model then sleeping for a fixed interval can return while UI is disabled.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var drained = false
        let drain = Task { @MainActor in
            await currentModel?.waitForPendingOperations()
            await currentModel?.onboarding?.waitForPersistence()
            drained = true
        }
        defer { drain.cancel() }
        window?.contentView?.layoutSubtreeIfNeeded()
        var quietSince: ContinuousClock.Instant?
        while true {
            let flow = currentModel?.onboarding
            let idle = drained && flow?.busy != true && flow?.checking != true && currentModel?.taskStopBusy != true
            if idle {
                if quietSince == nil { quietSince = .now }
                if quietSince!.duration(to: .now) >= .milliseconds(80) { return }
            } else { quietSince = nil }
            try require(ContinuousClock.now < deadline,
                "Timed out waiting for UI readiness: modelDrained=\(drained), busy=\(flow?.busy ?? false), checking=\(flow?.checking ?? false)")
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    func sendArrow(_ direction: UInt32, keyCode: UInt16) async throws {
        let character = String(UnicodeScalar(direction)!)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode)!
        window.sendEvent(event)
        try await settle()
    }
    func mount(step: Int, language: String, theme: String, dark: Bool, size: NSSize, scenario: String = "normal") async throws {
        currentCase = "\(language)/\(theme)/\(dark ? "dark" : "light")/\(Int(size.width))x\(Int(size.height))/step\(step)/\(scenario)"
        currentModel?.shutdownKeepAwake(); await currentModel?.waitForPendingOperations(); currentFixture?.clean()
        window?.close()
        let f = ModelFixture(); f.supportsLimit = true; f.config.theme = theme
        f.config.language = language; f.config.lowBatteryReminder = .disabled
        f.battery.externalConnected = true; f.helper.installed = step >= 3
        var record = OnboardingRecord(); record.step = step; record.task = step == 0 ? .none : .lid
        if step >= 4 { record.login = .skipped; record.reminder = .disabled; record.helper = .enabled }
        if step == 5 { record.completed = true; record.charge = .confirmed; record.ordinary = .confirmed; record.lid = .confirmed }
        if scenario == "old-helper" { f.helper.installed = true; f.helper.readinessOverride = .outdated }
        if scenario == "partial" { record.charge = .confirmed; record.ordinary = .confirmed; record.lid = .failed }
        if scenario == "unknown" { f.hardwareReadError = HardwareFailure(message: "Unavailable") }
        if scenario == "desktop" { f.battery = BatteryInfo(); f.clamshell = nil; f.availableEnergyModes = [.automatic]; record.task = .none }
        if scenario == "revoked" {
            f.login = .requiresApproval; record.login = .enabled; record.reminder = .enabled
            f.config.lowBatteryReminder = .enabled; f.notificationState = "notification.denied"
        }
        if ["no-80", "changed-limits"].contains(scenario) { f.availableLimits = [85, 90, 95, 100] }
        if scenario == "no-change" { record.habit = .unchanged; record.task = .none }
        if ["stop-failed", "completion-stop-failed"].contains(scenario) {
            record.charge = .confirmed; record.ordinary = .confirmed; record.lid = .confirmed
            f.helper.writeError = HelperError(message: "Injected OFF failure")
            f.helper.sleepDisabled = true
        }
        let store = OnboardingStore(directory: output.appendingPathComponent("fixture"))
        try store.save(record)
        let localizer = Localizer(language: language, resourceBundle: .main)
        var services = f.services(); services.translate = { localizer.tr($0) }; services.setLanguage = { localizer.language = $0 }
        let m = AppModel(services: services, startup: OnboardingStartup(record: record), onboardingStore: store)
        currentModel = m; currentFixture = f; currentLocalizer = localizer; panelOpenCount = 0
        await m.waitForPendingOperations(); await m.onboarding!.refresh()
        if ["stop-failed", "completion-stop-failed"].contains(scenario) { m.restoreSystemDefaults(); await m.waitForPendingOperations() }
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.titlebarAppearsTransparent = true
        window.title = "Coddle Setup Review"; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let view = OnboardingView(flow: m.onboarding!, model: m, l10n: localizer, close: {}, openPanel: { self.panelOpenCount += 1 })
            .environment(\.colorScheme, dark ? .dark : .light)
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(size); window.center(); window.makeKeyAndOrderFront(nil)
        try await settle()
    }
    func capture(_ filename: String) throws {
        let v = window.contentView!; v.layoutSubtreeIfNeeded()
        guard let bitmap = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { try require(false, "No bitmap"); return }
        v.cacheDisplay(in: v.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(filename))
    }
    func runRegressions() async throws {
        for language in option("--language").map({ [$0] }) ?? Localizer.supported {
            for (scenario, step) in Self.regressionScenes {
                try await mount(step: step, language: language, theme: "liquidGlass", dark: false,
                    size: NSSize(width: 440, height: 520), scenario: scenario)
                let flow = currentModel!.onboarding!
                let fixture = currentFixture!
                let name = "regression-\(language)-\(scenario)"
                try capture(name + ".png")
                try saveAX(name)
                let primary = step == 5 ? "onboarding.finish" : scenario == "revoked" ? "onboarding.repairPreparation" : scenario == "changed-limits" ? "onboarding.repairLimit" : "onboarding.next"
                try requireVisible(primary)
                if step < 5 { try requireVisible("onboarding.later") }
                switch scenario {
                case "revoked":
                    try require(flow.loginState == "login.requiresApproval" && flow.notificationState == "notification.denied", "Revoked fixture must expose current service state")
                    try require(!flow.canAdvance, "Unresolved permissions must prevent apply")
                    try requireText("login.requiresApproval")
                    try requireText("notification.denied")
                    try requireText("onboarding.notificationReady", present: false)
                    try requireText("onboarding.manualLogin", present: false)
                    try require(node("onboarding.repairLogin") != nil && node("onboarding.repairNotification") != nil, "Each unresolved preparation must provide a local repair action")
                    try await press("onboarding.repairPreparation"); try await settle()
                    try require(flow.record.step == 3, "Visible repair action must open permission preparation")
                case "stop-failed", "completion-stop-failed":
                    try require(currentModel!.taskStopStatus == "onboarding.stopPartial", "Injected lid OFF failure must remain partial")
                    try require(currentModel!.taskStopOrdinary == .confirmed && currentModel!.taskStopLid != .confirmed, "Partial stop must expose actual ordinary/lid readbacks")
                    try requireVisible("onboarding.currentStopStatus")
                    try requireVisible("retry-stop-keep-awake")
                    let retry = scenario == "completion-stop-failed" ? "onboarding.retryStop" : "onboarding.next"
                    try requireVisible(retry)
                    try requireButtonLabel(retry, key: "onboarding.retryStop")
                    try requireText("onboarding.stopPartial")
                    try requireText("onboarding.stopConfirmed")
                    try requireText("onboarding.stopUnconfirmed")
                    if scenario == "completion-stop-failed" {
                        try requireText("onboarding.awakeStarted", present: false)
                        try requireText("onboarding.awakeActiveBody", present: false)
                    }
                    // A remaining charge row may still truthfully be confirmed; awake rows must not be.
                    for identifier in ["onboarding.ordinaryResult", "onboarding.lidResult"] {
                        for result in nodes(window.contentView!).filter({ attribute($0, "accessibilityIdentifier") == identifier }) {
                            let values = nodes(result).flatMap { [attribute($0, "accessibilityLabel"), attribute($0, "accessibilityValue")].compactMap { $0 } }
                            try require(!values.contains(currentLocalizer!.tr("onboarding.result.confirmed")), "Stopped or uncertain awake result cannot retain an active label: \(identifier)")
                        }
                    }
                    fixture.helper.writeError = nil
                    try await press(retry); try await settle()
                    try require(currentModel!.taskStopStatus == "onboarding.stopped" && !flow.record.stopPending, "Visible retry must verify both effects off and clear the durable stop obligation")
                case "no-80":
                    try require(flow.record.targetLimit == 80 && !flow.canAdvance, "Unsupported default must wait for an explicit choice without silent rounding")
                    try require(!containsText(currentLocalizer!.tr("onboarding.dailyLimit", 80)), "Unsupported 80 percent must not be recommended")
                    try require(node("onboarding.availableLimits") != nil && node("onboarding.chargeSkip") != nil, "Picker and keep-current path must be available")
                    try requireText("onboarding.chooseAvailableLimit")
                    try require(node("onboarding.availableLimits").flatMap { attribute($0, "accessibilityValue") } == currentLocalizer!.tr("onboarding.chooseAvailableLimit"), "Unsupported-limit picker must expose a nonblank placeholder as its current value")
                    try require(fixture.limitWrites.isEmpty, "Inspecting an unsupported recommendation cannot change hardware")
                    flow.chooseLimit(85); try await settle()
                    try require(flow.record.targetLimit == 85 && flow.canAdvance, "An explicitly supported choice must enable continue")
                    try require(containsText("85%"), "The picker must display its supported selection")
                    try await press("onboarding.next"); try await settle()
                    try require(flow.record.step == 1 && fixture.limitWrites.isEmpty, "Continue after limit selection must only advance the draft")
                case "changed-limits":
                    try require(!flow.canAdvance && !flow.record.hasApplicationAttempt, "A newly unsupported limit must block confirmation before any write")
                    try requireButtonLabel("onboarding.repairLimit", key: "onboarding.chooseAvailableLimit")
                    try await press("onboarding.repairLimit"); try await settle()
                    try require(flow.record.step == 0 && flow.record.targetLimit == 80, "Limit repair must return to explicit selection without silently changing the draft target")
                    try require(node("onboarding.availableLimits").flatMap { attribute($0, "accessibilityValue") } == currentLocalizer!.tr("onboarding.chooseAvailableLimit"), "Repair path must expose the unselected picker placeholder")
                    try require(fixture.limitWrites.isEmpty, "Limit repair navigation must not write charging hardware")
                case "focus-habit":
                    try await press("onboarding.habit.desk"); try await settle()
                    try await sendArrow(UInt32(NSDownArrowFunctionKey), keyCode: 125)
                    try require(flow.record.habit == .mobile, "Down arrow must move the focused habit choice")
                    try await sendArrow(UInt32(NSUpArrowFunctionKey), keyCode: 126)
                    try require(flow.record.habit == .desk, "Up arrow must move focus back to the desk choice")
                    try require(window.firstResponder != nil, "Choice controls must preserve a keyboard responder")
                case "focus-task":
                    try await press("onboarding.task.none"); try await settle()
                    try await sendArrow(UInt32(NSDownArrowFunctionKey), keyCode: 125)
                    try require(flow.record.task == .open, "Task down arrow must select ordinary keep-awake")
                    try await sendArrow(UInt32(NSDownArrowFunctionKey), keyCode: 125)
                    try require(flow.record.task == .lid, "Task down arrow must select lid keep-awake")
                    try await sendArrow(UInt32(NSUpArrowFunctionKey), keyCode: 126)
                    try require(flow.record.task == .open, "Task up arrow must retain keyboard navigation")
                case "no-change":
                    try requireButtonLabel("onboarding.next", key: "onboarding.finishSetup")
                    try requireText("onboarding.confirmBody", present: false)
                    // Exercise the original race deterministically: refresh owns
                    // the disabled state until the delayed hardware read returns.
                    fixture.hardwareReadDelay = .milliseconds(250)
                    let refresh = Task { await flow.refresh() }
                    let refreshDeadline = ContinuousClock.now.advanced(by: .seconds(1))
                    while !flow.checking && ContinuousClock.now < refreshDeadline { try await Task.sleep(for: .milliseconds(1)) }
                    try require(flow.checking && !flow.canAdvance, "Delayed refresh must disable confirmation before the AX readiness wait")
                    try await press("onboarding.next"); try await settle()
                    await refresh.value; fixture.hardwareReadDelay = .zero
                    try require(flow.record.completed && flow.record.step == 5 && panelOpenCount == 0, "Complete setup action must accurately lead to completion before panel handoff")
                    try require(fixture.limitWrites.isEmpty && !fixture.helper.writes.contains(true) && !fixture.systemAssertions.contains(true), "No-change path must leave charging and sleep behavior untouched")
                    try requireButtonLabel("onboarding.finish", key: "onboarding.enterPanel")
                    try await press("onboarding.finish"); try await settle()
                    try require(panelOpenCount == 1, "Enter-panel action must perform exactly one panel handoff")
                case "complete":
                    try requireText("onboarding.persistentAwake", present: false)
                    try requireText("onboarding.awakeActiveBody")
                    try requireText("onboarding.firstStop")
                    let optional = currentLocalizer!.tr("onboarding.tutorialOptional")
                    let optionalCount = nodes(window.contentView!).filter { attribute($0, "accessibilityLabel") == optional || attribute($0, "accessibilityValue") == optional }.count
                    try require(optionalCount == 1, "Optional-tutorial note must appear once, got \(optionalCount)")
                    try requireButtonLabel("onboarding.finish", key: "onboarding.enterPanel")
                default: break
                }
                scenarioRows.append(["name": scenario, "language": language, "passed": true])
            }
        }
    }
    func run() async throws {
        if !arguments.contains("--scenarios-only") {
        for language in Localizer.supported {
            for theme in ["liquidGlass", "classic"] {
                for dark in [false, true] {
                    for size in [NSSize(width: 440, height: 520), NSSize(width: 480, height: 600), NSSize(width: 600, height: 800)] {
                        for step in 0...5 {
                            try await mount(step: step, language: language, theme: theme, dark: dark, size: size)
                            let id = step == 5 ? "onboarding.finish" : node("onboarding.repairPreparation") != nil ? "onboarding.repairPreparation" : "onboarding.next"
                            try requireVisible(id)
                            if step < 5 { try requireVisible("onboarding.later") }
                            if step > 0 && step < 5 { try requireVisible("onboarding.back") }
                            try require(!labels().contains(where: { $0.contains("onboarding.") }), "Untranslated key in \(language) step \(step)")
                            if language == "zh-Hans" && size.width == 480 { try capture("\(theme)-\(dark ? "dark" : "light")-\(step).png") }
                            rows.append(["language": language, "theme": theme, "dark": dark, "width": size.width, "height": size.height, "step": step, "primaryVisible": true])
                        }
                    }
                }
            }
        }
        }
        try await runRegressions()
        for (scenario, step) in [("old-helper", 2), ("partial", 4), ("unknown", 0), ("desktop", 1)] {
            try await mount(step: step, language: "zh-Hans", theme: "liquidGlass", dark: false, size: NSSize(width: 440, height: 520), scenario: scenario)
            try capture("scenario-\(scenario).png")
        }
        try await mount(step: 0, language: "en", theme: "liquidGlass", dark: false, size: NSSize(width: 480, height: 600))
        let flow = currentModel!.onboarding!
        try await press("onboarding.habit.desk"); try await settle()
        let arrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: String(UnicodeScalar(NSDownArrowFunctionKey)!),
            charactersIgnoringModifiers: String(UnicodeScalar(NSDownArrowFunctionKey)!), isARepeat: false, keyCode: 125)!
        window.sendEvent(arrow); try await settle()
        try require(flow.record.habit == .mobile, "Focused choice responds to native down-arrow event")
        try await press("onboarding.habit.mobile"); try await settle()
        try require(flow.record.habit == .mobile, "Actual choice AX action must change draft")
        try await press("onboarding.next"); try await settle()
        try await press("onboarding.task.open"); try await settle()
        try await press("onboarding.next"); try await settle()
        try require(flow.record.step == 2, "Helper preparation appears before completion")
        try await press("onboarding.installHelper"); try await settle()
        try require(flow.helperReady && !currentFixture!.helper.writes.contains(true), "AX install prepares without ON")
        try await press("onboarding.next"); try await settle()
        await flow.chooseLogin(false); await flow.chooseReminder(false); try await settle()
        try await press("onboarding.next"); try await settle()
        try await press("onboarding.next"); try await settle()
        try require(flow.record.completed && node("onboarding.finish") != nil, "AX final apply reaches verified completion")
        currentModel!.restoreSystemDefaults(); try await settle()
        try require(currentModel!.taskStopStatus == "onboarding.stopped", "Completed task can be stopped")
        currentModel!.shutdownKeepAwake(); await currentModel!.waitForPendingOperations(); currentFixture!.clean()
        try? FileManager.default.removeItem(at: output.appendingPathComponent("fixture"))
    }
}

@main private struct OnboardingUIReview {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate = SetupReview(output: URL(fileURLWithPath: CommandLine.arguments.last!), arguments: Array(CommandLine.arguments.dropFirst()))
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
