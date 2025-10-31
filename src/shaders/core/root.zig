pub const common = @import("math/common.zig");

pub const UniformBufferObject = extern struct {
    delta_time: f32 align(16),
    model: common.Mat4 align(16),
    view: common.Mat4 align(16),
    proj: common.Mat4 align(16),
};

test {
    _ = @import("math/common.zig");
}
