const std = @import("std");

const Vector = @import("vec.zig").Vector;

/// Computes the cubic spline kernel with a precision enforced by T.
/// - T must be a float type
/// - r is the radial vector (r_i - r_j)
/// - h is the smoothing length (control support domain radius)
///
/// Asserts that the smoothing length is strictly positive.
pub fn cubicSpline(comptime T: type, r: Vector(T, 3), h: T) T {
    comptime switch (@typeInfo(T)) {
        .float => {},
        else => @compileError("T must be a known float type"),
    };
    std.debug.assert(h > 0.0);
    const eight_piths = 8.0 * std.math.pi;

    const q = (1.0 / h) * r.mag();
    const sigma: T = eight_piths / std.math.pow(T, h, 3.0);
    return sigma * blk: {
        if (0.0 <= q and q <= 0.5) {
            break :blk @mulAdd(
                T,
                6.0,
                std.math.pow(T, q, 3.0) - std.math.pow(T, q, 2.0),
                1.0,
            );
        } else if (0.5 < q and q <= 1.0) {
            break :blk 2.0 * std.math.pow(T, 1.0 - q, 3.0);
        } else return 0.0;
    };
}
