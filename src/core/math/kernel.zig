const std = @import("std");

const Vector = @import("vec.zig").Vector;

/// Computes the cubic spline kernel with a precision enforced by T.
/// - `T` must be a float type
/// - `r` is the radial vector (r_i - r_j)
/// - `support_radius` is the smoothing length (control support domain radius)
///
/// Asserts that the smoothing length is strictly positive.
pub fn cubicSpline(comptime T: type, r: Vector(T, 3), comptime support_radius: T) T {
    comptime {
        switch (@typeInfo(T)) {
            .float => {},
            else => @compileError("T must be a known float type"),
        }
        std.debug.assert(support_radius > 0.0);
    }

    const sigma_d = comptime 8.0 / (std.math.pi * std.math.pow(T, support_radius, 3.0));
    const q = (comptime 1.0 / support_radius) * r.mag();

    return sigma_d * blk: {
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

/// Computes the Poly6 kernel.
/// - `T` must be a float type
/// - `r` is the radial vector (r_i - r_j)
/// - `support_radius` (h) is the smoothing length
pub fn poly6Spline(comptime T: type, r: Vector(T, 3), comptime support_radius: T) T {
    comptime {
        switch (@typeInfo(T)) {
            .float => {},
            else => @compileError("T must be a known float type"),
        }
        std.debug.assert(support_radius > 0.0);
    }

    // Pre-calculate normalization factor: 315 / (64 * pi * h^9)
    const h9 = comptime std.math.pow(T, support_radius, 9.0);
    const sigma_d = comptime 315.0 / (64.0 * std.math.pi * h9);

    const r_mag2 = r.magSq();
    const h2 = comptime support_radius * support_radius;

    if (r_mag2 > h2) {
        return 0.0;
    }

    const h2_r2 = h2 - r_mag2;
    return sigma_d * h2_r2 * h2_r2 * h2_r2;
}

/// Computes the gradient of the spiky kernel function.
/// - `T` must be a float type
/// - `r` is the radial vector (r_i - r_j)
/// - `support_radius` is the smoothing length (control support domain radius)
///
/// Asserts that the smoothing length is strictly positive.
pub fn spikyGradient(comptime T: type, r: Vector(T, 3), comptime support_radius: T) Vector(T, 3) {
    comptime {
        switch (@typeInfo(T)) {
            .float => {},
            else => @compileError("T must be a known float type"),
        }
        std.debug.assert(support_radius > 0.0);
    }

    const spiky_gradient: T = comptime blk: {
        const h6 = std.math.pow(T, support_radius, 6.0);
        break :blk -45.0 / (std.math.pi * h6);
    };

    const r_mag2 = r.magSq();
    const h2 = comptime support_radius * support_radius;
    if (r_mag2 > h2 or r_mag2 == 0.0) {
        return .splat(0.0);
    }

    const r_mag: T = @sqrt(r_mag2);
    const h_r = support_radius - r_mag;
    const gradient_mag = spiky_gradient * h_r * h_r / r_mag;
    return r.scale(gradient_mag);
}

/// Computes the Laplacian of the viscosity.
/// - `T` must be a float type
/// - `r` is the radial vector (r_i - r_j)
/// - `support_radius` is the smoothing length (control support domain radius)
///
/// Asserts that the smoothing length is strictly positive.
pub fn viscosityLaplacian(comptime T: type, r: Vector(T, 3), comptime support_radius: T) T {
    comptime {
        switch (@typeInfo(T)) {
            .float => {},
            else => @compileError("T must be a known float type"),
        }
        std.debug.assert(support_radius > 0.0);
    }

    const viscosity_lapl: T = comptime blk: {
        const h6 = std.math.pow(T, support_radius, 6.0);
        break :blk 45.0 / (std.math.pi * h6);
    };

    const r_mag = r.mag();
    return viscosity_lapl * blk: {
        if (r_mag > support_radius) {
            break :blk 0.0;
        } else {
            break :blk support_radius - r_mag;
        }
    };
}
