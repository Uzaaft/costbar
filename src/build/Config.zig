const std = @import("std");
const builtin = @import("builtin");

pub fn genericMacOSTarget(
    b: *std.Build,
    arch: ?std.Target.Cpu.Arch,
) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = arch orelse builtin.target.cpu.arch,
        .os_tag = .macos,
        .os_version_min = .{ .semver = .{
            .major = 14,
            .minor = 0,
            .patch = 0,
        } },
    });
}
