const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os_tag = target.result.os.tag;

    {
        var io_impl = std.Io.Threaded.init(b.allocator, .{});
        defer io_impl.deinit();
        const io = io_impl.io();
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, "lib/build/include") catch @panic("Failed creating include directory");
        cwd.createDirPath(io, "lib/build/lib") catch @panic("Failed creating lib directory");
        cwd.createDirPath(io, "lib/expat/build") catch @panic("Failed creating build directory");
    }

    // const expat_mod = b.createModule(.{
    //     .target = target,
    //     .optimize = optimize,
    //     .link_libc = true,
    // });
    //
    // expat_mod.addIncludePath(b.path("lib/expat/lib"));
    // expat_mod.addCSourceFiles(.{
    //     .files = &.{
    //         "lib/expat/lib/xmlparse.c",
    //         "lib/expat/lib/xmlrole.c",
    //         "lib/expat/lib/xmltok.c",
    //     },
    //     .flags = if (os_tag == .windows) &.{"-DXML_STATIC"} else &.{
    //         "-DXML_STATIC",
    //         if (os_tag.isDarwin() or os_tag == .freebsd)
    //             "-DHAVE_ARC4RANDOM_BUF"
    //         else if (os_tag == .linux)
    //             "-DHAVE_GETRANDOM"
    //         else
    //             "-DXML_POOR_ENTROPY",
    //     },
    // });
    //
    // const expat = b.addLibrary(.{
    //     .linkage = .static,
    //     .name = "expat",
    //     .root_module = expat_mod,
    // });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // exe_mod.addIncludePath(b.path("lib/expat/lib"));
    // exe_mod.linkLibrary(expat);

    exe_mod.addIncludePath(b.path("lib/build/include"));
    exe_mod.addLibraryPath(b.path("lib/build/lib"));
    exe_mod.linkSystemLibrary(if (os_tag == .windows) "expatMT" else "expat", .{
        .needed = true,
        .preferred_link_mode = .static,
        .search_strategy = .no_fallback,
    });

    const exe = b.addExecutable(.{
        .name = "xrss",
        .root_module = exe_mod,
    });

    if (os_tag == .windows) {
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
