const std = @import("std");

const hash = @import("hash.zig");
const zorder = @import("zorder.zig");
const points = @import("points.zig");

pub const initial_table_size: usize = 10;
pub const initial_num_indices: usize = 50;
pub const initial_num_neighbors: usize = 50;

/// Creates a neighborhood searcher with the given floating point type.
///
/// T must be a float, and this is confirmed at comptime.
pub fn Search(comptime T: type) type {
    switch (@typeInfo(T)) {
        .float => {},
        else => @compileError("T must be a known float type"),
    }

    return struct {
        const Self = @This();

        pub const PointSet = points.PointSet(T);

        pub const QueryVariant = union(enum) {
            /// Performs the actual query.
            ///
            /// Neighbors are tracked on a per-set basis.
            ///
            /// Assigns a list of neighboring points to each point in every added point set.
            actual: struct { points_changed: bool = true },

            /// Performs the query for a single point in the given set.
            ///
            /// The neighbors list is updated in place with a list of neighboring points.
            single_point_from_set: struct {
                point_set_id: usize,
                point_idx: usize,
                neighbors: *PointSet.NeighborAccumulator,
            },

            /// Performs the actual for a single point x.
            ///
            /// The neighbors list is updated in place with a list of neighboring points.
            single_point: struct {
                point: *const [3]T,
                neighbors: *PointSet.NeighborAccumulator,
            },
        };

        allocator: std.mem.Allocator,

        point_sets: std.ArrayList(PointSet),
        activation_table: hash.ActivationTable,
        old_activation_table: hash.ActivationTable,

        radius: T,
        inverse_radius: T,
        radius2: T,
        map: hash.SpatialMap,
        entries: std.ArrayList(hash.Entry),

        erase_empty_cells: bool = false,
        requires_refresh: bool = false,

        /// Creates a new neighborhood searcher.
        ///
        /// Asserts that the radius is strictly positive.
        pub fn init(allocator: std.mem.Allocator, radius: T) !Self {
            std.debug.assert(radius > 0.0);
            var self = Self{
                .allocator = allocator,

                .point_sets = try .initCapacity(allocator, initial_table_size),
                .activation_table = .init(allocator),
                .old_activation_table = .init(allocator),

                .radius = radius,
                .inverse_radius = 1.0 / radius,
                .radius2 = radius * radius,
                .map = .init(allocator),
                .entries = try .initCapacity(allocator, initial_num_neighbors),
            };

            try self.refresh(null);
            return self;
        }

        /// Rebuild hash table and entry array from scratch.
        ///
        /// Not specifying a new radius preserves the old value.
        ///
        /// Asserts that the radius is strictly positive.
        fn refresh(self: *Self, new_radius: ?T) !void {
            self.entries.clearRetainingCapacity();
            self.map.clearRetainingCapacity();

            if (new_radius) |radius| {
                self.radius = radius;
                self.radius2 = radius * radius;
                self.inverse_radius = 1.0 / radius;
            }

            var temp_keys = try std.ArrayList(hash.Key).initCapacity(self.allocator, 100);
            defer temp_keys.deinit(self.allocator);

            for (self.point_sets.items, 0..) |*point_set, j| {
                const old_size = point_set.locks.items.len;
                try point_set.locks.resize(self.allocator, self.point_sets.items.len);
                if (old_size < point_set.locks.items.len) {
                    for (point_set.locks.items) |*l| {
                        l.* = .empty;
                    }
                }

                for (point_set.locks.items) |*lock| {
                    try lock.resize(self.allocator, point_set.number_of_points);
                }

                for (0..point_set.number_of_points) |i| {
                    const key = self.cellIndex(point_set.point(i));
                    point_set.keys.items[i] = key;
                    point_set.old_keys.items[i] = key;

                    if (self.map.get(key)) |value| {
                        try self.entries.items[value].add(.{ .id = i, .set_id = j });
                        if (self.activation_table.isSearchingNeighbors(j)) {
                            self.entries.items[value].searching_points += 1;
                        }
                    } else {
                        var new_entry = try hash.Entry.init(self.allocator);
                        try new_entry.add(.{ .id = i, .set_id = j });
                        if (self.activation_table.isSearchingNeighbors(j)) {
                            new_entry.searching_points += 1;
                        }
                        try self.entries.append(self.allocator, new_entry);

                        try temp_keys.append(self.allocator, key);
                        try self.map.put(key, self.entries.items.len - 1);
                    }
                }
            }

            self.map.clearRetainingCapacity();
            for (0..self.entries.items.len) |i| {
                try self.map.put(temp_keys.items[i], i);
            }
            self.requires_refresh = false;
        }

        pub fn deinit(self: *Self) void {
            defer {
                self.point_sets.deinit(self.allocator);
                self.entries.deinit(self.allocator);
            }

            for (self.point_sets.items) |*point_set| {
                point_set.deinit();
            }

            for (self.entries.items) |*entry| {
                entry.deinit();
            }

            self.activation_table.deinit();
            self.old_activation_table.deinit();

            self.map.deinit();
        }

        /// Increases the size of a point set under the assumption
        /// that the existing points remain at the same position.
        pub fn resizePointSet(
            self: *Self,
            point_set_idx: usize,
            new_positions: []const T,
            total_points: usize,
        ) !void {
            if (self.requires_refresh) {
                return error.InvalidState;
            }

            std.debug.assert(point_set_idx < self.point_sets.items.len);
            var point_set = &self.point_sets.items[point_set_idx];
            const old_size = point_set.number_of_points;

            // Shrink, delete old
            if (old_size > total_points) {
                var to_delete: std.ArrayList(points.ValueType) = .empty;
                defer to_delete.deinit(self.allocator);

                if (self.erase_empty_cells) {
                    to_delete = try .initCapacity(self.allocator, self.entries.items.len);
                }

                for (total_points..old_size) |i| {
                    const key = point_set.keys.items[i];
                    if (self.map.get(key)) |value| {
                        self.entries.items[value].remove(.{ .id = i, .set_id = point_set_idx });

                        if (self.activation_table.isSearchingNeighbors(point_set_idx)) {
                            self.entries.items[value].searching_points -= 1;
                        }

                        if (self.erase_empty_cells and self.entries.items[value].indices.items.len == 0) {
                            try to_delete.append(self.allocator, value);
                        }
                    }
                }

                if (self.erase_empty_cells) {
                    try self.eraseEmptyEntries(&to_delete);
                }
            }

            try point_set.resize(new_positions, total_points);

            // Insert new entries and resize locks
            for (old_size..point_set.number_of_points) |i| {
                const key = self.cellIndex(point_set.point(i));
                point_set.keys.items[i] = key;
                point_set.old_keys.items[i] = key;

                if (self.map.get(key)) |value| {
                    try self.entries.items[value].add(.{ .id = i, .set_id = point_set_idx });
                    if (self.activation_table.isSearchingNeighbors(point_set_idx)) {
                        self.entries.items[self.entries.items.len - 1].searching_points += 1;
                    }
                } else {
                    var new_entry = try hash.Entry.init(self.allocator);
                    try new_entry.add(.{ .id = i, .set_id = point_set_idx });
                    if (self.activation_table.isSearchingNeighbors(point_set_idx)) {
                        new_entry.searching_points += 1;
                    }
                    try self.entries.append(self.allocator, new_entry);

                    try self.map.put(key, self.entries.items.len - 1);
                }
            }

            for (point_set.locks.items) |*lock| {
                try lock.resize(self.allocator, point_set.number_of_points);
                for (lock.items) |*sl| sl.* = .{};
            }
        }

        /// Creates and adds a new set of points.
        ///
        /// Returns unique identifier in form of an index assigned
        /// to the newly created point set.
        pub fn addPointSet(
            self: *Self,
            point_positions: []const T,
            total_points: usize,
            dynamic: bool,
            set_flags: hash.ActivationTable.SetFlags,
        ) !usize {
            try self.point_sets.append(self.allocator, try .init(
                self.allocator,
                point_positions,
                total_points,
                dynamic,
            ));

            try self.activation_table.addPointSet(set_flags);
            std.debug.assert(self.point_sets.items.len >= 1);
            return self.point_sets.items.len - 1;
        }

        /// When applicable, the neighbors payload is reset.
        pub fn findNeighbors(self: *Self, variant: QueryVariant) !void {
            switch (variant) {
                .actual => |actual| {
                    if (actual.points_changed) {
                        try self.updatePointSets();
                    }
                    try self.updateActivation();
                },
                else => {},
            }
            try self.query(variant);
        }

        /// Everything this function might be:
        /// - A never-nester's worst nightmare
        /// - A poor man's solution to function overloading
        /// - A leak-free manager of too many heap allocations
        /// - A graph data structure manager in disguise
        fn query(self: *Self, variant: QueryVariant) !void {
            switch (variant) {
                .actual => {
                    // Refresh the neighbors list for each point set's points
                    for (self.point_sets.items, 0..) |*point_set, i| {
                        try point_set.neighbors.resize(self.allocator, self.point_sets.items.len);
                        for (point_set.neighbors.items, 0..) |*neighbors, j| {
                            neighbors.* = .empty;
                            try neighbors.resize(self.allocator, point_set.number_of_points);
                            for (neighbors.items) |*nested| {
                                nested.* = .empty;
                                nested.clearRetainingCapacity();
                                if (self.activation_table.isActive(i, j)) {
                                    try nested.ensureTotalCapacity(self.allocator, initial_num_neighbors);
                                }
                            }
                        }
                    }

                    // Operations on the map will completely destroy the fragmented map
                    self.map.lockPointers();
                    defer self.map.unlockPointers();

                    // Split the map into non-owning fragments for trivial parallelization
                    const FragmentedMap = std.ArrayList(struct { *const hash.Key, *const points.ValueType });
                    var kv_pairs = try FragmentedMap.initCapacity(self.allocator, self.map.count());
                    defer kv_pairs.deinit(self.allocator);

                    var kv_iter = self.map.iterator();
                    while (kv_iter.next()) |entry| {
                        kv_pairs.appendAssumeCapacity(.{ entry.key_ptr, entry.value_ptr });
                    }

                    // TODO: Parallelize
                    for (kv_pairs.items) |kvp| {
                        _, const entry_idx = kvp;
                        std.debug.assert(entry_idx.* < self.entries.items.len);
                        const entry = self.entries.items[entry_idx.*];
                        if (entry.searching_points == 0) continue;

                        for (0..entry.indices.items.len) |a| {
                            const pa = entry.indices.items[a];
                            std.debug.assert(pa.set_id < self.point_sets.items.len);

                            for (a + 1..entry.indices.items.len) |b| {
                                const pb = entry.indices.items[b];
                                std.debug.assert(pb.set_id < self.point_sets.items.len);

                                const xa = self.point_sets.items[pa.set_id].point(pa.id);
                                const xb = self.point_sets.items[pb.set_id].point(pb.id);

                                // TODO: Investigate need for locks
                                if (distanceSquared(xa, xb) < self.radius) {
                                    // Check both activations since edges are directed
                                    if (self.activation_table.isActive(pa.set_id, pb.set_id)) {
                                        try self.point_sets.items[pa.set_id].neighbors.items[pb.set_id].items[pa.id].append(
                                            self.allocator,
                                            pb.id,
                                        );
                                    }
                                    if (self.activation_table.isActive(pb.set_id, pa.set_id)) {
                                        try self.point_sets.items[pb.set_id].neighbors.items[pa.set_id].items[pb.id].append(
                                            self.allocator,
                                            pa.id,
                                        );
                                    }
                                }
                            }
                        }
                    }

                    // Create some temp data structures for tracking on the second pass
                    var visited = std.ArrayList([27]bool).empty;
                    try visited.resize(self.allocator, self.entries.items.len);
                    defer visited.deinit(self.allocator);
                    for (visited.items) |*arr| arr.* = @splat(false);

                    var entry_locks = std.ArrayList(points.SpinLock).empty;
                    defer entry_locks.deinit(self.allocator);
                    try entry_locks.resize(self.allocator, self.entries.items.len);
                    for (entry_locks.items) |*sl| sl.* = .{};

                    // TODO: Parallelize
                    for (kv_pairs.items) |kvp| {
                        const key, const entry_idx = kvp;
                        std.debug.assert(entry_idx.* < self.entries.items.len);
                        const entry = self.entries.items[entry_idx.*];
                        if (entry.searching_points == 0) continue;

                        for ([_]i32{ -1, 0, 1 }) |dj| {
                            for ([_]i32{ -1, 0, 1 }) |dk| {
                                for ([_]i32{ -1, 0, 1 }) |dl| {
                                    const lock_idx: usize = @intCast(9 * (dj + 1) + 3 * (dk + 1) + (dl + 1));
                                    if (lock_idx == 13) continue;

                                    // Check if we've seen this before
                                    {
                                        entry_locks.items[entry_idx.*].lock();
                                        defer entry_locks.items[entry_idx.*].unlock();

                                        if (visited.items[entry_idx.*][lock_idx]) {
                                            continue;
                                        }
                                    }

                                    const value = self.map.get(.init(
                                        key.key[0] + dj,
                                        key.key[1] + dk,
                                        key.key[2] + dl,
                                    )) orelse continue;

                                    // Order the entry indices for thread safety
                                    var entry_ids: [2]points.ValueType = .{
                                        entry_idx.*, value,
                                    };
                                    if (entry_ids[0] > entry_ids[1]) {
                                        entry_ids = .{
                                            value, entry_idx.*,
                                        };
                                    }

                                    // Check if we've seen this before - marking if we haven't
                                    {
                                        entry_locks.items[entry_ids[0]].lock();
                                        defer entry_locks.items[entry_ids[0]].unlock();
                                        entry_locks.items[entry_ids[1]].lock();
                                        defer entry_locks.items[entry_ids[1]].unlock();

                                        if (visited.items[entry_idx.*][lock_idx]) {
                                            continue;
                                        }

                                        visited.items[entry_idx.*][lock_idx] = true;
                                        visited.items[value][26 - lock_idx] = true;
                                    }

                                    // Final neighborhood search
                                    for (entry.indices.items) |pa| {
                                        for (self.entries.items[value].indices.items) |pb| {
                                            const xa = self.point_sets.items[pa.set_id].point(pa.id);
                                            const xb = self.point_sets.items[pb.set_id].point(pb.id);

                                            if (distanceSquared(xa, xb) < self.radius) {
                                                // Check both activations since edges are directed
                                                if (self.activation_table.isActive(pa.set_id, pb.set_id)) {
                                                    self.point_sets.items[pa.set_id].locks.items[pb.set_id].items[pa.id].lock();
                                                    defer self.point_sets.items[pa.set_id].locks.items[pb.set_id].items[pa.id].unlock();

                                                    try self.point_sets.items[pa.set_id].neighbors.items[pb.set_id].items[pa.id].append(
                                                        self.allocator,
                                                        pb.id,
                                                    );
                                                }
                                                if (self.activation_table.isActive(pb.set_id, pa.set_id)) {
                                                    self.point_sets.items[pb.set_id].locks.items[pa.set_id].items[pb.id].lock();
                                                    defer self.point_sets.items[pb.set_id].locks.items[pa.set_id].items[pb.id].unlock();

                                                    try self.point_sets.items[pb.set_id].neighbors.items[pa.set_id].items[pb.id].append(
                                                        self.allocator,
                                                        pa.id,
                                                    );
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                },
                .single_point_from_set => |point| {
                    const point_idx = point.point_idx;
                    const point_set_id = point.point_set_id;
                    const neighbors = point.neighbors;

                    // Refresh the neighbors list
                    const old_len = neighbors.items.len;
                    const new_len = self.point_sets.items.len;

                    if (new_len < old_len) {
                        for (neighbors.items[new_len..]) |*nested| {
                            nested.deinit(self.allocator);
                        }
                    }

                    try neighbors.resize(self.allocator, new_len);
                    if (new_len > old_len) {
                        for (neighbors.items[old_len..]) |*nested| {
                            nested.* = .empty;
                        }
                    }

                    for (neighbors.items, 0..) |*nested, j| {
                        nested.clearRetainingCapacity();
                        if (self.activation_table.isActive(point_set_id, j)) {
                            try nested.ensureTotalCapacity(self.allocator, initial_num_neighbors);
                        }
                    }

                    // Now we can safely continue!
                    std.debug.assert(point_set_id < self.point_sets.items.len);
                    const point_set = self.point_sets.items[point_set_id];
                    const xa = point_set.point(point_idx);
                    const key = self.cellIndex(xa);

                    if (self.map.get(key)) |value| {
                        try addNeighbors(
                            self,
                            value,
                            xa,
                            neighbors,
                            .{ .id = point_idx, .set_id = point_set_id },
                            true,
                            true,
                        );
                    } else unreachable;

                    inline for ([_]i32{ -1, 0, 1 }) |dj| {
                        inline for ([_]i32{ -1, 0, 1 }) |dk| {
                            inline for ([_]i32{ -1, 0, 1 }) |dl| {
                                if (comptime 9 * (dj + 1) + 3 * (dk + 1) + (dl + 1) != 13) {
                                    if (self.map.get(.init(
                                        key.key[0] + dj,
                                        key.key[1] + dk,
                                        key.key[2] + dl,
                                    ))) |value| {
                                        try addNeighbors(
                                            self,
                                            value,
                                            xa,
                                            neighbors,
                                            .{ .id = point_idx, .set_id = point_set_id },
                                            true,
                                            false,
                                        );
                                    }
                                }
                            }
                        }
                    }
                },
                .single_point => |point| {
                    const xa = point.point;
                    const neighbors = point.neighbors;

                    // Refresh the neighbors list
                    const old_len = neighbors.items.len;
                    const new_len = self.point_sets.items.len;

                    if (new_len < old_len) {
                        for (neighbors.items[new_len..]) |*nested| {
                            nested.deinit(self.allocator);
                        }
                    }
                    try neighbors.resize(self.allocator, new_len);
                    if (new_len > old_len) {
                        for (neighbors.items[old_len..]) |*nested| {
                            nested.* = .empty;
                        }
                    }

                    for (neighbors.items) |*nested| {
                        nested.clearRetainingCapacity();
                        try nested.ensureTotalCapacity(self.allocator, initial_num_neighbors);
                    }

                    // Now we can safely continue!
                    const key = self.cellIndex(xa);
                    if (self.map.get(key)) |value| {
                        try addNeighbors(
                            self,
                            value,
                            xa,
                            neighbors,
                            null,
                            false,
                            false,
                        );
                    }

                    inline for ([_]i32{ -1, 0, 1 }) |dj| {
                        inline for ([_]i32{ -1, 0, 1 }) |dk| {
                            inline for ([_]i32{ -1, 0, 1 }) |dl| {
                                if (comptime 9 * (dj + 1) + 3 * (dk + 1) + (dl + 1) != 13) {
                                    if (self.map.get(.init(
                                        key.key[0] + dj,
                                        key.key[1] + dk,
                                        key.key[2] + dl,
                                    ))) |value| {
                                        try addNeighbors(
                                            self,
                                            value,
                                            xa,
                                            neighbors,
                                            null,
                                            false,
                                            false,
                                        );
                                    }
                                }
                            }
                        }
                    }
                },
            }
        }

        /// Searches and adds all relevant neighbors to the passed neighbor list.
        ///
        /// Perform a neighborhood search on the given node.
        ///
        /// Asserts that the entries array has the relevant point.
        pub fn addNeighbors(
            self: *const Self,
            relevant_entry_idx: points.ValueType,
            relevant_point: *const [3]f32,
            neighbors: *PointSet.NeighborAccumulator,
            relevant_point_id: ?points.PointID,
            comptime omit_inactive: bool,
            comptime omit_self: bool,
        ) !void {
            std.debug.assert(relevant_entry_idx < self.entries.items.len);
            const entry = self.entries.items[relevant_entry_idx];
            for (entry.indices.items) |id| {
                var point_set = self.point_sets.items[id.set_id];
                const xb = point_set.point(id.id);

                if (comptime omit_self) {
                    std.debug.assert(relevant_point_id != null);
                    if (relevant_point_id.?.set_id == id.set_id and relevant_point_id.?.id == id.id) continue;
                }

                if (comptime omit_inactive) {
                    std.debug.assert(relevant_point_id != null);
                    if (!self.activation_table.isActive(relevant_point_id.?.set_id, id.set_id)) {
                        continue;
                    }
                }

                if (distanceSquared(relevant_point, xb) < self.radius2) {
                    std.debug.assert(id.set_id < neighbors.items.len);
                    try neighbors.items[id.set_id].append(self.allocator, id.id);
                }
            }
        }

        /// Returns the squared distance between two points:
        ///
        /// d = (a1 - b1)^2 + (a3 - b3)^2 + (a3 - b3)^2
        fn distanceSquared(a: *const [3]T, b: *const [3]T) T {
            var dist: T = 0;
            inline for (a, b) |an, bn| {
                const diff = an - bn;
                dist += diff * diff;
            }
            return dist;
        }

        /// Generates a sort table according to a space-filling Z curve.
        /// The generated table is stored in each point set's internal sort table.
        ///
        /// Prerequisite for the PointSet's sort function. Forces the gird to
        /// be reinitialized, so do not call too frequently.
        pub fn zort(self: *Self) !void {
            for (self.point_sets.items) |*point_set| {
                try point_set.sort_table.resize(self.allocator, point_set.number_of_points);
                for (point_set.sort_table.items, 0..) |*ptr, val| {
                    ptr.* = val;
                }

                const context = .{ self, point_set };
                std.mem.sort(
                    points.ValueType,
                    point_set.sort_table.items,
                    context,
                    struct {
                        pub fn lt(ctx: @TypeOf(context), a: points.ValueType, b: points.ValueType) bool {
                            const searcher: *Self, const ps: *PointSet = ctx;
                            const a_z = zorder.zencodeKey(searcher.cellIndex(ps.point(a)));
                            const b_z = zorder.zencodeKey(searcher.cellIndex(ps.point(b)));
                            return a_z < b_z;
                        }
                    }.lt,
                );
            }

            self.requires_refresh = true;
        }

        /// Activate/Deactivate a requested table location.
        pub fn setActive(
            self: *Self,
            variant: hash.ActivationTable.Variant,
        ) void {
            self.activation_table.setActive(variant);
            self.requires_refresh = true;
        }

        /// Update neighborhood search data structures after a position change.
        pub fn updatePointSets(self: *Self) !void {
            if (self.requires_refresh) {
                try self.refresh(null);
            }

            // TODO: Parallelize
            for (self.point_sets.items) |*point_set| {
                if (point_set.dynamic) {
                    std.debug.assert(point_set.keys.capacity == point_set.old_keys.capacity);
                    std.debug.assert(point_set.keys.items.len == point_set.old_keys.items.len);

                    // This is spooky, memory is tossed around a ton here
                    std.mem.swap([]hash.Key, &point_set.keys.items, &point_set.old_keys.items);
                    for (0..point_set.number_of_points) |i| {
                        std.debug.assert(i < point_set.keys.items.len);
                        point_set.keys.items[i] = self.cellIndex(point_set.point(i));
                    }
                }
            }

            var to_delete: std.ArrayList(points.ValueType) = .empty;
            defer to_delete.deinit(self.allocator);

            if (self.erase_empty_cells) {
                to_delete = try .initCapacity(self.allocator, self.entries.items.len);
            }
            try self.updateHashTable(&to_delete);
            if (self.erase_empty_cells) {
                try self.eraseEmptyEntries(&to_delete);
            }
        }

        /// Update neighborhood search data structures after changing the activation table.
        pub fn updateActivation(self: *Self) !void {
            if (!self.activation_table.eql(self.old_activation_table)) {
                for (self.entries.items) |*entry| {
                    entry.searching_points = 0;
                    for (entry.indices.items) |idx| {
                        if (self.activation_table.isSearchingNeighbors(idx.set_id)) {
                            entry.searching_points += 1;
                        }
                    }
                }

                self.old_activation_table.deinit();
                self.old_activation_table = try self.activation_table.clone(self.allocator);
            }
        }

        /// Checks if a pair is active.
        ///
        /// Asserts that the two indices are valid, assuming the table has square dimensions.
        pub fn isActive(self: *Self, idx1: usize, idx2: usize) bool {
            return self.activation_table.isActive(idx1, idx2);
        }

        /// Updates the internal hashed points.
        ///
        /// to_delete is returned sorted in descending order with the points to remove with `eraseEmptyEntries`.
        fn updateHashTable(self: *Self, to_delete: *std.ArrayList(points.ValueType)) !void {
            for (self.point_sets.items, 0..) |*point_set, j| {
                for (0..point_set.number_of_points) |i| {
                    if (point_set.keys.items[i].eql(point_set.old_keys.items[i])) continue;

                    const key = point_set.keys.items[i];
                    if (self.map.get(key)) |value| {
                        try self.entries.items[value].add(.{ .id = i, .set_id = j });
                        if (self.activation_table.isSearchingNeighbors(j)) {
                            self.entries.items[value].searching_points += 1;
                        }
                    } else {
                        var new_entry = try hash.Entry.init(self.allocator);
                        try new_entry.add(.{ .id = i, .set_id = j });
                        if (self.activation_table.isSearchingNeighbors(j)) {
                            new_entry.searching_points += 1;
                        }
                        try self.entries.append(self.allocator, new_entry);

                        try self.map.put(key, self.entries.items.len - 1);
                    }

                    const entry_idx = self.map.get(point_set.old_keys.items[i]) orelse unreachable;
                    std.debug.assert(entry_idx < self.entries.items.len);

                    self.entries.items[entry_idx].remove(.{ .id = i, .set_id = j });
                    if (self.activation_table.isSearchingNeighbors(j)) {
                        self.entries.items[entry_idx].searching_points -= 1;
                    }

                    if (self.erase_empty_cells) {
                        if (self.entries.items[entry_idx].indices.items.len == 0) {
                            try to_delete.append(self.allocator, entry_idx);
                        }
                    }
                }
            }

            var to_prune = try std.ArrayList(usize).initCapacity(self.allocator, to_delete.items.len);
            defer to_prune.deinit(self.allocator);
            for (0..to_delete.items.len) |i| {
                if (self.entries.items[i].indices.items.len != 0) {
                    to_prune.appendAssumeCapacity(i);
                }
            }
            to_delete.orderedRemoveMany(to_prune.items);

            std.mem.sort(
                points.ValueType,
                to_delete.items,
                {},
                std.sort.desc(points.ValueType),
            );
        }

        /// Erases all entires from to_delete from the Searcher.
        ///
        /// Asserts that the array is sorted in descending order.
        fn eraseEmptyEntries(self: *Self, to_delete: *const std.ArrayList(points.ValueType)) !void {
            if (to_delete.items.len == 0) return;

            std.debug.assert(std.sort.isSorted(
                points.ValueType,
                to_delete.items,
                {},
                std.sort.desc(points.ValueType),
            ));

            // Remove empty entries
            var to_prune = try std.ArrayList(usize).initCapacity(self.allocator, self.entries.items.len);
            defer to_prune.deinit(self.allocator);
            for (self.entries.items, 0..) |*entry, i| {
                if (entry.indices.items.len == 0) {
                    to_prune.appendAssumeCapacity(i);
                }
            }
            self.entries.orderedRemoveMany(to_prune.items);

            // Erase from the map
            var it = self.map.iterator();
            while (it.next()) |entry| {
                const in_range = entry.value_ptr.* <= to_delete.items[0] and entry.value_ptr.* >= to_delete.getLast();
                if (in_range and (std.sort.binarySearch(
                    points.ValueType,
                    to_delete.items,
                    entry.value_ptr.*,
                    struct {
                        pub fn revOrd(ref: points.ValueType, other: points.ValueType) std.math.Order {
                            return switch (std.math.order(ref, other)) {
                                .lt => .gt,
                                .eq => .eq,
                                .gt => .lt,
                            };
                        }
                    }.revOrd,
                ) != null)) {
                    // We can now remove but must refresh the iterator to prevent invalidation
                    _ = self.map.remove(entry.key_ptr.*);
                    it = self.map.iterator();
                }
            }

            // Perform neighborhood search to update remaining entries
            // TODO: Parallelize
            var values = self.map.valueIterator();
            while (values.next()) |value| {
                for (to_delete.items, 0..) |selected, i| {
                    if (value.* >= selected) {
                        value.* -= to_delete.items.len - i;
                        break;
                    }
                }
            }
        }

        /// Converts a triple float index to a world space position x.
        pub fn cellIndex(self: *Self, point: *const [3]T) hash.Key {
            var key: hash.Key = undefined;
            inline for (0..3) |i| {
                key.key[i] = blk: {
                    const val: i32 = @intFromFloat(self.inverse_radius * point[i]);
                    break :blk if (point[i] >= 0.0) val else val - 1;
                };
            }
            return key;
        }
    };
}

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualSlices = testing.expectEqualSlices;

test "Search initialization and destruction" {
    const allocator = testing.allocator;
    var search = try Search(f32).init(allocator, 3.14);
    defer search.deinit();
}

test "Cell index probing" {
    const allocator = testing.allocator;
    var search = try Search(f32).init(allocator, 3.14);
    defer search.deinit();

    try expectEqualSlices(i32, &.{ -657740481, 153456480, 636497664 }, &search.cellIndex(&.{ -2065305262.0, 481853423.0, 1998602736.0 }).key);
    try expectEqualSlices(i32, &.{ -230444097, 230401024, -317766241 }, &search.cellIndex(&.{ -723594490.0, 723459257.0, -997786085.0 }).key);
    try expectEqualSlices(i32, &.{ 673585088, 646660352, -252833953 }, &search.cellIndex(&.{ 2115057420.0, 2030513621.0, -793898702.0 }).key);
    try expectEqualSlices(i32, &.{ -497842017, -120704697, 111086728 }, &search.cellIndex(&.{ -1563224045.0, -379012780.0, 348812344.0 }).key);
    try expectEqualSlices(i32, &.{ -673504321, 600115520, -463189697 }, &search.cellIndex(&.{ -2114803654.0, 1884362860.0, -1454415730.0 }).key);
    try expectEqualSlices(i32, &.{ 287908672, -227144529, 88177824 }, &search.cellIndex(&.{ 904033316.0, -713233864.0, 276878398.0 }).key);
    try expectEqualSlices(i32, &.{ -568131777, 582154048, -421773505 }, &search.cellIndex(&.{ -1783933800.0, 1827963946.0, -1324368939.0 }).key);
    try expectEqualSlices(i32, &.{ -615122241, -31370115, 263366896 }, &search.cellIndex(&.{ -1931484049.0, -98502170.0, 826972073.0 }).key);
    try expectEqualSlices(i32, &.{ -625082241, 226288784, -357421089 }, &search.cellIndex(&.{ -1962758367.0, 710546820.0, -1122302356.0 }).key);
    try expectEqualSlices(i32, &.{ -464479265, 111545256, -232559297 }, &search.cellIndex(&.{ -1458465012.0, 350252140.0, -730236255.0 }).key);
}

test "Search basic validity" {
    const allocator = testing.allocator;
    var search = try Search(f32).init(allocator, 3.14);
    defer search.deinit();

    try search.zort();
    try search.updatePointSets();
}

test "Search basic usage" {
    const allocator = testing.allocator;

    const radius: f32 = 1.0;
    const S = Search(f32);
    var search = try S.init(allocator, radius);
    defer search.deinit();

    // Set 0: Static, 2 points
    var p0_data: [6]f32 = .{
        0.0, 0.0, 0.0, // p0_0 @ cell (0,0,0)
        5.0, 5.0, 5.0, // p0_1 @ cell (5,5,5)
    };

    // Set 1: Dynamic, 2 points
    var p1_data_buf = try std.ArrayList(f32).initCapacity(allocator, 12);
    defer p1_data_buf.deinit(allocator);
    try p1_data_buf.appendSlice(allocator, &.{
        0.5, 0.0, 0.0, // p1_0 @ cell (0,0,0)
        10.0, 10.0, 10.0, // p1_1 @ cell (10,10,10)
    });

    const p0_id = try search.addPointSet(
        p0_data[0..],
        2,
        false,
        .{ .search_neighbors = true, .find_neighbors = false },
    );
    try search.resizePointSet(p0_id, p0_data[0..], 2);
    const p1_id = try search.addPointSet(
        p1_data_buf.items,
        2,
        true,
        .{ .search_neighbors = true, .find_neighbors = true },
    );
    try search.resizePointSet(p1_id, p1_data_buf.items, 2);

    try expectEqual(0, p0_id);
    try expectEqual(1, p1_id);
    try expect(search.point_sets.items.len == 2);
    try expect(search.point_sets.items[0].number_of_points == 2);
    try expect(search.point_sets.items[1].number_of_points == 2);

    // Set Activation & Initial Update
    search.setActive(.{ .neighbor = .{
        .idx1 = 0,
        .idx2 = 1,
        .active = false,
    } });
    try expect(search.isActive(1, 0));
    try expect(!search.isActive(0, 1));
    try expect(search.isActive(1, 1));

    try search.updatePointSets();
    try search.updateActivation();

    // Verify Initial State
    try expectEqual(3, search.map.count());
    const key0 = search.cellIndex(&.{ 0.0, 0.0, 0.0 });
    const key1 = search.cellIndex(&.{ 5.0, 5.0, 5.0 });
    const key2 = search.cellIndex(&.{ 10.0, 10.0, 10.0 });

    // Cell (0,0,0) has p0_0 and p1_0
    const entry0_idx = search.map.get(key0).?;
    const entry0 = &search.entries.items[entry0_idx];
    try expectEqual(2, entry0.indices.items.len);
    try expectEqual(2, entry0.searching_points);

    // Cell (5,5,5) has p0_1
    const entry1_idx = search.map.get(key1).?;
    const entry1 = &search.entries.items[entry1_idx];
    try expectEqual(1, entry1.indices.items.len);
    try expectEqual(1, entry1.searching_points);

    // Cell (10,10,10) has p1_1
    const entry2_idx = search.map.get(key2).?;
    const entry2 = &search.entries.items[entry2_idx];
    try expectEqual(1, entry2.indices.items.len);
    try expectEqual(1, entry2.searching_points);
    search.erase_empty_cells = true;

    // Move p1_0 (idx 0) from (0.5, 0, 0) -> (0.5, 2.0, 0)
    p1_data_buf.items[1] = 2.0;
    search.point_sets.items[p1_id].position_data[1] = 2.0;
    const new_key_p1_0 = search.cellIndex(search.point_sets.items[p1_id].point(0));
    try expectEqualSlices(i32, &.{ 0, 2, 0 }, &new_key_p1_0.key);

    // Move p1_1 (idx 1) from (10, 10, 10) -> (5.1, 5.0, 5.0)
    p1_data_buf.items[3] = 5.1;
    search.point_sets.items[p1_id].position_data[3] = 5.1;
    p1_data_buf.items[4] = 5.0;
    search.point_sets.items[p1_id].position_data[4] = 5.0;
    p1_data_buf.items[5] = 5.0;
    search.point_sets.items[p1_id].position_data[5] = 5.0;
    const new_key_p1_1 = search.cellIndex(search.point_sets.items[p1_id].point(1));
    try expectEqualSlices(i32, &.{ 5, 5, 5 }, &new_key_p1_1.key);

    // Neighbor fetching without validation (leak & compile check)
    var neighbors: S.PointSet.NeighborAccumulator = .empty;
    defer {
        defer neighbors.deinit(allocator);
        for (neighbors.items) |*nested| {
            nested.deinit(allocator);
        }
    }

    try search.findNeighbors(.{ .actual = .{ .points_changed = true } });
    try search.findNeighbors(.{ .single_point = .{
        .point = &.{ 0.0, 0.0, 0.0 },
        .neighbors = &neighbors,
    } });
    try search.findNeighbors(.{ .single_point_from_set = .{
        .point_set_id = p1_id,
        .point_idx = 1,
        .neighbors = &neighbors,
    } });
}

test "Search neighbor queries" {
    const allocator = testing.allocator;

    const radius: f32 = 1.0;
    const S = Search(f32);
    var search = try S.init(allocator, radius);
    defer search.deinit();

    var p0_data: [6]f32 = .{ 0.0, 0.0, 0.0, 5.0, 5.0, 5.0 };
    var p1_data_buf = try std.ArrayList(f32).initCapacity(allocator, 12);
    defer p1_data_buf.deinit(allocator);
    try p1_data_buf.appendSlice(allocator, &.{ 0.5, 0.0, 0.0, 10.0, 10.0, 10.0 });

    const p0_id = try search.addPointSet(
        p0_data[0..],
        2,
        false,
        .{ .search_neighbors = true, .find_neighbors = false },
    );
    try search.resizePointSet(p0_id, p0_data[0..], 2);
    const p1_id = try search.addPointSet(
        p1_data_buf.items,
        2,
        true,
        .{ .search_neighbors = true, .find_neighbors = true },
    );
    try search.resizePointSet(p1_id, p1_data_buf.items, 2);

    search.setActive(.{ .neighbor = .{ .idx1 = 0, .idx2 = 1, .active = false } });
    try search.updatePointSets();
    try search.updateActivation();
    search.erase_empty_cells = true;

    // Move points
    search.point_sets.items[p1_id].position_data[1] = 2.0;
    search.point_sets.items[p1_id].position_data[3] = 5.1;
    search.point_sets.items[p1_id].position_data[4] = 5.0;
    search.point_sets.items[p1_id].position_data[5] = 5.0;

    // Run search to update internal state (.actual)
    try search.findNeighbors(.{ .actual = .{ .points_changed = true } });

    // Using .single_point_from_set
    {
        var neighbors_from_set: S.PointSet.NeighborAccumulator = .empty;
        defer {
            defer neighbors_from_set.deinit(allocator);
            for (neighbors_from_set.items) |*list| list.deinit(allocator);
        }

        try search.findNeighbors(.{
            .single_point_from_set = .{
                .point_set_id = p1_id,
                .point_idx = 1,
                .neighbors = &neighbors_from_set,
            },
        });

        try expectEqual(2, neighbors_from_set.items.len);
        try expectEqual(1, neighbors_from_set.items[0].items.len);
        try expectEqual(1, neighbors_from_set.items[0].items[0]);
        try expectEqual(0, neighbors_from_set.items[1].items.len);
    }

    // Using .single_point
    {
        var neighbors_single: S.PointSet.NeighborAccumulator = .empty;
        defer {
            defer neighbors_single.deinit(allocator);
            for (neighbors_single.items) |*list| list.deinit(allocator);
        }
        const query_point: [3]f32 = .{ 0.1, 0.1, 0.1 };

        try search.findNeighbors(.{ .single_point = .{
            .point = &query_point,
            .neighbors = &neighbors_single,
        } });

        try expectEqual(2, neighbors_single.items.len);
        try expectEqual(1, neighbors_single.items[0].items.len);
        try expectEqual(0, neighbors_single.items[0].items[0]);
        try expectEqual(0, neighbors_single.items[1].items.len);
    }
}
