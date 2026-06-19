const builtin = @import("builtin");
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    exe_mod.addIncludePath(b.path("lib/build/include"));
    exe_mod.addLibraryPath(b.path("lib/build/lib"));
    exe_mod.linkSystemLibrary("expat", .{
        .needed = true,
        .preferred_link_mode = .static,
        .search_strategy = .no_fallback,
    });

    const exe = b.addExecutable(.{
        .name = "xrss",
        .root_module = exe_mod,
    });

    if (b.graph.host.result.os.tag == .windows) {
        const build_expat_ps = b.addSystemCommand(
            &.{ "powershell", "-ExecutionPolicy", "Bypass", "-File", "build-expat.ps1" },
        );
        exe.step.dependOn(&build_expat_ps.step);
    } else {
        const build_expat_bash = b.addSystemCommand(
            &.{ "bash", "build-expat.sh" },
        );
        exe.step.dependOn(&build_expat_bash.step);
    }

    b.installArtifact(exe);

    const exe_check = b.addExecutable(.{
        .name = "foo",
        .root_module = exe_mod,
    });

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const check = b.step("check", "Check if app compiles");
    check.dependOn(&exe_check.step);

    const exe_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
