const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const clap = b.dependency("clap", .{});
    const knfo = b.dependency("knfo", .{});

    const exe = b.addExecutable(.{
        .name = "jmp",
        .root_source_file = .{ .path = "jmp.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("clap", clap.module("clap"));
    exe.root_module.addImport("knfo", knfo.module("known-folders"));

    const tst = b.addTest(.{
        .root_source_file = .{ .path = "jmp.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_test = b.addRunArtifact(tst);

    b.default_step.dependOn(&run_test.step);
    b.installArtifact(exe);
}
