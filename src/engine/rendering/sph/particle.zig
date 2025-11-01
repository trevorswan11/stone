const std = @import("std");

const vulkan = @import("../vulkan/vulkan.zig");
const vk = vulkan.lib;

const glfw = @import("../glfw.zig");

const launcher = @import("../../launcher.zig");

const box = @import("box.zig");
const draw = @import("../vulkan/draw.zig");

pub const OpParticle = struct {
    position: box.Vec3,
    velocity: box.Vec3,
    color: box.Vec4,

    pub fn at(self: *const OpParticle, i: usize) f32 {
        return self.position.at(i);
    }
};

pub const NativeParticle = struct {
    position: box.Vec3.VecType,
    color: box.Vec4.VecType,
    velocity: box.Vec3.VecType,

    pub fn init(op: OpParticle) NativeParticle {
        return .{
            .position = op.position.vec,
            .color = op.color.vec,
            .velocity = op.velocity.vec,
        };
    }

    pub fn bindingDescription() vk.VertexInputBindingDescription {
        return .{
            .binding = 0,
            .stride = @sizeOf(NativeParticle),
            .input_rate = .vertex,
        };
    }

    pub fn attributeDescriptions() [3]vk.VertexInputAttributeDescription {
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
            .{
                .binding = 0,
                .location = 2,
                .format = .r32g32b32_sfloat,
                .offset = @offsetOf(NativeParticle, "velocity"),
            },
        };
    }
};
