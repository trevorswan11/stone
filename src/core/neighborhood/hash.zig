const std = @import("std");

const search = @import("search.zig");
const points = @import("points.zig");

/// The type for a spatial hash map.
pub const SpatialMap = std.HashMap(
    Key,
    points.ValueType,
    Key.Context,
    std.hash_map.default_max_load_percentage,
);

/// The hash key for a 3D particle.
pub const Key = struct {
    key: [3]i32,

    pub fn init(i: i32, j: i32, k: i32) Key {
        return .{ .key = .{ i, j, k } };
    }

    pub fn splat(scalar: i32) Key {
        return .{ .key = @splat(scalar) };
    }

    pub fn eql(self: Key, other: Key) bool {
        return std.mem.eql(i32, &self.key, &other.key);
    }

    pub const Context = struct {
        const factors: [3]i64 = .{
            73856093,
            19349663,
            83492791,
        };

        pub fn eql(ctx: Context, a: Key, b: Key) bool {
            _ = ctx;
            return a.eql(b);
        }

        pub fn hash(ctx: Context, k: Key) u64 {
            _ = ctx;
            const i_key = factors[0] *% k.key[0];
            const j_key = factors[1] *% k.key[1];
            const k_key = factors[2] *% k.key[2];

            return @bitCast(i_key ^ j_key ^ k_key);
        }
    };
};

/// The hash entry for a set of 3D particles.
pub const Entry = struct {
    allocator: std.mem.Allocator,

    searching_points: usize,
    indices: std.ArrayList(points.PointID),

    pub fn init(allocator: std.mem.Allocator) !Entry {
        return .{
            .allocator = allocator,
            .searching_points = 0,
            .indices = try .initCapacity(allocator, search.initial_num_indices),
        };
    }

    pub fn deinit(self: *Entry) void {
        self.indices.deinit(self.allocator);
    }

    /// Adds an id to the internal index tracker.
    ///
    /// Duplicates are allowed, and entries are not ordered.
    pub fn add(self: *Entry, id: points.PointID) !void {
        try self.indices.append(self.allocator, id);
    }

    /// Removes an id to the internal index tracker.
    ///
    /// This operation is a no-op if the list does not contain the item or is empty.
    ///
    /// Duplicates are handled by removing the first found as entries are not ordered.
    pub fn remove(self: *Entry, id: points.PointID) void {
        var index: ?usize = null;
        for (self.indices.items, 0..) |item, i| {
            if (item.eql(id)) {
                index = i;
            }
        }

        _ = self.indices.swapRemove(index orelse return);
    }
};

