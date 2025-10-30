const std = @import("std");
const gpu = std.gpu;

extern const in_position: @Vector(2, f32) addrspace(.input);
extern const in_color: @Vector(3, f32) addrspace(.input);

extern var frag_color: @Vector(3, f32) addrspace(.output);

export fn main() callconv(.spirv_vertex) void {
    gpu.location(&in_position, 0);
    gpu.location(&in_color, 1);
    gpu.location(&frag_color, 0);

    gpu.position_out.* = .{ in_position[0], in_position[1], 0.0, 1.0 };
    frag_color = in_color;
}
