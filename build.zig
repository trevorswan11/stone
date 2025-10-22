const std = @import("std");
const builtin = @import("builtin");

comptime {
    const current_zig = builtin.zig_version;
    const required_zig = std.SemanticVersion.parse("0.15.2") catch unreachable;

    if (current_zig.order(required_zig) != .eq) {
        const error_message =
            \\Sorry, it looks like your version of Zig isn't right. :-(
            \\
            \\Stone requires Zig version {}
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

    const core = b.addModule("core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const stone = b.addExecutable(.{
        .name = "stone",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "core", .module = core },
            },
        }),
        .use_llvm = true,
    });
    b.installArtifact(stone);

    // Prevent a console from opening on windows
    const disable_console = b.option(
        bool,
        "window",
        "Disables the opening on a console with the application on windows",
    ) orelse (optimize == .ReleaseFast or optimize == .ReleaseSmall);

    if (target.result.os.tag == .windows and disable_console) {
        stone.subsystem = .Windows;
    }

    // Add necessary steps and remaining artifacts
    const test_step = b.step("test", "Run tests");
    addGraphicsDeps(b, stone, target);
    const examples = addCoreExamples(b, core, target, optimize);
    try addShaders(b, stone, test_step, examples, &.{
        .{ .name = "vertex_shader", .source_path = "shaders/vertex.zig", .destination_name = "vertex.spv" },
        .{ .name = "fragment_shader", .source_path = "shaders/fragment.zig", .destination_name = "fragment.spv" },
    });
    addUtils(b);
    addRunStep(b, stone);

    addToTestStep(b, stone.root_module, test_step);
    addToTestStep(b, core, test_step);
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
    target: std.Build.ResolvedTarget,
) void {
    const is_wayland = b.option(
        bool,
        "wayland",
        "[Currently Broken] Use the wayland backend on linux, defaults to X11", // TODO: Fix message once wayland is supported
    ) orelse false;

    if (target.result.os.tag == .linux and is_wayland) {
        @panic("Wayland is not currently supported");
    }

    const vulkan = b.dependency("vulkan", .{
        .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
    }).module("vulkan-zig");
    exe.root_module.addImport("vulkan", vulkan);

    const glfw = b.dependency("glfw", .{});
    exe.addIncludePath(glfw.path("include/GLFW"));
    exe.addIncludePath(glfw.path("src"));
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
        exe.root_module.addCSourceFile(.{
            .file = glfw.path(src orelse continue),
            .flags = &.{ platform_define, optimize_flag },
        });
    }

    // Platform specific libraries
    switch (target.result.os.tag) {
        .windows => {
            exe.root_module.linkSystemLibrary("gdi32", .{});
            exe.root_module.linkSystemLibrary("user32", .{});
            exe.root_module.linkSystemLibrary("shell32", .{});
        },
        .linux => {
            if (is_wayland) {
                exe.root_module.linkSystemLibrary("wayland-client", .{});
                exe.root_module.linkSystemLibrary("wayland-cursor", .{});
                exe.root_module.linkSystemLibrary("wayland-egl", .{});
                exe.root_module.linkSystemLibrary("egl", .{});
                exe.root_module.linkSystemLibrary("drm", .{});
                exe.root_module.linkSystemLibrary("gbm", .{});

                // TODO: Wayland xdg header dependency resolution
            } else {
                exe.root_module.linkSystemLibrary("X11", .{});
                exe.root_module.linkSystemLibrary("Xrandr", .{});
                exe.root_module.linkSystemLibrary("Xi", .{});
                exe.root_module.linkSystemLibrary("Xxf86vm", .{});
                exe.root_module.linkSystemLibrary("Xcursor", .{});
                exe.root_module.linkSystemLibrary("GL", .{});
            }

            exe.root_module.linkSystemLibrary("pthread", .{});
            exe.root_module.linkSystemLibrary("dl", .{});
            exe.root_module.linkSystemLibrary("m", .{});
        },
        .macos => {
            exe.root_module.linkFramework("Cocoa", .{});
            exe.root_module.linkFramework("IOKit", .{});
            exe.root_module.linkFramework("CoreFoundation", .{});
            exe.root_module.linkFramework("CoreVideo", .{});
            exe.root_module.linkFramework("QuartzCore", .{});
        },
        else => unreachable,
    }
}

/// Compiles all provided shaders using zig's spirv target.
/// Compiled shaders are emitted to the shaders directory in the prefix path.
///
/// Currently uses a compilation workaround due to https://github.com/ziglang/zig/issues/23883
fn addShaders(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    test_step: *std.Build.Step,
    examples: anytype,
    comptime shaders: []const struct {
        name: []const u8,
        source_path: []const u8,
        destination_name: []const u8,
    },
) !void {
    const ExamplesType = @TypeOf(examples);
    const examples_type_info = @typeInfo(ExamplesType);
    if (examples_type_info != .@"struct") {
        @compileError("expected tuple or struct argument, found " ++ @typeName(ExamplesType));
    }

    const spirv_target = b.resolveTargetQuery(.{
        .cpu_arch = .spirv32,
        .os_tag = .vulkan,
        .cpu_model = .{ .explicit = &std.Target.spirv.cpu.vulkan_v1_2 },
        .ofmt = .spirv,
    });
    _ = spirv_target;

    try std.fs.cwd().makePath("zig-out/shaders/");

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

        // exe.root_module.addAnonymousImport(
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
        test_step.dependOn(&shader.step);

        const fields_info = examples_type_info.@"struct".fields;
        inline for (fields_info) |field| {
            const executable: *std.Build.Step.Compile = @field(examples, field.name);
            executable.step.dependOn(&shader.step);
        }

        exe.root_module.addAnonymousImport(shader_info.name, .{
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

fn addToTestStep(b: *std.Build, module: *std.Build.Module, step: *std.Build.Step) void {
    const tests = b.addTest(.{
        .root_module = module,
    });
    const run_tests = b.addRunArtifact(tests);
    step.dependOn(&run_tests.step);
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
