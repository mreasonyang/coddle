import Foundation
import CoreGraphics

enum DisplaySleepResult: Sendable {
    case requested, unavailable, failed

    var statusKey: String {
        switch self {
        case .requested: return "display.requested"
        case .unavailable: return "display.unavailable"
        case .failed: return "display.failed"
        }
    }
}

/// One explicit system request; no brightness control, wake request or retry timer.
enum DisplaySleep {
    static func request() async -> DisplaySleepResult {
        await Task.detached(priority: .userInitiated) {
            var count: UInt32 = 0
            guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
                return .unavailable
            }
            let result = BoundedIO.run("/usr/bin/pmset", arguments: ["displaysleepnow"], timeout: 5)
            return commandResult(status: result.status, output: result.output)
        }.value
    }

    static func commandResult(status: Int32, output: String) -> DisplaySleepResult {
        // pmset's displaySleepNow is void: some WindowServer failures are
        // printed to stderr without a nonzero process status.
        status == 0 && output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .requested : .failed
    }
}
