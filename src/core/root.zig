pub const allocator = @import("threading/allocator.zig").allocator;

pub const Timestep = @import("math/Timestep.zig");

pub const parallel_loop = @import("threading/parallel_loop.zig");
pub const ranges = @import("threading/ranges.zig");

pub const hash = @import("neighborhood/hash.zig");
pub const points = @import("neighborhood/points.zig");
pub const search = @import("neighborhood/search.zig");
pub const zorder = @import("neighborhood/zorder.zig");

pub const Vector = @import("math/vec.zig").Vector;
pub const Matrix = @import("math/mat.zig").Matrix;

test {
    _ = @import("math/Timestep.zig");
    _ = @import("threading/parallel_loop.zig");

    _ = @import("neighborhood/hash.zig");
    _ = @import("neighborhood/points.zig");
    _ = @import("neighborhood/search.zig");
    _ = @import("neighborhood/zorder.zig");

    _ = @import("math/vec.zig");
    _ = @import("math/mat.zig");
}
