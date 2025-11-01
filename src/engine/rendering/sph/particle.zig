const std = @import("std");

const vulkan = @import("../vulkan/vulkan.zig");
const vk = vulkan.lib;

const glfw = @import("../glfw.zig");

const launcher = @import("../../launcher.zig");

const pipeline = @import("../vulkan/pipeline.zig");
const draw = @import("../vulkan/draw.zig");

pub const OpParticle = struct {
    position: pipeline.Vec3,
    velocity: pipeline.Vec3,
    color: pipeline.Vec4,

    /// Creates n particles with random initial conditions.
    ///
    /// The caller is responsible for freeing the slice.
    pub fn spawn(stone: *launcher.Stone, seed: u64, n: usize) ![]OpParticle {
        const particles = try stone.allocator.alloc(OpParticle, n);

        var prng: std.Random.DefaultPrng = .init(seed);
        const random = prng.random();

        const h_float: f32 = @floatFromInt(stone.swapchain.extent.height);
        const w_float: f32 = @floatFromInt(stone.swapchain.extent.width);

        for (particles) |*particle| {
            const r = 0.25 * random.float(f32);
            const theta = random.float(f32) * 2 * std.math.pi;

            const circle_x = r * @cos(theta);
            const circle_y = r * @sin(theta);

            const pos_x = circle_x * (h_float / w_float);
            particle.position = .init(.{ pos_x, circle_y, 0.0 });

            if (r == 0.0) {
                const rand_theta = random.float(f32) * 2 * std.math.pi;
                particle.velocity = pipeline.Vec3.init(.{ @cos(rand_theta), @sin(rand_theta), 0.0 }).scale(0.25);
            } else {
                const vel_vec = pipeline.Vec3.init(.{ circle_x, circle_y, 0.0 });
                particle.velocity = vel_vec.normalize().scale(0.25);
            }
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

pub fn updateParticles(stone: *launcher.Stone) void {
    const dt = stone.timestep.dt;

    for (stone.particles) |*p| {
        p.position = .spawn(p.position.vec + p.velocity.scale(dt).vec);

        if (p.position.vec[0] <= -1.0 or p.position.vec[0] >= 1.0) {
            p.velocity.vec[0] *= -1;
        }
        if (p.position.vec[1] <= -1.0 or p.position.vec[1] >= 1.0) {
            p.velocity.vec[1] *= -1;
        }
    }

    const native_particles: [*]NativeParticle = @ptrCast(@alignCast(
        stone.particle_vertex_buffer.mapped,
    ));

    for (stone.particles, 0..) |op, i| {
        native_particles[i] = .init(op);
    }
}

pub const workgroup_load = 256;
pub const max_particles = workgroup_load * 32;

const NativeVec2 = pipeline.Vec2.VecType;
const NativeVec3 = pipeline.Vec3.VecType;
const NativeVec4 = pipeline.Vec4.VecType;
pub const NativeParticle = struct {
    position: NativeVec3,
    velocity: NativeVec3,
    color: NativeVec4,

    pub fn init(op: OpParticle) NativeParticle {
        return .{
            .position = op.position.vec,
            .velocity = op.velocity.vec,
            .color = op.color.vec,
        };
    }
};
