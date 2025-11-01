const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");

const n: usize = 30;
const n_float: Real = @floatFromInt(n);
const n_enright_rights: usize = 50;

const Real = f32;
const r_omega: Real = 0.15;
const r_omega2 = r_omega * r_omega;
const radius: Real = 2.0 * (2.0 * r_omega / (n_float - 1.0));
const velocity_damp: Real = 0.005;
const Vec3 = core.Vector(Real, 3);

const num_threads = if (builtin.single_threaded) 1 else 4;
const single_threaded = num_threads == 1;
const Search = core.search.Search(Real, Vec3, .{ .threadedness = .{ .multithreaded = num_threads } });

fn generatePositions() struct {
    positions: []const Vec3,
    min: Real,
    max: Real,
} {
    @setEvalBranchQuota(100_000_000);
    var total_len: comptime_int = 0;
    inline for (0..n) |i| {
        inline for (0..n) |j| {
            inline for (0..n) |k| {
                const x: Vec3 = .init(.{
                    r_omega * (2.0 * @as(Real, @floatFromInt(i)) / (n_float - 1.0) - 1.0),
                    r_omega * (2.0 * @as(Real, @floatFromInt(j)) / (n_float - 1.0) - 1.0),
                    r_omega * (2.0 * @as(Real, @floatFromInt(k)) / (n_float - 1.0) - 1.0),
                });

                const l2 = x.vec[0] * x.vec[0] + x.vec[1] * x.vec[1] + x.vec[2] * x.vec[2];
                if (l2 < r_omega2) {
                    total_len += 1;
                }
            }
        }
    }

    // Second pass for actual computation
    var points: [total_len]Vec3 = undefined;
    var p_idx: usize = 0;

    var min = std.math.floatMax(Real);
    var max = std.math.floatMin(Real);

    inline for (0..n) |i| {
        inline for (0..n) |j| {
            inline for (0..n) |k| {
                var x: Vec3 = .init(.{
                    r_omega * (2.0 * @as(Real, @floatFromInt(i)) / (n_float - 1.0) - 1.0),
                    r_omega * (2.0 * @as(Real, @floatFromInt(j)) / (n_float - 1.0) - 1.0),
                    r_omega * (2.0 * @as(Real, @floatFromInt(k)) / (n_float - 1.0) - 1.0),
                });

                const l2 = x.vec[0] * x.vec[0] + x.vec[1] * x.vec[1] + x.vec[2] * x.vec[2];
                if (l2 < r_omega2) {
                    x.vec[0] += 0.35;
                    x.vec[1] += 0.35;
                    x.vec[2] += 0.35;
                    min = @min(min, x.vec[0]);
                    max = @max(max, x.vec[0]);

                    points[p_idx] = x;
                    p_idx += 1;
                }
            }
        }
    }

    const s_points = points;
    return .{
        .positions = &s_points,
        .min = min,
        .max = max,
    };
}

const position_data = generatePositions();
const positions = position_data.positions;
const min_pos = position_data.min;
const max_pos = position_data.max;

