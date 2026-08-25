const std = @import("std");

const backup_name = "claude-statusline-backup.json";
const helper_name = "claude-statusline";
const previous_name = "claude-statusline-previous-command";

pub fn isInstalled(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
) !bool {
    const paths = try Paths.init(allocator, home);
    defer paths.deinit(allocator);
    const maybe_bytes = readOptional(allocator, io, paths.settings) catch return false;
    const bytes = maybe_bytes orelse return false;
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
    }) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const status = parsed.value.object.get("statusLine") orelse return false;
    if (status != .object) return false;
    const command = status.object.get("command") orelse return false;
    return command == .string and std.mem.indexOf(u8, command.string, paths.helper) != null;
}

pub fn install(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
) !void {
    const paths = try Paths.init(allocator, home);
    defer paths.deinit(allocator);
    try std.Io.Dir.createDirPath(.cwd(), io, std.fs.path.dirname(paths.settings).?);
    try std.Io.Dir.createDirPath(.cwd(), io, paths.support);

    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var settings = try readJSONObject(arena, io, paths.settings);
    const existing = settings.object.get("statusLine");
    const existing_command = if (existing) |value|
        if (value == .object)
            if (value.object.get("command")) |command|
                if (command == .string) command.string else ""
            else
                ""
        else
            ""
    else
        "";
    if (std.mem.indexOf(u8, existing_command, paths.helper) != null) return;

    if (!try fileExists(io, paths.backup)) {
        var backup: std.json.ObjectMap = .empty;
        try backup.put(arena, "had_status_line", .{ .bool = existing != null });
        if (existing) |value| try backup.put(arena, "status_line", value);
        try writeJSON(allocator, io, paths.backup, .{ .object = backup });
    }
    try atomicWrite(allocator, io, paths.previous, existing_command, .default_file);
    try atomicWrite(allocator, io, paths.helper, helper_script, .executable_file);
    var helper_file = try std.Io.Dir.openFileAbsolute(io, paths.helper, .{ .mode = .read_write });
    defer helper_file.close(io);
    if (std.Io.File.Permissions.has_executable_bit) {
        try helper_file.setPermissions(io, .fromMode(0o700));
    }

    var status: std.json.ObjectMap = if (existing) |value|
        if (value == .object) value.object else std.json.ObjectMap.empty
    else
        std.json.ObjectMap.empty;
    const command = try shellQuoted(arena, paths.helper);
    try status.put(arena, "type", .{ .string = "command" });
    try status.put(arena, "command", .{ .string = command });
    try settings.object.put(arena, "statusLine", .{ .object = status });
    try writeJSON(allocator, io, paths.settings, settings);
}

pub fn restore(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
) !void {
    const paths = try Paths.init(allocator, home);
    defer paths.deinit(allocator);
    const backup_bytes = (try readOptional(allocator, io, paths.backup)) orelse return;
    defer allocator.free(backup_bytes);

    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const backup = try std.json.parseFromSliceLeaky(std.json.Value, arena, backup_bytes, .{
        .allocate = .alloc_always,
    });
    if (backup != .object) return error.InvalidBackup;
    var settings = try readJSONObject(arena, io, paths.settings);
    const had_status = if (backup.object.get("had_status_line")) |value|
        value == .bool and value.bool
    else
        false;
    if (had_status) {
        const previous = backup.object.get("status_line") orelse return error.InvalidBackup;
        try settings.object.put(arena, "statusLine", previous);
    } else {
        _ = settings.object.orderedRemove("statusLine");
    }
    try writeJSON(allocator, io, paths.settings, settings);
    std.Io.Dir.deleteFileAbsolute(io, paths.backup) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

const Paths = struct {
    settings: []u8,
    support: []u8,
    backup: []u8,
    helper: []u8,
    previous: []u8,

    fn init(allocator: std.mem.Allocator, home: []const u8) !Paths {
        const settings = try std.fs.path.join(allocator, &.{ home, ".claude/settings.json" });
        errdefer allocator.free(settings);
        const support = try std.fs.path.join(
            allocator,
            &.{ home, "Library/Application Support/Costbar" },
        );
        errdefer allocator.free(support);
        const backup = try std.fs.path.join(allocator, &.{ support, backup_name });
        errdefer allocator.free(backup);
        const helper = try std.fs.path.join(allocator, &.{ support, helper_name });
        errdefer allocator.free(helper);
        const previous = try std.fs.path.join(allocator, &.{ support, previous_name });
        return .{
            .settings = settings,
            .support = support,
            .backup = backup,
            .helper = helper,
            .previous = previous,
        };
    }

    fn deinit(self: Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.settings);
        allocator.free(self.support);
        allocator.free(self.backup);
        allocator.free(self.helper);
        allocator.free(self.previous);
    }
};

