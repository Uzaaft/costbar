import Foundation
import Testing
@testable import Costbar

// The arithmetic itself is covered in Zig (`src/allowance_pace.zig`); these
// cover the bridge — that Swift hands the core the right values and reads its
// answer back correctly, including its refusals.

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func window(
    usedPercent: Double,
    resetsIn seconds: TimeInterval,
    durationMinutes: Int64? = 300
) -> Dashboard.AllowanceWindow {
    Dashboard.AllowanceWindow(
        id: "primary",
        label: "5 hour",
        usedPercent: usedPercent,
        resetsAtUnix: Int64(now.timeIntervalSince1970 + seconds),
        durationMinutes: durationMinutes,
        detail: nil
    )
}

@Test
func allowanceSpentFasterThanTheClockEmptiesBeforeItResets() throws {
    // Half the five-hour window gone, 80% of the allowance with it.
    let pace = try #require(AllowancePace(window: window(usedPercent: 80, resetsIn: 9_000), now: now))

    #expect(pace.isOverspending)
    #expect(abs(pace.deviationPoints - 30) < 0.001)
    #expect(pace.resetsAt == now.addingTimeInterval(9_000))
    guard case let .emptiesAt(date) = pace.outlook else {
        Issue.record("expected the allowance to run out before its reset")
        return
    }
    // 80 points bought 9_000 seconds, so the last 20 buy 2_250 more.
    #expect(abs(date.timeIntervalSince(now) - 2_250) < 1)
}

@Test
func allowanceSpentSlowerThanTheClockLastsUntilItResets() throws {
    let pace = try #require(AllowancePace(window: window(usedPercent: 20, resetsIn: 9_000), now: now))

    #expect(pace.isUnderspending)
    #expect(abs(pace.deviationPoints + 30) < 0.001)
    #expect(pace.outlook == .lastsUntilReset)
}

@Test
func allowanceWithoutAWindowLengthHasNoPace() throws {
    // Providers that report a percentage but no window length — OpenRouter's
    // key limit, say — get no verdict rather than a guessed one.
    #expect(AllowancePace(
        window: window(usedPercent: 80, resetsIn: 9_000, durationMinutes: nil),
        now: now
    ) == nil)
}

@Test
func allowanceWithoutEnoughElapsedWindowHasNoPace() throws {
    // One minute into a seven-day window a single request would read as a
    // runaway overspend, so no verdict is offered at all.
    #expect(AllowancePace(
        window: window(usedPercent: 4, resetsIn: 604_740, durationMinutes: 10_080),
        now: now
    ) == nil)
}

@Test
func allowancePaceIgnoresResetsThatDisagreeWithTheClock() throws {
    #expect(AllowancePace(window: window(usedPercent: 50, resetsIn: -60), now: now) == nil)
    #expect(AllowancePace(window: window(usedPercent: 50, resetsIn: 18_060), now: now) == nil)
}

@Test
func untouchedAllowanceLastsUntilItResets() throws {
    let pace = try #require(AllowancePace(window: window(usedPercent: 0, resetsIn: 9_000), now: now))

    #expect(pace.outlook == .lastsUntilReset)
    #expect(pace.isUnderspending)
}
