const std = @import("std");
const gpu = std.gpu;

const Vec4 = @Vector(4, f32);
const Mat4 = [4]Vec4;

const UniformBufferObject = extern struct {
    model: Mat4,
    view: Mat4,
    proj: Mat4,
};

extern const ubo: UniformBufferObject addrspace(.uniform);

extern const in_position: @Vector(2, f32) addrspace(.input);
extern const in_color: @Vector(3, f32) addrspace(.input);

extern var frag_color: @Vector(3, f32) addrspace(.output);

export fn main() callconv(.spirv_vertex) void {
    gpu.location(&in_position, 0);
    gpu.location(&in_color, 1);
    gpu.location(&frag_color, 0);
    gpu.binding(&ubo, 0, 0);

    const position: Vec4 = .{ in_position[0], in_position[1], 0.0, 1.0 };
    const perspective: Mat4 = mat4_mul(mat4_mul(ubo.proj, ubo.view), ubo.model);
    gpu.position_out.* = mat4_mulVec(perspective, position);

    frag_color = in_color;
}

fn vec4_dot(a: Vec4, b: Vec4) f32 {
    return @reduce(.Add, a * b);
}

fn mat4_transpose(mat: Mat4) Mat4 {
    var out: Mat4 = undefined;
    inline for (0..4) |i| {
        inline for (0..4) |j| {
            out[j][i] = mat[i][j];
        }
    }
    return out;
}

fn mat4_mulVec(mat: Mat4, vec: Vec4) Vec4 {
    var out: Vec4 = undefined;
    inline for (0..4) |i| {
        out[i] = vec4_dot(mat[i], vec);
    }
    return out;
}

fn mat4_mul(a: Mat4, b: Mat4) Mat4 {
    var out: Mat4 = undefined;
    const other_T = mat4_transpose(b);
    inline for (0..4) |i| {
        inline for (0..4) |k| {
            out[i][k] = vec4_dot(a[i], other_T[k]);
        }
    }
    return out;
}
