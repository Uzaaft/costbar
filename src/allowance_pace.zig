const std = @import("std");
const model = @import("model.zig");

/// How an allowance is tracking against its own clock.
///
/// "68% used" says nothing about whether that is fine. Comparing it against the
/// share of the window that has already elapsed does: burning faster than the
/// clock means the allowance empties before it resets, and how much faster says
/// when. Every consumer of a rate-limited subscription wants that answer, so it
/// is computed here once rather than in each UI.
pub const Pace = struct {
    /// Percentage points spent above (positive) or below (negative) an even burn.
    deviation_points: f64,
    /// When the allowance empties at the current rate, or null when the rate is
    /// slow enough that the reset arrives first.
    empties_at_unix: ?i64,
    resets_at_unix: i64,

    /// Points of slack before a deviation is worth naming in either direction.
    pub const deadband_points: f64 = 1.5;

    pub fn isOverspending(self: Pace) bool {
        return self.deviation_points > deadband_points;
    }

    pub fn isUnderspending(self: Pace) bool {
        return self.deviation_points < -deadband_points;
    }
};

/// Below this much of the window elapsed the rate is noise: one early request
/// in a fresh five-hour window reads as a runaway overspend.
const minimum_elapsed_fraction: f64 = 0.04;

/// Returns null whenever the inputs cannot support an honest verdict, rather
/// than guessing: no reset, no window length, a reset the clock disagrees with,
/// or too little of the window elapsed to imply a rate.
pub fn compute(window: model.AllowanceWindow, now: i64) ?Pace {
    const resets_at_unix = window.resets_at_unix orelse return null;
    const duration_minutes = window.duration_minutes orelse return null;
    if (duration_minutes <= 0) return null;
    if (!std.math.isFinite(window.used_percent)) return null;

    const duration: f64 = @floatFromInt(duration_minutes * std.time.s_per_min);
    const remaining: f64 = @floatFromInt(resets_at_unix -| now);
    // A reset already past, or further out than one whole window, means the
    // provider and this machine disagree about the time.
    if (remaining <= 0 or remaining > duration) return null;

    const elapsed = duration - remaining;
    if (elapsed / duration < minimum_elapsed_fraction) return null;

    const used_percent = std.math.clamp(window.used_percent, 0, 100);
    const points_per_second = used_percent / elapsed;
    const empties_at_unix: ?i64 = if (points_per_second > 0) blk: {
        const seconds_until_empty = (100 - used_percent) / points_per_second;
        if (seconds_until_empty >= remaining) break :blk null;
        break :blk now +| @as(i64, @intFromFloat(@round(seconds_until_empty)));
    } else null;

    return .{
        .deviation_points = used_percent - (elapsed / duration * 100),
        .empties_at_unix = empties_at_unix,
        .resets_at_unix = resets_at_unix,
    };
}

fn testWindow(used_percent: f64, resets_in: i64, duration_minutes: ?i64) model.AllowanceWindow {
    return .{
        .id = "primary",
        .label = "5 hour",
        .used_percent = used_percent,
        .resets_at_unix = 1_800_000_000 + resets_in,
        .duration_minutes = duration_minutes,
    };
}

test "spending faster than the clock empties the allowance before it resets" {
    // Half of a five-hour window gone, 80% of the allowance with it.
    const pace = compute(testWindow(80, 9_000, 300), 1_800_000_000).?;
    try std.testing.expect(pace.isOverspending());
    try std.testing.expectApproxEqAbs(@as(f64, 30), pace.deviation_points, 0.001);
    // 80 points bought 9_000 seconds, so the last 20 buy 2_250 more.
    try std.testing.expectEqual(@as(i64, 1_800_002_250), pace.empties_at_unix.?);
}

test "spending slower than the clock lasts until the reset" {
    const pace = compute(testWindow(20, 9_000, 300), 1_800_000_000).?;
    try std.testing.expect(pace.isUnderspending());
    try std.testing.expectApproxEqAbs(@as(f64, -30), pace.deviation_points, 0.001);
    try std.testing.expectEqual(@as(?i64, null), pace.empties_at_unix);
}

test "an untouched allowance lasts until the reset" {
    const pace = compute(testWindow(0, 9_000, 300), 1_800_000_000).?;
    try std.testing.expectEqual(@as(?i64, null), pace.empties_at_unix);
    try std.testing.expect(pace.isUnderspending());
}

test "too little of the window elapsed to imply a rate" {
    // One minute into a seven-day window a single request would read as a
    // runaway overspend, so no verdict is offered at all.
    try std.testing.expectEqual(
        @as(?Pace, null),
        compute(testWindow(4, 604_740, 10_080), 1_800_000_000),
    );
}

test "resets the clock disagrees with yield no pace" {
    try std.testing.expectEqual(
        @as(?Pace, null),
        compute(testWindow(50, -60, 300), 1_800_000_000),
    );
    try std.testing.expectEqual(
        @as(?Pace, null),
        compute(testWindow(50, 18_060, 300), 1_800_000_000),
    );
}

test "a window without a length or a reset has no pace" {
    try std.testing.expectEqual(
        @as(?Pace, null),
        compute(testWindow(50, 9_000, null), 1_800_000_000),
    );
    var window = testWindow(50, 9_000, 300);
    window.resets_at_unix = null;
    try std.testing.expectEqual(@as(?Pace, null), compute(window, 1_800_000_000));
}

test "a spent allowance empties now" {
    const pace = compute(testWindow(100, 9_000, 300), 1_800_000_000).?;
    try std.testing.expectEqual(@as(i64, 1_800_000_000), pace.empties_at_unix.?);
}