/// A dynamic table of activations, akin to an adjacency matrix.
///
/// The internal table is guaranteed to be of square size.
pub const ActivationTable = struct {
    const default_table_size: usize = 50;

    pub const SetFlags = struct {
        /// If true, neighbors in all other point sets are searched.
        search_neighbors: bool = true,

        /// If true, the new point set is activated in the neighborhood search of all other point sets.
        find_neighbors: bool = true,
    };

    pub const Variant = union(enum) {
        /// Activate/Deactivate all point set pairs.
        ///
        /// Asserts that the underlying table has square dimensions.
        /// This is an invariant of the table only invalidated by nefarious users.
        all: bool,

        /// Activate/Deactivate indicating whether index2 should be considered a neighbor of index1.
        ///
        /// Asserts that the two indices are valid, assuming the table has square dimensions.
        neighbor: struct { idx1: usize, idx2: usize, active: bool },

        /// Activate/Deactivate all point set pairs containing the given index.
        pairs: struct { index: usize, set_flags: SetFlags },
    };

    allocator: std.mem.Allocator,

    table: std.ArrayList(std.ArrayList(u1)) = .empty,

    pub fn init(allocator: std.mem.Allocator) ActivationTable {
        return .{ .allocator = allocator };
    }

    pub fn clone(self: *const ActivationTable, allocator: std.mem.Allocator) !ActivationTable {
        var cloned = ActivationTable.init(allocator);
        try cloned.table.ensureTotalCapacity(allocator, self.table.items.len);
        for (self.table.items) |row| {
            cloned.table.appendAssumeCapacity(try row.clone(allocator));
        }
        return cloned;
    }

    pub fn deinit(self: *ActivationTable) void {
        defer self.table.deinit(self.allocator);
        for (self.table.items) |*row| {
            row.deinit(self.allocator);
        }
    }

    /// Compares the underlying table for both objects.
    ///
    /// This is expensive and should only be used when absolutely necessary.
    pub fn eql(self: ActivationTable, other: ActivationTable) bool {
        if (self.table.items.len != other.table.items.len) return false;
        return for (self.table.items, other.table.items) |mine, theirs| {
            if (mine.items.len != theirs.items.len) return false;
            if (!std.mem.eql(u1, mine.items, theirs.items)) {
                return false;
            }
        } else return true;
    }

    /// Adds a point set to the graph.
    ///
    /// Can only fail due to memory allocation, which invalidates element pointers when successful.
    pub fn addPointSet(
        self: *ActivationTable,
        set_flags: SetFlags,
    ) !void {
        // Add a new column to each row
        const size = self.table.items.len;
        for (0..size) |i| {
            try self.table.items[i].resize(self.allocator, size + 1);
            self.table.items[i].items[size] = @intFromBool(set_flags.find_neighbors);
        }

        // Add a new row
        try self.table.resize(self.allocator, size + 1);
        self.table.items[size] = try .initCapacity(self.allocator, size + 1);
        try self.table.items[size].resize(self.allocator, size + 1);
        for (self.table.items[size].items) |*item| {
            item.* = @intFromBool(set_flags.search_neighbors);
        }
    }

    /// Activate/Deactivate a requested table location.
    pub fn setActive(self: *ActivationTable, variant: Variant) void {
        switch (variant) {
            .all => |active| {
                const size = self.table.items.len;
                for (0..size) |i| {
                    std.debug.assert(self.table.items[i].items.len == size);
                    for (0..size) |j| {
                        self.table.items[i].items[j] = @intFromBool(active);
                    }
                }
            },
            .neighbor => |neighbor| {
                const idx1, const idx2 = .{ neighbor.idx1, neighbor.idx2 };
                std.debug.assert(idx1 < self.table.items.len and idx2 < self.table.items.len);
                self.table.items[idx1].items[idx2] = @intFromBool(neighbor.active);
            },
            .pairs => |pair| {
                const size = self.table.items.len;
                const index, const find_neighbors, const search_neighbors = .{
                    pair.index,
                    pair.set_flags.find_neighbors,
                    pair.set_flags.search_neighbors,
                };
                std.debug.assert(index < size);

                for (0..size) |i| {
                    std.debug.assert(self.table.items[i].items.len == size);
                    self.table.items[i].items[index] = @intFromBool(find_neighbors);
                    self.table.items[index].items[i] = @intFromBool(search_neighbors);
                }
                self.table.items[index].items[index] = @intFromBool(find_neighbors and search_neighbors);
            },
        }
    }

    /// Checks if a pair is active.
    ///
    /// Asserts that the two indices are valid, assuming the table has square dimensions.
    pub fn isActive(self: *const ActivationTable, idx1: usize, idx2: usize) bool {
        std.debug.assert(idx1 < self.table.items.len and idx2 < self.table.items.len);
        return self.table.items[idx1].items[idx2] == 1;
    }

    /// Checks if an index is a contender for neighborhood searching.
    ///
    /// Asserts that the index is valid.
    pub fn isSearchingNeighbors(self: *ActivationTable, idx: usize) bool {
        std.debug.assert(idx < self.table.items.len);
        for (self.table.items[idx].items) |point| {
            if (point == 1) return true;
        } else return false;
    }
};

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualSlices = testing.expectEqualSlices;

test "Key creation and comparison" {
    const k = Key.init(0, 1, 2);
    try expectEqualSlices(i32, &.{ 0, 1, 2 }, &k.key);

    const other_eq = Key.init(0, 1, 2);
    try expect(k.eql(other_eq));

    var other_neq = k;
    other_neq.key[0] = -4;
    try expect(!k.eql(other_neq));

    var splatted = Key.splat(5.0);
    try expect(!splatted.eql(k));
}

