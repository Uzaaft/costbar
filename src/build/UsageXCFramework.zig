const std = @import("std");
const LibtoolStep = @import("LibtoolStep.zig");
const LipoStep = @import("LipoStep.zig");
const XCFrameworkStep = @import("XCFrameworkStep.zig");

/// The mobile policy has no provider collection, networking, or OS dependencies.
/// A separate archive keeps those capabilities out of the app and widget.
pub fn create(b: *std.Build, optimize: std.builtin.OptimizeMode) *XCFrameworkStep {
    const mac_arm = library(b, optimize, .aarch64, .macos, .none);
    const mac_intel = library(b, optimize, .x86_64, .macos, .none);
    const mac = LipoStep.create(b, .{ .name = "usage-macos", .out_name = "libcostbar_usage.a", .input_a = mac_arm, .input_b = mac_intel });
    const device = library(b, optimize, .aarch64, .ios, .none);
    const sim_arm = library(b, optimize, .aarch64, .ios, .simulator);
    const sim_intel = library(b, optimize, .x86_64, .ios, .simulator);
    const simulator = LipoStep.create(b, .{ .name = "usage-simulator", .out_name = "libcostbar_usage.a", .input_a = sim_arm, .input_b = sim_intel });
    return XCFrameworkStep.create(b, .{
        .name = "CostbarUsageKit",
        .out_path = "mobile/CostbarUsageKit.xcframework",
        .libraries = &.{
            .{ .source = .{ .framework = framework(b, mac.output) } },
            .{ .source = .{ .framework = framework(b, device) } },
            .{ .source = .{ .framework = framework(b, simulator.output) } },
        },
    });
}

fn library(b: *std.Build, optimize: std.builtin.OptimizeMode, arch: std.Target.Cpu.Arch, os: std.Target.Os.Tag, abi: std.Target.Abi) std.Build.LazyPath {
    const lib = b.addLibrary(.{
        .name = "costbar_usage",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/usage_api.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = os, .abi = abi, .os_version_min = .{ .semver = .{ .major = if (os == .macos) 14 else 17, .minor = 0, .patch = 0 } } }),
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_llvm = true,
    });
    lib.bundle_compiler_rt = true;
    lib.bundle_ubsan_rt = true;
    return LibtoolStep.create(b, .{ .name = b.fmt("usage-{s}-{s}-{s}", .{ @tagName(arch), @tagName(os), @tagName(abi) }), .out_name = "libcostbar_usage.a", .sources = &.{lib.getEmittedBin()} }).output;
}

fn framework(b: *std.Build, archive: std.Build.LazyPath) std.Build.LazyPath {
    const files = b.addWriteFiles();
    _ = files.addCopyFile(archive, "CostbarUsageKit.framework/CostbarUsageKit");
    _ = files.addCopyFile(b.path("include/usage/costbar_usage.h"), "CostbarUsageKit.framework/Headers/costbar_usage.h");
    _ = files.addCopyFile(b.path("include/usage/module.modulemap"), "CostbarUsageKit.framework/Modules/module.modulemap");
    _ = files.add("CostbarUsageKit.framework/Info.plist",
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<plist version="1.0"><dict>
        \\<key>CFBundleIdentifier</key><string>com.costbar.usage-kit</string>
        \\<key>CFBundleName</key><string>CostbarUsageKit</string>
        \\<key>CFBundleExecutable</key><string>CostbarUsageKit</string>
        \\<key>CFBundlePackageType</key><string>FMWK</string>
        \\<key>CFBundleVersion</key><string>1</string>
        \\<key>CFBundleShortVersionString</key><string>1.0</string>
        \\</dict></plist>
    );
    return files.getDirectory().path(b, "CostbarUsageKit.framework");
}
