const std = @import("std");

const vulkan = @import("vulkan.zig");
const vk = vulkan.lib;

const glfw = @import("../glfw.zig");

const launcher = @import("../../launcher.zig");

/// Creates a shader module from the given bytes.
///
/// Must be freed by the logical device when done.
pub fn createShaderModule(
    stone: *launcher.Stone,
    bytes: [:0]align(@alignOf(u32)) const u8,
) !vk.ShaderModule {
    const shader_create_info: vk.ShaderModuleCreateInfo = .{
        .s_type = .shader_module_create_info,
        .code_size = bytes.len,
        .p_code = @ptrCast(bytes.ptr),
    };

    return try stone.logical_device.createShaderModule(
        &shader_create_info,
        null,
    );
}
