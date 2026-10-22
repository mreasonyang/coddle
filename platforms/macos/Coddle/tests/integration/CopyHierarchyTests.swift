import Foundation

extension IntegrationTests {
    @MainActor static func copyHierarchyTests() async {
        do {
            let f = ModelFixture(); defer { f.clean() }
            var opensSettings = false
            var services = f.services()
            services.openDisplaySettings = {
                f.displaySettingsRequests += 1
                return opensSettings
            }
            let m = AppModel(services: services); await m.waitForPendingOperations()
            m.openDisplayTimeoutSettings()
            expect(!m.canSleepDisplayNow && m.awakeFeedbackIssues.first(where: { $0.id == .display })?.action == .retrySettings,
                   "settings-opening failure retries the settings route even when display sleep is unavailable")
            opensSettings = true
            m.openDisplayTimeoutSettings()
            expect(m.displaySleepStatus == nil && f.displaySettingsRequests == 2 && f.displaySleepRequests == 0,
                   "successful settings retry clears its own failure without requesting display sleep")
            m.sleepDisplayNow()
            let unrelatedStatus = m.displaySleepStatus
            m.openDisplayTimeoutSettings()
            expect(unrelatedStatus != nil && m.displaySleepStatus == unrelatedStatus && f.displaySleepRequests == 0,
                   "opening settings never clears an unrelated failed display-sleep action")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        // Ordinary success is quiet, and reading presentation has no side effects.
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true
            f.away.protectionReady = true
            let m = AppModel(services: f.services()); await m.waitForPendingOperations()
            expect(m.awakeFeedbackIssues.isEmpty && !m.hasAwakeFeedback,
                   "confirmed ordinary ON needs no repeated status prose")
            let before = (f.saved.count, f.systemAssertions.count, f.displayAssertions.count, f.helper.writes.count)
            for _ in 0..<10 { _ = m.awakeFeedbackIssues; _ = m.awakeCollapsedFeedbackKeys }
            expect(before == (f.saved.count, f.systemAssertions.count, f.displayAssertions.count, f.helper.writes.count),
                   "copy hierarchy is read-only")
            m.sleepDisplayNow(); await m.waitForPendingOperations()
            expect(m.awakeFeedbackIssues.contains { $0.id == .display && $0.summaryKey == "display.requested" && $0.isReceipt },
                   "screen action reports a request, not proof of a dark screen")
            expect(!m.hasAwakeFeedback && m.awakeCollapsedFeedbackKeys.isEmpty,
                   "ordinary request receipt does not replace the normal explanation or collapsed state")
            m.setKeepAwakeEnabled(false); await m.waitForPendingOperations()
            expect(m.awakeFeedbackIssues.isEmpty, "verified successful stop is quiet")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true; f.config.keepAwakeOnLidClosed = true
            f.away.protectionReady = true
            let m = AppModel(services: f.services()); await m.waitForPendingOperations()
            let lid = m.awakeFeedbackIssues.filter { $0.id == .lid }
            expect(lid.count == 1 && lid.first?.summaryKey == "helper.lidRequired" && lid.first?.action == .install,
                   "missing component has one explicit install requirement")
            expect(m.hasAwakeFeedback && m.awakeCollapsedFeedbackKeys == ["helper.lidRequired"],
                   "missing component remains discoverable while collapsed")
            expect(!m.helperBusy && !m.helperInstalled, "requesting lid mode never implicitly starts installation")
            f.helper.installGate = DispatchSemaphore(value: 0)
            m.installHelper()
            expect(m.helperBusy && m.awakeFeedbackIssues.filter { $0.id == .lid }.count == 1,
                   "explicit installation keeps one stable component cause while busy")
            f.helper.installGate?.signal(); await waitForInstall(m)
            expect(m.awakeFeedbackIssues.isEmpty && m.lidAwakeApplied,
                   "confirmed installation and lid readback resolve the requirement")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.clamshell = nil
            f.config.keepAwake = true; f.config.keepAwakeOnLidClosed = true
            let m = AppModel(services: f.services()); await m.waitForPendingOperations()
            expect(!m.awakeFeedbackIssues.contains { $0.action == .install },
                   "a retained lid preference on hardware without a lid does not request an installation")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            let m = AppModel(services: f.services()); await m.waitForPendingOperations()
            f.helper.installError = HelperError(message: "fixture installation transport diagnostic")
            m.installHelper(); await waitForInstall(m)
            expect(!m.awakeRepresentsHelperStatus && !m.awakeHasLidControlResponsibility,
                   "optional component install failure does not invent a prior lid-control owner")
            expect(m.awakeFeedbackIssues.count == 1 && m.awakeFeedbackIssues.first?.id == .component &&
                   m.awakeFeedbackIssues.first?.diagnostics == ["fixture installation transport diagnostic"],
                   "independent component failure keeps a compact management summary and diagnostic")
            expect(m.awakeCollapsedFeedbackKeys == ["awakeFeedback.componentUnavailable"],
                   "component lifecycle failure does not disappear when compact controls expand")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        // Guard activation is a request until every owned control is released.
        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true; f.config.keepDisplayAwake = true
            f.config.keepAwakeOnLidClosed = true; f.helper.installed = true
            f.away.protectionReady = true
            var holdOff = false
            var resumeOff: CheckedContinuation<Void, Never>?
            var services = f.services()
            services.setSystemAwake = { on in
                if holdOff && !on {
                    holdOff = false
                    await withCheckedContinuation { resumeOff = $0 }
                }
                if f.assertionFailure { return false }
                f.systemAssertions.append(on); return true
            }
            let m = AppModel(services: services); await m.waitForPendingOperations()
            let l10n = Localizer(language: "en")
            holdOff = true; f.away.isAway = true; f.awayCallback?(f.away)
            for _ in 0..<500 where resumeOff == nil { try? await Task.sleep(for: .milliseconds(2)) }
            expect(resumeOff != nil && m.bagGuardActive && !m.isGuardPauseConfirmed,
                   "pending assertion release never claims a successful protective pause")
            expect(m.guardStatusText(l10n) == l10n.tr("awakeFeedback.pauseUnconfirmed"),
                   "Away group status distinguishes triggered protection from confirmed release")
            resumeOff?.resume(); resumeOff = nil; await m.waitForPendingOperations()
            expect(m.isGuardPauseConfirmed && m.awakeCollapsedFeedbackKeys == ["awakeFeedback.paused"],
                   "only actual release establishes the protective pause")
            f.away.isAway = false; f.awayCallback?(f.away)
            await settle(); await m.waitForPendingOperations()
            f.assertionFailure = true
            f.helper.sleepDisabled = nil
            f.helper.writeError = HelperError(message: "fixture uncertain release")
            f.away.isAway = true; f.awayCallback?(f.away)
            await settle(); await m.waitForPendingOperations()
            expect(!m.isGuardPauseConfirmed && m.lidStateUnconfirmed,
                   "unknown lid state and failed assertions cannot become a successful pause")
            expect(m.awakeFeedbackIssues.filter { $0.id == .controls }.count == 1 &&
                   m.awakeFeedbackIssues.filter { $0.id == .lid }.count == 1,
                   "independent assertion and lid failures both remain visible exactly once")
            expect(m.awakeFeedbackIssues.first(where: { $0.id == .controls })?.summaryKey == "awakeFeedback.pauseUnconfirmed" &&
                   m.awakeCollapsedFeedbackKeys.contains("awakeFeedback.pauseUnconfirmed"),
                   "a failed protective release reports pause uncertainty, not failed activation")
            expect(!m.awakeCollapsedFeedbackKeys.contains("awakeFeedback.paused") &&
                   m.awakeFeedbackIssues.first(where: { $0.id == .lid })?.summaryKey == "awakeFeedback.stopLidUnconfirmed",
                   "collapsed release risk keeps the lid-open guidance instead of a success claim")
            f.assertionFailure = false; f.helper.writeError = nil
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        // Config persistence and release are different facts, including later
        // observations that invalidate an older confirmed stop report.
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coddle-copy-feedback-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = OnboardingStore(directory: directory)
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true; f.config.keepAwakeOnLidClosed = true
            f.helper.installed = true; f.away.protectionReady = true
            try! ConfigStore.save(f.config, at: store.configURL)
            let m = AppModel(services: f.services(), onboardingStore: store)
            await m.waitForPendingOperations()
            f.configSaveError = NSError(domain: "fixture.persistence", code: 1)
            m.setKeepAwakeEnabled(false); await m.waitForPendingOperations()
            expect(m.awakeStopConfirmed && m.awakeOwnsConfigError,
                   "the stop owns only its matching failed config-save revision")
            expect(m.awakeCollapsedFeedbackKeys == ["awakeFeedback.stoppedSaveFailed"],
                   "save-only failure explicitly reports current stop success")
            expect(m.onboarding?.record.stopPending == true && store.bootstrap().record.stopPending,
                   "save failure keeps the real temporary recovery journal pending")
            for actual: Bool? in [nil, true] {
                f.helper.sleepDisabled = actual
                f.helper.writeError = HelperError(message: "fixture late reconciliation failure")
                m.refreshHelperInstalled(); await m.waitForPendingOperations()
                expect(m.taskStopLid == .confirmed && !m.awakeStopConfirmed,
                       "later unknown or ON readback invalidates an older confirmed stop presentation")
                expect(m.awakeCollapsedFeedbackKeys.contains("awakeFeedback.stopLidUnconfirmed") &&
                       m.awakeCollapsedFeedbackKeys.contains("awakeFeedback.stopSaveFailed") &&
                       !m.awakeCollapsedFeedbackKeys.contains("awakeFeedback.stoppedSaveFailed"),
                       "late uncertain cleanup and unsaved state retain two independent truthful facts")
            }
            _ = await m.saveConfig().value
            expect(m.configError != nil && !m.awakeOwnsConfigError,
                   "an independent later save failure is not swallowed merely because its text matches")
            f.configSaveError = nil; f.helper.writeError = nil
            m.retryAwakeFeedback(); await m.waitForPendingOperations()
            expect(m.awakeFeedbackIssues.isEmpty && !store.bootstrap().record.stopPending,
                   "successful retry clears both release and persistence obligations")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.config.keepAwake = true
            var loadFails = false
            var services = f.services()
            services.loadConfig = {
                if loadFails { throw NSError(domain: "fixture.load", code: 1) }
                return f.config
            }
            let m = AppModel(services: services); await m.waitForPendingOperations()
            f.configSaveError = NSError(domain: "fixture.save", code: 1)
            m.setKeepAwakeEnabled(false); await m.waitForPendingOperations()
            expect(m.awakeOwnsConfigError, "stop-save error initially belongs to its own recovery issue")
            loadFails = true
            m.reloadConfig(); await m.waitForPendingOperations()
            expect(m.configError == "config.loadFailed" && !m.awakeOwnsConfigError && !m.configCanRetrySave,
                   "a later config-load failure remains independent and never inherits stop-save ownership")
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }

        do {
            let f = ModelFixture(); defer { f.clean() }
            f.supportsLimit = true
            let m = AppModel(services: f.services()); await m.waitForPendingOperations()
            f.helper.powerModeError = HelperError(message: "fixture energy failure")
            m.setEnergyMode(.lowPower); await m.waitForPendingOperations()
            m.applyLimit(85); await m.waitForPendingOperations()
            expect(m.lastError == nil && m.energyFeedbackError == "fixture energy failure",
                   "unrelated charge success may clear the legacy slot but retains energy failure")
            expect(m.globalError(excluding: [.charging]) == "fixture energy failure" &&
                   m.hasPersistentGlobalError(excluding: [.charging]),
                   "a page without energy controls still exposes the unresolved energy cause")
            expect(m.globalError(excluding: [.energy, .charging]) == nil,
                   "a domain is suppressed only when that view represents it locally")
            f.assertionFailure = true
            m.setKeepAwakeEnabled(true); await m.waitForPendingOperations()
            m.lastError = m.awakeFeedbackError
            expect(m.globalError(excluding: [.awake, .energy]) == m.lastError && m.lastError != nil,
                   "generic equal-text errors do not acquire another operation's ownership")
            expect(!m.hasPersistentGlobalError(excluding: [.awake, .energy, .charging]),
                   "only unrepresented persistent domains prevent generic banner dismissal")
            f.assertionFailure = false; f.helper.powerModeError = nil
            m.shutdownKeepAwake(); await m.waitForPendingOperations()
        }
    }
}
