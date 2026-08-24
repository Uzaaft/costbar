const Costbar = @This();

const std = @import("std");
const builtin = @import("builtin");
const RunStep = std.Build.Step.Run;
const XCFramework = @import("CostbarXCFramework.zig");

build: *RunStep,
open: *RunStep,
copy: *RunStep,
xctest: *RunStep,

pub fn init(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    xcframework: *const XCFramework,
) !Costbar {
    const xc_config = switch (optimize) {
        .Debug => "Debug",
        .ReleaseSafe,
        .ReleaseSmall,
        .ReleaseFast,
        => "ReleaseLocal",
    };
    const xc_arch: ?[]const u8 = switch (xcframework.target) {
        .universal => null,
        .native => switch (builtin.cpu.arch) {
            .aarch64 => "arm64",
            .x86_64 => "x86_64",
            else => @panic("unsupported macOS architecture"),
        },
    };
    const app_path = b.fmt("macos/build/{s}/Costbar.app", .{xc_config});

    const build = build: {
        const env_map = try b.allocator.create(std.process.Environ.Map);
        env_map.* = .init(b.allocator);
        try env_map.put("PATH", "/usr/bin:/bin:/usr/sbin:/sbin");

        const step = RunStep.create(b, "xcodebuild");
        step.has_side_effects = true;
        step.cwd = b.path("macos");
        step.environ_map = env_map;
        step.addArgs(&.{
            "xcodebuild",
            "-target",
            "Costbar",
            "-configuration",
            xc_config,
        });
        if (xc_arch) |arch| step.addArgs(&.{ "-arch", arch });
        xcframework.addStepDependencies(&step.step);
        step.expectExitCode(0);
        break :build step;
    };

    const xctest = xctest: {
        const env_map = try b.allocator.create(std.process.Environ.Map);
        env_map.* = .init(b.allocator);
        try env_map.put("PATH", "/usr/bin:/bin:/usr/sbin:/sbin");

        const step = RunStep.create(b, "xcodebuild test");
        step.has_side_effects = true;
        step.cwd = b.path("macos");
        step.environ_map = env_map;
        step.addArgs(&.{
            "xcodebuild",
            "test",
            "-scheme",
            "Costbar",
        });
        if (xc_arch) |arch| step.addArgs(&.{ "-arch", arch });
        xcframework.addStepDependencies(&step.step);
        step.expectExitCode(0);
        break :xctest step;
    };

    const open = open: {
        const step = RunStep.create(b, "run Costbar app");
        step.has_side_effects = true;
        step.cwd = b.path("");
        step.addArgs(&.{b.fmt(
            "{s}/Contents/MacOS/Costbar",
            .{app_path},
        )});
        step.step.dependOn(&build.step);
        if (b.args) |args| step.addArgs(args);
        break :open step;
    };

    const copy = copy: {
        // cp -R preserves app-bundle symlinks but merges into an existing
        // directory. Remove only the previous installed bundle first so stale
        // test plugins or debug dylibs cannot invalidate the new signature.
        const delete = RunStep.create(b, "delete installed app bundle");
        delete.has_side_effects = true;
        delete.addArgs(&.{
            "rm",
            "-rf",
            b.fmt("{s}/Costbar.app", .{b.install_path}),
        });
        delete.step.dependOn(&build.step);

        const step = RunStep.create(b, "copy app bundle");
        step.addArgs(&.{ "cp", "-R" });
        step.addFileArg(b.path(app_path));
        step.addArg(b.fmt("{s}", .{b.install_path}));
        step.step.dependOn(&delete.step);
        break :copy step;
    };

    return .{
        .build = build,
        .open = open,
        .copy = copy,
        .xctest = xctest,
    };
}

pub fn install(self: *const Costbar) void {
    self.copy.step.owner.getInstallStep().dependOn(&self.copy.step);
}