const Example = struct {
    allocator: std.mem.Allocator,

    writer: *std.Io.Writer,
    pos: [positions.len]Vec3 = undefined,
    workers: [num_threads]std.Thread = undefined,

    search: Search,

    pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer) !Example {
        var self: Example = .{
            .allocator = allocator,
            .writer = writer,
            .search = try .init(allocator, radius, .{ .erase_empty_cells = true }),
        };

        var prng: std.Random.DefaultPrng = .init(@bitCast(std.time.timestamp()));
        @memcpy(self.pos[0..], positions);
        std.Random.shuffle(prng.random(), Vec3, &self.pos);

        return self;
    }

    pub fn deinit(self: *Example) void {
        self.search.deinit();
    }

    fn enrightVelocityField(point: *const Vec3) Vec3 {
        const sin_pi_x = @sin(std.math.pi * point.vec[0]);
        const sin_pi_x_2 = sin_pi_x * sin_pi_x;
        const sin_pi_y = @sin(std.math.pi * point.vec[1]);
        const sin_pi_y_2 = sin_pi_y * sin_pi_y;
        const sin_pi_z = @sin(std.math.pi * point.vec[2]);
        const sin_pi_z_2 = sin_pi_z * sin_pi_z;

        const sin_2_pi_x = @sin(2.0 * std.math.pi * point.vec[0]);
        const sin_2_pi_y = @sin(2.0 * std.math.pi * point.vec[1]);
        const sin_2_pi_z = @sin(2.0 * std.math.pi * point.vec[2]);

        return .init(.{
            2.0 * sin_pi_x_2 * sin_2_pi_y * sin_2_pi_z,
            -sin_2_pi_x * sin_pi_y_2 * sin_2_pi_z,
            -sin_2_pi_x * sin_2_pi_y * sin_pi_z_2,
        });
    }

    pub fn advect(self: *Example) !void {
        const chunks = core.ranges.chunk(Vec3, &self.pos, num_threads);
        const context = .{};

        try core.parallel_loop.@"for"(
            Vec3,
            &self.pos,
            num_threads,
            chunks,
            &self.workers,
            context,
            struct {
                pub fn advectChunk(ctx: @TypeOf(context), slice: []Vec3, thread_num: usize) !void {
                    _ = ctx;
                    _ = thread_num;
                    for (slice) |*point| {
                        const v = enrightVelocityField(point);
                        point.vec[0] += velocity_damp * v.vec[0];
                        point.vec[1] += velocity_damp * v.vec[1];
                        point.vec[2] += velocity_damp * v.vec[2];
                    }
                }
            }.advectChunk,
            .{},
        );
        self.search.requires_refresh = true;
    }

    pub fn averageNeighbors(self: *const Example) Real {
        var acc: Real = 0.0;
        const first_set = self.search.point_sets.items[0];
        for (0..first_set.number_of_points) |i| {
            acc += @floatFromInt(first_set.neighborCount(0, i));
        }

        return acc / @as(Real, @floatFromInt(first_set.number_of_points));
    }

    pub fn averageDistance(self: *const Example) Real {
        var acc: Real = 0.0;
        var count: Real = 0.0;
        const first_set = self.search.point_sets.items[0];
        for (0..first_set.number_of_points) |i| {
            for (0..first_set.neighborCount(0, i)) |j| {
                const k = first_set.fetchNeighbor(0, i, j);
                const diff = @as(isize, @intCast(i)) - @as(isize, @intCast(k));
                acc += @floatFromInt(@abs(diff));
                count += 1.0;
            }
        }

        return acc / count;
    }

    pub fn run(self: *Example) !void {
        // Preliminary information
        try self.writer.print(
            \\Points                                 = {d}
            \\Search radius                          = {d}
            \\Min pos                                = {d}
            \\Max pos                                = {d}
            \\Average number of neighbors            = {d}
            \\Average index distance prior to z-sort = {d}
            \\
        , .{
            self.pos.len,
            radius,
            min_pos,
            max_pos,
            self.averageNeighbors(),
            self.averageDistance(),
        });
        try self.writer.flush();

        // Sorting
        try self.search.zort();
        for (self.search.point_sets.items) |*point_set| {
            try point_set.sort(Vec3, &self.pos);
        }
        try self.search.findNeighbors(.{ .actual = .{} });
        try self.writer.print(
            "Average index distance after z-sort    = {d}\n\n",
            .{self.averageDistance()},
        );
        try self.writer.flush();

        // Moving
        try self.writer.print("Moving Points:\n", .{});
        for (0..n_enright_rights) |i| {
            try self.advect();

            const start = std.time.nanoTimestamp();
            try self.search.findNeighbors(.{ .actual = .{} });
            const end = std.time.nanoTimestamp();

            const elapsed_ms: u64 = @intCast(@divTrunc(end - start, 1_000_000));
            try self.writer.print(
                "Enright step {d}: Neighborhood search took {d} ms\n",
                .{ i, elapsed_ms },
            );
            try self.writer.flush();
        }
    }
};

pub fn main() !void {
    @setFloatMode(.optimized);
    const allocator = core.allocator(single_threaded);

    var buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buffer);
    const stdout = &stdout_writer.interface;

    var example = try Example.init(allocator, stdout);
    defer example.deinit();

    // Add the point sets after init so that the position pointer is stable
    _ = try example.search.addPointSet(
        &example.pos,
        example.pos.len,
        true,
        .{},
    );
    _ = try example.search.addPointSet(
        &example.pos,
        example.pos.len,
        true,
        .{},
    );

    try example.search.findNeighbors(.{ .actual = .{} });
    try example.search.updatePointSets();

    // Specific neighbor retrieval
    var neighbors1: Search.PointSet.NeighborAccumulator = .empty;
    defer {
        defer neighbors1.deinit(allocator);
        for (neighbors1.items) |*nested| {
            nested.deinit(allocator);
        }
    }
    try example.search.findNeighbors(.{ .single_point_from_set = .{
        .point_set_id = 0,
        .point_idx = 1,
        .neighbors = &neighbors1,
    } });

    var neighbors2: Search.PointSet.NeighborAccumulator = .empty;
    defer {
        defer neighbors2.deinit(allocator);
        for (neighbors2.items) |*nested| {
            nested.deinit(allocator);
        }
    }
    try example.search.findNeighbors(.{ .single_point_from_set = .{
        .point_set_id = 1,
        .point_idx = 2,
        .neighbors = &neighbors2,
    } });

    try example.run();
    try stdout.flush();
}
