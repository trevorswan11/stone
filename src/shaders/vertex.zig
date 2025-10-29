const std = @import("std");
const gpu = std.gpu;

const positions: [3]@Vector(2, f32) = .{
    .{ 0.0, -0.5 },
    .{ 0.5, 0.5 },
    .{ -0.5, 0.5 },
};

const colors: [3]@Vector(3, f32) = .{
    .{ 1.0, 0.0, 0.0 },
    .{ 0.0, 1.0, 0.0 },
    .{ 0.0, 0.0, 1.0 },
};

extern var frag_color: @Vector(3, f32) addrspace(.output);

export fn main() callconv(.spirv_vertex) void {
    gpu.position_out.* = .{
        positions[gpu.vertex_index][0],
        positions[gpu.vertex_index][1],
        0.0,
        1.0,
    };

    gpu.location(&frag_color, 0);
    frag_color = colors[gpu.vertex_index];
}
