const std = @import("std");
const builtin = @import("builtin");

comptime {
    const current_zig = builtin.zig_version;
    const required_zig = std.SemanticVersion.parse("0.15.2") catch unreachable;

    if (current_zig.order(required_zig) != .eq) {
        const error_message =
            \\Sorry, it looks like your version of Zig isn't right. :-(
            \\
            \\Stone requires Zig version {f}
            \\
            \\https://ziglang.org/download/
            \\
        ;
        @compileError(std.fmt.comptimePrint(error_message, .{required_zig}));
    }
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    switch (target.result.os.tag) {
        .windows, .macos, .linux => {},
        else => return error.UnsupportedTarget,
    }

    // Standalone shader compute module, add to Shaders once windows build issue resolved
    const shader_core = b.addModule("core", .{
        .root_source_file = b.path("src/shaders/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });

    const core = b.addModule("core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const engine = b.addModule("engine", .{
        .root_source_file = b.path("src/engine/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "core", .module = core },
        },
    });
    addEngineOpts(b, engine);

    const stone = b.addExecutable(.{
        .name = "stone",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "core", .module = core },
                .{ .name = "engine", .module = engine },
            },
        }),
        .use_llvm = true,
    });
    b.installArtifact(stone);

    // Prevent a console from opening on windows
    const disable_console = b.option(
        bool,
        "disable-console",
        "Disables the opening of a console with the application on windows",
    ) orelse (optimize == .ReleaseFast or optimize == .ReleaseSmall);

    if (target.result.os.tag == .windows and disable_console) {
        stone.subsystem = .Windows;
    }

    // Add necessary steps and remaining artifacts
    const test_step = b.step("test", "Run core tests");
    const core_tests = addToTestStep(b, core, test_step);
    const shader_tests = addToTestStep(b, shader_core, test_step);

    const gest_step = b.step("gtest", "Run graphics tests");
    const stone_tests = addToTestStep(b, stone.root_module, gest_step);
    const engine_tests = addToTestStep(b, engine, gest_step);
    const shader_gests = addToTestStep(b, shader_core, gest_step);

    const compiles = addCoreExamples(
        b,
        core,
        target,
        optimize,
    ) ++ .{ stone_tests, core_tests, engine_tests, shader_tests, shader_gests };

    addGraphicsDeps(b, stone, .{ stone_tests.root_module, engine_tests.root_module }, target);
    try addShaders(b, stone, .{ test_step, gest_step }, compiles, &.{
        .{ .name = "vertex_shader", .source_path = "src/shaders/vertex.zig", .destination_name = "vertex.spv" },
        .{ .name = "fragment_shader", .source_path = "src/shaders/fragment.zig", .destination_name = "fragment.spv" },
        // .{ .name = "compute_shader", .source_path = "src/shaders/compute.zig", .destination_name = "compute.spv" }, // TODO: Bring me back when https://github.com/ziglang/zig/pull/24681
    });
    addUtils(b);
    addRunStep(b, stone);
}

/// Adds all relevant options to the engine module
fn addEngineOpts(b: *std.Build, engine: *std.Build.Module) void {
    const engine_opts = b.addOptions();

    const verbose = b.option(
        bool,
        "verbose",
        "Enable full verbose debug output in all modes",
    ) orelse false;
    engine_opts.addOption(
        bool,
        "verbose",
        verbose,
    );

    engine.addOptions("config", engine_opts);
}

