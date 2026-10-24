import AppKit
import Combine
import Foundation
import SwiftUI

/// An independent executable using the production model, localizer and panel.
/// ModelFixture replaces every power, helper, login, network and persistence
/// boundary. The only file outputs are review artifacts and an isolated suite
/// that is removed when the fixture exits.
@MainActor
private final class ReviewSession {
    let fixture = ModelFixture()
    let localizer: Localizer
    let model: AppModel
    let output: URL
    private var subscription: AnyCancellable?
    private(set) var openConfigRequests = 0
    private(set) var openSettingsRequests = 0
    private(set) var awakeSettingsRequests = 0
    private(set) var activityMonitorRequests: [pid_t] = []
    private var cleaned = false
    private var cleanupTask: Task<Void, Never>?
    private static var pendingCleanups: [UUID: Task<Void, Never>] = [:]
    private let overrideSignal: ChargeOverrideSignal

    init(language: String, theme: String, output: URL, packReadings: Bool = true,
         override: ChargeOverrideSignal = .none, predictedUnplug: Int? = nil) {
        self.output = output
        self.overrideSignal = override
        localizer = Localizer(language: language, resourceBundle: .main)
        fixture.config.language = language
        fixture.config.theme = theme
        fixture.config.smartEnabled = true
        fixture.config.keepAwake = true
        fixture.config.keepAwakeOnLidClosed = true
        fixture.helper.installed = true
        fixture.supportsLimit = true
        fixture.idle = 0
        // `packReadings == false` models a pack-less machine (Intel / older
        // macOS): both pack-derived readings are absent, exactly as the parser
        // reports them. The panel must then render no hardware row at all.
        fixture.battery = BatteryInfo(present: true, installed: true, percent: 78,
            externalConnected: true, cycleCount: 137, designCapacity: 6000,
            fullChargeCapacity: 5700, notChargingReason: 0x0100_0000,
            powerFlow: packReadings ? PowerFlow(adapterWatts: 90, systemPowerInWatts: 23.7, systemLoadWatts: 23.7, batteryPowerWatts: 0.0) : nil,
            hardwarePercent: packReadings ? 73.5 : nil,
            temperatureCelsius: packReadings ? 34.3 : nil)
        fixture.away = AwayStatus(fingerprint: "a1b2c3", vpnActive: true, isUsual: true, protectionReady: true)
        fixture.significantEnergyApps = [
            SignificantEnergyApp(
                id: 101,
                name: "Safari",
                bundleIdentifier: "com.apple.Safari",
                icon: NSWorkspace.shared.icon(forFile: "/Applications/Safari.app"),
                energyScore: 18.4
            ),
            SignificantEnergyApp(
                id: 102,
                name: "Activity Monitor",
                bundleIdentifier: "com.apple.ActivityMonitor",
                icon: NSWorkspace.shared.icon(forFile: "/System/Applications/Utilities/Activity Monitor.app"),
                energyScore: 6.2
            )
        ]
        // The override is driven through the model's own debounced detector, so
        // the fixture exercises the real rule rather than injecting a verdict.
        // `.confirmed` is `powerd`'s positive signal; `.inferred` is the pack-only
        // path and must be sustained past the hold.
        switch override {
        case .none:
            fixture.chargeOverrideState = 0
        case .confirmed:
            fixture.chargeOverrideState = 1
        case .inferred:
            fixture.chargeOverrideState = 0
            fixture.battery.isCharging = true
            fixture.battery.percent = 85
        }
        var services = fixture.services()
        let localizer = localizer
        services.setLanguage = { localizer.language = $0 }
        services.translate = { localizer.tr($0) }
        if let hour = predictedUnplug {
            var ac = [Int](repeating: 10, count: 24); ac[hour] = 0
            fixture.defaults.set(ac.map(String.init).joined(separator: ","), forKey: "profile.ac")
            fixture.defaults.set([Int](repeating: 10, count: 24).map(String.init).joined(separator: ","), forKey: "profile.total")
        }
        model = AppModel(services: services)
        subscription = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.writeState() }
        }
        writeState()
    }

    func prepare() async {
        await model.waitForPendingOperations()
        if overrideSignal == .inferred {
            for _ in 0..<3 {
                fixture.now += ChargeOverrideDebouncer.requiredPackHold / 2
                model.refresh()
                await model.waitForPendingOperations()
            }
            precondition(model.chargeOverrideSignal == .inferred,
                         "review fixture failed to reach the inferred override state")
        }
        writeState()
    }

    func revealConfig() {
        openConfigRequests += 1
        writeState()
    }

    func requestSettings() {
        openSettingsRequests += 1
        writeState()
    }

    func requestAwakeSettings() {
        awakeSettingsRequests += 1
        writeState()
    }

    func openActivityMonitor(_ app: SignificantEnergyApp) {
        activityMonitorRequests.append(app.id)
        writeState()
    }

    func writeState() {
        let state: [String: Any] = [
            "fixture": true, "suite": fixture.suite, "cleaned": cleaned,
            "language": model.language, "theme": model.theme,
            "awayDetectionEnabled": model.awayDetectionEnabled,
            "systemAssertionActive": fixture.systemAssertions.last ?? false,
            "displayAssertionActive": fixture.displayAssertions.last ?? false,
            "helperInstalled": model.helperInstalled,
            "helperWrites": fixture.helper.writes,
            "configSaveCount": fixture.saved.count,
            "openConfigRequests": openConfigRequests,
            "openSettingsRequests": openSettingsRequests,
            "awakeSettingsRequests": awakeSettingsRequests,
            "activityMonitorRequests": activityMonitorRequests,
            "launchAtLogin": model.launchAtLogin,
            "showInDock": model.showInDock,
            "showMenuBarIcon": model.showMenuBarIcon,
            "chargeOverrideActive": model.chargeOverrideActive,
            "chargeOverrideSignal": String(describing: model.chargeOverrideSignal),
            "chargeStatus": String(describing: model.chargeStatus),
            "dockRequests": fixture.dockCalls
        ]
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("state.json"), options: .atomic)
        } catch {
            NSLog("Review fixture could not write state: %@", error.localizedDescription)
        }
    }

    /// `defer` can start cleanup synchronously; audit completion and normal quit
    /// await the same task before reporting restored state or deleting its suite.
    @discardableResult
    func beginCleanup() -> Task<Void, Never> {
        if let cleanupTask { return cleanupTask }
        subscription?.cancel()
        model.shutdownKeepAwake()
        let id = UUID()
        let task = Task { @MainActor [self] in
            await model.waitForPendingOperations()
            fixture.clean()
            cleaned = true
            writeState()
            Self.pendingCleanups.removeValue(forKey: id)
        }
        cleanupTask = task
        Self.pendingCleanups[id] = task
        return task
    }

    func cleanup() async { await beginCleanup().value }

    var cleanupFinished: Bool { cleaned }
    static var hasPendingCleanups: Bool { !pendingCleanups.isEmpty }

    static func waitForCleanups() async {
        while let task = pendingCleanups.values.first { await task.value }
    }
}

/// Measures production hosting work without confusing scheduler gaps with FPS.
@MainActor
private final class DisclosurePerformanceHost<Content: View>: NSHostingView<Content> {
    var layoutMilliseconds: [Double] = []
    var constraintMilliseconds: [Double] = []

    override func layout() {
        let start = ProcessInfo.processInfo.systemUptime
        super.layout()
        layoutMilliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
    }

    override func updateConstraints() {
        let start = ProcessInfo.processInfo.systemUptime
        super.updateConstraints()
        constraintMilliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
    }
}

