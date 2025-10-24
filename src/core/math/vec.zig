const std = @import("std");

/// A stack-allocated, n-dimensional vector.
///
/// Implemented with SIMD in mind.
/// Other than `splat`, this does not wrap any other builtins.
/// Desired operations not provided by this api should access the `vec` field directly.
///
/// T must be a known float or int type.
///
/// Asserts that n is a strictly positive integer.
pub fn Vector(comptime T: type, comptime n: comptime_int) type {
    switch (@typeInfo(T)) {
        .float, .int => {},
        else => @compileError("T must be a known float or int type"),
    }

    if (n < 1) @compileError("Vector dimension n must be strictly positive");

    return struct {
        const Self = @This();

        const VecType: type = @Vector(n, T);

        /// Helper for iteration, mutating this does nothing good for you
        len: usize = n,
        vec: VecType,

        /// Creates a new vector with values corresponding the passed values.
        pub fn init(vals: [n]T) Self {
            var out: VecType = undefined;
            inline for (0..n) |i| {
                out[i] = vals[i];
            }
            return .{ .vec = out };
        }

        /// Shorthand for using @as with @splat
        pub fn splat(val: T) Self {
            return .{ .vec = @splat(val) };
        }

        pub fn scale(self: Self, val: T) Self {
            return .{ .vec = self.vec * splat(val).vec };
        }

        /// Computes the dot product. Applicable in all dimensions.
        pub fn dot(self: Self, other: Self) T {
            return @reduce(.Add, self.vec * other.vec);
        }

        /// Computes the cross product. Applicable only in 3D and 4D.
        ///
        /// In 4D, the 3D cross product is computed for the x, y, z part.
        /// The fourth lane is preserved as self's fourth lane.
        pub fn cross(self: Self, other: Self) Self {
            if (comptime n != 3 and n != 4) {
                @compileError("Cross product is only defined for 3D/4D vectors");
            }

            const a_yzx = @shuffle(
                T,
                self.vec,
                self.vec,
                if (n == 3) [_]i32{ 1, 2, 0 } else [_]i32{ 1, 2, 0, 3 },
            );
            const a_zxy = @shuffle(
                T,
                self.vec,
                self.vec,
                if (n == 3) [_]i32{ 2, 0, 1 } else [_]i32{ 2, 0, 1, 3 },
            );

            const b_yzx = @shuffle(
                T,
                other.vec,
                other.vec,
                if (n == 3) [_]i32{ 1, 2, 0 } else [_]i32{ 1, 2, 0, 3 },
            );
            const b_zxy = @shuffle(
                T,
                other.vec,
                other.vec,
                if (n == 3) [_]i32{ 2, 0, 1 } else [_]i32{ 2, 0, 1, 3 },
            );

            var c = a_yzx * b_zxy - a_zxy * b_yzx;
            if (comptime n == 4) {
                const mask = comptime @as(@Vector(4, bool), .{ false, false, false, true });
                c = @select(T, mask, self.vec, c);
            }

            return .{ .vec = c };
        }
    };
}

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualSlices = testing.expectEqualSlices;

test "Vector initialization and scalar multiplication" {
    const Vec4 = Vector(f32, 4);
    const expected_diff = [_]f32{ 0.0, 1.0, 2.0, 3.0 };
    const actual_diff = Vec4.init(expected_diff);
    for (0..actual_diff.len) |i| {
        try expectEqual(expected_diff[i], actual_diff.vec[i]);
    }

    const Vec16 = Vector(f32, 16);
    const expected_splat: [16]f32 = @splat(-24.7);
    const actual_splat = Vec16.splat(-24.7);
    for (0..actual_splat.len) |i| {
        try expectEqual(expected_splat[i], actual_splat.vec[i]);
    }

    const expected_scale = [_]f32{ 15.0, 18.0, -21.0, 24.0 };
    const vec = Vec4.init(.{ 5.0, 6.0, -7.0, 8.0 });
    const actual_scale = vec.scale(3);
    for (0..actual_scale.len) |i| {
        try expectEqual(expected_scale[i], actual_scale.vec[i]);
    }
}

test "Dot product" {
    const Vec2 = Vector(f32, 2);
    const Vec3 = Vector(f32, 3);
    const Vec4 = Vector(f32, 4);

    const a2 = Vec2.init(.{ 2.0, 3.0 });
    const b2 = Vec2.init(.{ 4.0, 5.0 });
    try expectEqual(23, a2.dot(b2));

    const a3 = Vec3.init(.{ 1.0, 2.0, 3.0 });
    const b3 = Vec3.init(.{ 4.0, 5.0, 6.0 });
    try expectEqual(32, a3.dot(b3));

    const a4 = Vec4.init(.{ 1.0, 2.0, 3.0, 4.0 });
    const b4 = Vec4.init(.{ 5.0, 6.0, 7.0, 8.0 });
    try expectEqual(70, a4.dot(b4));
}

test "Cross product" {
    const Vec3 = Vector(i32, 3);
    const Vec4 = Vector(f32, 4);

    const a3 = Vec3.init(.{ 2, 3, 4 });
    const b3 = Vec3.init(.{ 5, 6, 7 });
    try expectEqual(Vec3.init(.{ -3, 6, -3 }), a3.cross(b3));

    const a4 = Vec4.init(.{ 3.0, -3.0, 1.0, 30.0 });
    const b4 = Vec4.init(.{ 4.0, 9.0, 2.0, -9030.0 });
    try expectEqual(Vec4.init(.{ -15.0, -2.0, 39.0, 30.0 }), a4.cross(b4));
}
