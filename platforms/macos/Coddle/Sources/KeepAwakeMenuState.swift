/// Presentation only: observing this state never changes a power preference.
enum KeepAwakeMenuState: String, CaseIterable {
    case off, on, pending, stopping, paused, attention

    var localizationKey: String {
        switch self {
        case .off: return "awakeMenu.off"
        case .on: return "awakeMenu.on"
        case .pending: return "awakeMenu.pending"
        case .stopping: return "awakeMenu.stopping"
        case .paused: return "awakeMenu.paused"
        case .attention: return "awakeMenu.attention"
        }
    }
    var hasException: Bool { self != .off && self != .on }
}

@MainActor
extension AppModel {
    var keepAwakeMenuState: KeepAwakeMenuState {
        if taskStopBusy { return .stopping }

        let sleepNeedsAttention = displaySleepStatus.map {
            !$0.isEmpty && $0 != "display.preparing" && $0 != "display.requested" &&
                !($0 == "display.protected" && bagGuardActive)
        } ?? false
        let guardNeedsAttention = keepAwake && keepAwakeOnLidClosed &&
            (!awayDetectionEnabled || !awayStatus.protectionReady)
        if onboarding?.record.stopPending == true ||
            ["onboarding.stopPartial", "onboarding.stopSaveFailed"].contains(taskStopStatus) ||
            awakeFeedbackError?.isEmpty == false || helperStatus?.isEmpty == false ||
            lidStateUnconfirmed || sleepNeedsAttention || guardNeedsAttention {
            return .attention
        }

        if helperBusy || assertionsApplying || displaySleepBusy { return .pending }
        let allReleased = !systemAwakeApplied && !displayAwakeApplied && !lidAwakeApplied
        if bagGuardActive {
            if !allReleased { return .pending }
            return keepAwake ? .paused : .off
        }
        if !keepAwake { return allReleased ? .off : .pending }
        return systemAwakeApplied && displayAwakeApplied == keepDisplayAwake &&
            lidAwakeApplied == keepAwakeOnLidClosed ? .on : .pending
    }
}
