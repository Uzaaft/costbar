const std = @import("std");
const builtin = @import("builtin");
const buildpkg = @import("src/build/main.zig");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    var target = b.standardTargetOptions(.{});
    if (target.result.os.tag == .macos and builtin.target.os.tag.isDarwin()) {
        target = buildpkg.genericMacOSTarget(b, target.query.cpu_arch);
    }

    const emit_xcframework = b.option(
        bool,
        "emit-xcframework",
        "Build macos/CostbarKit.xcframework.",
    ) orelse (builtin.os.tag.isDarwin() and target.result.os.tag == .macos);
    const emit_macos_app = b.option(
        bool,
        "emit-macos-app",
        "Build and install the native macOS app.",
    ) orelse (builtin.os.tag.isDarwin() and target.result.os.tag == .macos);
    const xcframework_target = b.option(
        buildpkg.XCFrameworkTarget,
        "xcframework-target",
        "XCFramework architecture set (native or universal).",
    ) orelse .universal;

    const core = buildpkg.CostbarLib.init(b, target, optimize);
    core.install();
    b.getInstallStep().dependOn(&b.addInstallHeaderFile(
        b.path("include/costbar.h"),
        "costbar.h",
    ).step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the Zig and native macOS tests");
    test_step.dependOn(&run_tests.step);

    const run_step = b.step("run", "Run the native macOS app");

    if (builtin.os.tag.isDarwin() and target.result.os.tag == .macos) {
        const xcframework = buildpkg.CostbarXCFramework.init(
            b,
            optimize,
            xcframework_target,
        );
        if (emit_xcframework) xcframework.install();

        const macos_app = try buildpkg.CostbarXcodebuild.init(
            b,
            optimize,
            &xcframework,
        );
        if (emit_macos_app) macos_app.install();

        const native_xcframework = buildpkg.CostbarXCFramework.init(
            b,
            optimize,
            .native,
        );
        const native_macos_app = try buildpkg.CostbarXcodebuild.init(
            b,
            optimize,
            &native_xcframework,
        );
        run_step.dependOn(&native_macos_app.open.step);
        test_step.dependOn(&native_macos_app.xctest.step);
    } else {
        try run_step.addError("the Costbar app can only run on macOS", .{});
    }
}
