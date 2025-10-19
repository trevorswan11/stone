const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    switch (target.result.os.tag) {
        .windows, .macos, .linux => {},
        else => return error.UnsupportedTarget,
    }

    const wayland = b.option(
        bool,
        "wayland",
        "Use the wayland backend on linux, defaults to X11",
    ) orelse false;

    const stone_exe = b.addExecutable(.{
        .name = "stone",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_llvm = true,
    });
    b.installArtifact(stone_exe);

    addVulkan(b, stone_exe);
    addGLFW(b, stone_exe, target, wayland);
    try addShaders(b, stone_exe, &.{
        .{ .name = "vertex_shader", .source_path = "shaders/vertex.zig", .destination_name = "vertex.spv" },
        .{ .name = "fragment_shader", .source_path = "shaders/fragment.zig", .destination_name = "fragment.spv" },
    });

    const stone_run_cmd = b.addRunArtifact(stone_exe);
    stone_run_cmd.step.dependOn(b.getInstallStep());

    const stone_run_step = b.step("run", "Run the stone example");
    stone_run_step.dependOn(&stone_run_cmd.step);
}

/// Adds all glfw source files and includes to the dependencies.
///
/// Only windows, macos, and linux are supported. The wayland flag does nothing on non-linux builds.
fn addGLFW(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    is_wayland: bool,
) void {
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
                };
            },
            .linux => {
                const shared = [_]?[]const u8{
                    "src/xkb_unicode.c",
                    "src/posix_time.c",
                    "src/glx_context.c",

                    "src/posix_thread.c",
                    "src/osmesa_context.c",
                    "src/egl_context.c",
                    null,
                };

                if (is_wayland) {
                    platform_define = "-D_GLFW_WAYLAND";
                    break :blk shared ++ [_]?[]const u8{
                        "src/x11_init.c",
                        "src/x11_monitor.c",
                        "src/x11_window.c",
                    };
                } else {
                    platform_define = "-D_GLFW_X11";
                    break :blk shared ++ [_]?[]const u8{
                        "src/wl_init.c",
                        "src/wl_monitor.c",
                        "src/wl_window.c",
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

    const all_sources = platform_sources ++ common_sources;
    for (all_sources) |src| {
        exe.root_module.addCSourceFile(.{
            .file = glfw.path(src orelse continue),
            .flags = &.{platform_define},
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
            exe.root_module.linkSystemLibrary("X11", .{});
            exe.root_module.linkSystemLibrary("Xrandr", .{});
            exe.root_module.linkSystemLibrary("Xi", .{});
            exe.root_module.linkSystemLibrary("Xxf86vm", .{});
            exe.root_module.linkSystemLibrary("Xcursor", .{});
            exe.root_module.linkSystemLibrary("GL", .{});
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

fn addVulkan(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const vulkan = b.dependency("vulkan", .{
        .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
    }).module("vulkan-zig");
    exe.root_module.addImport("vulkan", vulkan);
}

/// Compiles all provided shaders using zig's spirv target.
/// Compiled shaders are emitted to the shaders directory in the prefix path.
///
/// Currently uses a compilation workaround due to https://github.com/ziglang/zig/issues/23883
fn addShaders(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    comptime shaders: []const struct {
        name: []const u8,
        source_path: []const u8,
        destination_name: []const u8,
    },
) !void {
    const spirv_target = b.resolveTargetQuery(.{
        .cpu_arch = .spirv32,
        .os_tag = .vulkan,
        .cpu_model = .{ .explicit = &std.Target.spirv.cpu.vulkan_v1_2 },
        .ofmt = .spirv,
    });
    _ = spirv_target;

    try std.fs.cwd().makePath("zig-out/shaders/");

    inline for (shaders) |shader_info| {
        const dest_path = "zig-out/shaders/" ++ shader_info.destination_name;
        const shader = b.addSystemCommand(&[_][]const u8{
            "zig",                   "build-obj",
            "-fno-llvm",             "-ofmt=spirv",
            "-target",               "spirv32-vulkan",
            "-mcpu",                 "vulkan_v1_2",
            shader_info.source_path, "-femit-bin=" ++ dest_path,
        });
        exe.step.dependOn(&shader.step);

        exe.root_module.addAnonymousImport(shader_info.name, .{
            .root_source_file = b.path(dest_path),
        });
    }
}
