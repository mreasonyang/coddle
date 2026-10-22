import AppKit
import Foundation

@MainActor
private final class UpdateFixture: UpdateDriving {
    var state = UpdateState()
    var onChange: (() -> Void)?
    var starts = 0
    var checks = 0
    var checkPreferenceWrites: [Bool] = []
    var downloadPreferenceWrites: [Bool] = []
    func start() { starts += 1; state.canCheckForUpdates = true; onChange?() }
    func checkForUpdates() { checks += 1; state.canCheckForUpdates = false; onChange?() }
    func setAutomaticallyChecksForUpdates(_ value: Bool) {
        checkPreferenceWrites.append(value); state.automaticallyChecksForUpdates = value; onChange?()
    }
    func setAutomaticallyDownloadsUpdates(_ value: Bool) {
        downloadPreferenceWrites.append(value); state.automaticallyDownloadsUpdates = value; onChange?()
    }
}

extension IntegrationTests {
    @MainActor static func updateTests() async {
        let inert = UpdateController()
        inert.start(); inert.checkForUpdates()
        inert.setAutomaticallyChecksForUpdates(true); inert.setAutomaticallyDownloadsUpdates(true)
        expect(!inert.isAvailable && inert.state == UpdateState(), "default updater fixture has no live services or preferences")

        let driver = UpdateFixture()
        driver.state.automaticallyDownloadsUpdates = true
        let updates = UpdateController(driver: driver)
        updates.checkForUpdates(); updates.setAutomaticallyChecksForUpdates(true)
        expect(driver.checks == 0 && driver.checkPreferenceWrites.isEmpty, "updater cannot act before startup")
        updates.start(); updates.start()
        expect(driver.starts == 1, "updater scheduler starts only once")
        expect(driver.checkPreferenceWrites.isEmpty && driver.downloadPreferenceWrites.isEmpty,
               "startup respects stored updater preferences and consent")
        updates.setAutomaticallyDownloadsUpdates(false)
        expect(driver.downloadPreferenceWrites.isEmpty && updates.state.automaticallyDownloadsUpdates,
               "disabled download setting preserves remembered preference")
        updates.setAutomaticallyChecksForUpdates(true)
        updates.setAutomaticallyChecksForUpdates(true)
        updates.setAutomaticallyDownloadsUpdates(false)
        expect(driver.checkPreferenceWrites == [true] && driver.downloadPreferenceWrites == [false],
               "explicit updater setting changes write once to its own store")
        updates.setAutomaticallyDownloadsUpdates(true)
        updates.setAutomaticallyChecksForUpdates(false)
        expect(updates.state.automaticallyDownloadsUpdates && driver.downloadPreferenceWrites == [false, true],
               "disabling checks retains download preference without another write")
        updates.checkForUpdates(); updates.checkForUpdates()
        expect(driver.checks == 1 && !updates.state.canCheckForUpdates,
               "manual checking works with automatic checks off and blocks concurrent requests")
        driver.state.canCheckForUpdates = true
        driver.state.automaticallyChecksForUpdates = true
        driver.onChange?()
        expect(updates.state.canCheckForUpdates && updates.state.automaticallyChecksForUpdates,
               "settings follow changes made by the native updater dialog")

        let modelFixture = ModelFixture(); defer { modelFixture.clean() }
        let model = AppModel(services: modelFixture.services())
        await model.waitForPendingOperations()
        let delegate = AppDelegate(model: model, localizer: Localizer(language: "en"),
            notificationCenter: NotificationCenter(), openConfig: {}, openActivityMonitor: { _ in }, updates: updates)
        let menuItem = NSMenuItem(title: "Update fixture", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
        expect(delegate.validateMenuItem(menuItem), "native update menu reflects available updater")
        delegate.checkForUpdates(nil)
        expect(driver.checks == 2 && !delegate.validateMenuItem(menuItem), "native update menu dispatches and disables while checking")
        model.shutdownKeepAwake()
        await model.waitForShutdownCleanup()
    }
}
