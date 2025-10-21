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

        allocator: std.mem.Allocator,

        point_sets: std.ArrayList(points.PointSet(T)),
        activation_table: hash.ActivationTable,
        old_activation_table: hash.ActivationTable,

        inverse_cell_size: T,
        r2: T,
        map: hash.SpatialMap,
        entries: std.ArrayList(hash.Entry),

        erase_empty_cells: bool = false,
        initialized: bool = false,

        /// Creates a new neighborhood searcher.
        ///
        /// Asserts that the radius is strictly positive.
        pub fn init(allocator: std.mem.Allocator, radius: T) !Self {
            std.debug.assert(radius > 0.0);
            return .{
                .allocator = allocator,

                .point_sets = try .initCapacity(allocator, initial_table_size),
                .activation_table = .init(allocator),
                .old_activation_table = .init(allocator),

                .inverse_cell_size = 1.0 / radius,
                .r2 = radius * radius,
                .map = .init(allocator),
                .entries = try .initCapacity(allocator, initial_num_neighbors),
            };
        }

        pub fn deinit(self: *Self) void {
            self.point_sets.deinit(self.allocator);
            self.activation_table.deinit();
            self.old_activation_table.deinit();

            self.map.deinit();
            self.entries.deinit(self.allocator);
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
