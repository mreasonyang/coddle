import AppKit
import Combine
import Foundation

@main struct IntegrationTests {
    @MainActor static var checks = 0
    @MainActor static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
        checks += 1
    }
    static func settle() async { try? await Task.sleep(nanoseconds: 50_000_000) }
    @MainActor static func waitForInstall(_ model: AppModel) async {
        for _ in 0..<100 where model.helperBusy { await settle() }
        expect(!model.helperBusy, "installation completion reached model")
        await model.waitForPendingOperations()
    }
    @MainActor static func main() async {
        await updateTests()
        await hardwareRefreshRecoveryTests()
        await keepAwakeMenuStateTests()
        await displayManagementTests()
        await lidReadbackTests()
        await copyHierarchyTests()
        // A read-only poll must not advertise a write that reconciliation skips.
        // Observe every publication; checking only the final state misses the flash.
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true
            f.battery.externalConnected = true
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            var busyEvents: [Bool] = []
            let observation = model.$chargeLimitBusy.dropFirst().sink { busyEvents.append($0) }
            let initialWrites = f.limitWrites.count
            for _ in 0..<8 { model.refresh(); await model.waitForPendingOperations() }
            expect(!busyEvents.contains(true), "unchanged hardware polls never publish charging busy")
            expect(f.limitWrites.count == initialWrites, "unchanged hardware polls perform no writes")
            // An enabled external limit is intentionally adopted in manual mode.
            // A disabled controller, however, must restore the configured target.
            f.hardwareLimit = (80, false)
            busyEvents.removeAll()
            model.refresh(); await model.waitForPendingOperations()
            expect(busyEvents.contains(true), "real background reconciliation advertises its write")
            expect(f.limitWrites.last == 80 && !model.chargeLimitBusy, "background reconciliation restores the target and clears busy")
            busyEvents.removeAll()
            model.applyLimit(90)
            expect(model.chargeLimitBusy, "explicit user operation immediately advertises pending state")
            await model.waitForPendingOperations()
            expect(busyEvents.contains(true) && model.currentLimit == 90, "user operation still writes and confirms")
            f.nextLimitError = "Fixture rejected limit"
            model.applyLimit(85); await model.waitForPendingOperations()
            busyEvents.removeAll()
            let failedWrites = f.limitWrites.count
            model.refresh(); await model.waitForPendingOperations()
            expect(!busyEvents.contains(true) && f.limitWrites.count == failedWrites,
                   "debounced retry does not flash a write that was skipped")
            expect(model.chargeFeedbackError != nil, "debouncing preserves actual error feedback")
            observation.cancel()
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true
            var assertionsFail = false
            var services = f.services()
            services.setSystemAwake = { _ in !assertionsFail }
            let model = AppModel(services: services)
            await model.waitForPendingOperations()
            f.helper.powerModeError = HelperError(message: "Power mode rejected")
            model.setEnergyMode(.lowPower); await model.waitForPendingOperations()
            expect(model.energyFeedbackError == "Power mode rejected", "power failure owned by energy controls")
            expect(model.panelGlobalError == nil, "power error not repeated globally")
            f.nextLimitError = "Limit rejected"
            model.applyLimit(90); await model.waitForPendingOperations()
            expect(model.chargeFeedbackError == "Limit rejected", "charge failure owned by charge controls")
            f.helper.powerModeError = nil
            model.setEnergyMode(.lowPower); await model.waitForPendingOperations()
            expect(model.energyFeedbackError == nil && model.chargeFeedbackError != nil,
                   "energy success resolves only its own error")
            assertionsFail = true
            model.keepAwake = true
            await model.waitForPendingOperations()
            expect(model.awakeFeedbackError != nil, "assertion failure stays with keep-awake controls")
            f.nextLimitError = nil
            model.applyLimit(80); await model.waitForPendingOperations()
            expect(model.chargeFeedbackError == nil && model.awakeFeedbackError != nil,
                   "charge success cannot hide failed keep awake")
            assertionsFail = false
            model.keepAwake = false
            await model.waitForPendingOperations()
            expect(model.awakeFeedbackError == nil, "assertion recovery clears local failure")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }
        // A real async installation finishes after the away verdict changes.
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwakeOnLidClosed = true
            f.config.keepAwake = true
            f.helper.installGate = DispatchSemaphore(value: 0)
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            model.installHelper()
            f.away.isAway = true; f.awayCallback?(f.away)
            await settle()
            expect(model.bagGuardActive, "bag guard activates while installer waits")
            f.helper.installGate?.signal()
            await waitForInstall(model)
            expect(f.helper.writes.last == false, "installation completion honors active bag guard")
            expect(!f.helper.writes.contains(true), "installation never re-enables sleep prohibition")
            model.refresh(); await model.waitForPendingOperations()
            expect(f.helper.writes.last == false, "next refresh preserves off")
            expect(f.systemAssertions.last == false, "bag guard releases system assertion")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }
        // Shutdown while an installer is pending must also win over its completion.
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwakeOnLidClosed = true
            f.config.keepAwake = true
            f.away.isAway = true
            f.helper.installGate = DispatchSemaphore(value: 0)
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            model.installHelper(); model.shutdownKeepAwake()
            f.away.isAway = false; f.awayCallback?(f.away)
            f.helper.installGate?.signal()
            await waitForInstall(model)
            expect(f.helper.writes.last == false, "late installer cannot resurrect shutdown state")
            expect(f.systemAssertions.last == false && f.displayAssertions.last == false,
                   "late away and installer callbacks cannot reacquire assertions after shutdown")
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true; f.config.keepAwakeOnLidClosed = true
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            model.installHelper(); await waitForInstall(model)
            expect(f.helper.writes.last == true, "ordinary installation applies requested lid mode")
            model.keepAwakeOnLidClosed = false
            await model.waitForPendingOperations()
            expect(f.helper.writes.last == false, "off is sent even when old write may still be pending")
            f.helper.writeError = HelperError(message: "timeout")
            model.keepAwakeOnLidClosed = true
            await model.waitForPendingOperations()
            expect(model.helperStatus == "timeout", "failed helper writes are visible")
            f.helper.writeError = nil
            model.refresh(); await model.waitForPendingOperations()
            expect(model.helperStatus == nil, "failed helper intent retries on refresh")
            f.helper.installed = false
            model.keepAwakeOnLidClosed = false
            await model.waitForPendingOperations()
            expect(model.helperStatus != nil, "unreachable helper retains pending OFF")
            f.helper.installed = true
            model.refresh(); await model.waitForPendingOperations()
            expect(f.helper.writes.last == false && model.helperStatus == nil,
                   "OFF is retried after helper recovers even when initial ping failed")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            expect(model.helperStatus == nil, "missing optional helper is not an error at startup")
            f.helper.installed = true; model.refresh(); await model.waitForPendingOperations()
            expect(f.helper.writes.last == false, "startup OFF reconciles when daemon becomes available later")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }
        // Reload uses the same batch path as programmatic config changes.
        do {
            let f = ModelFixture(); defer { f.clean() }
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            f.config.showInDock = true; f.config.showMenuBarIcon = false
            f.config.language = "zh-Hans"; f.config.theme = "classic"
            f.saved.removeAll(); model.reloadConfig(); await model.waitForPendingOperations()
            expect(f.dockCalls.last == true, "reload promotes actual Dock entry")
            expect(!model.showMenuBarIcon && model.showInDock, "reload applies requested visible entry")
            expect(f.language == "zh-Hans" && model.theme == "classic", "batch reload updates language and theme")
            expect(f.saved.count == 1, "reload persists a single coherent config")
            var invalid = model.config; invalid.showInDock = false; invalid.showMenuBarIcon = false
            model.config = invalid
            expect(model.showMenuBarIcon, "batch config cannot hide both entries")
            model.setShowMenuBarIcon(false)
            expect(f.dockCalls.last == true && model.showInDock, "UI menu toggle also preserves entry")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            f.config.lowBatteryReminder = .enabled; model.lowBatteryReminder = .enabled
            f.battery.percent = 15; model.refresh(); await model.waitForPendingOperations(); model.refresh(); await model.waitForPendingOperations()
            expect(f.notifications == [15], "low-battery notification is once per discharge")
            f.battery.externalConnected = true; model.refresh(); await model.waitForPendingOperations()
            f.battery.externalConnected = false; model.refresh(); await model.waitForPendingOperations()
            expect(f.notifications == [15, 15], "AC episode rearms notification")
            model.setLaunchAtLogin(true)
            await model.waitForPendingOperations()
            expect(model.launchAtLogin, "login item updates observed state")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.helper.installed = true
            f.config.awayDetectionEnabled = false
            f.away.isAway = true
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            let before = f.helper.writes.count
            var updated = model.config
            updated.awayDetectionEnabled = true; updated.keepAwake = true; updated.keepAwakeOnLidClosed = true
            model.config = updated
            expect(model.bagGuardActive, "batch update computes new away verdict")
            expect(!f.helper.writes.dropFirst(before).contains(true), "batch update never pulses ON using stale guard state")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true; f.config.smartEnabled = true; f.config.holdLimit = 0
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            expect(f.limitWrites == [0], "zero smart target disables limit once")
            f.limitWrites.removeAll(); model.holdLimit = 100
            model.refresh(); await model.waitForPendingOperations(); model.refresh(); await model.waitForPendingOperations(); model.refresh(); await model.waitForPendingOperations()
            expect(f.limitWrites == [100], "full charge does not rewrite equivalent disabled100 state every tick")
            model.applyLimit(85); await model.waitForPendingOperations()
            expect(!model.smartEnabled && model.currentLimit == 85, "manual selection overrides smart policy")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }
        // The OS charging-to-full override is surfaced as an *additional* state:
        // the charge-status machine is untouched; a positive Darwin state is
        // active on its own and licenses the confident wording; a zero state is
        // NOT proof of absence (a missing/renamed notification also reads 0) so
        // the bounded inference still fires — but only after a debounce hold, and
        // only STRICTLY above the limit, so the tester's false alarm
        // (`percent == limit && isCharging`, sustained) never raises the banner;
        // an unplugged flag is detected but never presented as charging; and the
        // subscription refreshes immediately.
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true
            // Held at the limit, not charging — the exact moment the naive panel
            // would say "Holding at 80%" while the OS charges to 100%.
            f.battery = BatteryInfo(present: true, installed: true, percent: 85,
                externalConnected: true, fullyCharged: false, notChargingReason: 0x0100_0000)
            f.chargeOverrideState = 1
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            expect(model.chargeOverrideActive, "override: non-zero state surfaces as active")
            expect(model.chargeOverridePresented, "override: on AC the honest state is presented")
            expect(model.chargeOverrideConfirmed,
                   "override: the Darwin signal licenses the confident wording")
            expect(model.chargeStatus == .holding(limit: 80),
                   "override: underlying chargeStatus is unchanged (still holding)")

            // (a) THE TESTER'S FALSE ALARM: percent == limit while charging, with a
            // zero Darwin state. The round-2 rule fired here on every normal
            // charge; the debounced strict-above rule must stay silent however
            // long it is sustained.
            f.chargeOverrideState = 0
            f.battery.percent = 80; f.battery.isCharging = true
            var falseAlarmFired = false
            for _ in 0..<20 {                 // 20 samples at the default 5 s = 100 s
                f.now += 5
                model.refresh(); await model.waitForPendingOperations()
                if model.chargeOverrideActive { falseAlarmFired = true }
            }
            expect(!falseAlarmFired,
                   "override: percent == limit while charging never activates, sustained 100 s")

            // (b) TRUE POSITIVE: strictly above the limit while charging on AC.
            // Inactive until the hold elapses, then inferred — not confirmed,
            // because there is no positive Darwin signal.
            f.battery.percent = 81
            f.now += 5
            model.refresh(); await model.waitForPendingOperations()
            expect(!model.chargeOverrideActive, "override: the first above-limit sample is not enough")
            f.now += ChargeOverrideDebouncer.requiredPackHold / 2
            model.refresh(); await model.waitForPendingOperations()
            expect(!model.chargeOverrideActive, "override: half the hold window is not enough")
            f.now += ChargeOverrideDebouncer.requiredPackHold / 2
            model.refresh(); await model.waitForPendingOperations()
            expect(model.chargeOverrideActive, "override: the inference activates after the hold window")
            expect(model.chargeOverridePresented, "override: the inferred override is presented on AC")
            expect(!model.chargeOverrideConfirmed,
                   "override: an inferred override does not license the confident wording")

            // (c) The hold resets when the condition breaks mid-window.
            f.battery.percent = 80            // back to exactly the limit: the break
            f.now += 5
            model.refresh(); await model.waitForPendingOperations()
            expect(!model.chargeOverrideActive, "override: the broken condition deactivates the inference")
            f.battery.percent = 82
            f.now += 5
            model.refresh(); await model.waitForPendingOperations()
            expect(!model.chargeOverrideActive, "override: the window restarts after a break")

            // Unreadable signal: the inference carries the feature.
            f.chargeOverrideState = nil
            f.battery.percent = 85; f.battery.isCharging = true
            f.now += ChargeOverrideDebouncer.requiredPackHold
            model.refresh(); await model.waitForPendingOperations()
            expect(model.chargeOverrideActive,
                   "override: unreadable signal falls back to the bounded inference")

            f.battery.percent = 77   // normal dead band, charging back up to 80
            f.now += 5
            model.refresh(); await model.waitForPendingOperations()
            expect(!model.chargeOverrideActive, "override: inference does not fire in the dead band")

            // A set flag while unplugged is detected but never presented as
            // present-tense charging, so the badge agrees with "On AC: No" and
            // the menu bar.
            f.chargeOverrideState = 1
            f.battery.externalConnected = false; f.battery.isCharging = false
            model.refresh(); await model.waitForPendingOperations()
            expect(model.chargeOverrideActive, "override: OS flag is still detected while unplugged")
            expect(!model.chargeOverridePresented, "override: unplugged flag is not presented as charging")

            f.battery.externalConnected = true
            f.chargeOverrideCallback?()
            await settle()
            expect(model.chargeOverridePresented, "override: notification callback refreshes the model")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }

        // MARK: - P0-3: External limit wipe / restart reset detection and re-apply

        // (a) Startup with wiped hardware: manualLimit == 80 in config, hardware reports
        //     enabled = false, limit = 100 -> re-applies setLimit(80).
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true
            f.config.manualLimit = 80
            f.config.smartEnabled = false
            f.hardwareLimit = (limit: 100, enabled: false) // wiped by macOS reboot/crash
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            expect(f.limitWrites == [80], "startup with wiped hardware re-applies setLimit(80)")
            expect(model.currentLimit == 80 && model.limitEnabled && model.selection == 80,
                   "startup re-apply restores model limit state")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }

        // (b) Wake with wiped hardware -> re-applies setLimit(80).
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true
            f.config.manualLimit = 80
            f.config.smartEnabled = false
            f.hardwareLimit = (limit: 80, enabled: true)
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            expect(f.limitWrites.isEmpty, "healthy hardware needs no startup writes")

            // macOS sleep/wake cycle wipes the native limit to disabled (100)
            f.hardwareLimit = (limit: 100, enabled: false)
            f.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
            await settle()
            expect(f.limitWrites == [80], "wake with wiped hardware re-applies setLimit(80)")
            expect(model.currentLimit == 80 && model.limitEnabled, "wake re-apply restores state")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }

        // (c) Hysteresis dead-band: battery drops to 78% or 77% while plugged in with
        //     limit intact (limit: 80, enabled: true) -> strictly NO writes to setLimit.
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true
            f.config.manualLimit = 80
            f.config.smartEnabled = false
            f.hardwareLimit = (limit: 80, enabled: true)
            f.battery = BatteryInfo(present: true, installed: true, percent: 80, externalConnected: true)
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            f.limitWrites.removeAll()

            // Battery drops due to normal firmware dead-band
            f.battery.percent = 78
            model.refresh(); await model.waitForPendingOperations()
            f.battery.percent = 77
            model.refresh(); await model.waitForPendingOperations()
            f.battery.percent = 76
            model.refresh(); await model.waitForPendingOperations()
            expect(f.limitWrites.isEmpty, "hysteresis dead-band battery drop causes strictly NO writes to setLimit")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }

        // (d) Explicit user turn-off: user sets 0 -> manualLimit = 0, calls disableLimit(),
        //     does NOT re-enable on reboot/refresh.
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true
            f.config.manualLimit = 80
            f.config.smartEnabled = false
            f.hardwareLimit = (limit: 80, enabled: true)
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            f.limitWrites.removeAll()

            // User explicitly turns limit off
            model.applyLimit(0); await model.waitForPendingOperations()
            expect(f.limitWrites == [0], "user turn-off calls disableLimit")
            expect(model.manualLimit == 0 && model.selection == 0, "manualLimit and selection updated to 0")
            expect(f.config.manualLimit == 0, "manualLimit = 0 persisted in config")

            // Next refresh must NOT re-enable
            f.limitWrites.removeAll()
            model.refresh(); await model.waitForPendingOperations()
            model.refresh(); await model.waitForPendingOperations()
            expect(f.limitWrites.isEmpty, "refresh does not re-enable when manualLimit is 0")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()

            // Subsequent reboot with manualLimit == 0 must NOT re-enable
            let f2 = ModelFixture(); defer { f2.clean() }
            f2.supportsLimit = true
            f2.config.manualLimit = 0
            f2.config.smartEnabled = false
            f2.hardwareLimit = (limit: 100, enabled: false)
            let model2 = AppModel(services: f2.services())
            await model2.waitForPendingOperations()
            expect(f2.limitWrites.isEmpty, "reboot with manualLimit == 0 does NOT write or re-enable")
            model2.shutdownKeepAwake(); await model2.waitForPendingOperations()
        }

        // (e) Smart mode vs manual mode transitions.
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true
            f.config.manualLimit = 80
            f.config.smartEnabled = false
            f.hardwareLimit = (limit: 80, enabled: true)
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()

            // Transition manual -> smart
            model.smartEnabled = true
            model.holdLimit = 90
            model.refresh(); await model.waitForPendingOperations()
            expect(f.limitWrites == [90], "transition to smart mode applies smart target")
            expect(model.selection == 90, "selection reflects smart target")

            // In smart mode, user changes limit via UI picker: reverts to manual mode
            f.limitWrites.removeAll()
            model.applyLimit(85); await model.waitForPendingOperations()
            expect(!model.smartEnabled, "applyLimit turns smart mode off")
            expect(model.manualLimit == 85, "manualLimit updated to 85")
            expect(f.limitWrites == [85], "hardware set to 85")
            expect(f.config.manualLimit == 85, "config persisted with manualLimit = 85")

            // Refresh in manual mode preserves 85 without duplicate writes
            f.limitWrites.removeAll()
            model.refresh(); await model.waitForPendingOperations()
            expect(f.limitWrites.isEmpty, "steady manual mode does not rewrite")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }

        // (f) Guard against rapid repeated writes / infinite loops if setLimit fails
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true
            f.config.manualLimit = 80
            f.config.smartEnabled = false
            f.hardwareLimit = (limit: 100, enabled: false) // wiped
            f.nextLimitError = "PowerUI IPC failure"
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            expect(f.limitWrites == [80], "first attempt was made")
            expect(model.lastError == "PowerUI IPC failure", "error recorded in model")

            // Rapid refreshes within debounce interval must NOT repeatedly spam hardware writes
            f.now += 1 // 1 second elapsed, less than refreshSeconds (5)
            model.refresh(); await model.waitForPendingOperations()
            f.now += 1
            model.refresh(); await model.waitForPendingOperations()
            expect(f.limitWrites.count == 1, "rapid refreshes are debounced on failure")

            // After refreshSeconds has passed, retry is allowed
            f.now += 5
            f.nextLimitError = nil // recovery
            model.refresh(); await model.waitForPendingOperations()
            expect(f.limitWrites == [80, 80], "retried after debounce window elapsed and succeeded")
            expect(model.lastError == nil, "error cleared on recovery")
            expect(model.currentLimit == 80 && model.limitEnabled, "limit successfully restored")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }

        // (g) Target == 100 selection stability: verify selection stays 100 across refreshes without pulsing to 0
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true
            f.config.manualLimit = 100
            f.config.smartEnabled = false
            f.hardwareLimit = (limit: 100, enabled: false)
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            expect(model.selection == 100, "initial selection is 100")
            for _ in 0..<5 {
                model.refresh(); await model.waitForPendingOperations()
                expect(model.selection == 100, "selection stays 100 across refreshes without pulsing to 0")
            }
            expect(f.limitWrites.isEmpty, "steady target 100 causes 0 writes")

            // Explicit applyLimit(100) from 80
            let f2 = ModelFixture(); defer { f2.clean() }
            f2.supportsLimit = true
            f2.config.manualLimit = 80
            f2.config.smartEnabled = false
            f2.hardwareLimit = (limit: 80, enabled: true)
            let model2 = AppModel(services: f2.services())
            await model2.waitForPendingOperations()
            model2.applyLimit(100); await model2.waitForPendingOperations()
            expect(model2.selection == 100, "selection updated to 100 on applyLimit")
            for _ in 0..<5 {
                model2.refresh(); await model2.waitForPendingOperations()
                expect(model2.selection == 100, "selection stays 100 across refreshes after applyLimit(100)")
            }
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
            model2.shutdownKeepAwake(); await model2.waitForPendingOperations()
        }

        // (h) Wake debounce resilience: verify failed limit write followed by didWakeNotification
        // does not bypass debounce or write storm.
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true
            f.config.manualLimit = 80
            f.config.smartEnabled = false
            f.hardwareLimit = (limit: 100, enabled: false)
            f.nextLimitError = "PowerUI IPC failure"
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            expect(f.limitWrites == [80], "initial startup write attempted and failed")
            expect(model.lastError == "PowerUI IPC failure", "error recorded in model")

            // System wakes shortly after failure (within debounce interval)
            f.now += 1 // 1 second elapsed, less than refreshSeconds (5)
            f.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
            await settle()
            expect(f.limitWrites.count == 1, "wake within debounce interval does NOT bypass debounce or write storm")

            // Additional wake still within debounce interval
            f.now += 1
            f.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
            await settle()
            expect(f.limitWrites.count == 1, "second wake within debounce interval is still debounced")

            // Once debounce interval has elapsed, wake retries and succeeds upon recovery
            f.now += 5
            f.nextLimitError = nil
            f.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
            await settle()
            expect(f.limitWrites == [80, 80], "wake after debounce window retries and restores limit")
            expect(model.currentLimit == 80 && model.limitEnabled, "limit successfully restored")
            expect(model.lastError == nil, "error cleared on recovery")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }

        // (i) External intent adoption: when manualLimit == 85 and hardware reports (limit: 80, enabled: true),
        // verify Coddle updates manualLimit to 80 with 0 hardware writes.
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true
            f.config.manualLimit = 85
            f.config.smartEnabled = false
            f.hardwareLimit = (limit: 80, enabled: true) // set externally in System Settings
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            expect(model.manualLimit == 80, "startup adopts external hardware limit 80 into manualLimit")
            expect(model.selection == 80, "selection updated to external 80")
            expect(f.config.manualLimit == 80, "config persisted with manualLimit = 80")
            expect(f.limitWrites.isEmpty, "strictly 0 hardware writes during startup external intent adoption")

            // Live external intent adoption while Coddle is running
            f.hardwareLimit = (limit: 90, enabled: true) // external tool sets 90
            model.refresh(); await model.waitForPendingOperations()
            expect(model.manualLimit == 90, "live refresh adopts external limit 90")
            expect(model.selection == 90, "live selection updated to 90")
            expect(f.config.manualLimit == 90, "live config persisted with manualLimit = 90")
            expect(f.limitWrites.isEmpty, "strictly 0 hardware writes during live external intent adoption")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }

        // (j) Wipe restoration: when manualLimit == 80 and hardware reports (limit: 100, enabled: false),
        // verify Coddle restores setLimit(80).
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true
            f.config.manualLimit = 80
            f.config.smartEnabled = false
            f.hardwareLimit = (limit: 80, enabled: true)
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            expect(f.limitWrites.isEmpty, "healthy hardware needs no write")

            // True hardware wipe occurs (e.g. reboot/wake wipe)
            f.hardwareLimit = (limit: 100, enabled: false)
            model.refresh(); await model.waitForPendingOperations()
            expect(f.limitWrites == [80], "hardware wipe restores setLimit(80)")
            expect(model.currentLimit == 80 && model.limitEnabled, "limit state restored after wipe")
            expect(model.selection == 80, "selection remains 80 after wipe restoration")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }

        // (k) Power flow telemetry: live model reflects power flow metrics correctly.
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.battery = BatteryInfo(present: true, installed: true, percent: 80, externalConnected: true,
                powerFlow: PowerFlow(adapterWatts: 90, systemPowerInWatts: 23.7, systemLoadWatts: 23.7, batteryPowerWatts: 0.0))
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            expect(model.battery.powerFlow?.adapterWatts == 90, "live model reflects adapterWatts")
            expect(model.battery.powerFlow?.systemPowerInWatts == 23.7, "live model reflects systemPowerInWatts")
            expect(model.battery.powerFlow?.systemLoadWatts == 23.7, "live model reflects systemLoadWatts")
            expect(model.battery.powerFlow?.batteryPowerWatts == 0.0, "live model reflects batteryPowerWatts")

            // Live update via refresh
            f.battery.powerFlow = PowerFlow(adapterWatts: 140, systemPowerInWatts: 65.0, systemLoadWatts: 20.0, batteryPowerWatts: 45.0)
            model.refresh(); await model.waitForPendingOperations()
            expect(model.battery.powerFlow?.adapterWatts == 140, "refreshed model reflects updated adapterWatts")
            expect(model.battery.powerFlow?.systemPowerInWatts == 65.0, "refreshed model reflects updated systemPowerInWatts")
            expect(model.battery.powerFlow?.batteryPowerWatts == 45.0, "refreshed model reflects charging battery power")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }

        // (l) Charge to Full Now & Resume Charge Limit lifecycle.
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true
            f.config.manualLimit = 80
            f.config.smartEnabled = false
            f.hardwareLimit = (limit: 80, enabled: true)
            f.battery = BatteryInfo(present: true, installed: true, percent: 80, externalConnected: true)
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            expect(!model.temporaryFullChargeActive, "initial temporaryFullChargeActive is false")

            model.chargeToFullNow(); await model.waitForPendingOperations()
            expect(f.chargeToFullNowCalls == 1, "chargeToFullNow calls service")
            expect(model.temporaryFullChargeActive, "temporaryFullChargeActive becomes true")
            f.limitWrites.removeAll()

            // Refresh while temporaryFullChargeActive is true must NOT re-enforce 80%
            model.refresh(); await model.waitForPendingOperations()
            expect(f.limitWrites.isEmpty, "refresh during temporary full charge does not re-enforce limit")

            // Resume charge limit re-applies 80%
            model.resumeChargeLimit(); await model.waitForPendingOperations()
            expect(!model.temporaryFullChargeActive, "resumeChargeLimit clears temporaryFullChargeActive")
            expect(f.limitWrites == [80], "resumeChargeLimit re-applies 80% limit")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }


        // Canceling uninstall must reconcile the still-persisted lid intent.
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.helper.installed = true
            f.config.keepAwake = true; f.config.keepAwakeOnLidClosed = true
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            let before = f.helper.writes.count
            f.helper.uninstallError = HelperError(message: "User canceled (-128)", status: 1)
            model.removeHelper()
            await model.waitForPendingOperations()
            expect(model.keepAwakeOnLidClosed && model.helperInstalled, "canceled removal preserves installed helper and intent")
            expect(f.helper.writes.dropFirst(before).contains(false) && f.helper.writes.last == true,
                   "canceled removal restores ON after the pre-uninstall OFF")
            expect(model.helperStatus == nil, "canceled removal does not leave a stale error")
            f.away.isAway = true; f.awayCallback?(f.away)
            await settle(); await model.waitForPendingOperations()
            model.removeHelper(); await model.waitForPendingOperations()
            expect(model.bagGuardActive && f.helper.writes.last == false,
                   "canceled removal cannot bypass a newly active bag guard")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }

        // Energy mode reflects the current source on every refresh, and a
        // selected-mode click remains a valid explicit reapplication.
        do {
            let f = ModelFixture(); defer { f.clean() }
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            f.energyMode = .highPower
            model.refresh(); await model.waitForPendingOperations()
            expect(model.energyMode == .highPower, "external energy-mode change reaches the UI")
            model.setEnergyMode(.highPower); await model.waitForPendingOperations()
            expect(f.helper.powerModeWrites == [2], "clicking the cached mode still executes a real request")
            f.energyMode = .lowPower
            f.application.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
            await settle(); await model.waitForPendingOperations()
            expect(model.energyMode == .lowPower, "power-source notification refreshes energy mode")
            f.energyMode = .automatic // snapshot will differ from the last visible low-power mode
            f.hardwareReadDelay = .milliseconds(100)
            var observedModes: [EnergyMode] = []
            let modeObservation = model.$energyMode.sink { observedModes.append($0) }
            model.refresh(); await Task.yield()
            model.setEnergyMode(.highPower)
            await model.waitForPendingOperations()
            expect(!observedModes.contains(.automatic),
                   "a pre-write snapshot is discarded instead of publishing its stale mode")
            expect(model.energyMode == .highPower, "fresh post-write snapshot observes requested high-power mode")
            modeObservation.cancel()
            f.hardwareReadDelay = .zero
            f.energyMode = .lowPower
            model.refresh(); await model.waitForPendingOperations()
            f.helper.powerModeError = HelperError(message: "denied")
            model.setEnergyMode(.automatic); await model.waitForPendingOperations()
            expect(model.lastError == "denied" && model.energyMode == .lowPower,
                   "failed mode write preserves observed mode and surfaces error")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }

        // A delayed private API must not block the main actor, and repeated
        // refresh requests must be coalesced instead of spawning 30 reads.
        do {
            let f = ModelFixture(); defer { f.clean() }
            let gate = AsyncTestGate(); defer { gate.open() }
            var services = f.services()
            let read = services.readHardware
            services.readHardware = { await gate.hold(); return await read() }
            let model = AppModel(services: services)
            let entered = await gate.waitForEntry()
            for _ in 0..<30 { model.refresh() }
            expect(entered && model.refreshBusy,
                   "main actor remains responsive while the hardware snapshot is delayed")
            gate.open()
            await model.waitForPendingOperations()
            expect(f.hardwareReads <= 2, "rapid refresh notifications coalesce into at most one follow-up read")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }

        // A snapshot started before an explicit user write cannot revert that
        // intent; pending writes also retain the newest target in their order.
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            f.hardwareReadDelay = .milliseconds(100)
            model.refresh(); await Task.yield()
            model.applyLimit(85)
            await model.waitForPendingOperations()
            expect(model.manualLimit == 85 && model.currentLimit == 85 && f.limitWrites == [85],
                   "stale refresh cannot adopt old 80 percent over explicit 85 percent intent")
            f.hardwareReadDelay = .zero; f.limitWriteDelay = .milliseconds(60)
            model.applyLimit(90)
            try? await Task.sleep(for: .milliseconds(10))
            model.applyLimit(95)
            await model.waitForPendingOperations()
            expect(f.limitWrites.suffix(2) == [90, 95] && model.currentLimit == 95 && model.manualLimit == 95,
                   "delayed older write completes before newest target, which wins")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }

        // Use the production executor, including its timeout and admission
        // failure, to prove a newer write is retried when the old call returns.
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true
            f.config.refreshSeconds = 3600
            let state = DelayedChargeFixture()
            let io = HardwareIO(label: "coddle.integration.delayed-charge")
            var services = f.services()
            let read = services.readHardware
            services.readHardware = {
                switch await read() {
                case .success(var snapshot):
                    snapshot.currentLimit = state.limit
                    return .success(snapshot)
                case .failure(let error): return .failure(error)
                }
            }
            services.subscribeHardwareRecovery = { handler in
                io.onRecovery { Task { @MainActor in handler() } }
            }
            services.setLimit = { target in
                switch await io.run(timeout: 0.025, { state.write(target); return true }) {
                case .success: return nil
                case .failure(let error): return error
                }
            }
            let model = AppModel(services: services)
            await model.waitForPendingOperations()
            state.nextDelay = 0.12
            model.applyLimit(85)
            try? await Task.sleep(for: .milliseconds(10))
            model.applyLimit(90)
            await model.waitForPendingOperations()
            expect(model.lastError != nil && model.manualLimit == 90,
                   "timeout/busy is visible while latest user intent is retained")
            // Wait for the automatic recovery outcome, rather than assuming
            // the executor and UI actor are scheduled within exactly 160 ms.
            // No refresh is triggered by this wait.
            for _ in 0..<100 {
                if state.limit == 90 && model.currentLimit == 90 { break }
                try? await Task.sleep(for: .milliseconds(20))
                await model.waitForPendingOperations()
            }
            print("Recovery probe: writes=\(state.writes) hardware=\(state.limit) model=\(String(describing: model.currentLimit)) intent=\(model.manualLimit) error=\(String(describing: model.lastError)) status=\(String(describing: model.chargeOperationStatus))")
            expect(state.writes == [85, 90] && state.limit == 90 && model.currentLimit == 90,
                   "late completion automatically retries latest target without a periodic refresh")
            expect(model.manualLimit == 90 && model.lastError == nil,
                   "uncertain old write never replaces persisted latest intent")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }

        // Native temporary-full support is distinct from ordinary limit support;
        // resuming must write even when macOS preserves the configured limit.
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true; f.supportsTemporaryFullCharge = false
            f.battery.externalConnected = true
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            model.chargeToFullNow(); await model.waitForPendingOperations()
            expect(!model.temporaryFullChargeSupported && f.chargeToFullNowCalls == 0,
                   "unsupported temporary override cannot permanently disable charge limit")
            f.supportsTemporaryFullCharge = true; f.preserveLimitDuringTemporaryFull = true
            model.refresh(); await model.waitForPendingOperations()
            model.chargeToFullNow(); await model.waitForPendingOperations()
            expect(model.temporaryFullChargeActive && model.currentLimit == 80 && f.limitWrites.isEmpty,
                   "temporary override preserves native configured limit without reasserting it")
            model.resumeChargeLimit(); await model.waitForPendingOperations()
            expect(f.limitWrites == [80] && !model.temporaryFullChargeActive,
                   "resume explicitly reasserts limit even when readback was unchanged")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }


        // A timed-out temporary request must stop suppressing normal limit
        // reconciliation if its power source/capabilities change before the
        // executor's recovery callback reaches the model.
        for transition in ["unplugged", "full", "temporaryUnsupported", "limitsUnsupported"] {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true; f.battery.externalConnected = true
            f.nextTemporaryFullError = HardwareFailure(message: "operation still pending", awaitingRecovery: true)
            let model = AppModel(services: f.services())
            await model.waitForPendingOperations()
            model.chargeToFullNow(); await model.waitForPendingOperations()
            expect(f.chargeToFullNowCalls == 1 && f.limitWrites.isEmpty,
                   "temporary recovery is pending before \(transition)")
            switch transition {
            case "unplugged": f.battery.externalConnected = false
            case "full": f.battery.percent = 100; f.battery.fullyCharged = true
            case "temporaryUnsupported": f.supportsTemporaryFullCharge = false
            default: f.supportsLimit = false
            }
            // The uncertain operation's readback must not replace user intent.
            f.hardwareLimit = (90, true)
            model.refresh(); await model.waitForPendingOperations()
            f.hardwareRecoveryCallback?()
            await model.waitForPendingOperations()
            if transition == "limitsUnsupported" {
                expect(f.limitWrites.isEmpty && model.manualLimit == 80,
                       "unavailable charge control retains original intent without writing")
                f.supportsLimit = true
                model.refresh(); await model.waitForPendingOperations()
            }
            expect(f.limitWrites == [80] && model.manualLimit == 80 && f.config.manualLimit == 80,
                   "\(transition) cancels stale temporary recovery and restores the original target")
            expect(!model.temporaryFullChargeActive && f.chargeToFullNowCalls == 1 && model.currentLimit == 80,
                   "\(transition) cannot revive or indefinitely suppress normal limit reconciliation")
            model.shutdownKeepAwake(); await model.waitForPendingOperations()
        }

        await mainActorOperationTests()
        await responsivenessTests()
        await persistenceTests()
        await uxAcceptance()
        await onboardingAcceptance()
        print("coddle-integration-tests: \(checks) checks passed")
    }
    @MainActor static func uxAcceptance() async {
        // Warm-up is exposed without weakening the existing protection predicate.
        var detector = AwayDetector()
        let now = Date(timeIntervalSince1970: 1000)
        let first = detector.sample(key: nil, now: now)
        let offline = detector.sample(key: nil, now: now.addingTimeInterval(72000))
        expect(!first.protectionReady && !offline.isAway && !offline.protectionReady, "untrained offline guard reports not ready")
        detector.load(dwell: ["home": 7200])
        let ready = detector.sample(key: "home", now: now.addingTimeInterval(72001))
        expect(ready.protectionReady && ready.isUsual, "learned guard reports ready")

        // Display is subordinate to the master, independently of away detection.
        for system in [false, true] { for screen in [false, true] { for guardOn in [false, true] {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = system; f.config.keepDisplayAwake = screen
            f.config.awayDetectionEnabled = guardOn
            let m = AppModel(services: f.services()); await m.waitForPendingOperations()
            expect(m.systemAwakeApplied == system && m.displayAwakeApplied == (system && screen), "display assertion requires the master")
            m.keepAwake = false; m.keepDisplayAwake = false
            await m.waitForPendingOperations()
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        } } }
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true; f.config.keepDisplayAwake = true
            var rejectRelease = false
            var services = f.services()
            services.setSystemAwake = { on in !(rejectRelease && !on) }
            services.setDisplayAwake = { on in !(rejectRelease && !on) }
            let m = AppModel(services: services); await m.waitForPendingOperations()
            rejectRelease = true; m.keepAwake = false; m.keepDisplayAwake = false
            await m.waitForPendingOperations()
            expect(m.systemAwakeApplied && m.displayAwakeApplied && m.lastError != nil, "failed assertion release retains last applied state")
            rejectRelease = false; m.keepAwake = false; m.keepDisplayAwake = false
            await m.waitForPendingOperations()
            expect(!m.systemAwakeApplied && !m.displayAwakeApplied && m.lastError == nil, "successful assertion retry confirms release")
            f.helper.installed = true
            m.setKeepAwakeEnabled(true); await m.waitForPendingOperations()
            m.keepAwakeOnLidClosed = true; await m.waitForPendingOperations()
            f.helper.writeError = HelperError(message: "release unconfirmed")
            m.keepAwakeOnLidClosed = false; await m.waitForPendingOperations()
            expect(m.lidStateUnconfirmed && m.helperStatus != nil, "failed lid OFF remains visibly unconfirmed")
            f.helper.writeError = nil; m.keepAwakeOnLidClosed = false; await m.waitForPendingOperations()
            expect(!m.lidStateUnconfirmed && !m.lidAwakeApplied, "lid OFF retry confirms release")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true; f.config.keepAwakeOnLidClosed = true
            var services = f.services(); services.helper.filesPresent = { true }
            let m = AppModel(services: services); await m.waitForPendingOperations()
            expect(m.helperFilesPresent && !m.helperInstalled && !m.lidAwakeApplied, "installed but unreachable helper can be removed")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            var invalid = false, saveFails = false
            var services = f.services()
            services.loadConfig = { if invalid { throw NSError(domain: "bad-json", code: 1) }; return f.config }
            services.saveConfig = { if saveFails { throw NSError(domain: "read-only", code: 1) }; f.config = $0; f.saved.append($0) }
            let m = AppModel(services: services); await m.waitForPendingOperations()
            m.keepAwake = true
            await m.waitForPendingOperations()
            let saves = f.saved.count
            invalid = true; m.reloadConfig(); await m.waitForPendingOperations()
            expect(m.keepAwake && m.configError == "config.loadFailed" && f.saved.count == saves, "invalid reload retains state without writes")
            invalid = false; m.reloadConfig(); await m.waitForPendingOperations()
            saveFails = true; m.iconOnly = true; await m.waitForPendingOperations()
            expect(m.configError == "config.saveFailed" && m.iconOnly && !f.config.iconOnly, "failed persistence reports session-only setting")
            saveFails = false; m.saveConfig(); await m.waitForPendingOperations()
            expect(m.configError == nil && f.config.iconOnly, "save retry clears persistent notice")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("config.json")
            let initial = try! ConfigStore.read(at: file)
            expect(!FileManager.default.fileExists(atPath: file.path) && initial.manualLimit == 80, "first launch reads defaults without creating config before setup")
            let bad = Data("{bad config".utf8); try! bad.write(to: file)
            do { _ = try ConfigStore.read(at: file); fatalError("invalid JSON accepted") } catch {}
            expect((try! Data(contentsOf: file)) == bad, "failed config read leaves original bytes unchanged")
            let f = ModelFixture(); defer { f.clean() }
            var services = f.services(); services.loadConfig = { try ConfigStore.read(at: file) }
            let m = AppModel(services: services); await m.waitForPendingOperations()
            m.keepAwake = true
            expect(m.configError != nil && f.saved.isEmpty, "invalid startup blocks accidental config overwrite")
            try! ConfigStore.save(CoddleConfig(), at: file); m.reloadConfig(); await m.waitForPendingOperations()
            expect(m.configError == nil && !m.keepAwake, "repaired config can reload")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true
            let m = AppModel(services: f.services()); await m.waitForPendingOperations()
            f.limitWriteDelay = .milliseconds(150); m.applyLimit(85)
            expect(m.chargeLimitBusy && m.chargeDisplaySelection == 85 && m.currentLimit == 80, "pending charge intent and confirmed value remain distinct")
            await m.waitForPendingOperations()
            expect(m.currentLimit == 85 && m.chargeOperationStatus == nil, "successful request removes pending status")
            f.nextLimitError = "rejected"; m.applyLimit(90); await m.waitForPendingOperations()
            expect(m.chargeDisplaySelection == 90 && m.currentLimit == 85 && m.chargeOperationStatus == "charge.retrying", "failed charge keeps target plus last confirmation")
            f.nextLimitError = nil
            f.battery.externalConnected = true; m.refresh(); await m.waitForPendingOperations()
            m.chargeToFullNow()
            expect(m.chargeOperationTarget == 100 && m.chargeOperationStatus == "charge.applying", "temporary request progress names its actual 100 percent target")
            await m.waitForPendingOperations()
            expect(m.temporaryFullChargeActive && m.chargeOperationStatus == nil, "temporary success is not confused with a failed fixed request")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.showInDock = true
            let m = AppModel(services: f.services()); await m.waitForPendingOperations()
            m.setShowInDock(false)
            expect(m.dockRestartPending && m.dockIconActive && !m.showInDock, "Dock hide shows pending restart")
            m.setShowInDock(true); expect(!m.dockRestartPending, "Dock promotion applies live")
            f.login = .enabled; f.application.post(name: NSApplication.didBecomeActiveNotification, object: nil); await settle()
            expect(m.launchAtLogin, "return from system approval refreshes login state")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
        do {
            let f = ModelFixture(); defer { f.clean() }
            var count = 0
            var services = f.services()
            services.notificationStatus = { "notification.denied" }
            services.testNotification = { count += 1; return "notification.denied" }
            let m = AppModel(services: services); await settle()
            expect(m.notificationStatus == "notification.denied", "notification permission is visible before threshold")
            m.testLowBatteryNotification(); await settle()
            expect(count == 0 && m.lowBatteryReminder == .disabled && !m.notificationBusy, "disabled reminder never sends a test or re-prompts")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
        for lead in [0, 2] {
            let f = ModelFixture(); defer { f.clean() }
            f.config.smartEnabled = true; f.config.topupLeadHours = lead
            let m = AppModel(services: f.services()); await m.waitForPendingOperations()
            expect(m.smartPlanKey == (lead == 0 ? "smart.topupOff" : "smart.learning"), "smart learning and disabled top-up are distinct")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
    }

}


/// Delays only the first write without touching any real system dependency.
private final class DelayedChargeFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedLimit = 80
    private var storedWrites: [Int] = []
    private var storedDelay: TimeInterval = 0
    var nextDelay: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return storedDelay }
        set { lock.lock(); storedDelay = newValue; lock.unlock() }
    }
    var limit: Int { lock.lock(); defer { lock.unlock() }; return storedLimit }
    var writes: [Int] { lock.lock(); defer { lock.unlock() }; return storedWrites }
    func write(_ target: Int) {
        lock.lock(); let delay = storedDelay; storedDelay = 0; lock.unlock()
        Thread.sleep(forTimeInterval: delay)
        lock.lock(); storedWrites.append(target); storedLimit = target; lock.unlock()
    }
}
