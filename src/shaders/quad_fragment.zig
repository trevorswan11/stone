const std = @import("std");
const gpu = std.gpu;

extern const frag_color: @Vector(4, f32) addrspace(.input);
extern var out_color: @Vector(4, f32) addrspace(.output);

export fn main() callconv(.spirv_fragment) void {
    gpu.location(&frag_color, 0);
    gpu.location(&out_color, 0);

    out_color = frag_color;
}