fn readJSONObject(arena: std.mem.Allocator, io: std.Io, path: []const u8) !std.json.Value {
    const bytes = (try readOptional(arena, io, path)) orelse
        return .{ .object = .empty };
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{
        .allocate = .alloc_always,
    });
    if (value != .object) return error.InvalidSettings;
    return value;
}

fn readOptional(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !?[]u8 {
    return std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(4 * 1024 * 1024)) catch |err|
        switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
}

fn fileExists(io: std.Io, path: []const u8) !bool {
    _ = std.Io.Dir.statFile(.cwd(), io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn writeJSON(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    value: std.json.Value,
) !void {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{
        .whitespace = .indent_2,
    });
    defer allocator.free(bytes);
    try atomicWrite(allocator, io, path, bytes, .default_file);
}

fn atomicWrite(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    bytes: []const u8,
    permissions: std.Io.File.Permissions,
) !void {
    const temporary = try std.fmt.allocPrint(allocator, "{s}.costbar-tmp", .{path});
    defer allocator.free(temporary);
    errdefer std.Io.Dir.deleteFileAbsolute(io, temporary) catch {};
    try std.Io.Dir.writeFile(.cwd(), io, .{
        .sub_path = temporary,
        .data = bytes,
        .flags = .{ .permissions = permissions },
    });
    try std.Io.Dir.renameAbsolute(temporary, path, io);
}

fn shellQuoted(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeByte('\'');
    for (value) |character| {
        if (character == '\'') try output.writer.writeAll("'\\''") else try output.writer.writeByte(character);
    }
    try output.writer.writeByte('\'');
    return output.toOwnedSlice();
}

const helper_script =
    \\#!/bin/sh
    \\set -u
    \\
    \\support_dir="${HOME}/Library/Application Support/Costbar"
    \\snapshot="${support_dir}/claude-status.json"
    \\previous="${support_dir}/claude-statusline-previous-command"
    \\temporary="${snapshot}.tmp.$$"
    \\input=$(/bin/cat)
    \\umask 077
    \\/usr/bin/printf '%s\n' "$input" > "$temporary"
    \\/bin/mv -f "$temporary" "$snapshot"
    \\
    \\if [ -s "$previous" ]; then
    \\    /usr/bin/printf '%s\n' "$input" | /bin/sh -c "$(/bin/cat "$previous")"
    \\    exit $?
    \\fi
    \\
    \\five=$(/usr/bin/plutil -extract rate_limits.five_hour.used_percentage raw -o - "$snapshot" 2>/dev/null || true)
    \\week=$(/usr/bin/plutil -extract rate_limits.seven_day.used_percentage raw -o - "$snapshot" 2>/dev/null || true)
    \\if [ -n "$five" ] || [ -n "$week" ]; then
    \\    /usr/bin/printf 'Claude%s%s\n' "${five:+ · 5h ${five}%}" "${week:+ · 7d ${week}%}"
    \\else
    \\    /usr/bin/printf 'Claude · Costbar sync\n'
    \\fi
;

test "shell quoting preserves spaces and apostrophes" {
    const value = try shellQuoted(std.testing.allocator, "/tmp/a b's");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("'/tmp/a b'\\''s'", value);
}

test "install and restore preserve unrelated Claude settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const home_length = try tmp.dir.realPath(std.testing.io, &home_buffer);
    const home = home_buffer[0..home_length];
    const settings_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ home, ".claude" },
    );
    defer std.testing.allocator.free(settings_dir);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, settings_dir);
    const settings_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ settings_dir, "settings.json" },
    );
    defer std.testing.allocator.free(settings_path);
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = settings_path,
        .data = "{\"theme\":\"dark\",\"statusLine\":{\"type\":\"command\",\"command\":\"old-status\"}}",
    });

    try install(std.testing.allocator, std.testing.io, home);
    try std.testing.expect(try isInstalled(std.testing.allocator, std.testing.io, home));
    try restore(std.testing.allocator, std.testing.io, home);

    const restored = try std.Io.Dir.readFileAlloc(
        .cwd(),
        std.testing.io,
        settings_path,
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(restored);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, restored, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("dark", parsed.value.object.get("theme").?.string);
    const status = parsed.value.object.get("statusLine").?.object;
    try std.testing.expectEqualStrings("old-status", status.get("command").?.string);
}
