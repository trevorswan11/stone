const std = @import("std");

const vulkan = @import("../vulkan/vulkan.zig");
const vk = vulkan.lib;

const core = @import("core");
pub const Vec2 = core.Vector(f32, 2);
pub const Vec3 = core.Vector(f32, 3);
pub const Vec4 = core.Vector(f32, 4);
pub const Mat4 = core.Matrix(f32, 4, 4);

const glfw = @import("../glfw.zig");

const launcher = @import("../../launcher.zig");

const pipeline = @import("../vulkan/pipeline.zig");
const draw = @import("../vulkan/draw.zig");

pub const Vertex = struct {
    pos: Vec3.VecType,
    color: Vec4.VecType,

    pub fn bindingDescription() vk.VertexInputBindingDescription {
        return .{
            .binding = 0,
            .stride = @sizeOf(Vertex),
            .input_rate = .vertex,
        };
    }

    pub fn attributeDescriptions() [2]vk.VertexInputAttributeDescription {
        return .{
            .{
                .binding = 0,
                .location = 0,
                .format = .r32g32b32_sfloat,
                .offset = @offsetOf(Vertex, "pos"),
            },
            .{
                .binding = 0,
                .location = 1,
                .format = .r32g32b32a32_sfloat,
                .offset = @offsetOf(Vertex, "color"),
            },
        };
    }
};

pub const vertices = [_]Vertex{
    .{
        .pos = Vec3.decay(.{ -2.0, -2.0, -0.75 }),
        .color = Vec4.decay(.{ 0.5, 0.5, 0.5, 1.0 }),
    },
    .{
        .pos = Vec3.decay(.{ 2.0, -2.0, -0.75 }),
        .color = Vec4.decay(.{ 0.5, 0.5, 0.5, 1.0 }),
    },
    .{
        .pos = Vec3.decay(.{ 2.0, 2.0, -0.75 }),
        .color = Vec4.decay(.{ 0.5, 0.5, 0.5, 1.0 }),
    },
    .{
        .pos = Vec3.decay(.{ -2.0, 2.0, -0.75 }),
        .color = Vec4.decay(.{ 0.5, 0.5, 0.5, 1.0 }),
    },
};
pub const vertices_size = @sizeOf(@TypeOf(vertices));

pub const indices = [_]u16{ 0, 1, 2, 2, 3, 0 };
pub const indices_size = @sizeOf(@TypeOf(indices));
pub const index_type: vk.IndexType = blk: {
    switch (@typeInfo(@TypeOf(indices))) {
        .array => |a| {
            switch (@typeInfo(a.child)) {
                .int => |int| {
                    if (int.signedness == .signed) {
                        @compileError("indices must have unsigned int child type");
                    }

                    break :blk switch (int.bits) {
                        8 => .uint8,
                        16 => .uint16,
                        32 => .uint32,
                        else => @compileError("indices child type must be 8, 16, or 32 bit unsigned int"),
                    };
                },
                else => @compileError("indices must have int child type"),
            }
        },
        else => @compileError("indices must be a compile time array"),
    }
};
