const std = @import("std");
const version = std.SemanticVersion.parse(@import("build.zig.zon").version) catch
    @compileError("invalid `.version` in build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption(u8, "version_major", @intCast(version.major));
    options.addOption(u8, "version_minor", @intCast(version.minor));
    options.addOption(u8, "version_patch", @intCast(version.patch));
    const options_mod = options.createModule();

    const mod = b.addModule("twig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "twig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "twig", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const c_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "twig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_abi.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = !target.result.cpu.arch.isWasm(),
        }),
    });
    c_lib.root_module.addImport("build_options", options_mod);
    const install_c_lib = b.addInstallArtifact(c_lib, .{});
    const install_c_header = b.addInstallHeaderFile(b.path("bindings/c/include/twig.h"), "twig.h");
    b.getInstallStep().dependOn(&install_c_lib.step);
    b.getInstallStep().dependOn(&install_c_header.step);

    const install_c_lib_step = b.step("install-c-lib", "Install the C ABI static library");
    install_c_lib_step.dependOn(&install_c_lib.step);
    install_c_lib_step.dependOn(&install_c_header.step);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    // The C ABI (`src/c_abi.zig`) isn't imported by `mod` or `exe`, so it
    // needs its own test artifact to be covered by `zig build test`.
    const c_lib_tests = b.addTest(.{
        .root_module = c_lib.root_module,
    });

    const run_c_lib_tests = b.addRunArtifact(c_lib_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_c_lib_tests.step);
}
