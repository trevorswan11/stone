const std = @import("std");

/// A stack-allocated, n-dimensional vector.
///
/// Implemented with SIMD in mind.
/// Other than `splat`, this does not wrap any other builtins.
///
/// Desired operations not provided by this api should access the `vec` field directly.
/// Operations like `add` are provided but never used in this implementation.
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

        pub const VecType: type = @Vector(n, T);

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

        /// Similar to init, except the returned value has decayed into the raw SIMD representation.
        ///
        /// While technically not lossy, this should only be used for GPU-specific use-cases.
        pub fn decay(vals: [n]T) @Vector(n, T) {
            return Self.init(vals).vec;
        }

        /// Similar to init, except the returned value has spawned from the SIMD vec.
        pub fn spawn(v: @Vector(n, T)) Self {
            return .{ .vec = v };
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

        /// Element wise addition.
        pub fn add(self: Self, other: Self) Self {
            return .spawn(self.vec + other.vec);
        }

        /// Element wise subtraction.
        pub fn sub(self: Self, other: Self) Self {
            return .spawn(self.vec - other.vec);
        }

        /// Returns the squared magnitude of the vector.
        ///
        /// Cheaper than mag() as it avoids a square root.
        pub fn magSq(self: Self) T {
            return self.dot(self);
        }

        /// Returns the magnitude of the vector.
        ///
        /// T must be a float type.
        pub fn mag(self: Self) T {
            comptime if (@typeInfo(T) != .float) {
                @compileError("mag is only defined for float vectors");
            };

            return @sqrt(self.magSq());
        }

        /// Returns a new vector with the same direction but a magnitude of 1.
        ///
        /// T must be a float type.
        ///
        /// Asserts that the magnitude is nonzero.
        pub fn normalize(self: Self) Self {
            comptime if (@typeInfo(T) != .float) {
                @compileError("normalize is only defined for float vectors");
            };

            const m = self.mag();
            std.debug.assert(m != 0);
            return self.scale(1.0 / m);
        }

        /// Provides immutable element index into the matrix.
        pub fn at(self: *const Self, idx: usize) T {
            std.debug.assert(idx < self.len);
            return self.vec[idx];
        }

        /// Provides mutable element index into the matrix.
        pub fn ptrAt(self: *Self, idx: usize) *T {
            std.debug.assert(idx < self.len);
            return &self.vec[idx];
        }
    };
}

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualSlices = testing.expectEqualSlices;
const expectApproxEqAbs = testing.expectApproxEqAbs;

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

test "Vector geometric operations" {
    const Vec3 = Vector(f32, 3);
    const a = Vec3.init(.{ 3.0, 0.0, 4.0 });

    try expectApproxEqAbs(25.0, a.magSq(), 1e-6);
    try expectApproxEqAbs(5.0, a.mag(), 1e-6);

    const expected_norm = Vec3.init(.{ 0.6, 0.0, 0.8 });
    const actual_norm = a.normalize();

    inline for (0..3) |i| {
        try expectApproxEqAbs(expected_norm.vec[i], actual_norm.vec[i], 1e-6);
    }
}
