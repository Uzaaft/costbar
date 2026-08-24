const CostbarLib = @This();

const std = @import("std");
const builtin = @import("builtin");
const LibtoolStep = @import("LibtoolStep.zig");
const LipoStep = @import("LipoStep.zig");
const genericMacOSTarget = @import("Config.zig").genericMacOSTarget;

step: *std.Build.Step,
output: std.Build.LazyPath,

pub fn init(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) CostbarLib {
    const lib = b.addLibrary(.{
        .name = "costbar",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_llvm = true,
    });
    lib.bundle_compiler_rt = true;
    lib.bundle_ubsan_rt = true;

    if (target.result.os.tag.isDarwin() and builtin.os.tag.isDarwin()) {
        const combined = LibtoolStep.create(b, .{
            .name = "costbar",
            .out_name = "libcostbar.a",
            .sources = &.{lib.getEmittedBin()},
        });
        combined.step.dependOn(&lib.step);
        return .{
            .step = combined.step,
            .output = combined.output,
        };
    }

    return .{
        .step = &lib.step,
        .output = lib.getEmittedBin(),
    };
}

pub fn initMacOSUniversal(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
) CostbarLib {
    const aarch64 = init(b, genericMacOSTarget(b, .aarch64), optimize);
    const x86_64 = init(b, genericMacOSTarget(b, .x86_64), optimize);
    const universal = LipoStep.create(b, .{
        .name = "costbar",
        .out_name = "libcostbar.a",
        .input_a = aarch64.output,
        .input_b = x86_64.output,
    });
    return .{
        .step = universal.step,
        .output = universal.output,
    };
}

pub fn install(self: *const CostbarLib) void {
    const b = self.step.owner;
    b.getInstallStep().dependOn(&b.addInstallLibFile(
        self.output,
        "libcostbar.a",
    ).step);
}
