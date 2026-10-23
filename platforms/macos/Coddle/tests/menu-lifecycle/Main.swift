import AppKit
import Foundation

/// Runs the production menu coordinator without starting Coddle's model,
/// persistence, helper, or power services. Only this window and its menus exist.
@MainActor
private final class MenuLifecycleTests: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var checks = 0
    private var failures: [String] = []
    private var interruptedPresentations = 0

    private final class Probe {}

    private final class Value: Hashable {
        let id: Int
        init(_ id: Int) { self.id = id }
        static func == (lhs: Value, rhs: Value) -> Bool { lhs === rhs }
        func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    }

    private final class WeakReference<T: AnyObject> {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }

    @MainActor private final class TrackingResult {
        var began = false
        var handled = false
        var selectedIDs: [Int] = []
        var tagsCorrect = false
        var checkmarkCorrect = false
        var invalidTagIgnored = false
        var actionDispatched = false
        var timer: Timer?
    }

    private enum Interaction: Sendable {
        case cancel
        case select(Int)
        case noAnchor
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 100),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Coddle Menu Lifecycle Regression"
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 100))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // A failed AppKit tracking setup must fail, not leave an unattended menu.
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            print("FAIL: native menu lifecycle harness timed out")
            fflush(stdout)
            exit(2)
        }
        // Give the launch activation/window transaction time to complete before
        // the first synchronous popup (later presentations need no such delay).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.run() }
    }

    private func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        if !condition() { failures.append(label) }
    }

    private func run() {
        // AppKit can immediately dismiss the first programmatic popup while
        // bringing this accessory app forward. Prime that framework setup with
        // a disposable menu before testing the production coordinator.
        warmUpMenuTracking()
        // Reusing each coordinator verifies stale callbacks and values do not
        // survive an individual presentation, even while its row remains alive.
        for interaction in [Interaction.cancel, .select(0), .select(1), .select(2), .noAnchor] {
            weak var releasedCoordinator: CoddleMenuCoordinator<Value>?
            autoreleasepool {
                let coordinator = CoddleMenuCoordinator<Value>()
                releasedCoordinator = coordinator
                for _ in 0..<10 {
                    var completed = false
                    for _ in 0..<3 {
                        let result = presentOnce(coordinator, interaction: interaction)
                        check(result.probe.value == nil, "callback capture released after presentation")
                        check(result.values.allSatisfy { $0.value == nil }, "option values released after presentation")
                        if result.completed {
                            completed = true
                            break
                        }
                        // Activation changes or a user's input can dismiss a
                        // native popup before the timer runs. Still verify its
                        // ownership, then require a completed bounded retry.
                        interruptedPresentations += 1
                        NSApp.activate(ignoringOtherApps: true)
                        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
                    }
                    check(completed, "native menu interaction completes within three attempts")
                }
            }
            check(releasedCoordinator == nil, "coordinator released after row lifetime")
        }

        window.close()
        if failures.isEmpty {
            print("PASS: \(checks) menu lifecycle checks (40 native interactions, 10 missing-anchor calls, \(interruptedPresentations) interrupted presentations)")
            fflush(stdout)
            exit(0)
        }
        for failure in Set(failures).sorted() { print("FAIL: \(failure)") }
        print("FAIL: \(failures.count) of \(checks) menu lifecycle checks (\(interruptedPresentations) interrupted presentations)")
        fflush(stdout)
        exit(1)
    }

    private func warmUpMenuTracking() {
        let menu = NSMenu(title: "")
        menu.addItem(withTitle: "Prepare native menu tracking", action: nil, keyEquivalent: "")
        let dismiss: @MainActor @Sendable () -> Void = { menu.cancelTracking() }
        let timer = Timer(timeInterval: 0.015, repeats: true) { _ in
            MainActor.assumeIsolated { dismiss() }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer { timer.invalidate() }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: window.contentView)
    }

    /// The returned observations are weak. The callback intentionally captures
    /// its coordinator strongly, reproducing the view -> coordinator -> callback
    /// ownership cycle independently of SwiftUI's rendering and optimizer.
    private func presentOnce(
        _ coordinator: CoddleMenuCoordinator<Value>,
        interaction: Interaction
    ) -> (probe: WeakReference<Probe>, values: [WeakReference<Value>], completed: Bool) {
        autoreleasepool {
            let probe = Probe()
            let values = [Value(41), Value(7), Value(99)]
            let weakProbe = WeakReference(probe)
            let weakValues = values.map(WeakReference.init)
            let state = TrackingResult()
            let options = values.enumerated().map {
                CoddleDropdownOption($0.element, label: "Option \($0.offset + 1)")
            }

            if case .noAnchor = interaction {
                coordinator.anchorView = nil
            } else {
                coordinator.anchorView = window.contentView
            }

            let observer = NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
            ) { notification in
                MainActor.assumeIsolated {
                    guard let menu = notification.object as? NSMenu else { return }
                    state.began = true
                    // This runs inside NSMenu.popUp's actual event-tracking loop.
                    let timer = Timer(timeInterval: 0.015, repeats: false) { _ in
                        MainActor.assumeIsolated {
                            state.handled = true
                            state.tagsCorrect = menu.items.map(\.tag) == [0, 1, 2]
                            state.checkmarkCorrect = menu.items.map(\.state) == [.off, .on, .off]
                            if case let .select(index) = interaction,
                               let item = menu.item(at: index) {
                                // Exercise the real target/action and verify an
                                // invalid tag cannot index the stored values.
                                item.tag = -1
                                menu.performActionForItem(at: index)
                                state.invalidTagIgnored = state.selectedIDs.isEmpty
                                item.tag = index
                                menu.performActionForItem(at: index)
                                state.actionDispatched = true
                            }
                            menu.cancelTracking()
                        }
                    }
                    state.timer = timer
                    RunLoop.main.add(timer, forMode: .eventTracking)
                }
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            coordinator.presentMenu(options: options, selection: values[1]) { [coordinator, probe] value in
                withExtendedLifetime((coordinator, probe)) {
                    state.selectedIDs.append(value.id)
                }
            }
            state.timer?.invalidate()
            state.timer = nil

            if case .noAnchor = interaction {} else if !state.handled {
                check(state.selectedIDs.isEmpty, "interrupted menu never delivers an unexpected callback")
                return (weakProbe, weakValues, false)
            }

            switch interaction {
            case .noAnchor:
                check(!state.began, "missing anchor never opens a menu")
                check(state.selectedIDs.isEmpty, "missing anchor never delivers a callback")
            case .cancel:
                check(state.began && state.handled, "cancellation uses native tracking")
                check(state.tagsCorrect && state.checkmarkCorrect, "menu tags and initial selection are correct")
                check(state.selectedIDs.isEmpty, "cancellation never delivers a callback")
            case let .select(index):
                check(state.began && state.handled, "selection uses native tracking")
                check(state.tagsCorrect && state.checkmarkCorrect, "menu tags and initial selection are correct")
                check(state.invalidTagIgnored, "invalid menu tag is ignored")
                check(state.actionDispatched && state.selectedIDs == [values[index].id],
                      "selection delivers the corresponding value exactly once")
            }
            return (weakProbe, weakValues, true)
        }
    }
}

@main
private enum MenuLifecycleMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let tests = MenuLifecycleTests()
        application.delegate = tests
        withExtendedLifetime(tests) { application.run() }
    }
}
