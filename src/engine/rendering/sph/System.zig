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
pub const workgroup_count = 4;
pub const max_particles = workgroup_load * workgroup_count;

const boundary_layers = 2;
const boundary_particle_spacing = 0.1;

const wall: f32 = 0.75;
const radius: f32 = 0.2;
const damping_factor: f32 = 0.5;
const bounce_factor: f32 = -1;

const smoothing_length: f32 = 0.2;
const rest_density: f32 = 1.0;
const fluid_stiffness: f32 = 3.0;
const wall_stiffness: f32 = 6.0;
const gamma: f32 = 7.0;
const speed_of_sound: f32 = 20.0;
const mass: f32 = 0.018;
const viscosity: f32 = 0.00089;

const gravity: Vec3 = .init(.{ 0.0, 0.0, -9.81 });

allocator: std.mem.Allocator,

seed: u64,
prng: std.Random.DefaultPrng = undefined,

min_particle: f32 = std.math.floatMax(f32),
max_particle: f32 = std.math.floatMin(f32),

particles: []particle.OpParticle = undefined,
boundary: []particle.OpParticle = undefined,
total_particles: usize = 0,

fluid_set_id: usize = undefined,
boundary_set_id: usize = undefined,

search: Search,
iteration: usize = 0,

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
///
/// The boundary layers are also created.
fn spawn(self: *Self) !void {
    const random = self.prng.random();

    // Generate random position inside cube [-wall, +wall]
    for (self.particles) |*p| {
        const x = (random.float(f32) * 2.0 - 1.0) * wall;
        const y = (random.float(f32) * 2.0 - 1.0) * wall;
        const z = (random.float(f32) * 2.0 - 1.0) * wall;

        const position: Vec3 = .init(.{ x, y, z });

        self.min_particle = @min(self.min_particle, x);
        self.max_particle = @max(self.max_particle, x);

        const color: Vec4 = .init(.{
            random.float(f32),
            random.float(f32),
            random.float(f32),
            1.0,
        });

        p.* = .{
            .position = position,
            .color = color,
            .mass = mass,
            .density = 0.0,
            .pressure = 0.0,
            .viscosity = viscosity,
            .stationary = false,
        };
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
        const layer_offset = @as(f32, @floatFromInt(layer_idx)) * boundary_particle_spacing;

        var u_pos: f32 = -wall;
        while (u_pos <= wall) : (u_pos += boundary_particle_spacing) {
            var v_pos: f32 = -wall;
            while (v_pos <= wall) : (v_pos += boundary_particle_spacing) {
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
                    .mass = mass,
                    .density = 0.0,
                    .pressure = 0.0,
                    .stationary = true,
                });
            }
        }
    }
}

pub fn finalize(self: *Self) !void {
    self.fluid_set_id = try self.search.addPointSet(
        self.particles,
        self.particles.len,
        true,
        .{},
    );

    self.boundary_set_id = try self.search.addPointSet(
        self.boundary,
        self.boundary.len,
        false,
        .{},
    );

    self.total_particles += self.particles.len;
    // self.total_particles += self.boundary.len;
}

/// Updates all particles on the screen and sends them to the vertex buffer's memory.
pub fn updateParticles(self: *Self, dt: f32, memory: *anyopaque) !void {
    const w_self = core.kernel.poly6Spline(f32, .splat(0.0), smoothing_length);
    try self.step(dt, w_self);

    // Move all fluid particles into vulkan
    const mapped_particles: [*]particle.NativeParticle = @ptrCast(@alignCast(memory));
    for (self.particles, 0..) |op, i| {
        mapped_particles[i] = .init(op);
    }

    // Load the boundary particles into vulkan if we have room
    if (self.total_particles == (self.particles.len + self.boundary.len)) {
        for (self.boundary, self.particles.len..) |op, i| {
            mapped_particles[i] = .init(op);
        }
    }
}

