const std = @import("std");

const search = @import("search.zig");
const points = @import("points.zig");

pub fn ActualSearch(
    comptime Context: type,
    comptime Fragment: type,
    comptime T: type,
    comptime P: type,
    comptime distance: fn (*const P, *const P) T,
) type {
    return struct {
        /// Checks for neighbors inside the same bucket in the hash grid.
        pub fn same(ctx: Context, slice: []Fragment, thread_num: usize) !void {
            _ = thread_num;
            const searcher = ctx.@"0";
            for (slice) |kvp| {
                _, const entry_idx = kvp;
                std.debug.assert(entry_idx.* < searcher.entries.items.len);
                const entry = searcher.entries.items[entry_idx.*];
                if (entry.searching_points == 0) continue;

                for (0..entry.indices.items.len) |a| {
                    const pa = entry.indices.items[a];
                    std.debug.assert(pa.set_id < searcher.point_sets.items.len);

                    for (a + 1..entry.indices.items.len) |b| {
                        const pb = entry.indices.items[b];
                        std.debug.assert(pb.set_id < searcher.point_sets.items.len);

                        const xa = searcher.point_sets.items[pa.set_id].point(pa.id);
                        const xb = searcher.point_sets.items[pb.set_id].point(pb.id);

                        // Check both activations since edges are directed
                        if (distance(xa, xb) < searcher.radius2) {
                            // Enforce canonical locking order
                            var p1, var p2 = .{ pa, pb };
                            if (p1.set_id > p2.set_id or (p1.set_id == p2.set_id and p1.id > p2.id)) {
                                std.mem.swap(@TypeOf(pa), &p1, &p2);
                            }

                            if (searcher.activation_table.isActive(pa.set_id, pb.set_id)) {
                                searcher.point_sets.items[p1.set_id].locks.items[p2.set_id].items[p1.id].lock();
                                defer searcher.point_sets.items[p1.set_id].locks.items[p2.set_id].items[p1.id].unlock();

                                try searcher.point_sets.items[pa.set_id].neighbors.items[pb.set_id].items[pa.id].append(
                                    searcher.allocator,
                                    pb.id,
                                );
                            }

                            if (searcher.activation_table.isActive(pb.set_id, pa.set_id)) {
                                searcher.point_sets.items[p2.set_id].locks.items[p1.set_id].items[p2.id].lock();
                                defer searcher.point_sets.items[p2.set_id].locks.items[p1.set_id].items[p2.id].unlock();

                                try searcher.point_sets.items[pb.set_id].neighbors.items[pa.set_id].items[pb.id].append(
                                    searcher.allocator,
                                    pa.id,
                                );
                            }
                        }
                    }
                }
            }
        }

        /// Checks for neighbors in all adjacent buckets in the hash grid.
        pub fn bucket(ctx: Context, slice: []Fragment, thread_num: usize) !void {
            _ = thread_num;
            const searcher, const visited_entries, const e_locks = ctx;
            for (slice) |kvp| {
                const key, const entry_idx = kvp;
                std.debug.assert(entry_idx.* < searcher.entries.items.len);
                const entry = searcher.entries.items[entry_idx.*];
                if (entry.searching_points == 0) continue;

                inline for (search.neighbors_3d) |n| {
                    // Determine the grid_idx at comptime to allow for inlining
                    const grid_idx: usize = comptime @intCast(n.gridIdx());
                    if (comptime grid_idx != search.grid_center) blk: {
                        // Check if we've seen this before
                        {
                            e_locks.items[entry_idx.*].lock();
                            defer e_locks.items[entry_idx.*].unlock();

                            if (visited_entries.items[entry_idx.*][grid_idx]) {
                                break :blk;
                            }
                        }

                        const value = searcher.map.get(.init(
                            key.key[0] + n.dj,
                            key.key[1] + n.dk,
                            key.key[2] + n.dl,
                        )) orelse break :blk;

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
                            e_locks.items[entry_ids[0]].lock();
                            defer e_locks.items[entry_ids[0]].unlock();
                            e_locks.items[entry_ids[1]].lock();
                            defer e_locks.items[entry_ids[1]].unlock();

                            if (visited_entries.items[entry_idx.*][grid_idx]) {
                                break :blk;
                            }

                            visited_entries.items[entry_idx.*][grid_idx] = true;
                            visited_entries.items[value][26 - grid_idx] = true;
                        }

                        // Final neighborhood search
                        for (entry.indices.items) |pa| {
                            for (searcher.entries.items[value].indices.items) |pb| {
                                const xa = searcher.point_sets.items[pa.set_id].point(pa.id);
                                const xb = searcher.point_sets.items[pb.set_id].point(pb.id);

                                // Check both activations since edges are directed
                                if (distance(xa, xb) < searcher.radius2) {
                                    // Enforce canonical locking order
                                    var p1, var p2 = .{ pa, pb };
                                    if (p1.set_id > p2.set_id or (p1.set_id == p2.set_id and p1.id > p2.id)) {
                                        std.mem.swap(@TypeOf(pa), &p1, &p2);
                                    }

                                    searcher.point_sets.items[p1.set_id].locks.items[p2.set_id].items[p1.id].lock();
                                    defer searcher.point_sets.items[p1.set_id].locks.items[p2.set_id].items[p1.id].unlock();

                                    searcher.point_sets.items[p2.set_id].locks.items[p1.set_id].items[p2.id].lock();
                                    defer searcher.point_sets.items[p2.set_id].locks.items[p1.set_id].items[p2.id].unlock();

                                    if (searcher.activation_table.isActive(pa.set_id, pb.set_id)) {
                                        try searcher.point_sets.items[pa.set_id].neighbors.items[pb.set_id].items[pa.id].append(
                                            searcher.allocator,
                                            pb.id,
                                        );
                                    }
                                    if (searcher.activation_table.isActive(pb.set_id, pa.set_id)) {
                                        try searcher.point_sets.items[pb.set_id].neighbors.items[pa.set_id].items[pb.id].append(
                                            searcher.allocator,
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
    };
}
