const std = @import("std");
// Keep safety checks, without Zig's desktop stack unwinder (its dyld entry
// point is unavailable to iOS apps and extensions).
pub const panic = std.debug.simple_panic;
const policy = @import("usage_policy.zig");

const Provider = extern struct { updated_at: f64, available: u8 };
const Quota = extern struct { provider_index: usize, used_percent: f64, resets_at: f64, has_reset: u8 };
const Snapshot = extern struct { generated_at: f64, providers: ?[*]const Provider, provider_count: usize, quotas: ?[*]const Quota, quota_count: usize };
const Result = extern struct { alert_window: i64, state: u32, should_alert: u8 };
const Summary = extern struct { highest_index: usize, next_transition: f64, stale: u8, has_next_transition: u8 };

export fn costbar_usage_is_stale(updated_at: f64, now: f64) u8 {
    return @intFromBool(policy.isStale(updated_at, now));
}
export fn costbar_usage_provider_is_fresh(updated_at: f64, available: u8, now: f64) u8 {
    return @intFromBool(policy.providerIsFresh(.{ .updated_at = updated_at, .available = available != 0 }, now));
}
export fn costbar_usage_is_active(reset: f64, has_reset: u8, now: f64) u8 {
    return @intFromBool(policy.isActive(if (has_reset != 0) reset else null, now));
}
export fn costbar_usage_evaluate(snapshot: ?*const Snapshot, now: f64, threshold: u32, results: ?[*]Result, result_count: usize, summary: ?*Summary) u8 {
    const input = snapshot orelse return 0;
    const output = summary orelse return 0;
    if (result_count < input.quota_count or (input.quota_count > 0 and (input.quotas == null or results == null)) or (input.provider_count > 0 and input.providers == null)) return 0;
    output.* = .{ .highest_index = input.quota_count, .next_transition = 0, .stale = costbar_usage_is_stale(input.generated_at, now), .has_next_transition = 0 };
    const expires = input.generated_at + policy.freshness_seconds;
    var next: ?f64 = if (output.stale == 0) policy.nextDate(null, expires, now, expires) else null;
    for (0..input.provider_count) |i| {
        const provider = input.providers.?[i];
        if (output.stale == 0 and provider.available != 0) next = policy.nextDate(next, provider.updated_at + policy.freshness_seconds, now, expires);
    }
    var highest: f64 = -1;
    for (0..input.quota_count) |i| {
        const quota = input.quotas.?[i];
        const result = &results.?[i];
        result.* = .{ .alert_window = 0, .state = @intFromEnum(policy.State.invalid), .should_alert = 0 };
        if (quota.provider_index >= input.provider_count) continue;
        const provider = input.providers.?[quota.provider_index];
        const p: policy.Provider = .{ .available = provider.available != 0, .updated_at = provider.updated_at };
        const q: policy.Quota = .{ .used_percent = quota.used_percent, .resets_at = if (quota.has_reset != 0) quota.resets_at else null };
        const state = policy.state(input.generated_at, p, q, now);
        result.state = @intFromEnum(state);
        if (state == .active and quota.used_percent > highest) {
            highest = quota.used_percent;
            output.highest_index = i;
        }
        if (policy.alertWindow(input.generated_at, p, q, threshold, now)) |window| {
            result.should_alert = 1;
            result.alert_window = window;
        }
        if (output.stale == 0 and p.available) {
            if (q.resets_at) |reset| next = policy.nextDate(next, reset, now, expires);
        }
    }
    if (next) |date| {
        output.has_next_transition = 1;
        output.next_transition = date;
    }
    return 1;
}
export fn costbar_usage_alert_key(provider: ?[*]const u8, provider_len: usize, quota: ?[*]const u8, quota_len: usize, window: i64, threshold: u32, output: ?[*]u8, capacity: usize) usize {
    if ((provider == null and provider_len > 0) or (quota == null and quota_len > 0) or output == null) return 0;
    const p = if (provider) |ptr| ptr[0..provider_len] else "";
    const q = if (quota) |ptr| ptr[0..quota_len] else "";
    return if (policy.alertKey(output.?[0..capacity], p, q, window, threshold)) |key| key.len else 0;
}

