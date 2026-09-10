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

    const policy_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/usage_api.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }) });
    const run_policy_tests = b.addRunArtifact(policy_tests);
    b.step("test-usage", "Run portable usage policy and C ABI tests").dependOn(&run_policy_tests.step);
    test_step.dependOn(&run_policy_tests.step);
    const session_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/sessions.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    const run_session_tests = b.addRunArtifact(session_tests);
    b.step("test-session", "Run portable session activity tests").dependOn(&run_session_tests.step);
    test_step.dependOn(&run_session_tests.step);
    const usage_step = b.step("usage-kit", "Build the shared macOS and iOS usage policy XCFramework");

    const emit_cli = b.option(bool, "emit-cli", "Build the costbar CLI.") orelse false;
    if (emit_cli) {
        const cli = b.addExecutable(.{
            .name = "costbar",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/cli.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        b.installArtifact(cli);
    }

    const run_step = b.step("run", "Run the native macOS app");

    if (builtin.os.tag.isDarwin() and target.result.os.tag == .macos) {
        const usage_kit = @import("src/build/UsageXCFramework.zig").create(b, optimize);
        usage_step.dependOn(usage_kit.step);
        if (emit_xcframework) b.getInstallStep().dependOn(usage_kit.step);
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
        macos_app.build.step.dependOn(usage_kit.step);
        macos_app.xctest.step.dependOn(usage_kit.step);
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
        native_macos_app.build.step.dependOn(usage_kit.step);
        native_macos_app.xctest.step.dependOn(usage_kit.step);
        run_step.dependOn(&native_macos_app.open.step);
        test_step.dependOn(&native_macos_app.xctest.step);
    } else {
        try run_step.addError("the Costbar app can only run on macOS", .{});
    }
}