/// Adds all graphics-related dependencies.
/// - GLFW is included based on the target build
/// - Vulkan is included trivially assuming library presence
///
/// Only windows, macos, and linux are supported.
/// The wayland flag does nothing on non-linux builds.
fn addGraphicsDeps(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    tests: anytype,
    target: std.Build.ResolvedTarget,
) void {
    const TestsType = @TypeOf(tests);
    validateTupleStruct(TestsType);

    const is_wayland = b.option(
        bool,
        "wayland",
        "[Currently Broken] Use the wayland backend on linux, defaults to X11", // TODO: Fix message once wayland is supported
    ) orelse false;

    if (target.result.os.tag == .linux and is_wayland) {
        @panic("Wayland is not currently supported");
    }

    const engine = exe.root_module.import_table.get("engine") orelse @panic("Engine module not found");
    const mods = .{engine} ++ tests;

    const mods_fields = @typeInfo(@TypeOf(mods)).@"struct".fields;
    inline for (mods_fields) |mod_field| {
        const mod: *std.Build.Module = @field(mods, mod_field.name);
        const vulkan = b.dependency("vulkan", .{
            .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
        }).module("vulkan-zig");
        mod.addImport("vulkan", vulkan);

        const glfw = b.dependency("glfw", .{});
        mod.addIncludePath(glfw.path("include/GLFW"));
        mod.addIncludePath(glfw.path("src"));
        var platform_define: []const u8 = undefined;

        // Platform specific source files and defines
        const platform_sources = blk: {
            switch (target.result.os.tag) {
                .windows => {
                    platform_define = "-D_GLFW_WIN32";
                    break :blk [_]?[]const u8{
                        "src/win32_init.c",
                        "src/win32_joystick.c",
                        "src/win32_monitor.c",
                        "src/win32_thread.c",
                        "src/win32_time.c",
                        "src/win32_window.c",
                        "src/wgl_context.c",

                        "src/win32_module.c",

                        "src/osmesa_context.c",
                        "src/egl_context.c",
                        null,
                        null,
                    };
                },
                .linux => {
                    const shared = [_]?[]const u8{
                        "src/linux_joystick.c",
                        "src/xkb_unicode.c",
                        "src/posix_time.c",
                        "src/glx_context.c",
                        "src/posix_module.c",
                        "src/posix_poll.c",

                        "src/posix_thread.c",
                        "src/osmesa_context.c",
                        "src/egl_context.c",
                    };

                    if (is_wayland) {
                        platform_define = "-D_GLFW_WAYLAND";
                        break :blk shared ++ [_]?[]const u8{
                            "src/wl_init.c",
                            "src/wl_monitor.c",
                            "src/wl_window.c",
                        };
                    } else {
                        platform_define = "-D_GLFW_X11";
                        break :blk shared ++ [_]?[]const u8{
                            "src/x11_init.c",
                            "src/x11_monitor.c",
                            "src/x11_window.c",
                        };
                    }
                },
                .macos => {
                    platform_define = "-D_GLFW_COCOA";
                    break :blk [_]?[]const u8{
                        "src/cocoa_init.m",
                        "src/cocoa_joystick.m",
                        "src/cocoa_monitor.m",
                        "src/cocoa_time.c",
                        "src/cocoa_window.m",
                        "src/nsgl_context.m",
                        "src/posix_module.c",
                        "src/posix_poll.c",

                        "src/posix_thread.c",
                        "src/osmesa_context.c",
                        "src/egl_context.c",
                        null,
                    };
                },
                else => unreachable,
            }
        };

        // Shared source files
        const common_sources = [_]?[]const u8{
            "src/init.c",
            "src/context.c",
            "src/input.c",
            "src/monitor.c",
            "src/platform.c",
            "src/vulkan.c",
            "src/window.c",

            "src/null_init.c",
            "src/null_joystick.c",
            "src/null_monitor.c",
            "src/null_window.c",
        };

        // Source compilation
        var optimize_flag: []const u8 = "";
        if (exe.root_module.optimize) |optimize| {
            switch (optimize) {
                .Debug => optimize_flag = "-O0",
                .ReleaseSafe => optimize_flag = "-O2",
                .ReleaseSmall, .ReleaseFast => optimize_flag = "-O3",
            }
        }

        const all_sources = platform_sources ++ common_sources;
        for (all_sources) |src| {
            mod.addCSourceFile(.{
                .file = glfw.path(src orelse continue),
                .flags = &.{ platform_define, optimize_flag },
            });
        }

        // Platform specific libraries
        switch (target.result.os.tag) {
            .windows => {
                mod.linkSystemLibrary("gdi32", .{});
                mod.linkSystemLibrary("user32", .{});
                mod.linkSystemLibrary("shell32", .{});
            },
            .linux => {
                if (is_wayland) {
                    mod.linkSystemLibrary("wayland-client", .{});
                    mod.linkSystemLibrary("wayland-cursor", .{});
                    mod.linkSystemLibrary("wayland-egl", .{});
                    mod.linkSystemLibrary("egl", .{});
                    mod.linkSystemLibrary("drm", .{});
                    mod.linkSystemLibrary("gbm", .{});

                    // TODO: Wayland xdg header dependency resolution
                } else {
                    mod.linkSystemLibrary("X11", .{});
                    mod.linkSystemLibrary("Xrandr", .{});
                    mod.linkSystemLibrary("Xi", .{});
                    mod.linkSystemLibrary("Xxf86vm", .{});
                    mod.linkSystemLibrary("Xcursor", .{});
                    mod.linkSystemLibrary("GL", .{});
                }

                mod.linkSystemLibrary("pthread", .{});
                mod.linkSystemLibrary("dl", .{});
                mod.linkSystemLibrary("m", .{});
            },
            .macos => {
                mod.linkFramework("Cocoa", .{});
                mod.linkFramework("IOKit", .{});
                mod.linkFramework("CoreFoundation", .{});
                mod.linkFramework("CoreVideo", .{});
                mod.linkFramework("QuartzCore", .{});
            },
            else => unreachable,
        }
    }
}

