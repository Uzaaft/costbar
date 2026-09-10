const std = @import("std");

pub const State = enum {
    busy,
    waiting,
    success,
    idle,
};

pub const Summary = enum {
    working,
    waiting,
    success,
    idle,
};

pub const Session = struct {
    id: []const u8,
    name: []const u8,
    detail: []const u8,
    state: State,
    waiting_for: ?[]const u8 = null,
    since_unix: i64,
    pid: ?i32 = null,
};

pub const ProviderActivity = struct {
    provider_id: []const u8,
    profile_id: []const u8,
    sessions: []const Session,
};

pub const Snapshot = struct {
    generated_at_unix: i64,
    any_busy: bool,
    any_waiting: bool,
    providers: []const ProviderActivity,
};

pub const TransitionKind = enum {
    finished,
    waiting,
};

pub const Transition = struct {
    id: []const u8,
    provider_id: []const u8,
    kind: TransitionKind,
    name: []const u8,
    pid: ?i32 = null,
};

pub const Root = struct {
    provider_id: []const u8,
    profile_id: []const u8,
    home_path: []const u8,
};

pub const Previous = struct {
    id: []const u8,
    provider_id: []const u8,
    state: State,
    name: []const u8,
    pid: ?i32,
};

pub fn summarize(sessions: []const Session) ?Summary {
    if (sessions.len == 0) return null;
    var saw_busy = false;
    var saw_success = false;
    for (sessions) |item| {
        switch (item.state) {
            .waiting => return .waiting,
            .busy => saw_busy = true,
            .success => saw_success = true,
            .idle => {},
        }
    }
    if (saw_busy) return .working;
    if (saw_success) return .success;
    return .idle;
}

pub fn collectTransitions(
    allocator: std.mem.Allocator,
    previous: []const Previous,
    current: []const ProviderActivity,
    first_poll: bool,
) ![]Transition {
    if (first_poll) return allocator.alloc(Transition, 0);
    var out: std.ArrayList(Transition) = .empty;
    errdefer out.deinit(allocator);
    for (previous) |prior| {
        if (prior.state != .busy) continue;
        if (findSession(current, prior.id)) |found| {
            if (found.state == .waiting) {
                try out.append(allocator, .{
                    .id = prior.id,
                    .provider_id = prior.provider_id,
                    .kind = .waiting,
                    .name = found.name,
                    .pid = found.pid,
                });
            } else if (found.state == .idle or found.state == .success) {
                try out.append(allocator, .{
                    .id = prior.id,
                    .provider_id = prior.provider_id,
                    .kind = .finished,
                    .name = found.name,
                    .pid = found.pid,
                });
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

fn findSession(providers: []const ProviderActivity, id: []const u8) ?Session {
    for (providers) |provider| {
        for (provider.sessions) |item| {
            if (std.mem.eql(u8, item.id, id)) return item;
        }
    }
    return null;
}

fn sample(id: []const u8, state: State) Session {
    return .{
        .id = id,
        .name = id,
        .detail = "",
        .state = state,
        .since_unix = 0,
    };
}

test "waiting outranks busy and empty lists disappear" {
    try std.testing.expect(summarize(&.{}) == null);
    try std.testing.expectEqual(
        Summary.waiting,
        summarize(&.{ sample("a", .busy), sample("b", .waiting) }).?,
    );
    try std.testing.expectEqual(Summary.working, summarize(&.{sample("a", .busy)}).?);
    try std.testing.expectEqual(Summary.success, summarize(&.{sample("a", .success)}).?);
    try std.testing.expectEqual(Summary.idle, summarize(&.{sample("a", .idle)}).?);
}

test "transitions fire only after the first poll and ignore vanished busy files" {
    const prior = [_]Previous{
        .{ .id = "a", .provider_id = "claude", .state = .busy, .name = "a", .pid = 1 },
        .{ .id = "b", .provider_id = "claude", .state = .busy, .name = "b", .pid = 2 },
        .{ .id = "c", .provider_id = "claude", .state = .busy, .name = "c", .pid = 3 },
    };
    const current = [_]ProviderActivity{.{
        .provider_id = "claude",
        .profile_id = "default",
        .sessions = &.{
            sample("a", .idle),
            sample("b", .waiting),
        },
    }};
    const silent = try collectTransitions(std.testing.allocator, &prior, &current, true);
    defer std.testing.allocator.free(silent);
    try std.testing.expectEqual(@as(usize, 0), silent.len);

    const events = try collectTransitions(std.testing.allocator, &prior, &current, false);
    defer std.testing.allocator.free(events);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqual(TransitionKind.finished, events[0].kind);
    try std.testing.expectEqualStrings("a", events[0].id);
    try std.testing.expectEqual(TransitionKind.waiting, events[1].kind);
    try std.testing.expectEqualStrings("b", events[1].id);
}
