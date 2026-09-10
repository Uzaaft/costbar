const std = @import("std");
const http = @import("../http.zig");
const local_ai = @import("local_ai.zig");
const model = @import("../model.zig");

pub const CursorLocal = local_ai.LocalAI("cursor-local", "Cursor");

const usage_url = "https://cursor.com/api/usage-summary";

pub const ParsedWindow = struct {
    id: []const u8,
    label: []const u8,
    used_percent: f64,
    resets_at_unix: ?i64,
    duration_minutes: ?i64,
};

pub fn parseUsageSummary(allocator: std.mem.Allocator, json: []const u8) ![]ParsedWindow {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{
        .allocate = .alloc_always,
    }) catch return error.InvalidCursorUsage;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCursorUsage;
    const root = parsed.value.object;
    const resets_at = parseIsoUnix(asString(root.get("billingCycleEnd")));
    const starts_at = parseIsoUnix(asString(root.get("billingCycleStart")));
    const duration_minutes = if (resets_at) |end|
        if (starts_at) |start| if (end > start) @divFloor(end - start, 60) else null else null
    else
        null;

    const usage = if (root.get("individualUsage")) |value|
        if (value == .object) value.object else null
    else
        null;
    const plan = if (usage) |object|
        if (object.get("plan")) |value| if (value == .object) value.object else null else null
    else
        null;

    var windows: std.ArrayList(ParsedWindow) = .empty;
    errdefer windows.deinit(allocator);

    if (plan) |object| {
        if (percent(object.get("autoPercentUsed"))) |value| {
            try windows.append(allocator, .{
                .id = try allocator.dupe(u8, "auto"),
                .label = try allocator.dupe(u8, "Auto usage"),
                .used_percent = value,
                .resets_at_unix = resets_at,
                .duration_minutes = duration_minutes,
            });
        }
        if (percent(object.get("apiPercentUsed"))) |value| {
            if (value > 0) {
                try windows.append(allocator, .{
                    .id = try allocator.dupe(u8, "api"),
                    .label = try allocator.dupe(u8, "API usage"),
                    .used_percent = value,
                    .resets_at_unix = resets_at,
                    .duration_minutes = duration_minutes,
                });
            }
        }
    }
    if (windows.items.len == 0) {
        if (usage) |object| {
            if (spendPercent(object.get("overall"))) |value| {
                try windows.append(allocator, .{
                    .id = try allocator.dupe(u8, "included"),
                    .label = try allocator.dupe(u8, "Included usage"),
                    .used_percent = value,
                    .resets_at_unix = resets_at,
                    .duration_minutes = duration_minutes,
                });
            }
        }
    }
    if (windows.items.len == 0) return error.NothingMetered;
    return windows.toOwnedSlice(allocator);
}

pub fn fetchUsageSummary(
    allocator: std.mem.Allocator,
    client: anytype,
    cookie: []const u8,
) ![]u8 {
    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Cookie", .value = cookie },
    };
    const response = try client.get(allocator, .{
        .url = usage_url,
        .privileged_headers = &headers,
    });
    defer response.deinit(allocator);
    try response.requireSuccess();
    return allocator.dupe(u8, response.body);
}

fn percent(value: ?std.json.Value) ?f64 {
    const number = asNumber(value) orelse return null;
    if (!std.math.isFinite(number) or number < 0 or number > 100) return null;
    return number;
}

fn spendPercent(value: ?std.json.Value) ?f64 {
    const object = if (value) |item| if (item == .object) item.object else return null else return null;
    if (object.get("enabled")) |enabled| {
        if (enabled == .bool and !enabled.bool) return null;
    }
    const limit = asNumber(object.get("limit")) orelse return null;
    const used = asNumber(object.get("used")) orelse return null;
    if (!(limit > 0) or !std.math.isFinite(used) or used < 0) return null;
    return std.math.clamp(used / limit * 100, 0, 100);
}

fn asNumber(value: ?std.json.Value) ?f64 {
    const item = value orelse return null;
    return switch (item) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        .number_string => |text| std.fmt.parseFloat(f64, text) catch null,
        else => null,
    };
}

fn asString(value: ?std.json.Value) ?[]const u8 {
    const item = value orelse return null;
    return if (item == .string) item.string else null;
}

fn parseIsoUnix(text: ?[]const u8) ?i64 {
    const value = text orelse return null;
    if (value.len < 19) return null;
    const year = std.fmt.parseInt(i32, value[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, value[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, value[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u8, value[17..19], 10) catch return null;
    return utcUnix(year, month, day, hour, minute, second);
}

fn utcUnix(year: i32, month: u8, day: u8, hour: u8, minute: u8, second: u8) i64 {
    var y: i64 = year;
    y -= @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const shifted: i64 = if (month > 2) month - 3 else month + 9;
    const doy = @divFloor(153 * shifted + 2, 5) + @as(i64, day) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return days * 86_400 + @as(i64, hour) * 3_600 + @as(i64, minute) * 60 + @as(i64, second);
}

fn freeWindows(allocator: std.mem.Allocator, windows: []ParsedWindow) void {
    for (windows) |window| {
        allocator.free(window.id);
        allocator.free(window.label);
    }
    allocator.free(windows);
}

test "cursor free plan uses auto percent and ignores zero used/limit" {
    const json =
        \\{"billingCycleStart":"2026-08-24T03:32:15.933Z","billingCycleEnd":"2026-09-24T03:32:15.933Z",
        \\"membershipType":"free","individualUsage":{"plan":{
        \\"used":0,"limit":0,"autoPercentUsed":9.5,"apiPercentUsed":0,"totalPercentUsed":9.5}}}
    ;
    const windows = try parseUsageSummary(std.testing.allocator, json);
    defer freeWindows(std.testing.allocator, windows);
    try std.testing.expectEqual(@as(usize, 1), windows.len);
    try std.testing.expectEqualStrings("auto", windows[0].id);
    try std.testing.expectEqual(@as(f64, 9.5), windows[0].used_percent);
}

test "cursor api row appears only when touched" {
    const json =
        \\{"individualUsage":{"plan":{"autoPercentUsed":10,"apiPercentUsed":19}}}
    ;
    const windows = try parseUsageSummary(std.testing.allocator, json);
    defer freeWindows(std.testing.allocator, windows);
    try std.testing.expectEqual(@as(usize, 2), windows.len);
    try std.testing.expectEqualStrings("api", windows[1].id);
}

test "cursor enterprise overall becomes included" {
    const json =
        \\{"individualUsage":{"overall":{"enabled":true,"used":6907,"limit":45000}}}
    ;
    const windows = try parseUsageSummary(std.testing.allocator, json);
    defer freeWindows(std.testing.allocator, windows);
    try std.testing.expectEqual(@as(usize, 1), windows.len);
    try std.testing.expectEqualStrings("included", windows[0].id);
    try std.testing.expect(windows[0].used_percent > 15 and windows[0].used_percent < 16);
}

test "cursor totalPercentUsed is never a window" {
    const json = "{\"individualUsage\":{\"plan\":{\"totalPercentUsed\":50}}}";
    try std.testing.expectError(error.NothingMetered, parseUsageSummary(std.testing.allocator, json));
}

test "cursor local provider id is distinct from team cursor" {
    _ = http;
    const provider = CursorLocal.init();
    try std.testing.expectEqualStrings("cursor-local", provider.metadata().id);
    try std.testing.expectEqual(model.ProviderKind.ai, provider.metadata().kind);
}
