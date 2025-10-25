pub const allocator = @import("core/threading/allocator.zig").allocator;

pub const Timestep = @import("core/math/Timestep.zig");

pub const parallel_loop = @import("core/threading/parallel_loop.zig");
pub const ranges = @import("core/threading/ranges.zig");

pub const hash = @import("core/neighborhood/hash.zig");
pub const points = @import("core/neighborhood/points.zig");
pub const search = @import("core/neighborhood/search.zig");
pub const zorder = @import("core/neighborhood/zorder.zig");

pub const Vector = @import("core/math/vec.zig").Vector;
pub const Matrix = @import("core/math/mat.zig").Matrix;

test {
    _ = @import("core/math/Timestep.zig");
    _ = @import("core/threading/parallel_loop.zig");

    _ = @import("core/neighborhood/hash.zig");
    _ = @import("core/neighborhood/points.zig");
    _ = @import("core/neighborhood/search.zig");
    _ = @import("core/neighborhood/zorder.zig");

    _ = @import("core/math/vec.zig");
    _ = @import("core/math/mat.zig");
}
