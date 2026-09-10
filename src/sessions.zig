const std = @import("std");

pub const model = @import("sessions/model.zig");
pub const claude = @import("sessions/claude.zig");
pub const codex = @import("sessions/codex.zig");
pub const process = @import("sessions/process.zig");

pub const State = model.State;
pub const Summary = model.Summary;
pub const Session = model.Session;
pub const ProviderActivity = model.ProviderActivity;
pub const Snapshot = model.Snapshot;
pub const TransitionKind = model.TransitionKind;
pub const Transition = model.Transition;
pub const Root = model.Root;
pub const Previous = model.Previous;
pub const summarize = model.summarize;
pub const collectTransitions = model.collectTransitions;

pub const Monitor = struct {
    allocator: std.mem.Allocator,
    roots: std.ArrayList(Root) = .empty,
    snapshot_arena: std.heap.ArenaAllocator,
    previous_arena: std.heap.ArenaAllocator,
    previous: []Previous = &.{},
    first_poll: bool = true,
    last_snapshot: Snapshot = .{
        .generated_at_unix = 0,
        .any_busy = false,
        .any_waiting = false,
        .providers = &.{},
    },
    last_transitions: []Transition = &.{},

    pub fn init(allocator: std.mem.Allocator) Monitor {
        return .{
            .allocator = allocator,
            .snapshot_arena = .init(allocator),
            .previous_arena = .init(allocator),
        };
    }

    pub fn deinit(self: *Monitor) void {
        self.clearRoots();
        self.roots.deinit(self.allocator);
        self.snapshot_arena.deinit();
        self.previous_arena.deinit();
    }

    pub fn setRoots(self: *Monitor, roots: []const Root) !void {
        self.clearRoots();
        try self.roots.ensureTotalCapacity(self.allocator, roots.len);
        for (roots) |root| {
            self.roots.appendAssumeCapacity(.{
                .provider_id = try self.allocator.dupe(u8, root.provider_id),
                .profile_id = try self.allocator.dupe(u8, root.profile_id),
                .home_path = try self.allocator.dupe(u8, root.home_path),
            });
        }
        self.first_poll = true;
        self.previous = &.{};
        _ = self.previous_arena.reset(.retain_capacity);
    }

    pub fn poll(
        self: *Monitor,
        io: std.Io,
        now_unix: i64,
        is_live: claude.LivenessFn,
    ) !Snapshot {
        var snapshot_arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer snapshot_arena.deinit();
        const arena = snapshot_arena.allocator();

        var providers: std.ArrayList(ProviderActivity) = .empty;
        var remembered: std.ArrayList(Previous) = .empty;
        var any_busy = false;
        var any_waiting = false;

        for (self.roots.items) |root| {
            const scanned = if (std.mem.eql(u8, root.provider_id, "claude"))
                try claude.scan(arena, io, root.home_path, root.profile_id, now_unix, is_live)
            else if (std.mem.eql(u8, root.provider_id, "codex"))
                try codex.scan(arena, io, root.home_path, root.profile_id, now_unix)
            else
                continue;
            if (scanned.len == 0) continue;
            const summary = summarize(scanned) orelse continue;
            any_busy = any_busy or summary == .working;
            any_waiting = any_waiting or summary == .waiting;
            const provider_id = try arena.dupe(u8, root.provider_id);
            try providers.append(arena, .{
                .provider_id = provider_id,
                .profile_id = try arena.dupe(u8, root.profile_id),
                .sessions = scanned,
            });
            for (scanned) |item| {
                try remembered.append(arena, .{
                    .id = item.id,
                    .provider_id = provider_id,
                    .state = item.state,
                    .name = item.name,
                    .pid = item.pid,
                });
            }
        }

        const snapshot = Snapshot{
            .generated_at_unix = now_unix,
            .any_busy = any_busy,
            .any_waiting = any_waiting,
            .providers = try providers.toOwnedSlice(arena),
        };
        const transitions = try collectTransitions(
            arena,
            self.previous,
            snapshot.providers,
            self.first_poll,
        );

        var stored_arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer stored_arena.deinit();
        const stored = stored_arena.allocator();
        var stored_previous: std.ArrayList(Previous) = .empty;
        for (remembered.items) |item| {
            try stored_previous.append(stored, .{
                .id = try stored.dupe(u8, item.id),
                .provider_id = try stored.dupe(u8, item.provider_id),
                .state = item.state,
                .name = try stored.dupe(u8, item.name),
                .pid = item.pid,
            });
        }

        self.snapshot_arena.deinit();
        self.snapshot_arena = snapshot_arena;
        self.previous_arena.deinit();
        self.previous_arena = stored_arena;
        self.previous = stored_previous.items;
        self.last_snapshot = snapshot;
        self.last_transitions = transitions;
        self.first_poll = false;
        return snapshot;
    }

    fn clearRoots(self: *Monitor) void {
        for (self.roots.items) |root| {
            self.allocator.free(root.provider_id);
            self.allocator.free(root.profile_id);
            self.allocator.free(root.home_path);
        }
        self.roots.clearRetainingCapacity();
    }
};

test {
    _ = model;
    _ = claude;
    _ = codex;
    _ = process;
}