fn step(self: *Self, dt: f32, w_self: f32) !void {
    try self.search.findNeighbors(.{ .actual = .{ .points_changed = true } });

    // First pass A - compute densities and pressures for fluid
    const fluid_point_set = &self.search.point_sets.items[self.fluid_set_id];
    for (self.particles, 0..) |*p_i, i| {
        p_i.density = p_i.mass * w_self;

        // Iterate over all fluid neighbors
        const fluid_neighbors = fluid_point_set.neighbors.items[self.fluid_set_id].items[i];
        for (fluid_neighbors.items) |j| {
            if (i == j) continue;
            const p_j = &self.particles[j];
            densityDifferentialUpdate(p_i, p_j);
        }

        // Iterate over all boundary neighbors
        const boundary_neighbors = fluid_point_set.neighbors.items[self.boundary_set_id].items[i];
        for (boundary_neighbors.items) |j| {
            const p_j = &self.boundary[j];
            densityDifferentialUpdate(p_i, p_j);
        }

        // Calculate pressure using state equation
        p_i.pressure = core.state.wcsph(
            f32,
            p_i.density,
            rest_density,
            speed_of_sound,
            gamma,
            0.0,
        );
    }

    // First pass B - compute densities and pressures for fluid
    const boundary_point_set = &self.search.point_sets.items[self.boundary_set_id];
    for (self.boundary, 0..) |*p_i, i| {
        p_i.density = p_i.mass * w_self;

        // Boundary particles only feel density from fluid particles
        const fluid_neighbors = boundary_point_set.neighbors.items[self.fluid_set_id].items[i];
        for (fluid_neighbors.items) |j| {
            const p_j = &self.particles[j];
            densityDifferentialUpdate(p_i, p_j);
        }

        // For pressure just treat them as a fluid with identical properties
        p_i.pressure = core.state.wcsph(
            f32,
            p_i.density,
            rest_density,
            speed_of_sound,
            gamma,
            0.0,
        );
    }

    // Second pass - update accelerations
    for (self.particles, 0..) |*p_i, i| {
        p_i.acceleration = gravity;

        // Iterate over all fluid neighbors
        const fluid_neighbors = fluid_point_set.neighbors.items[self.fluid_set_id].items[i];
        for (fluid_neighbors.items) |j| {
            if (i == j) continue;
            const p_j = &self.particles[j];
            accelerationDifferentialUpdate(p_i, p_j);
        }

        // Iterate over all boundary neighbors
        const boundary_neighbors = fluid_point_set.neighbors.items[self.boundary_set_id].items[i];
        for (boundary_neighbors.items) |j| {
            const p_j = &self.boundary[j];
            accelerationDifferentialUpdate(p_i, p_j);
        }
    }

    // Third pass - update the particle's positions with damping
    for (self.particles) |*p| {
        if (p.stationary) continue;
        p.velocity = p.velocity.add(p.acceleration.scale(dt));
        p.position = p.position.add(p.velocity.scale(dt));

        // Prevent penetration using the wall
        inline for (0..3) |coord| {
            if (p.position.at(coord) < -wall) {
                p.position.ptrAt(coord).* = -wall;
                if (p.velocity.at(coord) < 0.0) {
                    p.velocity.ptrAt(coord).* *= comptime bounce_factor * damping_factor;
                }
            } else if (p.position.at(coord) > wall) {
                p.position.ptrAt(coord).* = wall;
                if (p.velocity.at(coord) > 0.0) {
                    p.velocity.ptrAt(coord).* *= comptime bounce_factor * damping_factor;
                }
            }
        }
    }
    self.search.requires_refresh = true;
}

inline fn densityDifferentialUpdate(i: *particle.OpParticle, j: *const particle.OpParticle) void {
    const r_vec = i.position.sub(j.position);
    const dist_sq = r_vec.magSq();

    if (dist_sq < comptime smoothing_length * smoothing_length) {
        const w = core.kernel.poly6Spline(f32, r_vec, smoothing_length);
        i.density += j.mass * w;
    }
}

inline fn accelerationDifferentialUpdate(i: *particle.OpParticle, j: *const particle.OpParticle) void {
    const r_vec = i.position.sub(j.position);

    // Pressure acceleration
    const p_term = blk: {
        const p_i_comp = i.pressure / (i.density * i.density);
        const p_j_comp = j.pressure / (j.density * j.density);
        break :blk p_i_comp + p_j_comp;
    };

    i.acceleration = i.acceleration.add(core.kernel.spikyGradient(
        f32,
        r_vec,
        smoothing_length,
    ).scale(-j.mass * p_term));

    // Viscosity acceleration
    const v_diff = j.velocity.sub(i.velocity);
    i.acceleration = i.acceleration.add(blk: {
        const factor = i.viscosity * j.mass / j.density;
        const kernel = core.kernel.viscosityLaplacian(f32, r_vec, smoothing_length);
        break :blk v_diff.scale(factor * kernel);
    });
}
