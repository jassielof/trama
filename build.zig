const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("trama", .{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const docs_step = b.step("docs", "Generate the documentation");

    const docs_lib = b.addLibrary(.{
        .root_module = mod,
        .name = "docs",
    });

    const docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    docs_step.dependOn(&docs.step);

    const tests_step = b.step("test", "Run the test suite");

    const unit_tests = b.addTest(.{
        .name = "Trama",
        .root_module = mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    tests_step.dependOn(&run_unit_tests.step);

    const check_step = b.step("check", "Run code quality checks");

    const fmt = b.addFmt(.{
        .check = true,
        .paths = &.{"src/"},
    });
    check_step.dependOn(&fmt.step);
}
