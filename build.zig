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
    const tests = b.addTest(.{ .root_module = module, .use_llvm = llvm });
    b.step("test", "Run contract tests").dependOn(&b.addRunArtifact(tests).step);
}
