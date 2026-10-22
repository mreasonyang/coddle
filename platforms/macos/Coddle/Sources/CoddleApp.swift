import SwiftUI
import AppKit
import Combine

/// Launch-time application policy for Dock mode plus a manually hosted window
/// used as the Dock entry point.
///
/// `LSUIElement = true` keeps the app menu-bar-only by default; the activation
/// policy is promoted to `.regular` (Dock icon) at launch when `showInDock` is
/// set. Demotion back to `.accessory` is intentionally *not* done at runtime
/// (it can silently fail on macOS 26/27 when a window is visible) — the UI
/// hints that a restart is needed.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    /// The Dock dashboard and Preferences are separate, equally reachable surfaces.
    private(set) var window: NSWindow?
    private(set) var settingsWindow: NSWindow?
    private let panelNavigation = CoddlePanelNavigation()
    private let settingsNavigation = CoddleSettingsNavigation()
    private(set) var onboardingWindow: NSWindow?
    private var langCancellable: AnyCancellable?
    private var settingsCancellable: AnyCancellable?
    private var onboardingCancellable: AnyCancellable?
    private var terminationRequested = false
    private var terminationReplied = false
    private let modelProvider: @MainActor () -> AppModel
    private let localizerProvider: @MainActor () -> Localizer
    private let notifications: NotificationCenter
    private let openConfig: @MainActor () -> Void
    private let openActivityMonitor: @MainActor (SignificantEnergyApp) -> Void
    private let updates: UpdateController

    override init() {
        #if CODDLE_TESTING
        preconditionFailure("UI tests must inject AppDelegate's model and localizer.")
        #else
        modelProvider = { AppModel.shared }
        localizerProvider = { Localizer.shared }
        notifications = .default
        openConfig = { NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.url]) }
        openActivityMonitor = { EnergyAppMonitor.openInActivityMonitor($0) }
        updates = .live()
        super.init()
        #endif
    }

    /// Tests must inject the same isolated session used by their visible panel.
    /// Constructing a window must never silently substitute production singletons.
    init(model: AppModel, localizer: Localizer, notificationCenter: NotificationCenter,
         openConfig: @escaping @MainActor () -> Void,
         openActivityMonitor: @escaping @MainActor (SignificantEnergyApp) -> Void,
         updates: UpdateController? = nil) {
        modelProvider = { model }
        localizerProvider = { localizer }
        notifications = notificationCenter
        self.openConfig = openConfig
        self.openActivityMonitor = openActivityMonitor
        self.updates = updates ?? UpdateController()
        super.init()
    }

    private var model: AppModel { modelProvider() }
    private var localizer: Localizer { localizerProvider() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        settingsCancellable = observeSettingsRequests()
        onboardingCancellable = notifications.publisher(for: .coddleShowOnboarding)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.showOnboardingWindow() }

        // Re-localize AppKit Main Menu and window title when user switches language in UI
        langCancellable = localizer.$language.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            self.setupMainMenu()
            self.window?.title = self.localizer.tr("app.name")
            self.settingsWindow?.title = self.settingsTitle
            self.onboardingWindow?.title = self.localizer.tr("onboarding.windowTitle")
        }

        // If the Dock is the only entry point, open the panel so the app is reachable.
        Task { [weak self] in
            guard let self else { return }
            await self.model.waitForStartup()
            guard !self.terminationRequested else { return }
            self.updates.start()
            AppDelegate.applyActivationPolicy(showDockIcon: self.model.showInDock)
            if self.model.setupRequired { self.showOnboardingWindow() }
            else if self.model.showInDock && !self.model.showMenuBarIcon { self.showMainWindow() }
        }
    }

    /// The menu-bar popover cannot reach this object through `NSApp.delegate`
    /// (that is SwiftUI's delegate), so it asks by notification.
    @discardableResult
    func observeSettingsRequests() -> AnyCancellable {
        notifications
            .publisher(for: .coddleShowSettings)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                let tab = (notification.userInfo?["tab"] as? String).flatMap(CoddleSettingsTab.init(rawValue:))
                self?.showSettingsWindow(tab: tab)
            }
    }

    private func setupMainMenu() {
        let l10n = localizer
        let mainMenu = NSMenu()

        // App Menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: l10n.tr("menu.about"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let updateItem = appMenu.addItem(withTitle: l10n.tr("updates.check"), action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = self
        appMenu.addItem(NSMenuItem.separator())
        let prefItem = appMenu.addItem(withTitle: l10n.tr("menu.preferences"), action: #selector(openPreferences(_:)), keyEquivalent: ",")
        prefItem.target = self
        prefItem.keyEquivalentModifierMask = [.command]
        let setupItem = appMenu.addItem(withTitle: l10n.tr("onboarding.menuTitle"), action: #selector(openOnboarding(_:)), keyEquivalent: "")
        setupItem.target = self
        appMenu.addItem(NSMenuItem.separator())
        let hideItem = appMenu.addItem(withTitle: l10n.tr("menu.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.keyEquivalentModifierMask = [.command]
        let hideOthersItem = appMenu.addItem(withTitle: l10n.tr("menu.hideOthers"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: l10n.tr("menu.showAll"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let quitItem = appMenu.addItem(withTitle: l10n.tr("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit Menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: l10n.tr("menu.edit"))
        editMenu.addItem(withTitle: l10n.tr("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: l10n.tr("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: l10n.tr("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: l10n.tr("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window Menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: l10n.tr("menu.window"))
        let closeItem = windowMenu.addItem(withTitle: l10n.tr("menu.close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeItem.keyEquivalentModifierMask = [.command]
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    @objc func openPreferences(_ sender: Any?) {
        showSettingsWindow()
    }
    @objc func openOnboarding(_ sender: Any?) { showOnboardingWindow() }
    @objc func checkForUpdates(_ sender: Any?) { updates.checkForUpdates() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates(_:)) {
            return updates.isAvailable && updates.state.canCheckForUpdates
        }
        return true
    }

    /// A Dock click (or Cmd-Tab) with no visible window reopens the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    /// Give normal quit a bounded opportunity to send OFF. Crash/forced-exit
    /// recovery remains the daemon lease's responsibility.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationRequested else { return .terminateLater }
        terminationRequested = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.finishTermination(sender)
        }
        model.shutdownKeepAwake()
        Task { [weak self] in
            guard let self else { return }
            await self.model.waitForShutdownCleanup()
            self.finishTermination(sender)
        }
        return .terminateLater
    }

    private func finishTermination(_ sender: NSApplication) {
        guard !terminationReplied else { return }
        terminationReplied = true
        sender.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !terminationRequested { model.shutdownKeepAwake() }
    }

    static func applyActivationPolicy(showDockIcon: Bool) {
        NSApplication.shared.setActivationPolicy(showDockIcon ? .regular : .accessory)
        if showDockIcon { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    private var settingsTitle: String {
        "\(localizer.tr("app.name")) — \(localizer.tr("settings.windowTitle"))"
    }

    private func hideMenuBarPopover() {
        for candidate in NSApplication.shared.windows
        where candidate.isVisible && candidate.level == .popUpMenu {
            candidate.orderOut(nil)
        }
    }

    /// Dock mode retains the full live dashboard and its quick actions even
    /// when the menu-bar status item is disabled.
    func showMainWindow() {
        if model.startupLoading {
            Task { [weak self] in
                guard let self else { return }
                await self.model.waitForStartup()
                if !self.terminationRequested { self.showMainWindow() }
            }
            return
        }
        if model.setupRequired { showOnboardingWindow(); return }
        // Closing a retained AppKit window does not unmount its SwiftUI view.
        // Reset presentation only when reopening a hidden dashboard.
        if window?.isVisible != true { panelNavigation.keepAwakeExpanded = false }
        if window == nil {
            let root = DockDashboardView(navigation: panelNavigation)
            .environmentObject(model)
            .environmentObject(localizer)
            .environment(\.coddleOpenConfig, openConfig)
            .environment(\.coddleOpenActivityMonitor, openActivityMonitor)
            .environment(\.coddleOpenSettings, { [weak self] in self?.showSettingsWindow() })
            .environment(\.coddleOpenAwakeSettings, { [weak self] in self?.showSettingsWindow(tab: .awake) })
            let w = NSWindow(contentViewController: NSHostingController(rootView: root))
            w.title = localizer.tr("app.name")
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.isOpaque = false
            w.backgroundColor = .clear
            w.setContentSize(NSSize(width: 340, height: 640))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func showSettingsWindow(tab: CoddleSettingsTab? = nil) {
        if model.startupLoading {
            Task { [weak self] in
                guard let self else { return }
                await self.model.waitForStartup()
                if !self.terminationRequested { self.showSettingsWindow(tab: tab) }
            }
            return
        }
        if model.setupRequired { showOnboardingWindow(); return }
        if let tab { settingsNavigation.tab = tab }
        model.refreshLaunchAtLogin()
        model.refreshNotificationStatus()
        hideMenuBarPopover()
        if settingsWindow == nil {
            let root = SettingsWindowView(navigation: settingsNavigation, updates: updates)
                .environmentObject(model)
                .environmentObject(localizer)
                .environment(\.coddleOpenConfig, openConfig)
            let w = NSWindow(contentViewController: NSHostingController(rootView: root))
            w.title = settingsTitle
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            // Extend only the background under the native title bar. SwiftUI's
            // safe area keeps tabs and controls below the window controls.
            w.titlebarAppearsTransparent = true
            w.titlebarSeparatorStyle = .none
            w.contentMinSize = NSSize(width: 440, height: 520)
            w.contentMaxSize = NSSize(width: 600, height: 1000)
            w.isReleasedWhenClosed = false
            w.isOpaque = false
            w.backgroundColor = .clear
            w.setContentSize(NSSize(width: 440, height: 520))
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func showOnboardingWindow() {
        if model.startupLoading {
            Task { [weak self] in
                guard let self else { return }
                await self.model.waitForStartup()
                if !self.terminationRequested { self.showOnboardingWindow() }
            }
            return
        }
        guard let coordinator = model.onboarding else { return }
        if coordinator.record.completed { coordinator.beginReview() }
        hideMenuBarPopover()
        if onboardingWindow == nil {
            let root = OnboardingView(flow: coordinator, model: model, l10n: localizer,
                close: { [weak self] in self?.onboardingWindow?.close() },
                openPanel: { [weak self] in self?.onboardingWindow?.close(); self?.showMainWindow() })
            let w = NSWindow(contentViewController: NSHostingController(rootView: root))
            w.title = localizer.tr("onboarding.windowTitle")
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titlebarSeparatorStyle = .none
            w.contentMinSize = NSSize(width: 440, height: 520)
            w.contentMaxSize = NSSize(width: 600, height: 800)
            w.setContentSize(NSSize(width: 480, height: 600))
            w.isReleasedWhenClosed = false
            w.isOpaque = false; w.backgroundColor = .clear
            w.center(); onboardingWindow = w
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

}

/// Coddle menu-bar app (macOS). LSUIElement = true, so it lives in the menu bar
/// by default; Dock mode is opt-in via config. The label shows the template icon
/// followed by the live percentage; if the icon asset is missing it falls back to
/// text only.
#if !CODDLE_TESTING
@main
struct CoddleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared
    @StateObject private var l10n = Localizer.shared

    /// Template glyph bundled as Resources/MenuBarIconTemplate(.png/@2x).
    /// AppKit treats names ending in "Template" as template images and tints
    /// them for the current menu-bar appearance; we set the flag explicitly too.
    private var menuBarIcon: NSImage? {
        guard let img = NSImage(named: "MenuBarIconTemplate") else { return nil }
        img.isTemplate = true
        return img
    }

    /// Dynamic SF Symbol for menu bar status indication (especially in iconOnly mode).
    private var dynamicIconName: String {
        guard model.battery.present && model.battery.installed else {
            return "desktopcomputer"
        }
        guard let p = model.battery.percent else { return "battery.0" }
        if model.battery.externalConnected {
            // An override means the pack is genuinely charging, so the charging
            // glyph is the honest one — never the "holding" clock, which is what
            // `chargeStatus` can still report for the first moments of the
            // override. `chargeOverridePresented` is itself AC-gated, so this
            // agrees with the panel's badge.
            if model.chargeOverridePresented || (model.temporaryFullChargeActive && model.battery.isCharging) { return "battery.100.bolt" }
            switch model.chargeStatus {
            case .charging: return "battery.100.bolt"
            case .holding:  return "bolt.badge.clock.fill"
            case .charged:  return "battery.100"
            default:        return "powerplug.fill"
            }
        }
        if p >= 75 { return "battery.100" }
        if p >= 50 { return "battery.75" }
        if p >= 25 { return "battery.50" }
        return "battery.25"
    }

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(
            get: { model.showMenuBarIcon },
            set: { model.setShowMenuBarIcon($0) }
        )) {
            Group {
                if model.startupLoading {
                    ProgressView().controlSize(.small).frame(width: 180, height: 100)
                } else if let flow = model.onboarding, model.setupRequired {
                    OnboardingMenuView(flow: flow, model: model, l10n: l10n)
                } else { PopoverControlPanel() }
            }
                .environmentObject(model)
                .environmentObject(l10n)
        } label: {
            if model.iconOnly {
                Image(systemName: dynamicIconName)
            } else {
                HStack(spacing: 4) {
                    if let icon = menuBarIcon {
                        Image(nsImage: icon)
                    } else {
                        Image(systemName: dynamicIconName)
                    }
                    Text(model.menuBarText)
                        .monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
#endif
