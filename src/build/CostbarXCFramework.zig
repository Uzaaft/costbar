const CostbarXCFramework = @This();

const std = @import("std");
const CostbarLib = @import("CostbarLib.zig");
const XCFrameworkStep = @import("XCFrameworkStep.zig");
const Target = @import("xcframework.zig").Target;
const genericMacOSTarget = @import("Config.zig").genericMacOSTarget;

xcframework: *XCFrameworkStep,
target: Target,

pub fn init(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    target: Target,
) CostbarXCFramework {
    const macos_universal = CostbarLib.initMacOSUniversal(b, optimize);
    const macos_native = CostbarLib.init(
        b,
        genericMacOSTarget(b, null),
        optimize,
    );

    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(b.path("include/costbar.h"), "costbar.h");
    _ = wf.addCopyFile(b.path("include/module.modulemap"), "module.modulemap");
    const headers = wf.getDirectory();

    const xcframework = XCFrameworkStep.create(b, .{
        .name = "CostbarKit",
        .out_path = "macos/CostbarKit.xcframework",
        .libraries = switch (target) {
            .universal => &.{.{
                .source = .{ .library = macos_universal.output },
                .headers = headers,
            }},
            .native => &.{.{
                .source = .{ .library = macos_native.output },
                .headers = headers,
            }},
        },
    });

    return .{
        .xcframework = xcframework,
        .target = target,
    };
}

pub fn install(self: *const CostbarXCFramework) void {
    self.addStepDependencies(self.xcframework.step.owner.getInstallStep());
}

pub fn addStepDependencies(
    self: *const CostbarXCFramework,
    other_step: *std.Build.Step,
) void {
    other_step.dependOn(self.xcframework.step);
}