test "Key hashing" {
    try expectEqual(18416305591877621035, Key.Context.hash(.{}, .init(-2065305262, 481853423, 1998602736)));
    try expectEqual(120364129744059780, Key.Context.hash(.{}, .init(-723594490, 723459257, -997786085)));
    try expectEqual(18281781679266513065, Key.Context.hash(.{}, .init(2115057420, 2030513621, -793898702)));
    try expectEqual(137172815755025859, Key.Context.hash(.{}, .init(-1563224045, -379012780, 348812344)));
    try expectEqual(217303284002470276, Key.Context.hash(.{}, .init(-2114803654, 1884362860, -1454415730)));
    try expectEqual(18406753012562953102, Key.Context.hash(.{}, .init(904033316, -713233864, 276878398)));
    try expectEqual(9406530778922349, Key.Context.hash(.{}, .init(-1783933800, 1827963946, -1324368939)));
    try expectEqual(74667072075054406, Key.Context.hash(.{}, .init(-1931484049, -98502170, 826972073)));
    try expectEqual(251989153484924213, Key.Context.hash(.{}, .init(-1962758367, 710546820, -1122302356)));
    try expectEqual(125580828515700831, Key.Context.hash(.{}, .init(-1458465012, 350252140, -730236255)));
}

test "Entry init and deinit" {
    const allocator = testing.allocator;
    var entry = try Entry.init(allocator);
    defer entry.deinit();

    try expectEqual(allocator, entry.allocator);
    try expectEqual(0, entry.searching_points);
    try expectEqual(0, entry.indices.items.len);
    try expectEqual(search.initial_num_indices, entry.indices.capacity);
}

test "Entry operations" {
    const allocator = testing.allocator;

    // Add operations
    var entry = try Entry.init(allocator);

    try entry.add(.{ .id = 10, .set_id = 0 });
    try expectEqual(1, entry.indices.items.len);
    try expectEqual(10, entry.indices.items[0].id);

    try entry.add(.{ .id = 20, .set_id = 0 });
    try expectEqual(2, entry.indices.items.len);
    try expectEqual(10, entry.indices.items[0].id);
    try expectEqual(20, entry.indices.items[1].id);

    try entry.add(.{ .id = 10, .set_id = 0 });
    try expectEqual(3, entry.indices.items.len);
    try expectEqual(10, entry.indices.items[0].id);
    try expectEqual(20, entry.indices.items[1].id);
    try expectEqual(10, entry.indices.items[2].id);

    // Remove operations (no duplicates)
    entry.deinit();
    entry = try Entry.init(allocator);

    entry.remove(.{ .id = 10, .set_id = 0 });
    try expectEqual(0, entry.indices.items.len);

    try entry.add(.{ .id = 10, .set_id = 0 });
    try entry.add(.{ .id = 20, .set_id = 0 });
    try entry.add(.{ .id = 30, .set_id = 0 });
    try expectEqual(3, entry.indices.items.len);
    try expectEqualSlices(points.ValueType, &.{ 10, 20, 30 }, &.{
        entry.indices.items[0].id,
        entry.indices.items[1].id,
        entry.indices.items[2].id,
    });

    entry.remove(.{ .id = 99, .set_id = 0 });
    try expectEqual(3, entry.indices.items.len);

    entry.remove(.{ .id = 20, .set_id = 0 });
    try expectEqual(2, entry.indices.items.len);
    try expectEqualSlices(points.ValueType, &.{ 10, 30 }, &.{
        entry.indices.items[0].id,
        entry.indices.items[1].id,
    });

    entry.remove(.{ .id = 30, .set_id = 0 });
    try expectEqual(1, entry.indices.items.len);
    try expectEqual(10, entry.indices.items[0].id);

    entry.remove(.{ .id = 10, .set_id = 0 });
    try expectEqual(0, entry.indices.items.len);

    // Remove operations (with duplicates)
    entry.deinit();
    entry = try Entry.init(allocator);
    defer entry.deinit();

    try entry.add(.{ .id = 10, .set_id = 0 });
    try entry.add(.{ .id = 20, .set_id = 0 });
    try entry.add(.{ .id = 10, .set_id = 0 });
    try entry.add(.{ .id = 30, .set_id = 0 });

    entry.remove(.{ .id = 10, .set_id = 0 });
    try expectEqual(3, entry.indices.items.len);
    try expectEqualSlices(points.ValueType, &.{ 10, 20, 30 }, &.{
        entry.indices.items[0].id,
        entry.indices.items[1].id,
        entry.indices.items[2].id,
    });

    entry.remove(.{ .id = 10, .set_id = 0 });
    try expectEqual(2, entry.indices.items.len);
    try expectEqualSlices(points.ValueType, &.{ 30, 20 }, &.{
        entry.indices.items[0].id,
        entry.indices.items[1].id,
    });
}

