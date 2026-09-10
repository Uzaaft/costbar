const std = @import("std");
const sessions = @import("sessions.zig");

const allocator = std.heap.c_allocator;

const Bytes = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,
};

const Status = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    out_of_memory = 2,
    internal_error = 3,
    parse_error = 4,
    unsupported = 5,
};

const Monitor = struct {
    inner: sessions.Monitor,
    snapshot_json: ?[]u8 = null,
    transitions_json: ?[]u8 = null,
};

const JsonSession = struct {
    id: []const u8,
    name: []const u8,
    detail: []const u8,
    state: sessions.State,
    waiting_for: ?[]const u8,
    since_unix: i64,
    pid: ?i32,
};

const JsonProvider = struct {
    provider_id: []const u8,
    profile_id: []const u8,
    summary: sessions.Summary,
    sessions: []JsonSession,
};

const JsonSnapshot = struct {
    generated_at_unix: i64,
    any_busy: bool,
    any_waiting: bool,
    providers: []JsonProvider,
};

const JsonTransition = struct {
    id: []const u8,
    provider_id: []const u8,
    kind: sessions.TransitionKind,
    name: []const u8,
    pid: ?i32,
};

export fn costbar_session_monitor_create() ?*Monitor {
    const monitor = allocator.create(Monitor) catch return null;
    monitor.* = .{ .inner = sessions.Monitor.init(allocator) };
    return monitor;
}

export fn costbar_session_monitor_destroy(monitor: ?*Monitor) void {
    const value = monitor orelse return;
    freeOwned(&value.snapshot_json);
    freeOwned(&value.transitions_json);
    value.inner.deinit();
    allocator.destroy(value);
}

export fn costbar_session_monitor_set_roots(monitor: ?*Monitor, roots: Bytes) Status {
    const value = monitor orelse return .invalid_argument;
    const text = borrowed(roots) orelse return .invalid_argument;
    var parsed: std.ArrayList(sessions.Root) = .empty;
    defer parsed.deinit(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const provider_id = fields.next() orelse return .invalid_argument;
        const profile_id = fields.next() orelse return .invalid_argument;
        const home_path = fields.next() orelse return .invalid_argument;
        if (provider_id.len == 0 or profile_id.len == 0 or home_path.len == 0) return .invalid_argument;
        parsed.append(allocator, .{
            .provider_id = provider_id,
            .profile_id = profile_id,
            .home_path = home_path,
        }) catch return .out_of_memory;
    }
    value.inner.setRoots(parsed.items) catch return .out_of_memory;
    return .ok;
}

export fn costbar_session_monitor_poll(
    monitor: ?*Monitor,
    now_unix: i64,
    out_json: ?*Bytes,
) Status {
    const value = monitor orelse return .invalid_argument;
    const output = out_json orelse return .invalid_argument;
    output.* = .{};
    var io_threaded: std.Io.Threaded = .init(allocator, .{});
    defer io_threaded.deinit();
    const snapshot = value.inner.poll(io_threaded.io(), now_unix, sessions.process.isLive) catch
        return .internal_error;
    const json = stringifySnapshot(snapshot) catch return .out_of_memory;
    freeOwned(&value.snapshot_json);
    value.snapshot_json = json;
    output.* = .{ .ptr = json.ptr, .len = json.len };
    return .ok;
}

export fn costbar_session_monitor_transitions(
    monitor: ?*Monitor,
    out_json: ?*Bytes,
) Status {
    const value = monitor orelse return .invalid_argument;
    const output = out_json orelse return .invalid_argument;
    output.* = .{};
    const json = stringifyTransitions(value.inner.last_transitions) catch return .out_of_memory;
    freeOwned(&value.transitions_json);
    value.transitions_json = json;
    output.* = .{ .ptr = json.ptr, .len = json.len };
    return .ok;
}

export fn costbar_session_monitor_free_bytes(bytes: Bytes) void {
    const slice = borrowed(bytes) orelse return;
    allocator.free(@constCast(slice));
}

fn stringifySnapshot(snapshot: sessions.Snapshot) ![]u8 {
    var providers = try allocator.alloc(JsonProvider, snapshot.providers.len);
    defer allocator.free(providers);
    var session_storage: std.ArrayList([]JsonSession) = .empty;
    defer {
        for (session_storage.items) |item| allocator.free(item);
        session_storage.deinit(allocator);
    }
    for (snapshot.providers, 0..) |provider, index| {
        const copied = try allocator.alloc(JsonSession, provider.sessions.len);
        try session_storage.append(allocator, copied);
        for (provider.sessions, 0..) |session, session_index| {
            copied[session_index] = .{
                .id = session.id,
                .name = session.name,
                .detail = session.detail,
                .state = session.state,
                .waiting_for = session.waiting_for,
                .since_unix = session.since_unix,
                .pid = session.pid,
            };
        }
        providers[index] = .{
            .provider_id = provider.provider_id,
            .profile_id = provider.profile_id,
            .summary = sessions.summarize(provider.sessions) orelse .idle,
            .sessions = copied,
        };
    }
    const payload = JsonSnapshot{
        .generated_at_unix = snapshot.generated_at_unix,
        .any_busy = snapshot.any_busy,
        .any_waiting = snapshot.any_waiting,
        .providers = providers,
    };
    return std.json.Stringify.valueAlloc(allocator, payload, .{});
}

fn stringifyTransitions(transitions: []const sessions.Transition) ![]u8 {
    var copied = try allocator.alloc(JsonTransition, transitions.len);
    defer allocator.free(copied);
    for (transitions, 0..) |transition, index| {
        copied[index] = .{
            .id = transition.id,
            .provider_id = transition.provider_id,
            .kind = transition.kind,
            .name = transition.name,
            .pid = transition.pid,
        };
    }
    return std.json.Stringify.valueAlloc(allocator, copied, .{});
}

fn borrowed(bytes: Bytes) ?[]const u8 {
    const ptr = bytes.ptr orelse {
        if (bytes.len == 0) return "";
        return null;
    };
    return ptr[0..bytes.len];
}

fn freeOwned(slot: *?[]u8) void {
    if (slot.*) |bytes| allocator.free(bytes);
    slot.* = null;
}

test "session monitor JSON omits empty providers" {
    const monitor = costbar_session_monitor_create().?;
    defer costbar_session_monitor_destroy(monitor);
    const roots = "claude\tdefault\t/tmp/does-not-exist\n";
    try std.testing.expectEqual(Status.ok, costbar_session_monitor_set_roots(monitor, .{
        .ptr = roots.ptr,
        .len = roots.len,
    }));
    var json = Bytes{};
    try std.testing.expectEqual(Status.ok, costbar_session_monitor_poll(monitor, 100, &json));
    const text = json.ptr.?[0..json.len];
    try std.testing.expect(std.mem.indexOf(u8, text, "\"any_busy\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"providers\":[]") != null);
}