@MainActor
private final class ReviewAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var session: ReviewSession?
    private var dockDelegate: AppDelegate?
    private let options: [String: String]
    private let render: Bool
    private let e2e: Bool
    private var terminationRequested = false

    init(arguments: [String]) {
        render = arguments.contains("--render")
        e2e = arguments.contains("--e2e")
        var parsed: [String: String] = [:]
        for i in arguments.indices where arguments[i].hasPrefix("--") && i + 1 < arguments.count {
            if !arguments[i + 1].hasPrefix("--") { parsed[arguments[i]] = arguments[i + 1] }
        }
        options = parsed
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        let output = URL(fileURLWithPath: options["--output"] ?? NSTemporaryDirectory())
            .appendingPathComponent("coddle-ui-evidence", isDirectory: true)
        if render && options["--audit"] == "quit-cleanup" {
            let session = ReviewSession(language: "en", theme: "liquidGlass", output: output)
            self.session = session
            Task { @MainActor in
                await session.prepare()
                self.requestTermination()
            }
            return
        }
        if render || e2e {
            Task { @MainActor in
                do {
                    if e2e {
                        try await interactionAudit(output: output)
                    } else if options["--audit"] == "cleanup" {
                        try await cleanupAudit(output: output)
                    } else if options["--audit"] == "scroll-viewport" {
                        try await scrollViewportAudit(output: output)
                    } else if options["--audit"] == "child-options" {
                        try await childOptionAudit(output: output)
                    } else if options["--audit"] == "power-flow" {
                        try await powerFlowAudit(output: output)
                    } else if options["--audit"] == "switch-layout" {
                        try await switchLayoutAudit(output: output)
                    } else if options["--audit"] == "disclosure-motion" {
                        try await disclosureMotionAudit(output: output)
                    } else if options["--audit"] == "activity-motion" {
                        try await activityMotionAudit(output: output)
                    } else if options["--audit"] == "activity" {
                        try await activityRefreshAudit(output: output)
                    } else if options["--audit"] == "scenarios" {
                        try await scenarioAudit(output: output)
                    } else {
                        try await renderMatrix(output: output)
                    }
                } catch {
                    let data = Data("FAIL: \(error)\n".utf8)
                    try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    try? data.write(to: output.appendingPathComponent(self.e2e ? "e2e-failure.txt" : "render-failure.txt"))
                    NSLog("UI fixture render failed: %@", String(describing: error))
                }
                await self.session?.cleanup()
                await ReviewSession.waitForCleanups()
                self.requestTermination()
            }
        } else {
            let session = ReviewSession(language: options["--language"] ?? "en",
                theme: options["--theme"] ?? "liquidGlass", output: output)
            self.session = session
            Task { @MainActor in
                await session.prepare()
                if options["--scenario"] == "awake-off" {
                    session.model.setKeepAwakeEnabled(false)
                    await session.model.waitForPendingOperations()
                }
                if options["--scenario"] == "long-awake-diagnostics" {
                    session.model.helperStatus = String(repeating:
                        "The component could not confirm the requested keep-awake state. ", count: 48)
                }
                NSApp.appearance = NSAppearance(named: options["--appearance"] == "dark" ? .darkAqua : .aqua)
                if options["--surface"] == "dock" || options["--surface"] == "native-settings" {
                    let delegate = AppDelegate(model: session.model, localizer: session.localizer,
                        notificationCenter: session.fixture.application,
                        openConfig: { session.revealConfig() },
                        openActivityMonitor: { session.openActivityMonitor($0) })
                    dockDelegate = delegate
                    if options["--surface"] == "native-settings" {
                        delegate.showSettingsWindow(tab: .awake)
                        window = delegate.settingsWindow
                    } else {
                        delegate.showMainWindow()
                        window = delegate.window
                    }
                    window?.appearance = NSAppearance(named: options["--appearance"] == "dark" ? .darkAqua : .aqua)
                    if let value = options["--height"], let height = Double(value) {
                        window?.setContentSize(NSSize(width: 340, height: height))
                    }
                } else {
                    window = options["--surface"] == "settings"
                        ? makeSettingsWindow(session: session, dark: options["--appearance"] == "dark")
                        : makePopoverWindow(session: session, dark: options["--appearance"] == "dark")
                }
                window?.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                window?.contentView?.layoutSubtreeIfNeeded()
                let ready = ["ready": window != nil,
                    "appearance": window?.effectiveAppearance.name.rawValue ?? "unavailable",
                    "title": window?.title ?? "unavailable"] as [String: Any]
                if let data = try? JSONSerialization.data(withJSONObject: ready, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: output.appendingPathComponent("interactive-ready.json"), options: .atomic)
                }
            }
        }
    }

    private func requestTermination() {
        // AppKit may enter a termination modal loop. Run it as a run-loop event,
        // after the current actor task has returned, so async cleanup can run.
        RunLoop.main.perform {
            MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if session?.cleanupFinished != false && !ReviewSession.hasPendingCleanups { return .terminateNow }
        guard !terminationRequested else { return .terminateLater }
        terminationRequested = true
        Task { @MainActor in
            await self.session?.cleanup()
            await ReviewSession.waitForCleanups()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Automated runs replace windows between cases; only the interactive
        // fixture should quit when its last window is closed.
        !render && !e2e
    }

    private func installMenu() {
        let main = NSMenu()
        let item = NSMenuItem()
        let menu = NSMenu(title: "Coddle Review UI")
        menu.addItem(withTitle: "Quit Coddle Review UI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = menu
        main.addItem(item)
        NSApplication.shared.mainMenu = main
    }

    /// The production menu-bar popover with every outside-world hook replaced by the fixture.
    private func makeRoot(session: ReviewSession, dark: Bool, maximumHeight: CGFloat? = nil) -> some View {
        var panel = PopoverControlPanel()
        if let height = maximumHeight ?? options["--maximum-panel-height"].flatMap(Double.init).map({ CGFloat($0) }) {
            panel.maximumHeight = height
        }
        return panel
            .environmentObject(session.model)
            .environmentObject(session.localizer)
            .environment(\.coddleReduceTransparency, options["--reduce-transparency"] == "true")
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.coddleOpenConfig, { session.revealConfig() })
            .environment(\.coddleOpenSettings, { session.requestSettings() })
            .environment(\.coddleOpenAwakeSettings, { session.requestAwakeSettings() })
            .environment(\.coddleOpenActivityMonitor, { session.openActivityMonitor($0) })
    }

    /// The production Settings window view.
    private func makeSettingsRoot(session: ReviewSession, dark: Bool) -> some View {
        SettingsWindowView()
            .environmentObject(session.model)
            .environmentObject(session.localizer)
            .environment(\.coddleReduceTransparency, options["--reduce-transparency"] == "true")
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.coddleOpenConfig, { session.revealConfig() })
            .environment(\.coddleOpenSettings, { session.requestSettings() })
            .environment(\.coddleOpenAwakeSettings, { session.requestAwakeSettings() })
    }

    private func makePopoverWindow(session: ReviewSession, dark: Bool) -> NSWindow {
        let host = NSHostingView(rootView: makeRoot(session: session, dark: dark))
        host.layoutSubtreeIfNeeded()
        let fit = host.fittingSize
        let width = max(340, fit.width)
        let height = max(1, fit.height)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Coddle Review UI — Menu Bar Popover"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        window.setContentSize(NSSize(width: width, height: height))
        window.center()
        return window
    }

    private func makeSettingsWindow(session: ReviewSession, dark: Bool) -> NSWindow {
        let host = NSHostingView(rootView: makeSettingsRoot(session: session, dark: dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Coddle Review UI — Settings Window"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        window.setContentSize(NSSize(width: 440, height: 520))
        window.center()
        return window
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let found = scrollView(in: child) { return found }
        }
        return nil
    }

    private enum CaptureSurface {
        case window
        case keepAwakeExpanded
    }

    /// Hosted runners can expose SwiftUI accessibility after the first layout
    /// pass. Activate the native window and wait for the same positive geometry
    /// required by the audit, without accepting missing or clipped controls.
    private func waitForAccessibleControls(_ identifiers: [String], in view: NSView) async throws {
        guard let window = view.window else {
            throw NSError(domain: "CoddleUIReview", code: 43,
                userInfo: [NSLocalizedDescriptionKey: "Accessibility readiness requires a mounted host"])
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        var lastError = "No accessibility geometry was available"
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 50_000_000)
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            do {
                _ = try controlGeometry(identifiers, in: view, requireVisible: false)
                return
            } catch { lastError = error.localizedDescription }
        }
        let available = Set(accessibilityNodes(in: view).compactMap {
            attribute("accessibilityIdentifier", of: $0)
        }).sorted()
        throw NSError(domain: "CoddleUIReview", code: 44,
            userInfo: [NSLocalizedDescriptionKey:
                "Accessibility readiness timed out: \(lastError). Required: \(identifiers); available: \(available); "
                + "\(CoddleAccessibilityTree.diagnostic(for: window)); "
                + "keyWindow=\(window.isKeyWindow), appActive=\(NSApplication.shared.isActive)"])
    }

    private func controlGeometry(_ identifiers: [String], in view: NSView,
                                 requireVisible: Bool) throws -> [[String: Any]] {
        guard let window = view.window else {
            throw NSError(domain: "CoddleUIReview", code: 43,
                userInfo: [NSLocalizedDescriptionKey: "Control geometry requires a mounted host"])
        }
        let hostFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
        let nodes = accessibilityNodes(in: view)
        return try identifiers.map { identifier in
            guard let node = nodes.first(where: {
                attribute("accessibilityIdentifier", of: $0) == identifier
            }), node.responds(to: NSSelectorFromString("accessibilityFrame")),
                  let value = node.value(forKey: "accessibilityFrame") as? NSValue else {
                throw NSError(domain: "CoddleUIReview", code: 44,
                    userInfo: [NSLocalizedDescriptionKey: "Missing control geometry: \(identifier)"])
            }
            let frame = value.rectValue
            try require(frame.origin.x.isFinite && frame.origin.y.isFinite &&
                        frame.width.isFinite && frame.height.isFinite &&
                        frame.width > 0 && frame.height > 0,
                        "Control has empty or invalid geometry: \(identifier)")
            let visible = hostFrame.insetBy(dx: -1, dy: -1).contains(frame)
            try require(!requireVisible || visible,
                        "A non-overflowing panel clips its control: \(identifier), control=\(frame), host=\(hostFrame)")
            return ["identifier": identifier, "width": frame.width, "height": frame.height,
                    "withinHost": visible]
        }
    }

    private func capture(_ view: NSView, to url: URL,
                         surface: CaptureSurface = .window) throws -> [String: Any] {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        try require(view.bounds.width.isFinite && view.bounds.height.isFinite &&
                    view.bounds.width >= 340 && view.bounds.height > 0,
                    "Screenshot host has invalid dimensions: \(url.lastPathComponent)")
        var controls: [[String: Any]] = []
        if case .keepAwakeExpanded = surface {
            let overflow = scrollView(in: view).map {
                ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 1
            } ?? false
            try require(view.bounds.height <= 680 && view.fittingSize.height <= 680,
                        "Keep-awake screenshot exceeds the popover height limit")
            controls = try controlGeometry(
                ["keep-awake-menu-entry", "keep-awake-master", "keep-display-awake", "keep-awake-more-settings", "open-settings"],
                in: view, requireVisible: !overflow)
        }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw NSError(domain: "CoddleUIReview", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not allocate screenshot"])
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "CoddleUIReview", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not encode screenshot"])
        }
        try png.write(to: url)
        var colors = Set<Int>()
        var opaqueSamples = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent > 0.9 { opaqueSamples += 1 }
                let r = Int((color.redComponent * 255).rounded())
                let g = Int((color.greenComponent * 255).rounded())
                let b = Int((color.blueComponent * 255).rounded())
                colors.insert((r << 16) | (g << 8) | b)
            }
        }
        guard colors.count > 20, opaqueSamples > 100,
              bitmap.pixelsWide >= 340, bitmap.pixelsHigh > 0 else {
            throw NSError(domain: "CoddleUIReview", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Blank or undersized screenshot: \(url.lastPathComponent)"])
        }
        return ["file": url.lastPathComponent, "width": bitmap.pixelsWide,
            "height": bitmap.pixelsHigh, "sampledColors": colors.count,
            "opaqueSamples": opaqueSamples, "nonblank": true, "controlGeometry": controls]
    }

    /// Audit the requested theme before taking an opaque layout snapshot.
    /// cacheDisplay omits the expanded glass section's system-composited layers.
    private func captureKeepAwakeLayout(_ view: NSView, session: ReviewSession,
                                        to url: URL) async throws -> [String: Any] {
        let overflow = scrollView(in: view).map {
            ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 1
        } ?? false
        try require(view.bounds.height <= 680 && view.fittingSize.height <= 680,
                    "The requested keep-awake theme exceeds the popover height limit")
        let geometry = try controlGeometry(
            ["keep-awake-menu-entry", "keep-awake-master", "keep-display-awake", "keep-awake-more-settings", "open-settings"],
            in: view, requireVisible: !overflow)
        let requestedTheme = session.model.theme
        if requestedTheme != "classic" {
            session.model.theme = "classic"
            try await settle(session)
        }
        var result: [String: Any]
        do { result = try capture(view, to: url, surface: .keepAwakeExpanded) }
        catch {
            session.model.theme = requestedTheme
            throw error
        }
        if requestedTheme != "classic" {
            session.model.theme = requestedTheme
            try await settle(session)
        }
        result["theme"] = requestedTheme; result["snapshotTheme"] = "classic"
        result["auditedControlGeometry"] = geometry
        return result
    }

    /// A menu-bar popover sizes itself from the root view's *fitting* size and
    /// uses bounded scrolling only once its content reaches the height limit.
    private func fittingAudit(session: ReviewSession, in host: NSView, expectPackLabels: Bool,
                              expectOverrideKey: String?) throws -> [String: Any] {
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize
        let popoverScrollView = scrollView(in: host)
        let hasPopoverScrollView = popoverScrollView != nil
        let hasPopoverOverflow = popoverScrollView.map { scroll in
            scroll.contentView.bounds.height > 0 &&
                (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height + 1
        } ?? false
        // Production also caps the viewport to the screen's usable height.
        // Hosted macOS runners can have a 624-point cap rather than 680.
        let configuredMaximum = options["--maximum-panel-height"].flatMap(Double.init).map { CGFloat($0) }
            ?? PopoverControlPanel().maximumHeight
        let maximumPanelHeight = min(CGFloat(680), configuredMaximum)
        let controls = try controlGeometry(
            ["energy-mode-0", "keep-awake-menu-entry", "keep-awake-master", "open-settings"],
            in: host, requireVisible: !hasPopoverOverflow)
        let settingsLabel = session.localizer.tr("menu.preferences")
        let hardwareLabel = session.localizer.tr("label.hardwarePercent")
        let temperatureLabel = session.localizer.tr("label.temperature")
        let inputLabel = session.localizer.tr("power.input")
        let systemLabel = session.localizer.tr("power.system")
        let batteryLabel = session.localizer.tr("power.battery")
        let confirmedLabel = session.localizer.tr("state.chargingToFullDetail", 80)
        let inferredLabel = session.localizer.tr("state.chargingPastLimitDetail", 80)
        let overrideLabel = expectOverrideKey.map { session.localizer.tr($0, 80) } ?? ""
        let labels = accessibilityLabels(in: host)
        let hasInput = labels.contains(inputLabel)
        let hasSystem = labels.contains(systemLabel)
        let hasBattery = labels.contains(batteryLabel)
        let result: [String: Any] = [
            "fittingWidth": Double(fitting.width), "fittingHeight": Double(fitting.height),
            "zeroScrollPopover": !hasPopoverOverflow,
            "hasScrollContainer": hasPopoverScrollView,
            "maximumPanelHeight": Double(maximumPanelHeight),
            "controlGeometry": controls,
            "settingsControlLabel": settingsLabel,
            "hardwareControlLabel": hardwareLabel,
            "temperatureControlLabel": temperatureLabel,
            "powerInputControlLabel": inputLabel,
            "powerSystemControlLabel": systemLabel,
            "powerBatteryControlLabel": batteryLabel,
            "powerInputLabelPresent": hasInput,
            "powerSystemLabelPresent": hasSystem,
            "powerBatteryLabelPresent": hasBattery,
            "expectedOverrideKey": expectOverrideKey ?? "(none)",
            "overrideControlLabel": overrideLabel,
            "expectPackLabels": expectPackLabels,
            "expectOverride": expectOverrideKey != nil,
            "hardwareLabelPresent": labels.contains(hardwareLabel),
            "temperatureLabelPresent": labels.contains(temperatureLabel),
            "overrideLabelPresent": labels.contains(overrideLabel),
            "overrideConfirmedLabelPresent": labels.contains(confirmedLabel),
            "overrideInferredLabelPresent": labels.contains(inferredLabel),
            "accessibilityLabelCount": labels.count,
            "accessibilityLabels": labels.sorted()
        ]
        guard fitting.width.isFinite, fitting.height.isFinite, fitting.width >= 340,
              (!hasPopoverOverflow || fitting.height >= maximumPanelHeight - 1),
              fitting.height > 0, fitting.height <= maximumPanelHeight else {
            throw NSError(domain: "CoddleUIReview", code: 8, userInfo: [NSLocalizedDescriptionKey:
                "Menu-bar popover sizing out of bounds: fittingHeight=\(fitting.height) "
                + "(expected positive height at most \(maximumPanelHeight)), overflow=\(hasPopoverOverflow)"])
        }
        guard labels.contains(settingsLabel) else {
            throw NSError(domain: "CoddleUIReview", code: 9, userInfo: [NSLocalizedDescriptionKey:
                "No '\(settingsLabel)' control in the panel; the menu-bar popover has no way "
                + "into Settings. Labels found: \(labels.sorted())"])
        }
        let hasHardware = labels.contains(hardwareLabel)
        let hasTemperature = labels.contains(temperatureLabel)
        if expectPackLabels {
            guard hasHardware, hasTemperature else {
                throw NSError(domain: "CoddleUIReview", code: 12, userInfo: [NSLocalizedDescriptionKey:
                    "Pack data was supplied but the hardware row did not render: "
                    + "hardwareLabel '\(hardwareLabel)' present=\(hasHardware), "
                    + "temperatureLabel '\(temperatureLabel)' present=\(hasTemperature). "
                    + "Labels found: \(labels.sorted())"])
            }
            guard hasInput, hasSystem, hasBattery else {
                throw NSError(domain: "CoddleUIReview", code: 17, userInfo: [NSLocalizedDescriptionKey:
                    "Power telemetry was supplied but the power flow section did not render: "
                    + "input '\(inputLabel)' present=\(hasInput), "
                    + "system '\(systemLabel)' present=\(hasSystem), "
                    + "battery '\(batteryLabel)' present=\(hasBattery). "
                    + "Labels found: \(labels.sorted())"])
            }
        } else {
            guard !hasHardware, !hasTemperature else {
                throw NSError(domain: "CoddleUIReview", code: 13, userInfo: [NSLocalizedDescriptionKey:
                    "No pack data, but the hardware row rendered: hardwareLabel '\(hardwareLabel)' "
                    + "present=\(hasHardware), temperatureLabel '\(temperatureLabel)' present=\(hasTemperature)"])
            }
            guard !hasInput, !hasSystem, !hasBattery else {
                throw NSError(domain: "CoddleUIReview", code: 18, userInfo: [NSLocalizedDescriptionKey:
                    "No telemetry data, but power flow rendered: "
                    + "input '\(inputLabel)' present=\(hasInput)"])
            }
        }
        let hasConfirmed = labels.contains(confirmedLabel)
        let hasInferred = labels.contains(inferredLabel)
        if let expected = expectOverrideKey {
            let expectedPresent = expected == "state.chargingToFullDetail" ? hasConfirmed : hasInferred
            guard expectedPresent else {
                throw NSError(domain: "CoddleUIReview", code: 14, userInfo: [NSLocalizedDescriptionKey:
                    "The override signal was supplied but the panel did not explain it: "
                    + "expected '\(expected)' present=false. Labels found: \(labels.sorted())"])
            }
            let leaked = expected == "state.chargingToFullDetail" ? hasInferred : hasConfirmed
            guard !leaked else {
                throw NSError(domain: "CoddleUIReview", code: 16, userInfo: [NSLocalizedDescriptionKey:
                    "The override wording leaked: expected '\(expected)' but both detail lines "
                    + "rendered (confirmed=\(hasConfirmed), inferred=\(hasInferred))"])
            }
        } else {
            guard !hasConfirmed, !hasInferred else {
                throw NSError(domain: "CoddleUIReview", code: 15, userInfo: [NSLocalizedDescriptionKey:
                    "No override signal, but the panel claimed an override: "
                    + "confirmed=\(hasConfirmed), inferred=\(hasInferred)"])
            }
        }
        return result
    }

    /// Every accessibility label in the view tree, depth-first. Used to prove a
    /// control is still present and named, not just drawn somewhere.
    private func accessibilityLabels(in view: NSView) -> [String] {
        var labels: [String] = []
        for object in accessibilityNodes(in: view) {
            if let label = object.value(forKey: "accessibilityLabel") as? String, !label.isEmpty {
                labels.append(label)
            }
            if let value = object.value(forKey: "accessibilityValue") as? String, !value.isEmpty {
                labels.append(value)
            }
        }
        return labels
    }

    /// Read native AX nodes as well as SwiftUI nodes. Attribute presence alone
    /// never counts as an interaction: tests below execute the actual actions.
    /// When SwiftUI has not published identifiers, use the system accessibility
    /// tree documented in tests/ui/AccessibilityTree.swift.
    private func accessibilityNodes(in view: NSView) -> [NSObject] {
        CoddleAccessibilityTree.nodes(in: view, native: { nativeAccessibilityNodes(in: view) }) {
            attribute("accessibilityIdentifier", of: $0) != nil
        }
    }

    private func nativeAccessibilityNodes(in view: NSView) -> [NSObject] {
        var nodes: [NSObject] = []
        func walk(_ node: Any, _ depth: Int) {
            guard depth < 24, let object = node as? NSObject else { return }
            nodes.append(object)
            if object.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = object.value(forKey: "accessibilityChildren") as? [Any] {
                for child in children { walk(child, depth + 1) }
            }
        }
        walk(view, 0)
        return nodes
    }

    private func attribute(_ key: String, of object: NSObject) -> String? {
        let getter = key == "accessibilityEnabled" ? "isAccessibilityEnabled" : key
        guard object.responds(to: NSSelectorFromString(getter)) else { return nil }
        return object.value(forKey: key).map { String(describing: $0) }
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw NSError(domain: "CoddleUIReview", code: 20,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func press(_ identifier: String, in view: NSView,
                       confirmChange: (() -> Bool)? = nil) throws {
        guard let object = accessibilityNodes(in: view).first(where: {
            attribute("accessibilityIdentifier", of: $0) == identifier
        }) else {
            throw NSError(domain: "CoddleUIReview", code: 21,
                userInfo: [NSLocalizedDescriptionKey: "Missing accessible control: \(identifier)"])
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector), let implementation = object.method(for: selector) else {
            throw NSError(domain: "CoddleUIReview", code: 22,
                userInfo: [NSLocalizedDescriptionKey: "Control has no press action: \(identifier)"])
        }
        typealias PerformPress = @convention(c) (AnyObject, Selector) -> Bool
        let perform = unsafeBitCast(implementation, to: PerformPress.self)
        try require(attribute("accessibilityEnabled", of: object) != "0",
                    "Cannot press disabled control: \(identifier)")
        if confirmChange != nil {
            try require(attribute("accessibilityEnabled", of: object) == "1",
                        "Control readiness is unconfirmed: \(identifier)")
        }
        let performed = perform(object, selector)
        if let confirmChange {
            // A native switch can return false after its binding synchronously
            // disables it. Require the expected model transition instead of
            // treating that return value as proof that the action was rejected.
            try require(confirmChange(), "Press did not change state: \(identifier)")
        } else {
            try require(performed, "Press action failed: \(identifier)")
        }
    }

    private func nativeSliders(in view: NSView) -> [CoddleSemanticSlider] {
        ([view] + view.subviews.flatMap(allSubviews)).compactMap { $0 as? CoddleSemanticSlider }
    }

    private func hasControl(_ identifier: String, in view: NSView) -> Bool {
        accessibilityNodes(in: view).contains {
            attribute("accessibilityIdentifier", of: $0) == identifier
        }
    }

    private func scrollControlIntoView(_ identifier: String, in view: NSView) throws {
        guard let scroll = scrollView(in: view), let document = scroll.documentView,
              let window = view.window,
              let node = accessibilityNodes(in: view).first(where: {
                  attribute("accessibilityIdentifier", of: $0) == identifier
              }), let frame = node.value(forKey: "accessibilityFrame") as? NSValue else {
            throw NSError(domain: "CoddleUIReview", code: 45,
                userInfo: [NSLocalizedDescriptionKey: "Cannot locate scroll target: \(identifier)"])
        }
        let rect = document.convert(window.convertFromScreen(frame.rectValue), from: nil)
        document.scrollToVisible(rect)
    }

    private func expandKeepAwakeOptions(session: ReviewSession, in view: NSView) async throws {
        let originalWindow = view.window
        let visibleWindows = Set(NSApp.windows.filter(\.isVisible).map { ObjectIdentifier($0) })
        let intents = [session.model.keepAwake, session.model.keepDisplayAwake, session.model.keepAwakeOnLidClosed]
        let entries = accessibilityNodes(in: view).filter {
            attribute("accessibilityIdentifier", of: $0) == "keep-awake-menu-entry"
        }
        try require(entries.count == 1 &&
                    hasControl("keep-awake-master", in: view) &&
                    !hasControl("keep-display-awake", in: view) &&
                    !hasControl("keep-awake-lid", in: view),
                    "The collapsed section must retain its disclosure and master while hiding its options")
        let collapsedValue = attribute("accessibilityValue", of: entries[0])
        try press("keep-awake-menu-entry", in: view)
        try await settle(session)
        try require(originalWindow != nil && view.window === originalWindow &&
                    Set(NSApp.windows.filter(\.isVisible).map { ObjectIdentifier($0) }) == visibleWindows,
                    "Expanding keep-awake options must stay in the existing panel without a new window")
        try require(hasControl("keep-awake-menu-entry", in: view) &&
                    hasControl("keep-awake-master", in: view) &&
                    hasControl("keep-display-awake", in: view) &&
                    hasControl("keep-awake-more-settings", in: view),
                    "The expanded section must retain its row and expose quick options and More Settings")
        try require(hasControl("energy-mode-0", in: view) && hasControl("open-settings", in: view) &&
                    !hasControl("keep-awake-menu-back", in: view) &&
                    !hasControl("display-system-settings", in: view) &&
                    !hasControl("settings-tab-awake", in: view),
                    "Expansion must retain other menu controls without creating a second page or full Settings")
        for identifier in ["keep-awake-master", "open-settings"] {
            try require(accessibilityNodes(in: view).filter {
                attribute("accessibilityIdentifier", of: $0) == identifier
            }.count == 1, "Expansion duplicated a main-menu control: \(identifier)")
        }
        let expandedValue = accessibilityNodes(in: view).first(where: {
            attribute("accessibilityIdentifier", of: $0) == "keep-awake-menu-entry"
        }).flatMap { attribute("accessibilityValue", of: $0) }
        try require(collapsedValue == session.localizer.tr("awakeMenu.expand") &&
                    expandedValue == session.localizer.tr("awakeMenu.collapse") &&
                    hasControl("keep-awake-options", in: view),
                    "The disclosure must expose its current expand or collapse action through accessibility")
        try require(intents == [session.model.keepAwake, session.model.keepDisplayAwake, session.model.keepAwakeOnLidClosed],
                    "Manual expansion must preserve the master and option preferences")
    }

    private func collapseKeepAwakeOptions(session: ReviewSession, in view: NSView) async throws {
        let intents = [session.model.keepAwake, session.model.keepDisplayAwake, session.model.keepAwakeOnLidClosed]
        let applied = [session.model.systemAwakeApplied, session.model.displayAwakeApplied, session.model.lidAwakeApplied]
        try require(hasControl("keep-display-awake", in: view), "The section must be expanded before collapsing")
        try press("keep-awake-menu-entry", in: view)
        try await settle(session)
        try require(hasControl("keep-awake-menu-entry", in: view) &&
                    hasControl("keep-awake-master", in: view) && hasControl("open-settings", in: view) &&
                    !hasControl("keep-awake-menu-back", in: view) &&
                    !hasControl("keep-display-awake", in: view) && !hasControl("keep-awake-lid", in: view) &&
                    !hasControl("keep-awake-more-settings", in: view),
                    "Collapse must hide only the keep-awake options")
        try require(intents == [session.model.keepAwake, session.model.keepDisplayAwake, session.model.keepAwakeOnLidClosed] &&
                    applied == [session.model.systemAwakeApplied, session.model.displayAwakeApplied, session.model.lidAwakeApplied],
                    "Manual collapse must preserve preferences and active effects")
        let value = accessibilityNodes(in: view).first(where: {
            attribute("accessibilityIdentifier", of: $0) == "keep-awake-menu-entry"
        }).flatMap { attribute("accessibilityValue", of: $0) }
        try require(value == session.localizer.tr("awakeMenu.expand"),
                    "The collapsed disclosure must expose its expand action")
    }

    private func allSubviews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allSubviews)
    }

    private func settle(_ session: ReviewSession) async throws {
        await session.model.waitForPendingOperations()
        // Capture the settled tab, not the outgoing layer of its 0.26 s spring.
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    private func key(_ keyCode: UInt16, slider: CoddleSemanticSlider, window: NSWindow) throws {
        try require(window.makeFirstResponder(slider), "Slider refused keyboard focus")
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: keyCode) else {
            throw NSError(domain: "CoddleUIReview", code: 23)
        }
        window.sendEvent(event)
    }

    private func requireTabReachable(_ slider: CoddleSemanticSlider, window: NSWindow) throws {
        window.recalculateKeyViewLoop()
        window.makeFirstResponder(nil)
        for _ in 0..<100 {
            window.selectNextKeyView(nil)
            if window.firstResponder === slider { return }
        }
        throw NSError(domain: "CoddleUIReview", code: 28,
            userInfo: [NSLocalizedDescriptionKey: "Slider was not reachable through the window's Tab key loop"])
    }

    /// Exercise the production delegate with an injected fixture instead of
    /// loading the production singleton. The notification center is private too.
    private func settingsEntryAudit(session: ReviewSession) async throws -> [String: Any] {
        let delegate = AppDelegate(model: session.model, localizer: session.localizer,
            notificationCenter: session.fixture.application, openConfig: { session.revealConfig() },
            openActivityMonitor: { session.openActivityMonitor($0) })
        let observation = delegate.observeSettingsRequests()
        defer {
            observation.cancel()
            delegate.settingsWindow?.close()
            delegate.window?.close()
        }
        session.fixture.application.post(name: .coddleShowSettings, object: nil)
        try await settle(session)
        try require(delegate.settingsWindow?.isVisible == true, "Injected Settings notification did not open a window")
        let settingsWindow = delegate.settingsWindow
        session.fixture.application.post(name: .coddleShowSettings, object: nil, userInfo: ["tab": "awake"])
        try await settle(session)
        let awakeControlsVisible = settingsWindow?.contentView.map {
            hasControl("keep-awake-master", in: $0)
        } ?? false
        try require(delegate.settingsWindow === settingsWindow &&
                    awakeControlsVisible,
                    "An awake Settings request must reuse the open window and select its keep-awake tab")
        delegate.showMainWindow()
        try await settle(session)
        try require(delegate.window?.isVisible == true, "Dock dashboard did not open")
        return ["settingsTitle": delegate.settingsWindow?.title ?? "",
                "dashboardTitle": delegate.window?.title ?? "", "injectedSession": true,
                "awakeTabRoutedToExistingWindow": true]
    }

    /// Visible native-window E2E. All model/system boundaries are fixture-owned;
    /// controls are driven through their AX actions and AppKit key dispatch.
    private func settingsTabTypographyAudit(session: ReviewSession) async throws -> [[String: Any]] {
        // SwiftUI can give a longer fixed-size label a slightly wider slot.
        // Measure production button frames instead of assuming equal widths.
        var checks: [[String: Any]] = []
        for language in Localizer.supported {
            let localizer = Localizer(language: language)
            for dark in [false, true] {
                let host = NSHostingView(rootView: SettingsWindowView()
                    .environmentObject(session.model)
                    .environmentObject(localizer)
                    .environment(\.colorScheme, dark ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.setContentSize(NSSize(width: 440, height: 520))
                window.orderFront(nil)
                defer { window.close() }
                try await settle(session)
                host.layoutSubtreeIfNeeded()
                for tab in CoddleSettingsTab.allCases {
                    guard let button = accessibilityNodes(in: host).first(where: {
                        attribute("accessibilityIdentifier", of: $0) == "settings-tab-" + tab.rawValue
                    }), let frame = button.value(forKey: "accessibilityFrame") as? NSValue else {
                        throw NSError(domain: "CoddleUIReview", code: 29)
                    }
                    let labelWidth = frame.rectValue.width - 16
                    var sizes: [NSSize] = []
                    for selected in [false, true] {
                        let host = NSHostingView(rootView: SettingsTabLabel(tab: tab, isSelected: selected)
                            .environmentObject(localizer)
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .environment(\.coddleTheme, .liquidGlass))
                        let size = host.fittingSize
                        try require(size.width > 20 && size.width <= labelWidth + 0.5 && size.height <= 30,
                                    "Tab label does not fit intact: \(language)/\(tab.rawValue), \(size)")
                        sizes.append(size)
                    }
                    try require(abs(sizes[0].width - sizes[1].width) < 0.5 && abs(sizes[0].height - sizes[1].height) < 0.5,
                                "Selected tab changed text metrics: \(language)/\(tab.rawValue)")
                    checks.append(["language": language, "dark": dark, "tab": tab.rawValue,
                                   "width": sizes[0].width, "height": sizes[0].height,
                                   "availableWidth": labelWidth, "selectionMetricsStable": true])
                }
            }
        }
        return checks
    }

    private func cleanupAudit(output: URL) async throws {
        let session = ReviewSession(language: "en", theme: "liquidGlass", output: output)
        self.session = session
        defer { session.beginCleanup() }
        await session.prepare()
        try require(session.fixture.systemAssertions.last == true,
                    "Cleanup audit must start with active fixture assertions")
        await session.cleanup()
        try require(session.fixture.systemAssertions.last == false &&
                    session.fixture.displayAssertions.last == false && session.fixture.helper.writes.last == false,
                    "Cleanup returned before fixture device restoration finished")
        try require(session.fixture.defaults.persistentDomain(forName: session.fixture.suite)?.isEmpty != false,
                    "Cleanup retained the isolated defaults suite")
        let state = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("state.json"))) as? [String: Any]
        try require(state?["cleaned"] as? Bool == true &&
                    state?["systemAssertionActive"] as? Bool == false && state?["displayAssertionActive"] as? Bool == false,
                    "Cleanup evidence was written before confirmed restoration")
        let writes = session.fixture.systemAssertions.count
        await session.cleanup()
        try require(session.fixture.systemAssertions.count == writes, "Cleanup must be idempotent")
        let report: [String: Any] = ["passed": true, "fixtureOnly": true,
            "checks": ["awaited assertions", "awaited helper OFF", "isolated suite removed",
                       "final state records restoration", "idempotent cleanup"]]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("cleanup-report.json"), options: .atomic)
        print("UI fixture cleanup passed")
    }

    private func interactionAudit(output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        print("UI environment: reduceTransparency=\(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency), reduceMotion=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)")
        fflush(stdout)
        let session = ReviewSession(language: "en", theme: "liquidGlass", output: output)
        self.session = session
        // Native glass remains enabled for every interaction and backdrop check.
        // cacheDisplay cannot capture its composited layers; snapshot the same
        // settled controls in Classic, then restore glass before continuing.
        func captureLayout(_ view: NSView, to url: URL) async throws {
            let theme = session.model.theme
            session.model.theme = "classic"
            try await settle(session)
            do { _ = try capture(view, to: url) }
            catch { session.model.theme = theme; throw error }
            session.model.theme = theme
            try await settle(session)
        }
        defer { session.beginCleanup() }
        await session.prepare()
        session.model.setShowMenuBarIcon(false)
        let delegate = AppDelegate(model: session.model, localizer: session.localizer,
            notificationCenter: session.fixture.application, openConfig: { session.revealConfig() },
            openActivityMonitor: { session.openActivityMonitor($0) })
        defer {
            delegate.settingsWindow?.close()
            delegate.window?.close()
            self.window = nil
        }
        delegate.showMainWindow()
        try await settle(session)
        guard let dashboard = delegate.window, let panel = dashboard.contentView else {
            throw NSError(domain: "CoddleUIReview", code: 24)
        }
        self.window = dashboard
        session.fixture.hardwareReadError = HardwareFailure(message: "error.hardwarePending", awaitingRecovery: true)
        session.model.refresh()
        try await settle(session)
        try require(hasControl("coddle-error-message", in: panel),
                    "A failed hardware read must show its global error in the mounted panel")
        try await captureLayout(panel, to: output.appendingPathComponent("e2e-hardware-read-pending.png"))
        session.fixture.hardwareReadError = nil
        session.model.refresh()
        try await settle(session)
        try require(!hasControl("coddle-error-message", in: panel) && session.model.lastError == nil,
                    "Confirmed hardware-read recovery must remove the obsolete global banner")
        // Exercise the production window at both shorter and taller viewport
        // sizes. Exactly one desktop blur must span the full viewport; card
        // materials are in-window and must not accidentally satisfy this check.
        func desktopBlurs(in view: NSView) -> [NSVisualEffectView] {
            let own = (view as? NSVisualEffectView).map { [$0] } ?? []
            return own + view.subviews.flatMap { desktopBlurs(in: $0) }
        }
        func opaqueCoverage(in view: NSView) throws -> [Double] {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw NSError(domain: "CoddleUIReview", code: 1)
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            var alphas: [Double] = []
            for (x, y) in [(0.05, 0.05), (0.95, 0.05), (0.05, 0.95), (0.95, 0.95), (0.5, 0.5)] {
                let color = bitmap.colorAt(x: Int(Double(bitmap.pixelsWide - 1) * x),
                                           y: Int(Double(bitmap.pixelsHigh - 1) * y))?.usingColorSpace(.deviceRGB)
                let alpha = Double(color?.alphaComponent ?? 0)
                try require(alpha >= 0.98, "Reduced-transparency background leaves an uncovered viewport sample")
                alphas.append(alpha)
            }
            return alphas
        }
        let reducedTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        var dockBackdrops: [[String: Any]] = []
        for height in [480.0, 640.0, 760.0] {
            dashboard.setContentSize(NSSize(width: 340, height: height))
            try await settle(session)
            panel.layoutSubtreeIfNeeded()
            let backdrops = desktopBlurs(in: panel).filter { $0.blendingMode == .behindWindow }
            try require(backdrops.count == (reducedTransparency ? 0 : 1),
                        "Dock backdrop does not match accessibility mode; count=\(backdrops.count), reduceTransparency=\(reducedTransparency)")
            var evidence: [String: Any] = ["height": height, "desktopBlurCount": backdrops.count]
            if reducedTransparency {
                evidence["opaqueCoverageAlphas"] = try opaqueCoverage(in: panel)
            } else {
                let coverage = backdrops[0].convert(backdrops[0].bounds, to: panel)
                try require(coverage.insetBy(dx: -1, dy: -1).contains(panel.bounds),
                            "Dock backdrop does not cover the \(height)-point viewport")
            }
            dockBackdrops.append(evidence)
        }
        dashboard.setContentSize(NSSize(width: 340, height: 640))
        try await settle(session)
        try require(!session.model.showMenuBarIcon && session.model.showInDock, "Fixture was not in Dock-only mode")
        try await expandKeepAwakeOptions(session: session, in: panel)
        try await collapseKeepAwakeOptions(session: session, in: panel)
        try press("energy-app-101", in: panel)
        try require(session.activityMonitorRequests == [101], "Activity Monitor action escaped its fixture")
        try press("energy-mode-1", in: panel)
        try await settle(session)
        try require(session.model.energyMode == .lowPower, "Dock Energy Mode action did not finish")
        try press("charge-to-full-now", in: panel)
        try await settle(session)
        try require(session.model.temporaryFullChargeActive, "Dock charge-to-full action did not start")
        try press("resume-charge-limit", in: panel)
        try await settle(session)
        try require(!session.model.temporaryFullChargeActive, "Dock resume action did not finish")
        for (supported, onAC) in [(false, true), (true, false)] {
            session.fixture.supportsTemporaryFullCharge = supported
            session.fixture.battery.externalConnected = onAC
            session.model.refresh()
            try await settle(session)
            try require(!accessibilityNodes(in: panel).contains {
                attribute("accessibilityIdentifier", of: $0) == "charge-to-full-now"
            }, "Unavailable temporary-full action must not be offered")
        }
        session.fixture.supportsTemporaryFullCharge = true
        session.fixture.battery.externalConnected = true
        session.model.refresh()
        try await settle(session)
        try await captureLayout(panel, to: output.appendingPathComponent("e2e-dock-dashboard.png"))

        try press("open-settings", in: panel)
        try await settle(session)
        guard let settings = delegate.settingsWindow, let content = settings.contentView else {
            throw NSError(domain: "CoddleUIReview", code: 25)
        }
        self.window = settings
        // The native title bar must share the full-window backdrop, while
        // interactive content remains within the title-bar safe area.
        var settingsChrome: [[String: Any]] = []
        for dark in [false, true] {
            settings.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for size in [NSSize(width: 440, height: 520), NSSize(width: 600, height: 740)] {
                settings.setContentSize(size)
                try await settle(session)
                content.layoutSubtreeIfNeeded()
                let blurs = desktopBlurs(in: content).filter { $0.blendingMode == .behindWindow }
                try require(blurs.count == (reducedTransparency ? 0 : 1),
                            "Settings backdrop does not match accessibility mode")
                if reducedTransparency {
                    _ = try opaqueCoverage(in: content.superview ?? content)
                } else {
                    let coverage = blurs[0].convert(blurs[0].bounds, to: nil)
                    let fullFrame = NSRect(origin: .zero, size: settings.frame.size)
                    try require(coverage.insetBy(dx: -1, dy: -1).contains(fullFrame),
                                "Settings glass does not cover the native title bar")
                }
                let safeFrame = settings.convertToScreen(settings.contentLayoutRect)
                for tab in CoddleSettingsTab.allCases {
                    guard let node = accessibilityNodes(in: content).first(where: {
                        attribute("accessibilityIdentifier", of: $0) == "settings-tab-" + tab.rawValue
                    }), let value = node.value(forKey: "accessibilityFrame") as? NSValue else {
                        throw NSError(domain: "CoddleUIReview", code: 29)
                    }
                    try require(safeFrame.insetBy(dx: -1, dy: -1).contains(value.rectValue),
                                "Settings tab overlaps native window controls")
                }
                try require(settings.title == "Coddle — Settings", "Window title reused menu ellipsis")
                let name = "settings-chrome-\(dark ? "dark" : "light")-\(Int(size.width)).png"
                try await captureLayout(content.superview ?? content, to: output.appendingPathComponent(name))
                settingsChrome.append(["dark": dark, "width": size.width, "height": size.height,
                                       "fullBackdrop": true, "tabsWithinSafeArea": true, "title": settings.title])
            }
        }
        settings.appearance = nil
        settings.setContentSize(NSSize(width: 440, height: 520))
        try await settle(session)
        var visited: [String] = []
        for tab in CoddleSettingsTab.allCases {
            try press("settings-tab-" + tab.rawValue, in: content)
            try await settle(session)
            visited.append(tab.rawValue)
            try await captureLayout(content, to: output.appendingPathComponent("e2e-tab-" + tab.rawValue + ".png"))
        }

        try press("settings-tab-awake", in: content)
        try await settle(session)
        func hasAwakeControl(_ identifier: String) -> Bool {
            accessibilityNodes(in: content).contains {
                attribute("accessibilityIdentifier", of: $0) == identifier
            }
        }
        try require(hasAwakeControl("keep-awake-master") && hasAwakeControl("keep-display-awake") &&
                    hasAwakeControl("keep-awake-lid"), "Keep-awake master and both options must be accessible")
        try require(hasAwakeControl("keep-awake-help") &&
                    !hasAwakeControl("display-system-settings"),
                    "Durable sleep rules must have one accessible, initially collapsed help entry")
        try require(session.model.keepAwake && !session.model.keepDisplayAwake && session.model.keepAwakeOnLidClosed,
                    "Keep-awake fixture must start with ordinary and lid control")
        try require(!hasAwakeControl("stop-keep-awake") && !hasAwakeControl("retry-stop-keep-awake"),
                    "Normal settings must not expose a separate stop or recovery action")
        try press("sleep-display-now", in: content)
        try await settle(session)
        try require(session.fixture.displaySleepRequests == 1 && session.model.keepAwake &&
                    !session.model.keepDisplayAwake && session.model.keepAwakeOnLidClosed,
                    "One-shot display sleep leaves the master and both option intents unchanged")
        try press("keep-display-awake", in: content)
        try await settle(session)
        try require(session.model.keepDisplayAwake && !hasAwakeControl("sleep-display-now"),
                    "Continuous display hides the incompatible sleep action")
        try press("keep-awake-lid", in: content)
        try await settle(session)
        try require(!session.model.keepAwakeOnLidClosed, "Lid checkbox must change the actual option")
        try press("keep-awake-lid", in: content)
        try await settle(session)
        try require(session.model.keepDisplayAwake && session.model.keepAwakeOnLidClosed,
                    "Both options must be enabled before the master-off check")
        try press("keep-awake-master", in: content,
                  confirmChange: { !session.model.keepAwake && session.model.taskStopBusy })
        try await settle(session)
        try require(!session.model.keepAwake && session.model.keepDisplayAwake && session.model.keepAwakeOnLidClosed &&
                    !session.model.systemAwakeApplied && !session.model.displayAwakeApplied && !session.model.lidAwakeApplied,
                    "Master OFF must release every actual effect while preserving both option preferences")
        try require(!hasAwakeControl("sleep-display-now") && !hasAwakeControl("retry-stop-keep-awake") &&
                    !hasAwakeControl("stop-keep-awake"), "Successful master OFF hides sleep and recovery controls")
        try press("keep-awake-master", in: content, confirmChange: { session.model.keepAwake })
        try await settle(session)
        try require(session.model.keepAwake && session.model.keepDisplayAwake && session.model.keepAwakeOnLidClosed &&
                    session.model.displayAwakeApplied && session.model.lidAwakeApplied,
                    "Re-enabling the master must restore both remembered options")
        try press("keep-display-awake", in: content)
        try press("keep-awake-lid", in: content)
        try await settle(session)
        try require(hasAwakeControl("sleep-display-now"), "Ordinary keep-awake offers one-shot display sleep")
        session.fixture.assertionFailure = true
        try press("keep-awake-master", in: content,
                  confirmChange: { !session.model.keepAwake && session.model.taskStopBusy })
        try await settle(session)
        try require(!session.model.keepAwake && session.model.systemAwakeApplied &&
                    session.model.taskStopStatus == "onboarding.stopPartial",
                    "Failed master OFF must preserve the actual active state and report partial stop")
        try require(hasAwakeControl("retry-stop-keep-awake"), "Partial stop retains an accessible recovery action")
        session.fixture.assertionFailure = false
        try press("retry-stop-keep-awake", in: content)
        try await settle(session)
        try require(!session.model.systemAwakeApplied && session.model.taskStopStatus == "onboarding.stopped" &&
                    !hasAwakeControl("retry-stop-keep-awake"), "Successful recovery clears its action and active state")
        try press("keep-awake-help", in: content)
        try await settle(session)
        try require(accessibilityLabels(in: content).contains(session.localizer.tr("keepAwake.helpPreferences")),
                    "Opening sleep help must explain that master OFF remembers both options")
        try press("display-system-settings", in: content)
        try require(session.fixture.displaySettingsRequests == 1, "System settings action uses injected opener")

        try press("settings-tab-charging", in: content)
        try await settle(session)
        guard let limit = nativeSliders(in: content).first(where: {
            $0.accessibilityLabel() == session.localizer.tr("section.chargeLimit")
        }) else { throw NSError(domain: "CoddleUIReview", code: 27) }
        try require(limit.accessibilityRole() == .slider, "Charge limit must expose AXSlider")
        try requireTabReachable(limit, window: settings)
        try key(124, slider: limit, window: settings)
        try await settle(session)
        try require(session.model.selection == 81, "Charge-limit keyboard adjustment failed")
        session.fixture.nextLimitError = "UI fixture rejected the charge limit"
        limit.setAccessibilityValue(NSNumber(value: 87))
        try await settle(session)
        let errors = accessibilityNodes(in: content).filter {
            attribute("accessibilityIdentifier", of: $0) == "panel-operation-error"
        }
        try require(errors.count == 1 && !hasControl("coddle-error-message", in: content),
                    "The failed charge write must appear once beside its control")
        try await captureLayout(content, to: output.appendingPathComponent("e2e-settings-error.png"))
        try press("settings-tab-general", in: content)
        try await settle(session)
        try require(hasControl("coddle-error-message", in: content) && !hasControl("dismiss-error", in: content),
                    "An unresolved error from another tab must remain discoverable until recovery")
        session.fixture.nextLimitError = nil
        session.model.applyLimit(87)
        try await settle(session)
        try require(session.model.chargeFeedbackError == nil && !hasControl("coddle-error-message", in: content),
                    "Successful charge recovery must clear the corresponding cross-tab error")
        session.model.lastError = "UI fixture unrelated action failed"
        try await settle(session)
        try press("dismiss-error", in: content)
        try await settle(session)
        try require(session.model.lastError == nil, "An unrelated dismissible error must retain its close action")

        settings.close()
        let preferencesBeforeReopen = [session.model.keepAwake, session.model.keepDisplayAwake, session.model.keepAwakeOnLidClosed]
        try await expandKeepAwakeOptions(session: session, in: panel)
        dashboard.close()
        _ = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        try await settle(session)
        try require(delegate.window?.isVisible == true, "Dock reopen lost the dashboard")
        if let reopenedContent = delegate.window?.contentView {
            try require(hasControl("keep-awake-master", in: reopenedContent) &&
                        hasControl("keep-awake-menu-entry", in: reopenedContent) &&
                        !hasControl("keep-awake-options", in: reopenedContent),
                        "Reopening the dashboard must restore the collapsed section without changing preferences")
        }
        try require(preferencesBeforeReopen == [session.model.keepAwake, session.model.keepDisplayAwake, session.model.keepAwakeOnLidClosed],
                    "Closing and reopening the dashboard must preserve keep-awake preferences")
        let report: [String: Any] = [
            "passed": true, "fixtureOnly": true, "tabsVisited": visited, "settingsChrome": settingsChrome,
            "reducedTransparency": reducedTransparency, "dockBackdrops": dockBackdrops,
            "settingsTabTypography": try await settingsTabTypographyAudit(session: session),
            "settingsEntry": try await settingsEntryAudit(session: session),
            "checks": ["hardware read error and confirmed recovery", "Dock-only dashboard", "single full-viewport backdrop at 480/640/760 pt", "Activity Monitor routing", "Energy Mode action", "charge to full + resume",
                       "temporary-full capability and AC gates",
                       "Settings gear", "all three tabs", "one-shot display sleep preserves intents",
                       "keep-awake disclosure expands in place without hiding other menu controls",
                       "keep-awake master and option checkboxes", "master OFF releases effects and retains preferences", "master ON restores preferences",
                       "continuous display hides sleep action", "partial stop recovery remains accessible",
                       "slider Tab traversal", "charge-limit keyboard adjustment",
                       "Settings write-error feedback + dismiss", "Dock reopen"],
            "scope": "Actual native windows, production views, AX control actions and AppKit keyboard dispatch with fixture services; no real power/config/helper operations."
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("e2e-report.json"), options: .atomic)
        await session.cleanup()
        print("UI E2E passed: native windows, all tabs, keyboard/AX actions, errors, and Dock-only flow")
    }

    /// The semantic AX representation bypasses a custom ToggleStyle's Button.
    /// Dispatch mouse events through AppKit to cover that production input path.
    /// A fixed backdrop must cover the clip view at both scroll boundaries.
    /// Fitting content stays still; overflow retains a reachable footer.
    private func scrollViewportAudit(output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var cases: [[String: Any]] = []
        for theme in [CoddleTheme.liquidGlass, .classic] {
            for dark in [false, true] {
                for mode in ["fitting", "short-viewport", "expanded"] {
                    let session = ReviewSession(language: "en", theme: theme.rawValue, output: output)
                    self.session = session
                    await session.prepare()
                    session.model.smartEnabled = false
                    let oldHelperStatus = session.model.helperStatus
                    if mode == "expanded" {
                        session.model.helperStatus = String(repeating: "The component could not confirm the requested keep-awake state. ", count: 48)
                    } else { session.model.setKeepAwakeEnabled(false) }
                    try await settle(session)
                    let cap: CGFloat = mode == "short-viewport" ? 300 : 680
                    let anchor = NSButton(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
                    let anchorWindow = NSWindow(contentRect: anchor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    anchorWindow.isReleasedWhenClosed = false
                    anchorWindow.contentView = anchor
                    let screen = NSScreen.main!.visibleFrame
                    anchorWindow.setFrameTopLeftPoint(NSPoint(x: screen.midX, y: screen.maxY - 8))
                    anchorWindow.makeKeyAndOrderFront(nil)
                    let popover = NSPopover(); popover.animates = false
                    popover.contentViewController = NSHostingController(rootView: makeRoot(session: session, dark: dark, maximumHeight: cap))
                    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
                    let host = popover.contentViewController!.view
                    self.window = host.window
                    host.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    try await settle(session)
                    if mode == "expanded" { try await expandKeepAwakeOptions(session: session, in: host) }
                    guard let scroll = scrollView(in: host), let document = scroll.documentView else {
                        throw NSError(domain: "CoddleUIReview", code: 76)
                    }
                    let clip = scroll.contentView
                    let effects = allSubviews(host).compactMap { $0 as? NSVisualEffectView }
                        .filter { $0.blendingMode == .behindWindow }
                    let fixedBackdrops = effects.filter { !$0.isDescendant(of: document) }
                    if theme == .liquidGlass {
                        try require(fixedBackdrops.count == 1 && effects.count == 1,
                                    "Popover needs one fixed viewport backdrop, not a scrolling document backdrop")
                    }
                    try require(!scroll.drawsBackground && !clip.drawsBackground,
                                "A native scroll or clip view can paint an opaque background")
                    try require(scroll.verticalScrollElasticity == .none && scroll.horizontalScrollElasticity == .none,
                                "A menu panel must not rubber-band beyond its document")
                    let overflow = document.frame.height > clip.bounds.height + 1
                    try require(overflow == (mode != "fitting") && scroll.hasVerticalScroller == overflow,
                                "Only genuine overflow may enable the vertical scroller")
                    var positions: [CGFloat] = []
                    let limit = max(0, document.frame.height - clip.bounds.height)
                    for y in [CGFloat(0), limit] {
                        clip.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(clip)
                        host.layoutSubtreeIfNeeded()
                        let viewport = scroll.convert(scroll.bounds, to: host)
                        for backdrop in fixedBackdrops {
                            let coverage = backdrop.convert(backdrop.bounds, to: host)
                            try require(coverage.insetBy(dx: -1, dy: -1).contains(viewport),
                                        "Scrolling exposed an uncovered viewport edge")
                        }
                        positions.append(clip.bounds.minY)
                    }
                    let top = clip.constrainBoundsRect(NSRect(x: 0, y: -100, width: clip.bounds.width, height: clip.bounds.height))
                    let bottom = clip.constrainBoundsRect(NSRect(x: 0, y: limit + 100, width: clip.bounds.width, height: clip.bounds.height))
                    try require(abs(top.minY) <= 1 && abs(bottom.minY - limit) <= 1,
                                "The clip view permits empty space beyond a document boundary")
                    try scrollControlIntoView("open-settings", in: host)
                    host.layoutSubtreeIfNeeded()
                    guard let footer = accessibilityNodes(in: host).first(where: {
                        attribute("accessibilityIdentifier", of: $0) == "open-settings"
                    }), let footerFrame = footer.value(forKey: "accessibilityFrame") as? NSValue,
                          let window = host.window else { throw NSError(domain: "CoddleUIReview", code: 77) }
                    let visible = window.convertToScreen(clip.convert(clip.bounds, to: nil))
                    try require(visible.insetBy(dx: -1, dy: -1).contains(footerFrame.rectValue),
                                "The overflow footer must remain reachable")
                    if mode == "expanded" {
                        session.model.helperStatus = oldHelperStatus
                        session.model.setKeepAwakeEnabled(false)
                        try await settle(session)
                        host.layoutSubtreeIfNeeded()
                        try require(!scroll.hasVerticalScroller && abs(clip.bounds.minY) <= 1,
                                    "Shrinking content must clear the obsolete scroll offset")
                    }
                    cases.append(["theme": theme.rawValue, "dark": dark, "mode": mode,
                        "maximumHeight": cap, "overflow": overflow, "boundaryOffsets": positions,
                        "fixedBackdrops": fixedBackdrops.count, "noRubberBand": true, "footerReachable": true])
                    popover.close(); anchorWindow.close(); self.window = nil
                    await session.cleanup()
                }
            }
        }
        let report: [String: Any] = ["passed": true, "fixtureOnly": true, "cases": cases,
            "scope": "Production PopoverControlPanel in native NSPopover: fixed glass backdrop outside the document, transparent clip/scroll views, no elasticity, fitting/overflow sizing, both boundaries, reachable footer and reset after collapse. Geometry does not establish native glass pixels or physical trackpad timing."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("scroll-viewport-report.json"), options: .atomic)
        print("Scroll viewport: \(cases.count) native popover cases passed")
    }

    /// Try disabled native controls through mouse, current AX and retained AX
    /// callbacks. The latter models an event queued while the master was ON.
    private func childOptionAudit(output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var cases: [[String: Any]] = []
        let ids = ["keep-display-awake", "keep-awake-lid"]
        for theme in CoddleTheme.allCases {
            for bits in 0..<4 {
                let session = ReviewSession(language: "en", theme: theme.rawValue, output: output)
                self.session = session
                await session.prepare()
                session.model.keepDisplayAwake = bits & 1 != 0
                session.model.keepAwakeOnLidClosed = bits & 2 != 0
                try await settle(session)
                let anchor = NSButton(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
                let anchorWindow = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 80, height: 24),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                anchorWindow.isReleasedWhenClosed = false
                anchorWindow.contentView = anchor
                anchorWindow.makeKeyAndOrderFront(nil)
                let popover = NSPopover()
                popover.animates = false
                popover.contentViewController = NSHostingController(rootView: makeRoot(session: session, dark: false))
                popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
                let host = popover.contentViewController!.view
                guard let window = host.window else { throw NSError(domain: "CoddleUIReview", code: 73) }
                self.window = window
                try await settle(session)
                try await expandKeepAwakeOptions(session: session, in: host)
                func node(_ identifier: String) throws -> NSObject {
                    guard let node = accessibilityNodes(in: host).first(where: {
                        attribute("accessibilityIdentifier", of: $0) == identifier
                    }) else { throw NSError(domain: "CoddleUIReview", code: 74) }
                    return node
                }
                let retainedNodes = try ids.map(node)
                session.model.setKeepAwakeEnabled(false)
                try await settle(session)
                try await expandKeepAwakeOptions(session: session, in: host)
                let saved = session.fixture.saved.count
                let writes = session.fixture.helper.writes.count
                let assertions = session.fixture.systemAssertions.count + session.fixture.displayAssertions.count
                func unchanged() -> Bool {
                    !session.model.keepAwake && session.model.keepDisplayAwake == (bits & 1 != 0) &&
                        session.model.keepAwakeOnLidClosed == (bits & 2 != 0) &&
                        session.fixture.saved.count == saved && session.fixture.helper.writes.count == writes &&
                        session.fixture.systemAssertions.count + session.fixture.displayAssertions.count == assertions
                }
                for (index, id) in ids.enumerated() {
                    let current = try node(id)
                    // Verify actual delivery, displayed value and persistence;
                    // wrapper metadata alone is not interaction acceptance.
                    let frame = (current.value(forKey: "accessibilityFrame") as! NSValue).rectValue
                    for x in [frame.minX + 7, frame.midX] {
                        let point = window.convertPoint(fromScreen: NSPoint(x: x, y: frame.midY))
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                            window.sendEvent(event)
                        }
                        try await settle(session)
                        try require(unchanged(), "Disabled mouse input changed \(id) with master OFF")
                        let displayed = attribute("accessibilityValue", of: try node(id))
                        try require(displayed == (bits & (1 << index) != 0 ? "1" : "0"),
                                    "Disabled mouse input changed checkbox appearance")
                    }
                    for (route, target) in [("current", current), ("retained", retainedNodes[index])] {
                        let selector = NSSelectorFromString("accessibilityPerformPress")
                        guard target.responds(to: selector), let implementation = target.method(for: selector) else {
                            throw NSError(domain: "CoddleUIReview", code: 75)
                        }
                        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                        _ = unsafeBitCast(implementation, to: Press.self)(target, selector)
                        try await settle(session)
                        try require(unchanged(), "Disabled \(route) AX callback changed \(id) with master OFF")
                        let displayed = attribute("accessibilityValue", of: try node(id))
                        try require(displayed == (bits & (1 << index) != 0 ? "1" : "0"),
                                    "Disabled AX callback changed checkbox appearance")
                    }
                }
                try require(!session.model.systemAwakeApplied && !session.model.displayAwakeApplied && !session.model.lidAwakeApplied,
                            "Disabled options unexpectedly applied effects")
                session.model.setKeepAwakeEnabled(true)
                try await settle(session)
                // Positive control: the same physical hit locations must work
                // when enabled, so an ignored off-screen click cannot pass.
                for (index, id) in ids.enumerated() {
                    try scrollControlIntoView(id, in: host)
                    try await settle(session)
                    let current = try node(id)
                    let frame = (current.value(forKey: "accessibilityFrame") as! NSValue).rectValue
                    let point = window.convertPoint(fromScreen: NSPoint(x: frame.minX + 7, y: frame.midY))
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                        window.sendEvent(event)
                    }
                    try await settle(session)
                    let actual = index == 0 ? session.model.keepDisplayAwake : session.model.keepAwakeOnLidClosed
                    try require(actual != (bits & (1 << index) != 0), "Enabled checkbox mouse positive control failed")
                }
                cases.append(["theme": theme.rawValue, "savedPreferenceBits": bits,
                    "disabledMouseAndAXIgnored": true, "noSaveOrServiceWrite": true])
                popover.close(); anchorWindow.close(); self.window = nil
                await session.cleanup()
            }
        }
        let report: [String: Any] = ["passed": true, "cases": cases, "fixtureOnly": true,
            "scope": "Production PopoverControlPanel in native NSPopover. Checkbox and label mouse clicks plus current/retained AX callbacks while master OFF; all four saved preference combinations in both themes. Actual MenuBarExtra status-item interaction is separate."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("child-options-report.json"), options: .atomic)
        print("Disabled child options: \(cases.count) popover scenarios passed")
    }

    /// Telemetry must not negotiate unequal columns or change the row height.
    private func powerFlowAudit(output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var results: [[String: Any]] = []
        let states: [(name: String, watts: Double?, connected: Bool, value: String, key: String?)] = [
            ("bypassed", 0, true, "0.0 W", "power.bypassed"),
            ("charging", 123.4, true, "+123.4 W", "state.charging"),
            ("discharging", -123.4, false, "-123.4 W", "state.discharging"),
            ("idle-unplugged", 0, false, "0.0 W", nil),
            ("unknown", nil, true, "—", nil)
        ]
        let identifiers = ["power-flow-input", "power-flow-system", "power-flow-battery"]
        for language in Localizer.supported {
            for theme in CoddleTheme.allCases {
                for dark in [false, true] {
                    let session = ReviewSession(language: language, theme: theme.rawValue, output: output)
                    self.session = session
                    await session.prepare()
                    let window = makePopoverWindow(session: session, dark: dark)
                    self.window = window
                    window.makeKeyAndOrderFront(nil)
                    guard let host = window.contentView else { throw NSError(domain: "CoddleUIReview", code: 70) }
                    var initialFrames: [NSRect] = []
                    for state in states {
                        session.fixture.battery.externalConnected = state.connected
                        session.fixture.battery.powerFlow = PowerFlow(adapterWatts: 140,
                            systemPowerInWatts: state.watts == nil ? nil : 499.9,
                            systemLoadWatts: state.watts == nil ? nil : 499.9,
                            batteryPowerWatts: state.watts)
                        session.model.refresh()
                        try await settle(session)
                        host.layoutSubtreeIfNeeded()
                        let nodes = accessibilityNodes(in: host)
                        let cells = try identifiers.map { identifier -> NSObject in
                            guard let node = nodes.first(where: {
                                attribute("accessibilityIdentifier", of: $0) == identifier
                            }) else { throw NSError(domain: "CoddleUIReview", code: 71,
                                userInfo: [NSLocalizedDescriptionKey: "Missing power cell: \(identifier)"]) }
                            return node
                        }
                        let frames = try cells.map { cell -> NSRect in
                            guard let value = cell.value(forKey: "accessibilityFrame") as? NSValue else {
                                throw NSError(domain: "CoddleUIReview", code: 72)
                            }
                            return value.rectValue
                        }
                        // SwiftUI's combined AX frame hugs the text, excluding
                        // the flexible cell frame. Compare leading-edge pitch
                        // and absence of overlap, rather than text widths.
                        let pitches = [frames[1].minX - frames[0].minX, frames[2].minX - frames[1].minX]
                        try require(pitches.min()! > 90 && abs(pitches[0] - pitches[1]) <= 1,
                                    "Power Flow column spacing is unequal: \(pitches)")
                        try require(zip(frames, frames.dropFirst()).allSatisfy { $0.maxX < $1.minX - 8 },
                                    "Power Flow content overlaps the next column")
                        if initialFrames.isEmpty { initialFrames = frames }
                        for (frame, initial) in zip(frames, initialFrames) {
                            try require(abs(frame.minX - initial.minX) <= 1 && abs(frame.height - initial.height) <= 0.5,
                                        "Telemetry changed Power Flow column position or row height")
                            try require(abs(frame.minY - frames[0].minY) <= 0.5,
                                        "Power Flow cells no longer share a baseline")
                        }
                        let status = state.key.map(session.localizer.tr)
                        let expected = status.map { "\(state.value) (\($0))" } ?? state.value
                        try require(attribute("accessibilityValue", of: cells[2]) == expected &&
                                    attribute("accessibilityHelp", of: cells[2]) == expected,
                                    "Battery AX value or tooltip lost its power or state: \(expected)")
                        if let status {
                            try require(accessibilityLabels(in: host).contains(status),
                                        "Power Flow header lost its localized state")
                        }
                        let name = "power-flow-\(language)-\(theme.rawValue)-\(dark ? "dark" : "light")-\(state.name)"
                        var result: [String: Any] = ["name": name, "leadingPitches": pitches,
                            "contentWidths": frames.map(\.width),
                            "height": frames[0].height, "batteryAXValue": expected, "state": status ?? "(none)"]
                        if state.name == "bypassed" || (language == "en" && theme == .classic && !dark) {
                            result["capture"] = try capture(host, to: output.appendingPathComponent(name + ".png"))
                        }
                        results.append(result)
                    }
                    window.orderOut(nil)
                    await session.cleanup()
                }
            }
        }
        let report: [String: Any] = ["passed": true, "cases": results.count, "checks": results,
            "scope": "Production PopoverControlPanel with injected services; equally spaced native AX content starts, no column overlap, aligned rows, stable horizontal positions and row height across five telemetry states, complete localized AX values and tooltips. AX frames hug text; cached images prove layout, not glass compositing."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("power-flow-report.json"), options: .atomic)
        print("Power Flow: \(results.count) equal-column and telemetry-state cases passed")
    }

    private func switchLayoutAudit(output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let session = ReviewSession(language: options["--language"] ?? "en",
            theme: options["--theme"] ?? "liquidGlass", output: output)
        self.session = session
        await session.prepare()
        session.model.keepAwakeOnLidClosed = false
        session.model.smartEnabled = false
        session.model.setKeepAwakeEnabled(false)
        try await settle(session)
        let anchor = NSButton(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        let anchorWindow = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 80, height: 24),
            styleMask: [.borderless], backing: .buffered, defer: false)
        anchorWindow.isReleasedWhenClosed = false
        anchorWindow.contentView = anchor
        let visible = NSScreen.main!.visibleFrame
        anchorWindow.setFrameTopLeftPoint(NSPoint(x: visible.midX, y: visible.maxY - 8))
        anchorWindow.makeKeyAndOrderFront(nil)
        let popover = NSPopover()
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.contentViewController = NSHostingController(rootView: makeRoot(session: session,
            dark: options["--appearance"] == "dark"))
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        let host = popover.contentViewController!.view
        guard let window = host.window else { throw NSError(domain: "CoddleUIReview", code: 60) }
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        try await settle(session)
        let chromeHeight = window.frame.height - host.fittingSize.height
        func node(_ identifier: String) -> NSObject? {
            accessibilityNodes(in: host).first {
                attribute("accessibilityIdentifier", of: $0) == identifier ||
                (identifier == "smart" && attribute("accessibilityIdentifier", of: $0) == "smart-charging-master")
            }
        }
        func rect(_ identifier: String) -> NSRect? {
            guard let object = node(identifier), object.responds(to: NSSelectorFromString("accessibilityFrame")),
                let value = object.value(forKey: "accessibilityFrame") as? NSValue else { return nil }
            return value.rectValue
        }
        func mouseClick(_ identifier: String) throws {
            guard let frame = rect(identifier) else {
                let labels = accessibilityNodes(in: host).map {
                    ["label": attribute("accessibilityLabel", of: $0) ?? "",
                     "title": attribute("accessibilityTitle", of: $0) ?? "",
                     "id": attribute("accessibilityIdentifier", of: $0) ?? ""]
                }
                try JSONSerialization.data(withJSONObject: labels, options: [.prettyPrinted])
                    .write(to: output.appendingPathComponent("missing-mouse-target.json"))
                throw NSError(domain: "CoddleUIReview", code: 61,
                    userInfo: [NSLocalizedDescriptionKey: "Missing mouse target: \(identifier)"])
            }
            let point = window.convertPoint(fromScreen: NSPoint(x: frame.maxX - 10, y: frame.midY))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
                else { throw NSError(domain: "CoddleUIReview", code: 62) }
                window.sendEvent(event)
            }
        }
        var cases: [[String: Any]] = []
        var maxSizingMismatch: CGFloat = 0
        for identifier in ["smart", "keep-awake-master", "keep-awake-menu-entry"] {
            for step in 0..<4 {
                let ids = identifier == "smart" ? ["charge-to-full-now", "detent-slider"] :
                    ["charge-to-full-now", "detent-slider", "energy-mode-0", "keep-awake-menu-entry"]
                let before = Dictionary(uniqueKeysWithValues: ids.compactMap { id in rect(id).map { (id, $0) } })
                try require(before.count == ids.count, "Missing stable layout anchors")
                let top = window.frame.maxY
                let start = ProcessInfo.processInfo.systemUptime
                try mouseClick(identifier)
                var samples: [[String: Any]] = []
                var maxDrift: CGFloat = 0
                while ProcessInfo.processInfo.systemUptime - start < 0.5 {
                    try await Task.sleep(nanoseconds: 8_333_333)
                    var sample: [String: Any] = ["elapsedMs": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                        "windowTop": window.frame.maxY, "windowHeight": window.frame.height]
                    for id in ids {
                        guard let frame = rect(id), let original = before[id] else { continue }
                        let screenDelta = frame.maxY - original.maxY
                        let horizontalDelta = frame.minX - original.minX
                        let localDelta = (window.frame.maxY - frame.maxY) - (top - original.maxY)
                        sample[id] = ["screenX": frame.minX, "horizontalDelta": horizontalDelta,
                                      "screenY": frame.maxY, "screenDelta": screenDelta,
                                      "topInsetDelta": localDelta]
                        maxDrift = max(maxDrift, abs(screenDelta), abs(localDelta), abs(horizontalDelta))
                    }
                    if let scroll = scrollView(in: host) {
                        sample["scrollY"] = scroll.contentView.bounds.minY
                        sample["viewportHeight"] = scroll.contentView.bounds.height
                        sample["documentHeight"] = scroll.documentView?.frame.height ?? 0
                    }
                    samples.append(sample)
                }
                let expected = step % 2 == 0
                let actual = identifier == "smart" ? session.model.smartEnabled :
                    identifier == "keep-awake-master" ? session.model.keepAwake : hasControl("keep-awake-options", in: host)
                try require(actual == expected, "Native mouse input failed to toggle \(identifier)")
                let fittingHeight = host.fittingSize.height
                let sizingMismatch = abs(window.frame.height - fittingHeight - chromeHeight)
                maxSizingMismatch = max(maxSizingMismatch, sizingMismatch)
                cases.append(["control": identifier, "step": step, "on": actual,
                    "maxUnrelatedDriftPoints": maxDrift, "samples": samples,
                    "fittingHeight": fittingHeight, "sizingMismatchPoints": sizingMismatch])
                try await settle(session)
            }
        }
        let maximum = cases.compactMap { $0["maxUnrelatedDriftPoints"] as? CGFloat }.max() ?? 0
        let report: [String: Any] = ["passed": maximum <= 1 && maxSizingMismatch <= 1, "fixtureOnly": true,
            "input": "NSEvent leftMouseDown/up through the mounted NSWindow",
            "host": "NSPopover containing production PopoverControlPanel", "cases": cases,
            "maxUnrelatedDriftPoints": maximum,
            "maxSizingMismatchPoints": maxSizingMismatch,
            "scope": "In-flight screen and window-top-relative geometry of controls above the changing section; no live hardware/config operations or rendered FPS claim."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("switch-layout-report.json"), options: .atomic)
        popover.close()
        anchorWindow.close()
        self.window = nil
        await session.cleanup()
        if options["--baseline"] != "true" {
            try require(maximum <= 1, "Unrelated controls moved by \(maximum) pt")
            try require(maxSizingMismatch <= 1, "Popover did not shrink to its contents: \(maxSizingMismatch) pt")
        }
        print("Switch layout max unrelated drift: \(maximum) pt")
    }

    private func disclosureMotionAudit(output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let dark = options["--appearance"] == "dark"
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let session = ReviewSession(language: options["--language"] ?? "en",
            theme: options["--theme"] ?? "liquidGlass", output: output)
        self.session = session
        await session.prepare()
        // Match the ordinary system-only state without performing device writes.
        session.model.keepAwakeOnLidClosed = false
        await session.model.waitForPendingOperations()
        let navigation = CoddlePanelNavigation()
        let dock = options["--surface"] == "dock"
        let root = Group {
            if dock { DockDashboardView(navigation: navigation) }
            else { makeRoot(session: session, dark: dark) }
        }
        .environmentObject(session.model)
        .environmentObject(session.localizer)
        .environment(\.colorScheme, dark ? .dark : .light)
        let host = DisclosurePerformanceHost(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 640),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        try await settle(session)
        let preferences = [session.model.keepAwake, session.model.keepDisplayAwake, session.model.keepAwakeOnLidClosed]
        let saves = session.fixture.saved.count
        let writes = session.fixture.helper.writes.count
        var transitions: [[String: Any]] = []
        for step in 0..<12 {
            host.layoutMilliseconds = []
            host.constraintMilliseconds = []
            let start = ProcessInfo.processInfo.systemUptime
            try press("keep-awake-menu-entry", in: host)
            let actionMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
            var previous = start
            var gaps: [Double] = []
            while ProcessInfo.processInfo.systemUptime - start < 0.35 {
                try await Task.sleep(nanoseconds: 1_000_000)
                let now = ProcessInfo.processInfo.systemUptime
                gaps.append((now - previous) * 1000)
                previous = now
            }
            let expanded = step % 2 == 0
            try require(hasControl("keep-awake-options", in: host) == expanded,
                        "Disclosure did not settle in the requested state")
            try require(hasControl("open-settings", in: host), "Disclosure lost the footer")
            let sorted = gaps.sorted()
            let transition: [String: Any] = ["step": step, "expanded": expanded, "actionMilliseconds": actionMs,
                "mainRunLoopGapsMilliseconds": gaps,
                "gapP95Milliseconds": sorted[Int(Double(sorted.count - 1) * 0.95)],
                "gapMaxMilliseconds": sorted.last ?? 0,
                "gapsOver16_67Milliseconds": gaps.filter { $0 > 16.67 }.count,
                "gapsOver33_33Milliseconds": gaps.filter { $0 > 33.33 }.count,
                "layoutMilliseconds": host.layoutMilliseconds,
                "constraintMilliseconds": host.constraintMilliseconds]
            transitions.append(transition)
        }
        try require(preferences == [session.model.keepAwake, session.model.keepDisplayAwake, session.model.keepAwakeOnLidClosed] &&
                    session.fixture.saved.count == saves && session.fixture.helper.writes.count == writes,
                    "Presentation-only disclosure changed preferences or requested a write")
        let report: [String: Any] = ["passed": true, "fixtureOnly": true,
            "surface": dock ? "dock" : "popover", "theme": session.model.theme,
            "language": session.model.language, "dark": dark, "reduceMotion": reduceMotion,
            "transitions": transitions,
            "scope": "Mounted production UI, real AX press, measured main-run-loop scheduling gaps and hosting layout/constraint work; not rendered FPS or literal status-item interaction."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("disclosure-motion-report.json"), options: .atomic)
        window.orderOut(nil)
        self.window = nil
        await session.cleanup()
        print("Disclosure motion: 12 presentation-only transitions passed")
    }

    private func activityMotionAudit(output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let session = ReviewSession(language: "en", theme: "liquidGlass", output: output)
        self.session = session
        await session.prepare()
        let apps = session.fixture.significantEnergyApps
        let host = NSHostingView(rootView: makeRoot(session: session, dark: true))
        let window = NSWindow(contentViewController: NSViewController())
        window.contentView = host
        window.setContentSize(NSSize(width: 340, height: 640))
        window.makeKeyAndOrderFront(nil)
        self.window = window
        try await settle(session)
        func frame(_ id: String) -> [Double]? {
            guard let node = accessibilityNodes(in: host).first(where: {
                attribute("accessibilityIdentifier", of: $0) == id
            }), node.responds(to: NSSelectorFromString("accessibilityFrame")),
               let value = node.value(forKey: "accessibilityFrame") as? NSValue else { return nil }
            let rect = value.rectValue
            return [rect.minX, rect.minY, rect.width, rect.height]
        }
        var busyEvents: [Bool] = []
        let busyObserver = session.model.$chargeLimitBusy.dropFirst().sink { busyEvents.append($0) }
        var samples: [[String: Any]] = []
        let orders = [[0, 1], [1, 0], [0], [], [1, 0], [0, 1]]
        for (step, order) in orders.enumerated() {
            session.fixture.significantEnergyApps = order.map { apps[$0] }
            session.model.refresh()
            for tick in 0..<48 {
                try await Task.sleep(nanoseconds: 8_333_333)
                var sample: [String: Any] = ["step": step, "tick": tick, "height": host.fittingSize.height, "chargeLimitBusy": session.model.chargeLimitBusy,
                    "chargeOperationStatus": session.model.chargeOperationStatus ?? "none"]
                for id in ["open-settings", "energy-app-101", "energy-app-102"] {
                    if let rect = frame(id) { sample[id] = rect }
                }
                samples.append(sample)
            }
        }
        let baseline = options["--baseline"] == "true"
        let heights = samples.compactMap { $0["height"] as? CGFloat }
        let drift = (heights.max() ?? 0) - (heights.min() ?? 0)
        busyObserver.cancel()
        let report: [String: Any] = ["samples": samples, "fixtureOnly": true, "baseline": baseline,
            "heightDrift": drift, "busyEvents": busyEvents,
            "passed": drift <= 1 && !busyEvents.contains(true),
            "scope": "288 in-flight samples at approximately 8 ms intervals, plus every published charge-busy transition; unchanged hardware with activity churn"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("activity-motion-report.json"))
        if !baseline {
            try require(!busyEvents.contains(true), "Read-only refresh published a false charging busy state")
            try require(drift <= 1, "Panel moved during refresh by \(drift) pt")
        }
        window.orderOut(nil)
        self.window = nil
        await session.cleanup()
    }

    /// Exercise data churn in one mounted production panel, including a threshold
    /// crossing, rank swap, icon replacement and an empty result.
    private func activityRefreshAudit(output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let baseline = options["--baseline"] == "true"
        var results: [[String: Any]] = []
        for theme in (baseline ? ["liquidGlass"] : ["liquidGlass", "classic"]) {
            for dark in (baseline ? [true] : [false, true]) {
                let session = ReviewSession(language: "en", theme: theme, output: output)
                self.session = session
                await session.prepare()
                let apps = session.fixture.significantEnergyApps + [SignificantEnergyApp(
                    id: 103, name: "A Long Application Name", bundleIdentifier: "fixture.third", icon: nil, energyScore: 2)]
                let host = NSHostingView(rootView: makeRoot(session: session, dark: dark))
                let window = NSWindow(contentViewController: NSViewController())
                window.contentView = host
                window.setContentSize(NSSize(width: 340, height: 640))
                window.makeKeyAndOrderFront(nil)
                self.window = window
                var heights: [CGFloat] = []
                for (index, ids) in [[101, 102], [101, 102], [101, 102, 103], [103], [], [103, 102, 101], [], [101, 102]].enumerated() {
                    session.fixture.significantEnergyApps = ids.compactMap { id in
                        apps.first(where: { $0.id == id }).map {
                            SignificantEnergyApp(id: $0.id, name: $0.name, bundleIdentifier: $0.bundleIdentifier,
                                icon: index.isMultiple(of: 2) ? $0.icon : nil, energyScore: Double(index + 1))
                        }
                    }
                    session.model.refresh()
                    try await settle(session)
                    host.layoutSubtreeIfNeeded()
                    let height = host.fittingSize.height
                    heights.append(height)
                    let visible = accessibilityNodes(in: host).compactMap { attribute("accessibilityIdentifier", of: $0) }
                        .filter { $0.hasPrefix("energy-app-") }
                    try require(Set(visible) == Set(ids.map { "energy-app-\($0)" }), "Activity list retained stale or missing actions")
                    if let first = ids.first {
                        try press("energy-app-\(first)", in: host)
                        try require(session.activityMonitorRequests.last == pid_t(first), "Refresh routed a click to a stale app")
                    }
                    results.append(["theme": theme, "dark": dark, "refresh": index, "ids": ids, "height": height])
                }
                let drift = (heights.max() ?? 0) - (heights.min() ?? 0)
                if !baseline { try require(drift <= 1, "Activity refresh resized the panel by \(drift) points") }
                window.orderOut(nil)
                self.window = nil
                await session.cleanup()
            }
        }
        let report: [String: Any] = ["baseline": baseline, "passed": !baseline, "fixtureOnly": true,
            "checks": results, "scope": "Same mounted production popover; 0/1/2/3 apps, rank/score/icon churn, current AX actions and click routing; maximum allowed height drift 1 pt"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("activity-refresh-report.json"))
    }

    private func scenarioAudit(output: URL) async throws {
        let session = ReviewSession(language: "en", theme: "liquidGlass", output: output)
        self.session = session
        defer { session.beginCleanup() }
        await session.prepare()
        var checks: [String] = []
        func capturePanel(_ name: String, expanded: Bool = false) async throws -> NSView {
            let window = makePopoverWindow(session: session, dark: false)
            self.window = window
            window.orderFront(nil)
            try await Task.sleep(nanoseconds: 50_000_000)
            let content = window.contentView!
            if expanded { try await expandKeepAwakeOptions(session: session, in: content) }
            let imageURL = output.appendingPathComponent("scenario-" + name + ".png")
            if expanded {
                _ = try await captureKeepAwakeLayout(content, session: session, to: imageURL)
            } else {
                _ = try capture(content, to: imageURL)
            }
            return content
        }
        var normal = try await capturePanel("awake-collapsed")
        var normalLabels = accessibilityLabels(in: normal)
        try require(!normalLabels.contains(session.localizer.tr("smart.desc")), "Smart-charge teaching text still always visible")
        try require(!normalLabels.contains(session.localizer.tr("energyMode.scope")), "Power scope still always visible")
        try require(normalLabels.contains(session.localizer.tr("panel.smart.learning")), "Compact learning phase missing")
        try require(hasControl("keep-awake-menu-entry", in: normal) &&
                    hasControl("keep-awake-master", in: normal) &&
                    !hasControl("keep-display-awake", in: normal) &&
                    !hasControl("keep-awake-lid", in: normal),
                    "The main menu must start collapsed with its master switch directly accessible")
        try require(!accessibilityNodes(in: normal).contains {
            attribute("accessibilityIdentifier", of: $0) == "awake-summary"
        }, "Confirmed keep-awake options must not repeat their checkbox states")
        guard let panelSlider = nativeSliders(in: normal).first else { throw NSError(domain: "CoddleUIReview", code: 40) }
        try require(panelSlider.accessibilityHelp() == session.localizer.tr("panel.charge.manualHint"), "Slider consequence missing from native accessibility help")
        let beforeFocus = normal.frame.size
        try require(panelSlider.window?.makeFirstResponder(panelSlider) == true, "Panel slider cannot receive keyboard focus")
        try await settle(session)
        try require(normal.frame.size == beforeFocus, "Keyboard help changed panel geometry")
        try key(124, slider: panelSlider, window: panelSlider.window!)
        try await settle(session)
        try require(!session.model.smartEnabled, "Keyboard manual limit did not switch off smart mode")
        try await expandKeepAwakeOptions(session: session, in: normal)
        try require(hasControl("keep-awake-lid", in: normal) && hasControl("sleep-display-now", in: normal),
                    "The expanded section must expose lid and display-sleep controls")
        try press("keep-display-awake", in: normal)
        try await settle(session)
        try require(session.model.keepDisplayAwake && !hasControl("sleep-display-now", in: normal),
                    "The quick display option must hide incompatible immediate sleep")
        try press("keep-display-awake", in: normal)
        try await settle(session)
        try press("keep-awake-lid", in: normal)
        try await settle(session)
        try require(!session.model.keepAwakeOnLidClosed, "The quick lid option must change its actual intent")
        try press("keep-awake-lid", in: normal)
        try await settle(session)
        try press("keep-display-awake", in: normal)
        try await settle(session)
        try press("keep-awake-master", in: normal,
                  confirmChange: { !session.model.keepAwake && session.model.taskStopBusy })
        try await settle(session)
        try require(!session.model.keepAwake && session.model.keepDisplayAwake && session.model.keepAwakeOnLidClosed &&
                    !session.model.systemAwakeApplied && !session.model.displayAwakeApplied && !session.model.lidAwakeApplied &&
                    hasControl("keep-awake-master", in: normal) && !hasControl("keep-awake-options", in: normal) &&
                    !hasControl("sleep-display-now", in: normal),
                    "Quick master OFF must collapse and release every effect while retaining both preferences")
        try press("keep-awake-master", in: normal, confirmChange: { session.model.keepAwake })
        try await settle(session)
        try require(session.model.keepDisplayAwake && session.model.keepAwakeOnLidClosed &&
                    session.model.displayAwakeApplied && session.model.lidAwakeApplied &&
                    hasControl("keep-awake-options", in: normal) && !hasControl("sleep-display-now", in: normal),
                    "Quick master ON must expand and restore both remembered options")
        try press("keep-display-awake", in: normal)
        try await settle(session)
        let sleepRequests = session.fixture.displaySleepRequests
        try press("sleep-display-now", in: normal)
        try await settle(session)
        try require(session.fixture.displaySleepRequests == sleepRequests + 1 && session.model.keepAwake &&
                    !session.model.keepDisplayAwake && session.model.keepAwakeOnLidClosed,
                    "Quick display sleep must issue one request without changing the selected options")
        session.fixture.assertionFailure = true
        try press("keep-awake-master", in: normal,
                  confirmChange: { !session.model.keepAwake && session.model.taskStopBusy })
        try await settle(session)
        try require(session.model.taskStopStatus == "onboarding.stopPartial" &&
                    session.model.keepAwakeMenuState == .attention &&
                    !hasControl("keep-awake-options", in: normal) &&
                    hasControl("keep-awake-menu-status", in: normal),
                    "A failed quick stop must keep a visible attention control on the collapsed row")
        _ = try capture(normal, to: output.appendingPathComponent("scenario-awake-stop-incomplete-collapsed.png"))
        try press("keep-awake-menu-status", in: normal)
        try await settle(session)
        try require(hasControl("keep-awake-options", in: normal) && hasControl("retry-stop-keep-awake", in: normal) &&
                    !session.model.keepAwake && !session.model.keepDisplayAwake && session.model.keepAwakeOnLidClosed,
                    "The collapsed failure summary must expand recovery without restarting or changing preferences")
        try require(!hasControl("keep-awake-menu-status", in: normal),
                    "An expanded failure must replace its collapsed summary instead of duplicating it")
        try await collapseKeepAwakeOptions(session: session, in: normal)
        try require(hasControl("keep-awake-menu-status", in: normal),
                    "Manually collapsing a failed stop must not hide the attention summary")
        try await expandKeepAwakeOptions(session: session, in: normal)
        try require(hasControl("retry-stop-keep-awake", in: normal),
                    "Expanding a failed stop must expose its recovery action")
        _ = try await captureKeepAwakeLayout(normal, session: session,
            to: output.appendingPathComponent("scenario-awake-stop-incomplete-expanded.png"))
        session.fixture.assertionFailure = false
        try press("retry-stop-keep-awake", in: normal)
        try await settle(session)
        try require(session.model.taskStopStatus == "onboarding.stopped" &&
                    !hasControl("retry-stop-keep-awake", in: normal) &&
                    !session.model.systemAwakeApplied && !session.model.lidAwakeApplied,
                    "A successful quick retry must release actual control and hide recovery")
        try press("keep-awake-master", in: normal, confirmChange: { session.model.keepAwake })
        try await settle(session)
        try require(session.model.keepAwakeOnLidClosed && session.model.lidAwakeApplied &&
                    hasControl("keep-awake-options", in: normal),
                    "Re-enabling after recovery must restore the remembered lid option and expand")
        try await collapseKeepAwakeOptions(session: session, in: normal)
        try await expandKeepAwakeOptions(session: session, in: normal)
        let awakeRequests = session.awakeSettingsRequests
        let ordinarySettingsRequests = session.openSettingsRequests
        try press("keep-awake-more-settings", in: normal)
        try await settle(session)
        try require(session.awakeSettingsRequests == awakeRequests + 1 &&
                    session.openSettingsRequests == ordinarySettingsRequests &&
                    hasControl("keep-awake-menu-entry", in: normal) &&
                    hasControl("keep-awake-options", in: normal) &&
                    session.model.keepAwake && !session.model.keepDisplayAwake && session.model.keepAwakeOnLidClosed,
                    "More Settings must route once without collapsing or changing preferences")
        checks.append("persistent master and disclosure, in-place expansion, manual collapse preserves effects, master OFF retains preferences, master ON restores and expands, one-shot sleep, collapsed failure status and expanded recovery, targeted More Settings")
        session.model.smartEnabled = true
        session.model.keepAwakeOnLidClosed = false
        try await settle(session)
        self.window?.orderOut(nil)
        normal = try await capturePanel("compact-system-only")
        normalLabels = accessibilityLabels(in: normal)
        try require(!accessibilityNodes(in: normal).contains { attribute("accessibilityIdentifier", of: $0) == "awake-summary" }, "Ordinary keep-awake repeats its switch state")
        session.model.keepAwakeOnLidClosed = true
        try await settle(session)
        self.window?.orderOut(nil)
        checks.append("compact default copy, independent lid option, no repeated active summary, native consequence help, stable keyboard focus, manual mode transition")

        session.model.requireBattery = false
        session.fixture.locked = true
        session.fixture.helper.writeError = HelperError(message: "Lid pause unconfirmed")
        session.fixture.away.isAway = true
        session.fixture.awayCallback?(session.fixture.away)
        try await settle(session)
        normal = try await capturePanel("compact-guard-unconfirmed", expanded: true)
        normalLabels = accessibilityLabels(in: normal)
        try require(session.model.bagGuardActive && session.model.lidStateUnconfirmed, "Guard uncertainty fixture failed")
        try require(normalLabels.contains(session.localizer.tr("awakeFeedback.stopLidUnconfirmed")) &&
                    !normalLabels.contains(session.localizer.tr("awakeFeedback.paused")), "Unconfirmed guard pause presented as successful")
        session.fixture.helper.writeError = nil
        session.model.setKeepAwakeEnabled(false)
        try await settle(session)
        self.window?.orderOut(nil)
        normal = try await capturePanel("compact-stopped-during-guard")
        try require(session.model.bagGuardActive && !session.model.keepAwake &&
                    session.model.keepAwakeMenuState == .off,
                    "Confirmed master OFF must show OFF even while the guard remains active")
        try await expandKeepAwakeOptions(session: session, in: normal)
        normalLabels = accessibilityLabels(in: normal)
        try require(!hasControl("keep-awake-description", in: normal) &&
                    !normalLabels.contains(session.localizer.tr("awakeFeedback.paused")) &&
                    !normalLabels.contains(session.localizer.tr("awakeFeedback.pauseUnconfirmed")),
                    "Confirmed master OFF must not retain a resumable guard pause or normal explanation")
        session.model.setKeepAwakeEnabled(true)
        session.model.keepAwakeOnLidClosed = true
        try await settle(session)
        session.fixture.locked = false
        session.fixture.away.isAway = false
        session.fixture.awayCallback?(session.fixture.away)
        try await settle(session)
        self.window?.orderOut(nil)
        checks.append("guard pause never claims success while lid helper cannot confirm")

        session.fixture.away = AwayStatus(learningRemainingSeconds: 7200)
        session.fixture.awayCallback?(session.fixture.away)
        try await settle(session)
        var content = try await capturePanel("guard-learning", expanded: true)
        try require(accessibilityLabels(in: content).contains(session.localizer.tr("awakeFeedback.guardUnavailable")),
                    "Learning warning missing from expanded keep-awake options")
        checks.append("untrained offline guard visibly not ready")
        self.window?.orderOut(nil)

        session.model.keepAwakeOnLidClosed = false
        try await settle(session)
        session.fixture.helper.installed = false
        session.model.refresh()
        try await settle(session)
        content = try await capturePanel("component-needed", expanded: true)
        try press("keep-awake-lid", in: content)
        try await settle(session)
        try require(session.model.keepAwakeOnLidClosed && !session.model.helperBusy &&
                    !session.fixture.helper.installed && hasControl("install-keep-awake-component", in: content),
                    "Selecting closed-lid operation must explain installation before invoking the installer")
        try require(accessibilityLabels(in: content).contains(session.localizer.tr("helper.installApproval")),
                    "Administrator approval must be explained before the explicit install action")
        try press("install-keep-awake-component", in: content)
        for _ in 0..<100 where session.model.helperBusy { try await settle(session) }
        try await settle(session)
        try require(session.fixture.helper.installed && !session.model.helperBusy,
                    "Only the explicit install action may invoke the injected installer")
        checks.append("lid selection explains component and administrator approval before explicit installation")
        self.window?.orderOut(nil)

        let previousHelperStatus = session.model.helperStatus
        session.model.helperStatus = String(repeating: "The component could not confirm the requested keep-awake state. ", count: 48)
        content = try await capturePanel("awake-expanded-long-error", expanded: true)
        try require(!accessibilityLabels(in: content).contains(session.model.helperStatus!),
                    "Raw component diagnostics must start behind the details disclosure")
        try press("awake-feedback-details", in: content)
        try await settle(session)
        _ = try await captureKeepAwakeLayout(content, session: session,
            to: output.appendingPathComponent("scenario-awake-long-diagnostics-expanded.png"))
        try require(content.fittingSize.height <= 680 && content.frame.height <= 680,
                    "A long expanded-section error must respect the popover height limit")
        guard let awakeScroll = scrollView(in: content), let awakeDocument = awakeScroll.documentView,
              let awakeWindow = content.window else {
            throw NSError(domain: "CoddleUIReview", code: 41,
                userInfo: [NSLocalizedDescriptionKey: "The long keep-awake error has no bounded scroll container"])
        }
        try require(awakeDocument.frame.height > awakeScroll.contentView.bounds.height,
                    "The long keep-awake error fixture must exercise actual overflow")
        try scrollControlIntoView("keep-awake-more-settings", in: content)
        try await settle(session)
        guard let moreSettings = accessibilityNodes(in: content).first(where: {
            attribute("accessibilityIdentifier", of: $0) == "keep-awake-more-settings"
        }), let moreSettingsFrame = moreSettings.value(forKey: "accessibilityFrame") as? NSValue else {
            throw NSError(domain: "CoddleUIReview", code: 42)
        }
        let awakeViewport = awakeWindow.convertToScreen(awakeScroll.contentView.convert(awakeScroll.contentView.bounds, to: nil))
        try require(awakeViewport.insetBy(dx: -1, dy: -1).contains(moreSettingsFrame.rectValue),
                    "More Settings must remain reachable below a long keep-awake error")
        _ = try await captureKeepAwakeLayout(content, session: session,
            to: output.appendingPathComponent("scenario-awake-long-diagnostics-actions.png"))
        try scrollControlIntoView("keep-awake-menu-entry", in: content)
        try await settle(session)
        try await collapseKeepAwakeOptions(session: session, in: content)
        session.model.helperStatus = previousHelperStatus
        try await settle(session)
        checks.append("expanded long error stays height-bounded with reachable More Settings and disclosure")
        self.window?.orderOut(nil)

        session.fixture.battery.powerFlow = PowerFlow(adapterWatts: 90, systemPowerInWatts: nil, systemLoadWatts: 15, batteryPowerWatts: 0)
        session.model.refresh(); try await settle(session)
        content = try await capturePanel("unknown-input")
        let input = accessibilityNodes(in: content).first { attribute("accessibilityLabel", of: $0) == session.localizer.tr("power.input") }
        try require(input != nil && attribute("accessibilityValue", of: input!) == session.localizer.tr("power.unavailable"), "Rated watts leaked into real-time input")
        checks.append("missing real-time input exposes unknown, not adapter rating")
        self.window?.orderOut(nil)

        session.model.chargeToFullNow(); try await settle(session)
        content = try await capturePanel("temporary-not-charging")
        let labels = accessibilityLabels(in: content)
        try require(session.model.temporaryFullChargeActive && !session.model.battery.isCharging, "Temporary pause fixture failed")
        try require(!labels.contains(session.localizer.tr("state.chargingToFull")), "Temporary intention falsely claimed active charging")
        try require(accessibilityNodes(in: content).contains { attribute("accessibilityIdentifier", of: $0) == "temporary-charge-intent" }, "Temporary lifetime missing")
        checks.append("temporary full intention and observed pause are distinct")
        self.window?.orderOut(nil)
        session.model.resumeChargeLimit(); try await settle(session)

        session.fixture.limitWriteDelay = .seconds(1)
        session.model.applyLimit(85)
        content = try await capturePanel("pending-limit")
        try require(session.model.chargeDisplaySelection == 85 && session.model.currentLimit == 80, "Pending target did not retain last confirmed limit")
        try require(accessibilityNodes(in: content).contains { attribute("accessibilityIdentifier", of: $0) == "charge-operation-status" }, "Pending charge operation invisible")
        checks.append("pending charge target visible alongside confirmation")
        self.window?.orderOut(nil)
        try await settle(session)
        session.fixture.limitWriteDelay = .zero

        session.fixture.nextLimitError = String(repeating: "Hardware rejected the requested setting. ", count: 12)
        session.model.applyLimit(90); try await settle(session)
        content = try await capturePanel("long-error")
        try require(content.frame.height <= 680, "Long error overflowed popover screen bounds")
        let scroll = scrollView(in: content)
        try require(scroll != nil, "Overflow has no scroll recovery")
        if let document = scroll?.documentView, let viewport = scroll?.contentView {
            document.scroll(NSPoint(x: 0, y: max(0, document.frame.height - viewport.bounds.height)))
            try await settle(session)
            _ = try capture(content, to: output.appendingPathComponent("scenario-long-error-scrolled.png"))
        }
        checks.append("long error scrolls to footer within original maximum height")
        let chargeFailure = session.model.chargeFeedbackError
        try require(chargeFailure != nil && session.model.panelGlobalError == nil, "Charge failure not owned by its panel section")
        session.model.setEnergyMode(.lowPower); try await settle(session)
        try require(session.model.chargeFeedbackError == chargeFailure, "Unrelated success erased charge failure")
        session.fixture.nextLimitError = nil
        session.model.applyLimit(80); try await settle(session)
        try require(session.model.chargeFeedbackError == nil, "Successful charge retry retained old failure")
        checks.append("local charge failure deduplicated, survives unrelated success, clears on recovery")
        self.window?.orderOut(nil)

        let settings = makeSettingsWindow(session: session, dark: false)
        self.window = settings; settings.orderFront(nil)
        try await settle(session)
        let settingsContent = settings.contentView!
        try press("settings-tab-awake", in: settingsContent); try await settle(session)
        let toggles = accessibilityNodes(in: settingsContent).filter { attribute("accessibilityRole", of: $0) == "AXCheckBox" || attribute("accessibilityRole", of: $0) == "AXSwitch" }
        try require(!toggles.isEmpty, "Custom switches lost native toggle semantics")
        try require(toggles.allSatisfy { $0.value(forKey: "accessibilityValue") != nil }, "Toggle value absent")
        checks.append("switches expose native role and current value")
        session.fixture.helper.filesRemain = true
        session.fixture.helper.installed = false
        session.model.refreshHelperInstalled(); try await settle(session)
        try require(hasControl("system-component-management", in: settingsContent) &&
                    !hasControl("remove-system-component", in: settingsContent),
                    "Component management must start as a compact disclosure")
        try press("system-component-management", in: settingsContent)
        try await settle(session)
        let helperLabels = accessibilityLabels(in: settingsContent)
        let componentLabel = accessibilityNodes(in: settingsContent).first {
            attribute("accessibilityIdentifier", of: $0) == "system-component-management"
        }.flatMap { attribute("accessibilityLabel", of: $0) }
        try require(componentLabel?.contains(session.localizer.tr("helper.unavailable")) == true &&
                    helperLabels.contains(session.localizer.tr("helper.installApproval")) &&
                    hasControl("remove-system-component", in: settingsContent) &&
                    hasControl("install-system-component", in: settingsContent),
                    "Unreachable installed helper must retain explicit repair and removal actions in management")
        checks.append("installed but unreachable component retains repair and removal")
        _ = try capture(settingsContent, to: output.appendingPathComponent("scenario-helper-unavailable.png"))
        session.fixture.configSaveError = NSError(domain: "read-only-fixture", code: 1)
        session.model.iconOnly.toggle(); try await settle(session)
        try require(accessibilityNodes(in: settingsContent).contains { attribute("accessibilityIdentifier", of: $0) == "retry-config-save" }, "Unsaved settings lost retry action")
        _ = try capture(settingsContent, to: output.appendingPathComponent("scenario-config-save-error.png"))
        session.fixture.configSaveError = nil
        try press("retry-config-save", in: settingsContent); try await settle(session)
        try require(session.model.configError == nil, "Saving retry did not recover")
        checks.append("configuration save failure announces unsaved state and offers a working retry")
        settings.setContentSize(NSSize(width: 540, height: 850)); try await settle(session)
        _ = try capture(settingsContent, to: output.appendingPathComponent("scenario-expanded-settings.png"))
        settings.orderOut(nil)
        let planned = ReviewSession(language: "en", theme: "liquidGlass", output: output, predictedUnplug: 8)
        defer { planned.beginCleanup() }
        await planned.prepare()
        try require(planned.model.predictedUnplugHour == 8, "Seeded usage did not predict unplug time")
        let planSettings = makeSettingsWindow(session: planned, dark: false)
        self.window = planSettings; planSettings.orderFront(nil); try await settle(planned)
        let planContent = planSettings.contentView!
        try require(accessibilityLabels(in: planContent).contains { $0.contains("08:00") && $0.contains("06:00") }, "Smart plan did not expose predicted unplug and start times")
        _ = try capture(planContent, to: output.appendingPathComponent("scenario-smart-plan.png"))
        planned.model.topupLeadHours = 0; try await settle(planned)
        try require(accessibilityLabels(in: planContent).contains(planned.localizer.tr("smart.topupOff", planned.model.holdLimit)), "Zero-hour top-up did not explain disabled state")
        _ = try capture(planContent, to: output.appendingPathComponent("scenario-topup-off.png"))
        planSettings.orderOut(nil)
        checks.append("recorded smart prediction exposes local unplug and start times; zero disables top-up")
        let data = try JSONSerialization.data(withJSONObject: ["passed": true, "fixtureOnly": true, "checks": checks], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("scenario-report.json"), options: .atomic)
        await planned.cleanup()
        await session.cleanup()
    }

    private func renderMatrix(output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var results: [[String: Any]] = []
        let requestedLanguages = options["--languages"].map { Set($0.split(separator: ",").map(String.init)) }
        let requestedThemes = options["--themes"].map { Set($0.split(separator: ",").map(String.init)) }
        let languages = Localizer.supported.filter { requestedLanguages?.contains($0) ?? true }
        let themes = CoddleTheme.allCases.filter { requestedThemes?.contains($0.rawValue) ?? true }
        guard !languages.isEmpty, !themes.isEmpty else {
            throw NSError(domain: "CoddleUIReview", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Render filters did not select a supported language and theme"])
        }
        for language in languages {
            for theme in themes {
                for dark in [false, true] {
                    let name = "\(language)-\(theme.rawValue)-\(dark ? "dark" : "light")"
                    results.append(contentsOf: try await renderCombination(
                        language: language, theme: theme, dark: dark,
                        packReadings: true, override: .none, name: name, output: output))
                }
            }
        }
        let packlessName = "\(languages[0])-\(themes[0].rawValue)-light-noPack"
        results.append(contentsOf: try await renderCombination(
            language: languages[0], theme: themes[0], dark: false,
            packReadings: false, override: .none, name: packlessName, output: output))
        let overrideName = "\(languages[0])-\(themes[0].rawValue)-light-override-confirmed"
        results.append(contentsOf: try await renderCombination(
            language: languages[0], theme: themes[0], dark: false,
            packReadings: true, override: .confirmed, name: overrideName, output: output))
        let inferredName = "\(languages[0])-\(themes[0].rawValue)-light-override-inferred"
        results.append(contentsOf: try await renderCombination(
            language: languages[0], theme: themes[0], dark: false,
            packReadings: true, override: .inferred, name: inferredName, output: output))
        let combinations = languages.count * themes.count * 2 + 3
        try await scenarioAudit(output: output)
        let report: [String: Any] = [
            "fixture": "real ControlPanel/SettingsWindowView/AppModel/Localizer with ModelFixture services",
            "combinations": combinations, "images": results.count, "checks": results,
            "captureMethod": "NSView.cacheDisplay; system-composited Liquid Glass layers may be absent. Use native window screenshots for visual acceptance.",
            "reduceTransparency": options["--reduce-transparency"] == "true",
            "packlessCombination": "\(packlessName) (pack readings absent; the hardware row must not render)",
            "confirmedOverrideCombination": "\(overrideName) (positive OS signal; the panel may assert the calibration cause)",
            "inferredOverrideCombination": "\(inferredName) (pack-only inference; the panel must not assert the cause)",
            "settingsEntryAudit": "Covered by isolated native-window E2E (tests/ui/build.sh ... e2e)",
            "selfSizingAudit": "Measured with NSHostingView.fittingSize (the menu bar popover's bounded sizing mode).",
            "scope": "Nonblank dimensions, localized resources, self-sized layout bounds and reachable overflow footer, the Settings entry point, the pack row (present with pack data, absent without it), and both charging-to-full override wordings are automated; screenshots require visual layout review."
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("render-report.json"), options: .atomic)
        print("Rendered \(results.count) production panel & settings screenshots across \(combinations) language/theme/appearance combinations")
    }

    private func renderCombination(language: String, theme: CoddleTheme, dark: Bool,
                                   packReadings: Bool, override: ChargeOverrideSignal,
                                   name: String, output: URL) async throws -> [[String: Any]] {
        let session = ReviewSession(language: language, theme: theme.rawValue,
                                    output: output, packReadings: packReadings,
                                    override: override)
        self.session = session
        defer { session.beginCleanup() }
        await session.prepare()
        guard session.localizer.tr("theme.title") != "theme.title" else {
            throw NSError(domain: "CoddleUIReview", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Localization bundle missing for \(language)"])
        }
        let popoverWindow = makePopoverWindow(session: session, dark: dark)
        self.window = popoverWindow
        let expectOverrideKey: String?
        switch override {
        case .none: expectOverrideKey = nil
        case .confirmed: expectOverrideKey = "state.chargingToFullDetail"
        case .inferred: expectOverrideKey = "state.chargingPastLimitDetail"
        }
        guard let popoverContent = popoverWindow.contentView else {
            throw NSError(domain: "CoddleUIReview", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Popover window had no content view"])
        }
        try await waitForAccessibleControls(
            ["energy-mode-0", "keep-awake-menu-entry", "keep-awake-master", "open-settings"], in: popoverContent)
        let audit = try fittingAudit(session: session, in: popoverContent,
                                     expectPackLabels: packReadings, expectOverrideKey: expectOverrideKey)
        var top = try capture(popoverContent, to: output.appendingPathComponent(name + "-top.png"))
        top["language"] = language; top["theme"] = theme.rawValue; top["dark"] = dark
        top["position"] = "popover"; top["packReadings"] = packReadings
        top["overrideSignal"] = String(describing: override)
        top["selfSizing"] = audit
        var panelImages = [top]
        let entryGeometry = try controlGeometry(["keep-awake-menu-entry"], in: popoverContent,
                                                requireVisible: false)
        try require((entryGeometry[0]["height"] as? CGFloat).map { $0 > 0 && $0 <= 33 } == true,
                    "The keep-awake entry must remain a single menu row")
        if let scroll = scrollView(in: popoverContent), let document = scroll.documentView,
           document.frame.height > scroll.contentView.bounds.height + 1 {
            document.scroll(NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
            try await settle(session)
            guard let footer = accessibilityNodes(in: popoverContent).first(where: {
                attribute("accessibilityIdentifier", of: $0) == "open-settings"
            }), let frame = footer.value(forKey: "accessibilityFrame") as? NSValue else {
                throw NSError(domain: "CoddleUIReview", code: 30,
                              userInfo: [NSLocalizedDescriptionKey: "Missing Settings footer geometry"])
            }
            let viewportFrame = popoverWindow.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
            try require(viewportFrame.insetBy(dx: -1, dy: -1).contains(frame.rectValue),
                        "Settings footer must be fully reachable after scrolling")
            let requests = session.openSettingsRequests
            try press("open-settings", in: popoverContent)
            try require(session.openSettingsRequests == requests + 1, "Scrolled Settings action must still work")
            var scrolled = try capture(popoverContent, to: output.appendingPathComponent(name + "-popover-scrolled.png"))
            scrolled["position"] = "popover-scrolled"; scrolled["language"] = language
            panelImages.append(scrolled)
        }
        try await expandKeepAwakeOptions(session: session, in: popoverContent)
        try require(!hasControl("keep-awake-description", in: popoverContent),
                    "Settled expanded options must keep explanatory copy in Settings")
        var expandedSnapshot = try await captureKeepAwakeLayout(popoverContent, session: session,
            to: output.appendingPathComponent(name + "-keep-awake-expanded.png"))
        expandedSnapshot["language"] = language; expandedSnapshot["theme"] = theme.rawValue; expandedSnapshot["dark"] = dark
        expandedSnapshot["position"] = "keep-awake-expanded"; expandedSnapshot["entryGeometry"] = entryGeometry
        panelImages.append(expandedSnapshot)
        try await collapseKeepAwakeOptions(session: session, in: popoverContent)
        popoverWindow.orderOut(nil)

        let settingsWindow = makeSettingsWindow(session: session, dark: dark)
        self.window = settingsWindow
        guard let settingsContent = settingsWindow.contentView else {
            throw NSError(domain: "CoddleUIReview", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Settings window had no content view"])
        }
        try await waitForAccessibleControls(CoddleSettingsTab.allCases.map { "settings-tab-" + $0.rawValue },
                                            in: settingsContent)
        var settingsImages: [[String: Any]] = []
        for tab in CoddleSettingsTab.allCases {
            try press("settings-tab-" + tab.rawValue, in: settingsContent)
            try await settle(session)
            let suffix = tab == .charging ? "-bottom.png" : "-settings-" + tab.rawValue + ".png"
            var lower = try capture(settingsContent, to: output.appendingPathComponent(name + suffix))
            lower["language"] = language; lower["theme"] = theme.rawValue; lower["dark"] = dark
            lower["position"] = "settings"; lower["tab"] = tab.rawValue
            lower["packReadings"] = packReadings
            lower["overrideSignal"] = String(describing: override)
            settingsImages.append(lower)
            if let scroll = scrollView(in: settingsContent), let document = scroll.documentView {
                document.scroll(NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
                try await settle(session)
                var bottom = try capture(settingsContent, to: output.appendingPathComponent(name + "-settings-" + tab.rawValue + "-scrolled.png"))
                bottom["language"] = language; bottom["theme"] = theme.rawValue; bottom["dark"] = dark
                bottom["position"] = "settings-scrolled"; bottom["tab"] = tab.rawValue
                settingsImages.append(bottom)
            }
        }
        settingsWindow.orderOut(nil)
        self.window = nil
        await session.cleanup()
        return panelImages + settingsImages
    }
}

@main
private struct ReviewUIApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = ReviewAppDelegate(arguments: Array(CommandLine.arguments.dropFirst()))
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
