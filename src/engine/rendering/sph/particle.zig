const std = @import("std");

const vulkan = @import("../vulkan/vulkan.zig");
const vk = vulkan.lib;

const glfw = @import("../glfw.zig");

const launcher = @import("../../launcher.zig");

const box = @import("box.zig");
const draw = @import("../vulkan/draw.zig");

pub const OpParticle = struct {
    position: box.Vec3,
    velocity: box.Vec3,
    color: box.Vec4,

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
            particle.position = .init(.{ pos_x, circle_y, random.float(f32) });

            if (r == 0.0) {
                const rand_theta = random.float(f32) * 2 * std.math.pi;
                const vel_vec: box.Vec3 = box.Vec3.init(.{ @cos(rand_theta), @sin(rand_theta), rand_theta });
                particle.velocity = vel_vec.scale(0.25);
            } else {
                const vel_vec: box.Vec3 = .init(.{ circle_x, circle_y, random.float(f32) });
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
    const wall: f32 = 0.5;

    for (stone.particles) |*p| {
        p.position = .spawn(p.position.vec + p.velocity.scale(dt).vec);

        if (p.position.vec[0] <= -wall or p.position.vec[0] >= wall) {
            p.velocity.vec[0] *= -1;
        }

        if (p.position.vec[1] <= -wall or p.position.vec[1] >= wall) {
            p.velocity.vec[1] *= -1;
        }

        if (p.position.vec[2] <= 0.0 or p.position.vec[2] >= 1.0) {
            p.velocity.vec[2] *= -1;
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

pub const NativeParticle = struct {
    position: box.Vec3.VecType,
    color: box.Vec4.VecType,
    velocity: box.Vec3.VecType,

    pub fn init(op: OpParticle) NativeParticle {
        return .{
            .position = op.position.vec,
            .velocity = op.velocity.vec,
            .color = op.color.vec,
        };
    }

    pub fn bindingDescription() vk.VertexInputBindingDescription {
        return .{
            .binding = 0,
            .stride = @sizeOf(NativeParticle),
            .input_rate = .vertex,
        };
    }

    pub fn attributeDescriptions() [3]vk.VertexInputAttributeDescription {
        return .{
            .{
                .binding = 0,
                .location = 0,
                .format = .r32g32b32_sfloat,
                .offset = @offsetOf(NativeParticle, "position"),
            },
            .{
                .binding = 0,
                .location = 1,
                .format = .r32g32b32a32_sfloat,
                .offset = @offsetOf(NativeParticle, "color"),
            },
            .{
                .binding = 0,
                .location = 2,
                .format = .r32g32b32_sfloat,
                .offset = @offsetOf(NativeParticle, "velocity"),
            },
        };
    }
};
