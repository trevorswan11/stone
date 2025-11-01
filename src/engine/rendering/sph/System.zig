const std = @import("std");
const builtin = @import("builtin");

const vulkan = @import("../vulkan/vulkan.zig");
const vk = vulkan.lib;

const core = @import("core");
pub const Vec2 = core.Vector(f32, 2);
pub const Vec3 = core.Vector(f32, 3);
pub const Vec4 = core.Vector(f32, 4);
pub const Mat4 = core.Matrix(f32, 4, 4);

const box = @import("box.zig");
const particle = @import("particle.zig");

const glfw = @import("../glfw.zig");

const launcher = @import("../../launcher.zig");

const pipeline = @import("../vulkan/pipeline.zig");
const draw = @import("../vulkan/draw.zig");

const Self = @This();

const num_threads = if (builtin.single_threaded) 1 else 4;
const single_threaded = num_threads == 1;
const Search = core.Search(
    f32,
    particle.OpParticle,
    .{
        .threadedness = .{ .multithreaded = num_threads },
        .at = particle.OpParticle.at,
    },
);

pub const workgroup_load = 256;
pub const max_particles = workgroup_load * 32;

const n: usize = 30;
const n_float: f32 = @floatFromInt(n);

const r_omega: f32 = 0.15;
const r_omega2 = r_omega * r_omega;
const radius: f32 = 2.0 * (2.0 * r_omega / (n_float - 1.0));
const velocity_damp: f32 = 0.005;

const wall: f32 = 0.5;

allocator: std.mem.Allocator,

seed: u64,
prng: std.Random.DefaultPrng = undefined,

min_particle: f32 = std.math.floatMax(f32),
max_particle: f32 = std.math.floatMin(f32),
particles: []particle.OpParticle = undefined,

thread_pool: [num_threads]std.Thread = undefined,
search: Search,

pub fn init(allocator: std.mem.Allocator) !struct { *Self, std.Thread } {
    const self = try allocator.create(Self);
    const seed: u64 = @bitCast(std.time.microTimestamp());
    self.* = .{
        .allocator = allocator,
        .seed = seed,
        .search = try .init(allocator, radius, .{ .erase_empty_cells = true }),
        .prng = .init(seed),
    };

    self.particles = try self.allocator.alloc(particle.OpParticle, max_particles);
    const initializer = try std.Thread.spawn(
        .{},
        spawn,
        .{self},
    );

    return .{ self, initializer };
}

pub fn deinit(self: *Self) void {
    defer {
        self.search.deinit();
        self.allocator.destroy(self);
    }

    self.allocator.free(self.particles);
}

/// Creates n particles with random initial conditions.
///
/// The caller is responsible for freeing the slice.
fn spawn(self: *Self) void {
    const random = self.prng.random();

    // Generate random position inside cube [-wall, +wall]
    for (0..max_particles) |i| {
        const x = (random.float(f32) * 2.0 - 1.0) * wall;
        const y = (random.float(f32) * 2.0 - 1.0) * wall;
        const z = (random.float(f32) * 2.0 - 1.0) * wall;

        const pos = Vec3.init(.{ x, y, z });
        self.particles[i].position = pos;

        self.min_particle = @min(self.min_particle, x);
        self.max_particle = @max(self.max_particle, x);
    }
}

/// Updates all particles on the screen and sends them to the vertex buffer's memory.
pub fn updateParticles(self: *Self, dt: f32, memory: *anyopaque) !void {
    for (self.particles) |*p| {
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

    const mapped_particles: [*]particle.NativeParticle = @ptrCast(@alignCast(memory));

    for (self.particles, mapped_particles) |op, *mapped_particle| {
        mapped_particle.* = .init(op);
    }
}
