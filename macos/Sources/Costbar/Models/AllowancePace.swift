import CostbarKit
import Foundation

/// How an allowance is tracking against its own clock.
///
/// The arithmetic lives in the Zig core (`costbar_allowance_pace`) so every
/// consumer of a snapshot reaches the same verdict; this is only the Swift
/// shape of its answer.
struct AllowancePace: Equatable {
    enum Outlook: Equatable {
        /// The current burn rate empties the allowance before the reset.
        case emptiesAt(Date)
        case lastsUntilReset
    }

    /// Percentage points spent above (positive) or below (negative) an even burn.
    let deviationPoints: Double
    let outlook: Outlook
    let resetsAt: Date

    /// Points of slack before a deviation is worth naming in either direction.
    static let deadbandPoints = 1.5

    var isOverspending: Bool { deviationPoints > Self.deadbandPoints }
    var isUnderspending: Bool { deviationPoints < -Self.deadbandPoints }

    /// Nil whenever the core reports no honest verdict: no reset, no window
    /// length, a reset the clock disagrees with, or too little of the window
    /// elapsed to imply a rate.
    init?(window: Dashboard.AllowanceWindow, now: Date = .now) {
        var view = costbar_allowance_pace_view_t()
        let status = costbar_allowance_pace(
            window.usedPercent,
            .init(optional: window.resetsAtUnix),
            .init(optional: window.durationMinutes),
            Int64(now.timeIntervalSince1970.rounded()),
            &view
        )
        guard status == COSTBAR_STATUS_OK else { return nil }

        deviationPoints = view.deviation_points
        resetsAt = Date(timeIntervalSince1970: TimeInterval(view.resets_at_unix))
        outlook = view.empties_at_unix.optional.map {
            .emptiesAt(Date(timeIntervalSince1970: TimeInterval($0)))
        } ?? .lastsUntilReset
    }
}
