const std = @import("std");

const vulkan = @import("../vulkan/vulkan.zig");
const vk = vulkan.lib;

const glfw = @import("../glfw.zig");

const launcher = @import("../../launcher.zig");

const box = @import("box.zig");
const draw = @import("../vulkan/draw.zig");

pub const particle_size: f32 = 10.0;

/// The particle type that the SPH system likes to work with.
///
/// Only the position and color are forwarded to the gpu.
pub const OpParticle = struct {
    position: box.Vec3,
    color: box.Vec4,

    velocity: box.Vec3 = .splat(0.0),
    acceleration: box.Vec3 = .splat(0.0),
    viscosity: f32 = 0.0,

    mass: f32,
    density: f32,
    pressure: f32,

    pub fn at(self: *const OpParticle, i: usize) f32 {
        return self.position.at(i);
    }
};

/// The particle type that is passed to the shader.
///
/// Only contains position and color information.
pub const NativeParticle = struct {
    position: box.Vec3.VecType,
    color: box.Vec4.VecType,

    pub fn init(op: OpParticle) NativeParticle {
        return .{
            .position = op.position.vec,
            .color = op.color.vec,
        };
    }

    pub fn bindingDescription() vk.VertexInputBindingDescription {
        return .{
            .binding = 0,
            .stride = @sizeOf(NativeParticle),
            .input_rate = .vertex,
        };
    }

    pub fn attributeDescriptions() [2]vk.VertexInputAttributeDescription {
        return .{
            .{
                .binding = 0,
                .location = 0,
                .format = .r32g32b32_sfloat,
                .offset = @offsetOf(NativeParticle, "position"),
            },
            .{
                .binding = 0,
                .location = 1,
                .format = .r32g32b32a32_sfloat,
                .offset = @offsetOf(NativeParticle, "color"),
            },
        };
    }
};
