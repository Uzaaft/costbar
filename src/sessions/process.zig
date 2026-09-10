const std = @import("std");

/// Whether `pid` is still the process that started at `started_at_unix`.
/// A missing start time trusts a live pid; a mismatched start time is a reuse.
pub fn isSameProcess(alive: bool, recorded_start_unix: ?i64, live_start_unix: ?i64) bool {
    if (!alive) return false;
    const recorded = recorded_start_unix orelse return true;
    const live = live_start_unix orelse return true;
    const delta = if (recorded > live) recorded - live else live - recorded;
    return delta <= 2;
}

pub fn exists(pid: i32) bool {
    if (pid <= 0) return false;
    // Signal 0 is not in Darwin's SIG enum; libc kill still accepts it.
    return std.c.kill(@intCast(pid), @enumFromInt(0)) == 0;
}

pub fn isLive(pid: i32, started_at_unix: ?i64) bool {
    _ = started_at_unix;
    return exists(pid);
}

test "pid reuse is rejected when start times disagree" {
    try std.testing.expect(isSameProcess(true, 100, 100));
    try std.testing.expect(isSameProcess(true, 100, 102));
    try std.testing.expect(!isSameProcess(true, 100, 200));
    try std.testing.expect(!isSameProcess(false, 100, 100));
    try std.testing.expect(isSameProcess(true, null, 100));
    try std.testing.expect(isSameProcess(true, 100, null));
}
