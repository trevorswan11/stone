const std = @import("std");

const Vector = @import("vec.zig").Vector;

/// Calculates the new pressure using 'Weakly Compressible SPH'.
/// - `T` must be a float type
/// - `particle_density` is the particles density whose pressure we are solving for
/// - `rest_density` is the starting fluid density
/// - `speed_of_sound` is the speed of sound through that fluid at your conditions
/// - `gamma` is a constant, and is generally 7 for water
/// - `initial_pressure` is the fluid's initial pressure which is added to the result.
///
/// This is the most efficient yet most incorrect way to handle pressure updates.
/// The equation used in the 'Cole Equation'.
///
/// Asserts that:
/// - The rest density is non-zero
/// - Gamma is non-zero
///
/// Guarantees that:
/// - The returned pressure is at least 0.0
///
/// https://en.wikipedia.org/wiki/Smoothed-particle_hydrodynamics
pub fn wcsph(
    comptime T: type,
    particle_density: T,
    comptime rest_density: T,
    comptime speed_of_sound: T,
    comptime gamma: T,
    comptime initial_pressure: T,
) T {
    comptime {
        std.debug.assert(rest_density != 0.0);
        std.debug.assert(gamma != 0.0);
    }

    const B = comptime blk: {
        const numerator = rest_density * speed_of_sound * speed_of_sound;
        break :blk numerator / gamma;
    };

    const ratio = particle_density / rest_density;
    const ratio_raised = std.math.pow(T, ratio, gamma);

    const pressure: T = @mulAdd(T, B, ratio_raised - 1.0, initial_pressure);
    return @max(pressure, 0.0);
}
