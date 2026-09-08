const std = @import("std");

pub const freshness_seconds: f64 = 1_800;
pub const Provider = struct { available: bool, updated_at: f64 };
pub const Quota = struct { used_percent: f64, resets_at: ?f64 };
pub const State = enum(u32) { active, unavailable, stale, expired, invalid };

pub fn isStale(updated_at: f64, now: f64) bool {
    return !std.math.isFinite(updated_at) or !std.math.isFinite(now) or now - updated_at >= freshness_seconds;
}

pub fn providerIsFresh(provider: Provider, now: f64) bool {
    return provider.available and !isStale(provider.updated_at, now);
}

pub fn isActive(resets_at: ?f64, now: f64) bool {
    if (!std.math.isFinite(now)) return false;
    return if (resets_at) |reset| std.math.isFinite(reset) and reset > now else true;
}

pub fn state(generated_at: f64, provider: Provider, quota: Quota, now: f64) State {
    if (!std.math.isFinite(quota.used_percent) or quota.used_percent < 0) return .invalid;
    if (!provider.available) return .unavailable;
    if (isStale(generated_at, now) or isStale(provider.updated_at, now)) return .stale;
    if (!isActive(quota.resets_at, now)) return .expired;
    return .active;
}

/// Returns the stable reset/day identity only for an eligible alert. Reject
/// unrepresentable timestamps instead of trapping when a snapshot is corrupt.
pub fn alertWindow(generated_at: f64, provider: Provider, quota: Quota, threshold: u32, now: f64) ?i64 {
    if (threshold > 100 or state(generated_at, provider, quota, now) != .active or quota.used_percent < @as(f64, @floatFromInt(threshold))) return null;
    const window = if (quota.resets_at) |reset| @trunc(reset) else @floor(now / 86_400);
    if (!std.math.isFinite(window) or window < -9_223_372_036_854_775_808.0 or window >= 9_223_372_036_854_775_808.0) return null;
    return @intFromFloat(window);
}

pub fn nextDate(current: ?f64, candidate: f64, now: f64, expires: f64) ?f64 {
    if (!std.math.isFinite(candidate) or candidate <= now or candidate > expires) return current;
    return if (current) |date| @min(date, candidate) else candidate;
}

pub fn alertKey(buffer: []u8, provider: []const u8, quota: []const u8, window: i64, threshold: u32) ?[]const u8 {
    return std.fmt.bufPrint(buffer, "{s}/{s}/{d}/{d}", .{ provider, quota, window, threshold }) catch null;
}

test "freshness and resets transition exactly at their boundaries" {
    try std.testing.expect(!isStale(100.25, 1_900.24));
    try std.testing.expect(isStale(100.25, 1_900.25));
    try std.testing.expect(isActive(200.5, 200.4));
    try std.testing.expect(!isActive(200.5, 200.5));
    try std.testing.expect(isActive(null, 200));
    try std.testing.expect(isStale(std.math.nan(f64), 200));
}

test "alerts reject unavailable stale expired and below-threshold quotas" {
    const provider: Provider = .{ .available = true, .updated_at = 1_000 };
    const quota: Quota = .{ .used_percent = 80, .resets_at = 3_000 };
    try std.testing.expectEqual(@as(?i64, 3_000), alertWindow(1_000, provider, quota, 80, 1_200));
    try std.testing.expectEqual(null, alertWindow(1_000, provider, quota, 81, 1_200));
    try std.testing.expectEqual(null, alertWindow(1_000, .{ .available = false, .updated_at = 1_000 }, quota, 80, 1_200));
    try std.testing.expectEqual(null, alertWindow(1_000, provider, quota, 80, 2_800));
    try std.testing.expectEqual(null, alertWindow(2_000, .{ .available = true, .updated_at = 2_000 }, quota, 80, 3_000));
    try std.testing.expectEqual(null, alertWindow(1_000, provider, .{ .used_percent = std.math.nan(f64), .resets_at = null }, 80, 1_200));
    try std.testing.expectEqual(null, alertWindow(1_000, provider, .{ .used_percent = 90, .resets_at = 1e30 }, 80, 1_200));
}

test "missing reset rolls the alert identity at UTC midnight" {
    const provider: Provider = .{ .available = true, .updated_at = 86_000 };
    const quota: Quota = .{ .used_percent = 90, .resets_at = null };
    try std.testing.expectEqual(@as(?i64, 0), alertWindow(86_000, provider, quota, 80, 86_399));
    try std.testing.expectEqual(@as(?i64, 1), alertWindow(86_000, provider, quota, 80, 86_400));
    var buffer: [100]u8 = undefined;
    try std.testing.expectEqualStrings("codex/personal/weekly/1/80", alertKey(&buffer, "codex/personal", "weekly", 1, 80).?);
    try std.testing.expectEqual(null, alertKey(buffer[0..2], "codex", "weekly", 1, 80));
}
