const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    stone_exe.linkSystemLibrary("glfw");

    const vulkan = b.dependency("vulkan", .{
        .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
    }).module("vulkan-zig");

    stone_exe.root_module.addImport("vulkan", vulkan);

    // Shader Compilation
    const spirv_target = b.resolveTargetQuery(.{
        .cpu_arch = .spirv32,
        .os_tag = .vulkan,
        .cpu_model = .{ .explicit = &std.Target.spirv.cpu.vulkan_v1_2 },
        .ofmt = .spirv,
    });

    const vert_spv = b.addObject(.{
        .name = "vertex_shader",
        .root_module = b.createModule(.{
            .root_source_file = b.path("shaders/vertex.zig"),
            .target = spirv_target,
        }),
        .use_llvm = false,
    });
    stone_exe.root_module.addAnonymousImport(
        "vertex_shader",
        .{ .root_source_file = vert_spv.getEmittedBin() },
    );

    const frag_spv = b.addObject(.{
        .name = "fragment_shader",
        .root_module = b.createModule(.{
            .root_source_file = b.path("shaders/fragment.zig"),
            .target = spirv_target,
        }),
        .use_llvm = false,
    });
    stone_exe.root_module.addAnonymousImport(
        "fragment_shader",
        .{ .root_source_file = frag_spv.getEmittedBin() },
    );
    // const shader_out_dir = b.path("shaders/out");
    // const shader_out_dir_path = shader_out_dir.src_path.sub_path;
    // std.fs.cwd().access(shader_out_dir_path, .{}) catch {
    //     try std.fs.cwd().makeDir(shader_out_dir.src_path.sub_path);
    // };

    // const vert_spv = b.addSystemCommand(&.{
    //     "zig", "build-obj",
    //     "-fno-llvm", "-ofmt=spirv",
    //     "-target", "spirv32-vulkan",
    //     "-mcpu", "vulkan_v1_2",
    //     "shaders/vertex.zig",
    // });

    // const frag_spv = b.addSystemCommand(&.{
    //     "zig", "build-obj",
    //     "-fno-llvm", "-ofmt=spirv",
    //     "-target", "spirv32-vulkan",
    //     "-mcpu", "vulkan_v1_2",
    //     "shaders/fragment.zig",
    // });

    // stone_exe.step.dependOn(&vert_spv.step);
    // stone_exe.step.dependOn(&frag_spv.step);

    const stone_run_cmd = b.addRunArtifact(stone_exe);
    stone_run_cmd.step.dependOn(b.getInstallStep());

    const stone_run_step = b.step("run", "Run the stone example");
    stone_run_step.dependOn(&stone_run_cmd.step);
}
