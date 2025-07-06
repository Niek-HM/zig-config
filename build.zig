const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Modules can depend on one another using the `std.Build.Module.addImport` function.
    // This is what allows Zig source code to use `@import("foo")` where 'foo' is not a
    // file path. In this case, we set up `exe_mod` to import `lib_mod`.
    exe_mod.addImport("zig_config", lib_mod);

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zig_config",
        .root_module = lib_mod,
    });

    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "zig_config",
        .root_module = exe_mod,
    });

    // ------------------------------
    // Individual test files
    // ------------------------------

    const env_tests = b.addTest(.{
        .root_source_file = b.path("tests/env_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    env_tests.root_module.addImport("config", lib_mod);

    const ini_tests = b.addTest(.{
        .root_source_file = b.path("tests/ini_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    ini_tests.root_module.addImport("config", lib_mod);

    const toml_tests = b.addTest(.{
        .root_source_file = b.path("tests/toml_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    toml_tests.root_module.addImport("config", lib_mod);

    const other_tests = b.addTest(.{
        .root_source_file = b.path("tests/other_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    other_tests.root_module.addImport("config", lib_mod);

    b.step("env-tests", "Run env_tests.zig").dependOn(&b.addRunArtifact(env_tests).step);
    b.step("ini-tests", "Run ini_tests.zig").dependOn(&b.addRunArtifact(ini_tests).step);
    b.step("toml-tests", "Run toml_tests.zig").dependOn(&b.addRunArtifact(toml_tests).step);
    b.step("other-tests", "Run other_tests.zig").dependOn(&b.addRunArtifact(other_tests).step);

    // ------------------------------
    // Combined test runner: zig build test
    // ------------------------------
    const all_tests = b.step("all-tests", "Run all tests");
    all_tests.dependOn(&b.addRunArtifact(env_tests).step);
    all_tests.dependOn(&b.addRunArtifact(ini_tests).step);
    all_tests.dependOn(&b.addRunArtifact(toml_tests).step);
    all_tests.dependOn(&b.addRunArtifact(other_tests).step);

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
