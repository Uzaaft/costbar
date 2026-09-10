const std = @import("std");
const sessions = @import("sessions.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len < 2 or !std.mem.eql(u8, args[1], "sessions")) {
        std.debug.print("usage: {s} sessions\n", .{args[0]});
        return;
    }

    const home = std.mem.span(std.c.getenv("HOME") orelse return error.HomeUnavailable);
    const claude_home = try allocator.dupe(u8, home);
    defer allocator.free(claude_home);
    const codex_home = try std.fs.path.join(allocator, &.{ home, ".codex" });
    defer allocator.free(codex_home);

    var monitor = sessions.Monitor.init(allocator);
    defer monitor.deinit();
    try monitor.setRoots(&.{
        .{ .provider_id = "claude", .profile_id = "default", .home_path = claude_home },
        .{ .provider_id = "codex", .profile_id = "default", .home_path = codex_home },
    });

    var io_threaded: std.Io.Threaded = .init(allocator, .{});
    defer io_threaded.deinit();
    var timestamp: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &timestamp) != 0) return error.ClockUnavailable;
    const snapshot = try monitor.poll(io_threaded.io(), timestamp.sec, sessions.process.isLive);
    const json = try std.json.Stringify.valueAlloc(allocator, snapshot, .{});
    defer allocator.free(json);
    std.debug.print("{s}\n", .{json});
}
