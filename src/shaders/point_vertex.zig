const std = @import("std");
const gpu = std.gpu;

const core = @import("core/root.zig");
const Mat4 = core.common.Mat4;
const Vec4 = core.common.Vec4;
const UniformBufferObject = core.UniformBufferObject;

extern const ubo: UniformBufferObject addrspace(.uniform);

extern const in_position: @Vector(3, f32) addrspace(.input);
extern const in_color: @Vector(4, f32) addrspace(.input);

extern var frag_color: @Vector(4, f32) addrspace(.output);

export fn main() callconv(.spirv_vertex) void {
    gpu.location(&in_position, 0);
    gpu.location(&in_color, 1);
    gpu.location(&frag_color, 0);
    gpu.binding(&ubo, 0, 0);

    const position: Vec4 = .init(.{ in_position[0], in_position[1], in_position[2], 1.0 });
    const perspective = ubo.proj.mul(ubo.view).mul(ubo.point_model);
    gpu.position_out.* = perspective.mulVec(position).raw;

    frag_color = in_color;
    gpu.point_size_out.* = ubo.particle_size;
}
