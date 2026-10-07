const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const llvm = b.option(bool, "llvm", "Use LLVM instead of the fast native backend") orelse false;
    const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "vaxis", .module = vaxis.module("vaxis") }},
    });
    module.linkSystemLibrary("pq", .{});
    const exe = b.addExecutable(.{ .name = "mz-watch", .root_module = module, .use_llvm = llvm });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run the dashboard").dependOn(&run.step);
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "vaxis", .module = vaxis.module("vaxis") }},
    });
    test_module.linkSystemLibrary("pq", .{});
    const tests = b.addTest(.{ .root_module = test_module, .use_llvm = llvm });
    const run_tests = b.addRunArtifact(tests);
    // Cache compilation, not execution of a requested test run.
    run_tests.has_side_effects = true;
    b.step("test", "Run contract tests").dependOn(&run_tests.step);
    const integration_module = b.createModule(.{
        .root_source_file = b.path("src/integration.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    integration_module.linkSystemLibrary("pq", .{});
    const integration = b.addExecutable(.{ .name = "mz-watch-integration", .root_module = integration_module, .use_llvm = llvm });
    const integration_run = b.addRunArtifact(integration);
    integration_run.addPassthruArgs();
    b.step("integration", "Test against disposable PostgreSQL (use scripts/integration.sh)").dependOn(&integration_run.step);
}
