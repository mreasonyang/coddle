import Foundation
import Combine

#if !CODDLE_TESTING
import Sparkle
#endif

struct UpdateState: Equatable {
    var canCheckForUpdates = false
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false
}

/// The updater owns its persisted preferences. Fixtures inject this boundary
/// instead of loading Sparkle, contacting GitHub, or using production defaults.
@MainActor
protocol UpdateDriving: AnyObject {
    var state: UpdateState { get }
    var onChange: (() -> Void)? { get set }
    func start()
    func checkForUpdates()
    func setAutomaticallyChecksForUpdates(_ value: Bool)
    func setAutomaticallyDownloadsUpdates(_ value: Bool)
}

@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var state: UpdateState
    let isAvailable: Bool
    private let driver: (any UpdateDriving)?
    private var started = false

    /// An omitted driver is deliberately inert, including in UI previews.
    init(driver: (any UpdateDriving)? = nil) {
        self.driver = driver
        isAvailable = driver != nil
        state = driver?.state ?? UpdateState()
        driver?.onChange = { [weak self] in self?.refresh() }
    }

    func start() {
        guard !started, let driver else { return }
        started = true
        driver.start()
        refresh()
    }

    func checkForUpdates() {
        guard started, state.canCheckForUpdates else { return }
        driver?.checkForUpdates()
        refresh()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard started, state.automaticallyChecksForUpdates != enabled else { return }
        driver?.setAutomaticallyChecksForUpdates(enabled)
        refresh()
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard started, state.automaticallyChecksForUpdates,
              state.automaticallyDownloadsUpdates != enabled else { return }
        driver?.setAutomaticallyDownloadsUpdates(enabled)
        refresh()
    }

    private func refresh() { state = driver?.state ?? UpdateState() }

    #if !CODDLE_TESTING
    static func live(bundle: Bundle = .main) -> UpdateController {
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: publicKey)?.count == 32 else { return UpdateController() }
        return UpdateController(driver: SparkleUpdateDriver())
    }
    #endif
}

#if !CODDLE_TESTING
@MainActor
private final class SparkleUpdateDriver: UpdateDriving {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    private var observations: [NSKeyValueObservation] = []
    var onChange: (() -> Void)?

    init() {
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.onChange?() }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.onChange?() }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.onChange?() }
            }
        ]
    }

    var state: UpdateState {
        UpdateState(canCheckForUpdates: controller.updater.canCheckForUpdates,
                    automaticallyChecksForUpdates: controller.updater.automaticallyChecksForUpdates,
                    automaticallyDownloadsUpdates: controller.updater.automaticallyDownloadsUpdates)
    }

    func start() { controller.startUpdater() }
    func checkForUpdates() { controller.checkForUpdates(nil) }
    func setAutomaticallyChecksForUpdates(_ value: Bool) {
        controller.updater.automaticallyChecksForUpdates = value
    }
    func setAutomaticallyDownloadsUpdates(_ value: Bool) {
        controller.updater.automaticallyDownloadsUpdates = value
    }
}
#endif