/// Compiles all provided shaders using zig's spirv target.
/// Compiled shaders are emitted to the shaders directory in the prefix path.
///
/// Currently uses a compilation workaround due to https://github.com/ziglang/zig/issues/23883
fn addShaders(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    test_steps: anytype,
    examples: anytype,
    comptime shaders: []const struct {
        name: []const u8,
        source_path: []const u8,
        destination_name: []const u8,
    },
) !void {
    const TestsType = @TypeOf(test_steps);
    validateTupleStruct(TestsType);

    const ExamplesType = @TypeOf(examples);
    validateTupleStruct(ExamplesType);

    const spirv_target = b.resolveTargetQuery(.{
        .cpu_arch = .spirv32,
        .os_tag = .vulkan,
        .cpu_model = .{ .explicit = &std.Target.spirv.cpu.vulkan_v1_2 },
        .ofmt = .spirv,
    });
    _ = spirv_target;

    try std.fs.cwd().makePath("zig-out/shaders/");
    const engine = exe.root_module.import_table.get("engine") orelse @panic("Engine module not found");

    inline for (shaders) |shader_info| {
        // Once the above linked issue is resolved, this can be used for shader compilation
        // const vert_spv = b.addObject(.{
        //     .name = shader_info.name,
        //     .root_module = b.createModule(.{
        //         .root_source_file = b.path(shader_info.source_path),
        //         .target = spirv_target,
        //         .optimize = exe.root_module.optimize,
        //     }),
        //     .use_llvm = false,
        // });

        // engine.addAnonymousImport(
        //     shader_info.name,
        //     .{ .root_source_file = vert_spv.getEmittedBin() },
        // );

        const dest_path = "zig-out/shaders/" ++ shader_info.destination_name;
        const shader = b.addSystemCommand(&[_][]const u8{
            "zig",                   "build-obj",
            "-fno-llvm",             "-ofmt=spirv",
            "-target",               "spirv32-vulkan",
            "-mcpu",                 "vulkan_v1_2",
            shader_info.source_path, "-femit-bin=" ++ dest_path,
        });

        exe.step.dependOn(&shader.step);

        const tests_fields_info = @typeInfo(TestsType).@"struct".fields;
        inline for (tests_fields_info) |field| {
            const test_step: *std.Build.Step = @field(test_steps, field.name);
            test_step.dependOn(&shader.step);
        }

        const examples_fields_info = @typeInfo(ExamplesType).@"struct".fields;
        inline for (examples_fields_info) |field| {
            const executable: *std.Build.Step.Compile = @field(examples, field.name);
            executable.step.dependOn(&shader.step);
        }

        engine.addAnonymousImport(shader_info.name, .{
            .root_source_file = b.path(dest_path),
        });
    }
}

fn addRunStep(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the engine");
    run_step.dependOn(&run_cmd.step);
}

fn addCoreExamples(
    b: *std.Build,
    core_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) struct { *std.Build.Step.Compile } {
    const single_threaded = b.option(
        bool,
        "single-threaded",
        "Run examples in single-threaded mode",
    ) orelse false;

    // Neighborhood search demo
    const search_exe = b.addExecutable(.{
        .name = "neighbor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/neighborhood/example.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "core", .module = core_module },
            },
            .single_threaded = single_threaded,
        }),
        .use_llvm = true,
    });

    const run_search_example = b.addRunArtifact(search_exe);
    run_search_example.step.dependOn(b.getInstallStep());

    const search_step = b.step("neighbor", "Run the neighborhood search 'benchmark'");
    search_step.dependOn(&run_search_example.step);
    search_step.dependOn(&b.addInstallArtifact(search_exe, .{}).step);

    return .{
        search_exe,
    };
}

fn addToTestStep(b: *std.Build, module: *std.Build.Module, step: *std.Build.Step) *std.Build.Step.Compile {
    const tests = b.addTest(.{
        .root_module = module,
    });
    const run_tests = b.addRunArtifact(tests);
    step.dependOn(&run_tests.step);
    return tests;
}

fn addUtils(b: *std.Build) void {
    // Lint
    const lint_files = b.addFmt(.{ .paths = &.{"src"}, .check = true });
    const lint_step = b.step("lint", "Check formatting in all Zig source files");
    lint_step.dependOn(&lint_files.step);

    // In-place formatting
    const fmt_files = b.addFmt(.{ .paths = &.{"src"} });
    const fmt_step = b.step("fmt", "Format all Zig source files");
    fmt_step.dependOn(&fmt_files.step);

    // Cloc
    const cloc_src = b.addSystemCommand(&.{
        "cloc",
        "build.zig",
        "src",
        "shaders",
    });

    const cloc_step = b.step("cloc", "Count total lines of Zig source code");
    cloc_step.dependOn(&cloc_src.step);

    // Clean (because uninstall broken)
    const clean_step = b.step("clean", "Clean up emitted artifacts");
    clean_step.dependOn(&b.addRemoveDirTree(b.path("zig-out")).step);
}

/// Asserts whether or not the given type is tuple struct type.
fn validateTupleStruct(comptime T: type) void {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct" or !type_info.@"struct".is_tuple) {
        @compileError("expected tuple struct argument, found " ++ @typeName(T));
    }
}
