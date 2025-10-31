pub const common = @import("math/common.zig");

pub const UniformBufferObject = extern struct {
    delta_time: f32,
    model: common.Mat4,
    view: common.Mat4,
    proj: common.Mat4,
};

test {
    _ = @import("math/common.zig");
}