test "ActivationTable comprehensive" {
    const allocator = testing.allocator;
    var table = ActivationTable.init(allocator);
    defer table.deinit();

    try expectEqual(allocator, table.allocator);
    try expectEqual(0, table.table.items.len);

    try table.addPointSet(.{});
    try expectEqual(1, table.table.items.len);
    try expectEqual(1, table.table.items[0].items.len);
    try expectEqual(1, table.table.items[0].items[0]);

    var t2 = ActivationTable.init(allocator);
    defer t2.deinit();
    try expect(!table.eql(t2));
    try t2.addPointSet(.{});
    try expect(table.eql(t2));

    try table.addPointSet(.{});
    try expectEqual(2, table.table.items.len);
    try expectEqual(2, table.table.items[0].items.len);
    try expectEqual(2, table.table.items[1].items.len);
    try expectEqualSlices(u1, &.{ 1, 1 }, table.table.items[0].items);
    try expectEqualSlices(u1, &.{ 1, 1 }, table.table.items[1].items);

    try table.addPointSet(.{ .search_neighbors = false, .find_neighbors = false });
    try expectEqual(3, table.table.items.len);
    try expectEqualSlices(u1, &.{ 1, 1, 0 }, table.table.items[0].items);
    try expectEqualSlices(u1, &.{ 1, 1, 0 }, table.table.items[1].items);
    try expectEqualSlices(u1, &.{ 0, 0, 0 }, table.table.items[2].items);

    table.setActive(.{ .all = true });
    try expectEqualSlices(u1, &.{ 1, 1, 1 }, table.table.items[0].items);
    try expectEqualSlices(u1, &.{ 1, 1, 1 }, table.table.items[1].items);
    try expectEqualSlices(u1, &.{ 1, 1, 1 }, table.table.items[2].items);

    try expect(table.isActive(0, 0));
    try expect(table.isActive(1, 2));
    try expect(table.isActive(2, 1));

    try expect(table.isSearchingNeighbors(0));
    try expect(table.isSearchingNeighbors(1));
    try expect(table.isSearchingNeighbors(2));

    table.setActive(.{ .all = false });
    try expectEqualSlices(u1, &.{ 0, 0, 0 }, table.table.items[0].items);
    try expectEqualSlices(u1, &.{ 0, 0, 0 }, table.table.items[1].items);
    try expectEqualSlices(u1, &.{ 0, 0, 0 }, table.table.items[2].items);

    table.setActive(.{ .neighbor = .{
        .idx1 = 0,
        .idx2 = 1,
        .active = true,
    } });
    try expectEqualSlices(u1, &.{ 0, 1, 0 }, table.table.items[0].items);
    try expectEqualSlices(u1, &.{ 0, 0, 0 }, table.table.items[1].items);

    try t2.addPointSet(.{});
    try t2.addPointSet(.{});
    t2.setActive(.{ .all = true });
    try expect(!table.eql(t2));

    try expect(!table.isActive(0, 0));
    try expect(table.isActive(0, 1));
    try expect(!table.isActive(1, 0));
    try expect(!table.isActive(2, 2));

    table.setActive(.{ .pairs = .{
        .index = 2,
        .set_flags = .{
            .search_neighbors = true,
            .find_neighbors = true,
        },
    } });
    try expectEqualSlices(u1, &.{ 0, 1, 1 }, table.table.items[0].items);
    try expectEqualSlices(u1, &.{ 0, 0, 1 }, table.table.items[1].items);
    try expectEqualSlices(u1, &.{ 1, 1, 1 }, table.table.items[2].items);

    try expect(table.isSearchingNeighbors(0));
    try expect(table.isSearchingNeighbors(1));
    try expect(table.isSearchingNeighbors(2));

    table.setActive(.{ .pairs = .{
        .index = 1,
        .set_flags = .{
            .search_neighbors = false,
            .find_neighbors = true,
        },
    } });
    try expectEqualSlices(u1, &.{ 0, 1, 1 }, table.table.items[0].items);
    try expectEqualSlices(u1, &.{ 0, 0, 0 }, table.table.items[1].items);
    try expectEqualSlices(u1, &.{ 1, 1, 1 }, table.table.items[2].items);

    try expect(table.isSearchingNeighbors(0));
    try expect(!table.isSearchingNeighbors(1));
    try expect(table.isSearchingNeighbors(2));
}
