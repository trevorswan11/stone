const std = @import("std");

const vulkan = @import("../vulkan/vulkan.zig");
const vk = vulkan.lib;

const glfw = @import("../glfw.zig");

const launcher = @import("../../launcher.zig");

const pipeline = @import("../vulkan/pipeline.zig");
const draw = @import("../vulkan/draw.zig");

pub const OpParticle = struct {
    position: pipeline.Vec2,
    velocity: pipeline.Vec2,
    color: pipeline.Vec4,

    /// Creates n particles with random initial conditions.
    ///
    /// The caller is responsible for freeing the slice.
    pub fn spawn(allocator: std.mem.Allocator, seed: u64, n: usize) ![]OpParticle {
        const particles = try allocator.alloc(OpParticle, n);

        var prng: std.Random.DefaultPrng = .init(seed);
        const random = prng.random();

        const h_float: f32 = @floatFromInt(launcher.initial_window_height);
        const w_float: f32 = @floatFromInt(launcher.initial_window_width);

        for (particles) |*particle| {
            const r = 0.25 * @sqrt(random.float(f32));
            const theta = random.float(f32) * 2 * std.math.pi;
            const x = r * @cos(theta) * (h_float / w_float);
            const y = r * @sin(theta);

            const position: pipeline.Vec2 = .init(.{ x, y });
            particle.position = position;
            particle.velocity = position.normalize().scale(0.00025);
            particle.color = .init(.{
                random.float(f32),
                random.float(f32),
                random.float(f32),
                1.0,
            });
        }

        return particles;
    }
};

pub const workgroup_load = 256;
pub const max_particles = workgroup_load * 32;

const NativeVec2 = pipeline.Vec2.VecType;
const NativeVec3 = pipeline.Vec3.VecType;
const NativeVec4 = pipeline.Vec4.VecType;
pub const NativeParticle = struct {
    position: NativeVec2,
    velocity: NativeVec2,
    color: NativeVec4,

    pub fn init(op: OpParticle) NativeParticle {
        return .{
            .position = op.position.vec,
            .velocity = op.velocity.vec,
            .color = op.color.vec,
        };
    }
};
