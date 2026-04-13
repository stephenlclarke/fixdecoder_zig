const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = b.option([]const u8, "app-version", "Application version") orelse "0.1.0";
    const git_commit = "unknown";
    const git_branch = "main";

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "app_version", version);
    build_options.addOption([]const u8, "git_commit", git_commit);
    build_options.addOption([]const u8, "git_branch", git_branch);

    const mod = b.addModule("fixdecoder", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", build_options);

    const exe = b.addExecutable(.{
        .name = "fixdecoder",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fixdecoder", .module = mod },
            },
        }),
    });
    exe.linkLibC();
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    mod_tests.linkLibC();
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    exe_tests.linkLibC();
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
