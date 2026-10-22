/// An error belongs to the operation that published it, not its translated text.
enum FeedbackDomain: Hashable { case charging, energy, awake }

struct AwakeFeedbackIssue: Identifiable, Equatable {
    enum ID: String { case progress, controls, lid, persistence, protection, display, component }
    enum Action: Equatable { case retry, retryStop, install, protection, retryDisplay, retrySettings, component }
    let id: ID
    let summaryKey: String
    var diagnostics: [String] = []
    var action: Action? = nil
    var isReceipt = false
}

@MainActor
extension AppModel {
    var isGuardPauseConfirmed: Bool {
        bagGuardActive && !assertionsApplying && !awakeLidControlPending &&
            !systemAwakeApplied && !displayAwakeApplied && !lidAwakeApplied &&
            !lidStateUnconfirmed && awakeFeedbackError == nil
    }

    var awakeStopConfirmed: Bool {
        taskStopOrdinary == .confirmed && taskStopDisplay == .confirmed && taskStopLid == .confirmed &&
            !systemAwakeApplied && !displayAwakeApplied && !lidAwakeApplied && !lidStateUnconfirmed &&
            !assertionsApplying && !awakeLidControlPending && awakeFeedbackError == nil
    }

    var awakeRepresentsHelperStatus: Bool {
        helperStatus != nil && ((hasClamshell && keepAwake && keepAwakeOnLidClosed) ||
            lidAwakeApplied || (lidStateUnconfirmed && awakeHasLidControlResponsibility) || awakeStopNeedsRecovery)
    }

    /// Independent unresolved causes survive together. One cause has one summary,
    /// even when a failed command, readback and stop report describe it separately.
    var awakeFeedbackIssues: [AwakeFeedbackIssue] {
        var issues: [AwakeFeedbackIssue] = []
        let lidUnknown = lidStateUnconfirmed && awakeHasLidControlResponsibility
        let stopping = awakeStopNeedsRecovery || (!keepAwake &&
            (systemAwakeApplied || displayAwakeApplied || lidAwakeApplied || lidUnknown))
        let retry: AwakeFeedbackIssue.Action = stopping ? .retryStop : .retry
        let stopResultsExist = taskStopStatus != "" && taskStopStatus != "onboarding.stopped"
        let controlsStopUnknown = stopping && !taskStopBusy && stopResultsExist &&
            (taskStopOrdinary != .confirmed || taskStopDisplay != .confirmed)
        let controlsMismatch = !assertionsApplying && !bagGuardActive &&
            (systemAwakeApplied != keepAwake || displayAwakeApplied != (keepAwake && keepDisplayAwake))
        if awakeFeedbackError != nil || controlsStopUnknown || (stopping && controlsMismatch) {
            issues.append(.init(id: .controls,
                summaryKey: stopping ? "awakeFeedback.stopControlsUnconfirmed" :
                    bagGuardActive ? "awakeFeedback.pauseUnconfirmed" : "awakeFeedback.controlsUnconfirmed",
                diagnostics: [awakeFeedbackError].compactMap { $0 }, action: retry))
        }

        let wantsLid = hasClamshell && keepAwake && keepAwakeOnLidClosed
        let lidStopUnknown = stopping && !taskStopBusy && stopResultsExist && taskStopLid != .confirmed
        // Absent hardware does not require an optional installation. Previously
        // observed activity/unknown cleanup still remains visible on any machine.
        let needsComponent = wantsLid && !helperInstalled && !stopping
        let lidMismatch = !awakeLidControlPending && !bagGuardActive &&
            (wantsLid != lidAwakeApplied) && (wantsLid || lidAwakeApplied)
        if needsComponent {
            issues.append(.init(id: .lid,
                summaryKey: helperFilesPresent ? "awakeFeedback.componentUnavailable" : "helper.lidRequired",
                diagnostics: [helperStatus].compactMap { $0 }, action: .install))
        } else if lidUnknown || lidStopUnknown || lidMismatch || awakeRepresentsHelperStatus {
            issues.append(.init(id: .lid,
                summaryKey: stopping || bagGuardActive ? "awakeFeedback.stopLidUnconfirmed" : "awakeFeedback.lidUnconfirmed",
                diagnostics: [helperStatus].compactMap { $0 }, action: retry))
        } else if let helperStatus {
            // The compact panel has no component-management section. Preserve its
            // independent lifecycle failure there, with a route to management.
            issues.append(.init(id: .component, summaryKey: "awakeFeedback.componentUnavailable",
                diagnostics: [helperStatus], action: .component))
        }

        if taskStopStatus == "onboarding.stopSaveFailed" {
            issues.append(.init(id: .persistence,
                summaryKey: awakeStopConfirmed ? "awakeFeedback.stoppedSaveFailed" : "awakeFeedback.stopSaveFailed",
                diagnostics: awakeOwnsConfigError ? [configError].compactMap { $0 } : [], action: .retryStop))
        }

        if keepAwake && !stopping {
            if bagGuardActive {
                if isGuardPauseConfirmed {
                    issues.append(.init(id: .protection, summaryKey: "awakeFeedback.paused"))
                } else if !issues.contains(where: { $0.id == .controls || $0.id == .lid }) {
                    issues.append(.init(id: .protection, summaryKey: "awakeFeedback.pauseUnconfirmed",
                        action: assertionsApplying || awakeLidControlPending ? nil : .retry))
                }
            } else if wantsLid && (!awayDetectionEnabled || !awayStatus.protectionReady) {
                issues.append(.init(id: .protection,
                    summaryKey: awayDetectionEnabled ? "awakeFeedback.guardUnavailable" : "awakeFeedback.guardDisabled",
                    action: .protection))
            }
        }

        if taskStopBusy {
            issues.insert(.init(id: .progress, summaryKey: "onboarding.stopping"), at: 0)
        } else if issues.isEmpty && (assertionsApplying || helperBusy ||
            (keepAwake && !bagGuardActive && (controlsMismatch || lidMismatch))) {
            issues.append(.init(id: .progress, summaryKey: "panel.awake.pending"))
        } else if stopping && issues.isEmpty {
            // A durable unfinished stop remains actionable even before readback.
            issues.append(.init(id: .progress, summaryKey: "awakeFeedback.stopControlsUnconfirmed", action: .retryStop))
        }

        if let status = displaySleepStatus {
            let sameProtection = status == "display.protected" && bagGuardActive && keepAwake
            let sameControls = status == "display.assertionFailed" && issues.contains { $0.id == .controls }
            if !sameProtection && !sameControls {
                let receipt = status == "display.requested"
                issues.append(.init(id: .display, summaryKey: status,
                    action: status == "display.settingsFailed" ? .retrySettings :
                        receipt || displaySleepBusy || !canSleepDisplayNow ? nil : .retryDisplay,
                    isReceipt: receipt))
            }
        }
        return issues
    }

    var hasAwakeFeedback: Bool { awakeFeedbackIssues.contains { !$0.isReceipt && $0.id != .component } }
    var awakeCollapsedFeedbackKeys: [String] { awakeFeedbackIssues.filter { !$0.isReceipt }.map(\.summaryKey) }
}
