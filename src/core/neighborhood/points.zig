const std = @import("std");

const hash = @import("hash.zig");

pub const ValueType = usize;

/// A qualified point with a categorized set id.
pub const PointID = struct {
    id: ValueType,
    set_id: ValueType,

    pub fn eql(self: PointID, other: PointID) bool {
        return self.id == other.id and self.set_id == other.set_id;
    }
};

/// A multi-threading safety lock for a pool of operations.
pub const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *SpinLock) void {
        while (true) {
            if (!self.locked.swap(true, .acquire)) {
                return;
            }

            // On yield-supporting systems this will work
            std.Thread.yield() catch continue;
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

/// Creates a flat array of floats from a dynamic array of 3D positions.
///
/// T must be a float, and this is confirmed at comptime.
///
/// The returned slice directly references the input memory.
pub fn flattenPositions(
    comptime T: type,
    positions: []const [3]T,
) []const T {
    switch (@typeInfo(T)) {
        .float => {},
        else => @compileError("T must be a known float type"),
    }

    const ptr: [*]const T = @ptrCast(positions.ptr);
    const count = positions.len * 3;
    return ptr[0..count];
}

/// Creates a set of points in three-dimensional space.
/// Almost entirely managed externally.
///
/// T must be a float, and this is confirmed at comptime.
pub fn PointSet(comptime T: type) type {
    switch (@typeInfo(T)) {
        .float => {},
        else => @compileError("T must be a known float type"),
    }

    return struct {
        const Self = @This();

        pub const NeighborAccumulator = std.ArrayList(std.ArrayList(ValueType));
        pub const NeighborList = std.ArrayList(NeighborAccumulator);

        allocator: std.mem.Allocator,

        position_data: []T,
        number_of_points: usize,
        dynamic: bool,

        neighbors: NeighborList = .empty,
        keys: std.ArrayList(hash.Key) = .empty,
        old_keys: std.ArrayList(hash.Key) = .empty,

        sort_table: std.ArrayList(ValueType) = .empty,
        locks: std.ArrayList(std.ArrayList(SpinLock)) = .empty,

        /// Creates a PointSet with the allocator and all fields uninitialized.
        ///
        /// The provided position data is managed internally.
        pub fn init(
            allocator: std.mem.Allocator,
            position_data: []const T,
            total_points: usize,
            dynamic: bool,
        ) !Self {
            var self = Self{
                .allocator = allocator,

                .position_data = try allocator.dupe(T, position_data),
                .number_of_points = total_points,
                .dynamic = dynamic,

                .neighbors = try .initCapacity(allocator, total_points),
            };

            try self.keys.resize(allocator, total_points);
            for (self.keys.items) |*key| {
                key.* = .splat(std.math.minInt(i32));
            }
            self.old_keys = try self.keys.clone(allocator);

            return self;
        }

        /// Resizes the point set, obviously.
        pub fn resize(
            self: *Self,
            position_data: []const T,
            total_points: usize,
        ) !void {
            self.allocator.free(self.position_data);
            self.position_data = try self.allocator.dupe(T, position_data);
            self.number_of_points = total_points;

            try self.keys.resize(self.allocator, total_points);
            try self.old_keys.resize(self.allocator, total_points);
            for (0..total_points) |i| {
                self.keys.items[i] = .splat(std.math.minInt(i32));
                self.old_keys.items[i] = .splat(std.math.minInt(i32));
            }

            const old_len = self.neighbors.items.len;
            if (total_points < old_len) {
                for (self.neighbors.items[total_points..]) |*neighbor_L2| {
                    defer neighbor_L2.deinit(self.allocator);
                    for (neighbor_L2.items) |*nested_L1| {
                        nested_L1.deinit(self.allocator);
                    }
                }
            }

            try self.neighbors.resize(self.allocator, total_points);
            if (total_points > old_len) {
                for (self.neighbors.items[old_len..]) |*neighbor_L2| {
                    neighbor_L2.* = .empty;
                }
            }
        }

        /// Deinitializes all allocated data.
        pub fn deinit(self: *Self) void {
            defer {
                self.allocator.free(self.position_data);

                self.neighbors.deinit(self.allocator);
                self.keys.deinit(self.allocator);
                self.old_keys.deinit(self.allocator);

                self.sort_table.deinit(self.allocator);
                self.locks.deinit(self.allocator);
            }

            for (self.neighbors.items) |*neighbor| {
                defer neighbor.deinit(self.allocator);
                for (neighbor.items) |*nested| {
                    nested.deinit(self.allocator);
                }
            }

            for (self.locks.items) |*lock_row| {
                lock_row.deinit(self.allocator);
            }
        }

        /// Returns the number of neighbors of the given point in the given point set.
        ///
        /// Asserts that the set and index values are within range.
        pub fn neighborCount(self: *const Self, point_set: usize, point_index: usize) usize {
            std.debug.assert(point_set < self.neighbors.items.len);
            std.debug.assert(point_index < self.neighbors.items[point_set].items.len);
            return self.neighbors.items[point_set].items[point_index].items.len;
        }

        /// Fetches the id pair of the kth neighbor of the given point in the given point set.
        ///
        /// Asserts that the set, index, and neighbor values are within range.
        pub fn fetchNeighbor(self: *const Self, point_set: usize, point_index: usize, neighbor: usize) ValueType {
            std.debug.assert(point_set < self.neighbors.items.len);
            std.debug.assert(point_index < self.neighbors.items[point_set].items.len);
            std.debug.assert(neighbor < self.neighbors.items[point_set].items[point_index].items.len);
            return self.neighbors.items[point_set].items[point_index].items[neighbor];
        }

        /// Fetches the neighbor list of the given point in the given point set.
        ///
        /// The caller owns the list of neighbors and is responsible for freeing it.
        ///
        /// Asserts that the set and index values are within range.
        pub fn fetchNeighborList(
            self: *const Self,
            point_set: usize,
            point_index: usize,
        ) ![]ValueType {
            std.debug.assert(point_set < self.neighbors.items.len);
            std.debug.assert(point_index < self.neighbors.items[point_set].items.len);
            const neighbors = self.neighbors.items[point_set].items[point_set];
            return try self.allocator.dupe(ValueType, neighbors.items);
        }

        /// Reorders an array according to a previously generated sort table by zort.
        ///
        /// This sort method must be called beforehand.
        pub fn sort(self: *const Self, comptime A: type, list: []A) !void {
            if (self.sort_table.items.len == 0 or list.len == 0) {
                return error.InvalidOrMissingTable;
            }

            const tmp = try self.allocator.dupe(A, list);
            defer self.allocator.free(tmp);
            for (self.sort_table.items, 0..) |src_idx, dst_idx| {
                list[dst_idx] = tmp[src_idx];
            }
        }

        /// Retrieves the 3 data points at offset i in the internal position data.
        ///
        /// The offset should be a multiple of three, but this is not asserted.
        /// Asserts that the upper found of the requested index is in range (valid z).
        pub fn point(self: *const Self, offset: usize) *const [3]T {
            std.debug.assert(3 * offset + 3 <= self.position_data.len);
            return self.position_data[3 * offset .. 3 * offset + 3][0..3];
        }
    };
}

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualSlices = testing.expectEqualSlices;
const expectError = testing.expectError;

test "Position data flattening" {
    const allocator = testing.allocator;

    var positions: std.ArrayList([3]f32) = .empty;
    defer positions.deinit(allocator);

    try positions.append(allocator, .{ 1.0, 2.0, 3.0 });
    try positions.append(allocator, .{ 4.0, 5.0, 6.0 });
    try positions.append(allocator, .{ 7.0, 8.0, 9.0 });

    const flattened = flattenPositions(f32, positions.items);

    try std.testing.expectEqual(9, flattened.len);
    try std.testing.expectEqual(flattened[0], 1.0);
    try std.testing.expectEqual(flattened[1], 2.0);
    try std.testing.expectEqual(flattened[2], 3.0);
    try std.testing.expectEqual(flattened[3], 4.0);
    try std.testing.expectEqual(flattened[4], 5.0);
    try std.testing.expectEqual(flattened[5], 6.0);
    try std.testing.expectEqual(flattened[6], 7.0);
    try std.testing.expectEqual(flattened[7], 8.0);
    try std.testing.expectEqual(flattened[8], 9.0);
}

test "PointSet initialization and destruction" {
    const allocator = testing.allocator;
    var ps = try PointSet(f32).init(
        allocator,
        &.{ 1.0, 2.0, 3.0 },
        1,
        true,
    );
    defer ps.deinit();
}

test "PointSet basic init/deinit and sort" {
    const allocator = testing.allocator;

    var points = [_]f32{
        0.0, 0.1, 0.2,
        1.0, 1.1, 1.2,
        2.0, 2.1, 2.2,
    };

    var set = try PointSet(f32).init(allocator, &points, 3, false);
    defer set.deinit();

    try expectEqual(3, set.number_of_points);
    try expect(!set.dynamic);

    const p1 = set.point(1);
    try expectEqualSlices(f32, p1, &[_]f32{ 1.0, 1.1, 1.2 });
    try set.sort_table.appendSlice(allocator, &[_]ValueType{ 2, 1, 0 });

    var data = [_]ValueType{ 10, 20, 30 };
    try set.sort(ValueType, &data);
    try expectEqualSlices(ValueType, &[_]ValueType{ 30, 20, 10 }, &data);
}

test "PointSet neighborCount and fetchNeighbor" {
    const allocator = testing.allocator;

    var points = [_]f32{ 0, 0, 0, 1, 1, 1 };
    var set = try PointSet(f32).init(allocator, &points, 2, true);
    defer set.deinit();

    try set.neighbors.append(allocator, try std.ArrayList(std.ArrayList(ValueType)).initCapacity(allocator, 2));
    try set.neighbors.items[0].append(allocator, try std.ArrayList(ValueType).initCapacity(allocator, 2));
    try set.neighbors.items[0].items[0].appendSlice(allocator, &[_]ValueType{ 7, 8, 9 });

    const count = set.neighborCount(0, 0);
    try expectEqual(3, count);

    const n0 = set.fetchNeighbor(0, 0, 0);
    const n2 = set.fetchNeighbor(0, 0, 2);
    try expectEqual(7, n0);
    try expectEqual(9, n2);
}

test "PointSet fetchNeighborList returns copy" {
    const allocator = testing.allocator;

    var points = [_]f32{ 0, 0, 0, 1, 1, 1 };
    var set = try PointSet(f32).init(allocator, &points, 2, true);
    defer set.deinit();

    try set.neighbors.append(allocator, try std.ArrayList(std.ArrayList(ValueType)).initCapacity(allocator, 2));
    try set.neighbors.items[0].append(allocator, try std.ArrayList(ValueType).initCapacity(allocator, 2));
    try set.neighbors.items[0].items[0].appendSlice(allocator, &[_]ValueType{ 42, 43 });

    const duped = try set.fetchNeighborList(0, 0);
    defer allocator.free(duped);

    try expectEqualSlices(ValueType, duped, &[_]ValueType{ 42, 43 });

    duped[0] = 999;
    try expectEqual(42, set.neighbors.items[0].items[0].items[0]);
}

test "PointSet sort errors when table missing" {
    const allocator = testing.allocator;

    var points = [_]f32{ 0, 0, 0, 1, 1, 1 };
    var set = try PointSet(f32).init(allocator, &points, 2, true);
    defer set.deinit();

    var arr = [_]ValueType{ 1, 2 };
    const err = set.sort(ValueType, &arr) catch |e| e;
    try expectError(error.InvalidOrMissingTable, err);
}
