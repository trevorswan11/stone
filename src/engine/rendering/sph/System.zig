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

const num_threads = if (builtin.single_threaded) 1 else 8;
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

const boundary_layers = 4;
const particle_spacing = radius * 0.75;

const n: usize = 30;
const n_float: f32 = @floatFromInt(n);
const wall: f32 = 0.75;

const r_omega: f32 = 0.15;
const radius: f32 = 2.0 * (2.0 * r_omega / (n_float - 1.0));

allocator: std.mem.Allocator,

seed: u64,
prng: std.Random.DefaultPrng = undefined,

min_particle: f32 = std.math.floatMax(f32),
max_particle: f32 = std.math.floatMin(f32),

particles: []particle.OpParticle = undefined,
boundary: []particle.OpParticle = undefined,
total_particles: usize = 0,

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
    self.allocator.free(self.boundary);
}

/// Creates n particles with random initial positions.
/// The boundary layers are also created
fn spawn(self: *Self) !void {
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

        self.particles[i].color = .init(.{
            random.float(f32),
            random.float(f32),
            random.float(f32),
            1.0,
        });
    }

    // Generate the boundary layers along the walls
    var boundary: std.ArrayList(particle.OpParticle) = try .initCapacity(self.allocator, 10_000);
    defer boundary.deinit(self.allocator);

    try spawnWall(self.allocator, &boundary, .x, .neg);
    try spawnWall(self.allocator, &boundary, .x, .pos);
    try spawnWall(self.allocator, &boundary, .y, .neg);
    try spawnWall(self.allocator, &boundary, .y, .pos);
    try spawnWall(self.allocator, &boundary, .z, .neg);
    try spawnWall(self.allocator, &boundary, .z, .pos);

    self.boundary = try boundary.toOwnedSlice(self.allocator);
}

fn spawnWall(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(particle.OpParticle),
    comptime axis: enum { x, y, z },
    comptime side: enum { pos, neg },
) !void {
    const direction: f32 = comptime switch (side) {
        .pos => 1.0,
        .neg => -1.0,
    };

    for (0..boundary_layers) |layer_idx| {
        const layer_offset = @as(f32, @floatFromInt(layer_idx)) * particle_spacing;

        var u_pos: f32 = -wall;
        while (u_pos <= wall) : (u_pos += particle_spacing) {
            var v_pos: f32 = -wall;
            while (v_pos <= wall) : (v_pos += particle_spacing) {
                const pos: Vec3 = switch (axis) {
                    .x => .init(.{
                        (wall * direction) + (layer_offset * direction),
                        u_pos,
                        v_pos,
                    }),
                    .y => .init(.{
                        u_pos,
                        (wall * direction) + (layer_offset * direction),
                        v_pos,
                    }),
                    .z => .init(.{
                        u_pos,
                        v_pos,
                        (wall * direction) + (layer_offset * direction),
                    }),
                };

                try list.append(allocator, .{
                    .position = pos,
                    .velocity = .splat(0.0),
                    .color = .splat(0.0),
                });
            }
        }
    }
}

pub fn finalize(self: *Self) !void {
    _ = try self.search.addPointSet(
        self.particles,
        self.particles.len,
        true,
        .{},
    );

    _ = try self.search.addPointSet(
        self.boundary,
        self.boundary.len,
        false,
        .{},
    );

    self.total_particles += self.particles.len;
}

/// Updates all particles on the screen and sends them to the vertex buffer's memory.
pub fn updateParticles(self: *Self, dt: f32, memory: *anyopaque) !void {
    self.search.requires_refresh = true;
    try self.search.updatePointSets();
    try self.search.findNeighbors(.{ .actual = .{ .points_changed = true } });
    _ = dt;

    const mapped_particles: [*]particle.NativeParticle = @ptrCast(@alignCast(memory));
    for (self.particles, 0..) |op, i| {
        mapped_particles[i] = .init(op);
    }
}