test "C evaluation selects fresh quotas and schedules reset and expiry" {
    const providers = [_]Provider{ .{ .updated_at = 1_000, .available = 1 }, .{ .updated_at = -500, .available = 1 } };
    const quotas = [_]Quota{ .{ .provider_index = 0, .used_percent = 95, .resets_at = 1_120, .has_reset = 1 }, .{ .provider_index = 1, .used_percent = 70, .resets_at = 0, .has_reset = 0 } };
    const input: Snapshot = .{ .generated_at = 1_000, .providers = &providers, .provider_count = 2, .quotas = &quotas, .quota_count = 2 };
    var results: [2]Result = undefined;
    var summary: Summary = undefined;
    try std.testing.expectEqual(1, costbar_usage_evaluate(&input, 1_000, 80, &results, 2, &summary));
    try std.testing.expectEqual(0, summary.highest_index);
    try std.testing.expectEqual(1, results[0].should_alert);
    try std.testing.expectEqual(1_120, summary.next_transition);
    try std.testing.expectEqual(1, costbar_usage_evaluate(&input, 1_120, 80, &results, 2, &summary));
    try std.testing.expectEqual(1, summary.highest_index);
    try std.testing.expectEqual(0, results[0].should_alert);
    try std.testing.expectEqual(1_300, summary.next_transition);
    try std.testing.expectEqual(1, costbar_usage_evaluate(&input, 1_300, 80, &results, 2, &summary));
    try std.testing.expectEqual(2, summary.highest_index);
    try std.testing.expectEqual(2_800, summary.next_transition);
    try std.testing.expectEqual(1, costbar_usage_evaluate(&input, 2_800, 80, &results, 2, &summary));
    try std.testing.expectEqual(1, summary.stale);
    try std.testing.expectEqual(0, summary.has_next_transition);
    try std.testing.expectEqual(0, costbar_usage_evaluate(&input, 1_000, 80, &results, 1, &summary));
    try std.testing.expectEqual(0, costbar_usage_evaluate(null, 1_000, 80, null, 0, &summary));
}

test {
    _ = policy;
}

test "C boundary handles empty snapshots invalid provider indices and byte keys" {
    var summary: Summary = undefined;
    var empty: Snapshot = .{ .generated_at = 1_000, .providers = null, .provider_count = 0, .quotas = null, .quota_count = 0 };
    try std.testing.expectEqual(1, costbar_usage_evaluate(&empty, 1_000, 80, null, 0, &summary));
    try std.testing.expectEqual(0, summary.highest_index);
    try std.testing.expectEqual(2_800, summary.next_transition);
    const quotas = [_]Quota{.{ .provider_index = 0, .used_percent = 90, .resets_at = 0, .has_reset = 0 }};
    empty.quotas = &quotas;
    empty.quota_count = 1;
    var results: [1]Result = undefined;
    try std.testing.expectEqual(1, costbar_usage_evaluate(&empty, 1_000, 80, &results, 1, &summary));
    try std.testing.expectEqual(@intFromEnum(policy.State.invalid), results[0].state);
    try std.testing.expectEqual(0, results[0].should_alert);
    var buffer: [100]u8 = undefined;
    const provider = "claude/私用";
    const quota = "weekly";
    const count = costbar_usage_alert_key(provider.ptr, provider.len, quota.ptr, quota.len, 3_000, 80, &buffer, buffer.len);
    try std.testing.expectEqualStrings("claude/私用/weekly/3000/80", buffer[0..count]);
    try std.testing.expectEqual(0, costbar_usage_alert_key(null, 1, quota.ptr, quota.len, 3_000, 80, &buffer, buffer.len));
    try std.testing.expectEqual(0, costbar_usage_alert_key(provider.ptr, provider.len, quota.ptr, quota.len, 3_000, 80, &buffer, 2));
}
