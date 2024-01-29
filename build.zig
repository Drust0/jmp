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

    b.installArtifact(exe);
}
