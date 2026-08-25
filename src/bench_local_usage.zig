const std = @import("std");
const costbar = @import("root.zig").c_api;

extern fn costbar_core_create() ?*anyopaque;
extern fn costbar_core_destroy(core: ?*anyopaque) void;
extern fn costbar_core_cached_snapshot_create(
    core: ?*anyopaque,
    period_start_unix: i64,
    period_end_exclusive_unix: i64,
    snapshot: *?*anyopaque,
) costbar.Status;
extern fn costbar_snapshot_destroy(snapshot: ?*anyopaque) void;
extern fn costbar_core_refresh(
    core: ?*anyopaque,
    options: costbar.RefreshOptions,
    result: *costbar.RefreshResult,
) costbar.Status;
extern fn costbar_bytes_free(bytes: costbar.Bytes) void;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len != 4) {
        std.debug.print("usage: {s} codex|claude|cache START_UNIX END_UNIX\n", .{args[0]});
        return error.InvalidArguments;
    }
    const start = try std.fmt.parseInt(i64, args[2], 10);
    const end = try std.fmt.parseInt(i64, args[3], 10);
    const is_codex = std.mem.eql(u8, args[1], "codex");
    const is_claude = std.mem.eql(u8, args[1], "claude");
    const is_cache = std.mem.eql(u8, args[1], "cache");
    if (!is_codex and !is_claude and !is_cache) return error.InvalidArguments;

    const core = costbar_core_create() orelse return error.OutOfMemory;
    defer costbar_core_destroy(core);
    const restore_before = monotonicNanoseconds();
    var snapshot: ?*anyopaque = null;
    const restore_status = costbar_core_cached_snapshot_create(core, start, end, &snapshot);
    if (restore_status == .ok) {
        defer costbar_snapshot_destroy(snapshot);
        std.debug.print(
            "dashboard restore: {d:.3} ms\n",
            .{@as(f64, @floatFromInt(monotonicNanoseconds() - restore_before)) /
                std.time.ns_per_ms},
        );
    } else if (is_cache) {
        return error.CacheUnavailable;
    }
    if (is_cache) return;
    for (0..2) |iteration| {
        const before = monotonicNanoseconds();
        var result: costbar.RefreshResult = .{};
        const status = costbar_core_refresh(core, .{
            .period_start_unix = start,
            .period_end_exclusive_unix = end,
            .track_codex = @intFromBool(is_codex),
            .track_claude = @intFromBool(is_claude),
            .track_opencode = 0,
            .use_github_cli = 0,
        }, &result);
        defer costbar_bytes_free(result.errors);
        if (status != .ok) return error.RefreshFailed;
        const elapsed = monotonicNanoseconds() - before;
        std.debug.print(
            "{s} {s}: {d:.3} ms ({d}/{d} refreshed)\n",
            .{
                args[1],
                if (iteration == 0) "cold" else "cached",
                @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_ms,
                result.refreshed_count,
                result.configured_count,
            },
        );
    }
}

fn monotonicNanoseconds() i128 {
    var timestamp: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &timestamp) != 0) return 0;
    return @as(i128, timestamp.sec) * std.time.ns_per_s + timestamp.nsec;
}
