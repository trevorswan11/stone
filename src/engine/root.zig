pub const vk = @import("vulkan");

pub const vert_spv align(@alignOf(u32)) = @embedFile("vertex_shader").*;
pub const frag_spv align(@alignOf(u32)) = @embedFile("fragment_shader").*;

pub const glfw = @import("rendering/backend/glfw.zig");
pub const vulkan = @import("rendering/backend/vulkan.zig");
pub const Stone = @import("launcher.zig").Stone;
