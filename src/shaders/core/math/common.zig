/// A minimal, SIMD-native 4D Vector representation, aligning with the core module.
pub const Vec4 = extern struct {
    raw: @Vector(4, f32),

    pub fn init(vals: [4]f32) Vec4 {
        var out: Vec4 = undefined;
        inline for (0..4) |i| {
            out.raw[i] = vals[i];
        }
        return out;
    }

    pub fn dot(self: Vec4, other: Vec4) f32 {
        return @reduce(.Add, self.raw * other.raw);
    }
};

/// A minimal, SIMD-native 3D Vector representation, aligning with the core module.
pub const Vec3 = extern struct {
    raw: @Vector(3, f32),

    pub fn init(vals: [3]f32) Vec3 {
        var out: Vec3 = undefined;
        inline for (0..3) |i| {
            out.raw[i] = vals[i];
        }
        return out;
    }

    pub fn dot(self: Vec3, other: Vec3) f32 {
        return @reduce(.Add, self.raw * other.raw);
    }
};

/// A minimal, SIMD-native 4D Matrix representation, aligning with the core module.
pub const Mat4 = extern struct {
    raw: [4]Vec4,

    /// Performs matrix-matrix multiplication with the given vec.
    pub fn mulVec(self: Mat4, vec: Vec4) Vec4 {
        var out: Vec4 = undefined;
        inline for (0..4) |i| {
            out.raw[i] = self.raw[i].dot(vec);
        }
        return out;
    }

    /// Performs matrix-matrix multiplication with the given mat.
    pub fn mul(self: Mat4, other: Mat4) Mat4 {
        var out: Mat4 = undefined;
        const other_T = other.transpose();
        inline for (0..4) |i| {
            inline for (0..4) |k| {
                out.raw[i].raw[k] = self.raw[i].dot(other_T.raw[k]);
            }
        }
        return out;
    }

    /// Transposes the matrix, [i][j] maps to [j][i].
    pub fn transpose(self: Mat4) Mat4 {
        var out: Mat4 = undefined;
        inline for (0..4) |i| {
            inline for (0..4) |j| {
                out.raw[j].raw[i] = self.raw[i].raw[j];
            }
        }
        return out;
    }

    fn dimsFrom(idx: usize) struct { usize, usize } {
        const row: usize = @divFloor(idx, 4);
        const col = idx % 4;
        return .{ row, col };
    }

    /// Provides immutable element index into the matrix.
    pub fn at(self: *const Mat4, idx: usize) f32 {
        const row, const col = dimsFrom(idx);
        return self.mat[row].vec[col];
    }

    /// Provides mutable element index into the matrix.
    pub fn ptrAt(self: *Mat4, idx: usize) *f32 {
        const row, const col = dimsFrom(idx);
        return &self.mat[row].vec[col];
    }
};

const testing = @import("std").testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualSlices = testing.expectEqualSlices;
const expectApproxEqAbs = testing.expectApproxEqAbs;

const epsilon = 1e-6;

test "Vec basic operations" {
    const a3: Vec3 = .init(.{ 1.0, 2.0, 3.0 });
    const b3: Vec3 = .init(.{ 2.0, 0.0, 1.0 });
    try expectApproxEqAbs(1 * 2 + 2 * 0 + 3 * 1, a3.dot(b3), epsilon);
    try expectApproxEqAbs(1 * 1 + 2 * 2 + 3 * 3, a3.dot(a3), epsilon);

    const a4: Vec4 = .init(.{ 1.0, 2.0, 3.0, 4.0 });
    const b4: Vec4 = .init(.{ 2.0, 0.0, 1.0, 3.0 });

    try expectApproxEqAbs(1 * 2 + 2 * 0 + 3 * 1 + 4 * 3, a4.dot(b4), epsilon);
    try expectApproxEqAbs(1 * 1 + 2 * 2 + 3 * 3 + 4 * 4, a4.dot(a4), epsilon);
}

test "Mat4 transpose and multiplication" {
    const row0: Vec4 = .init(.{ 1, 2, 3, 4 });
    const row1: Vec4 = .init(.{ 5, 6, 7, 8 });
    const row2: Vec4 = .init(.{ 9, 10, 11, 12 });
    const row3: Vec4 = .init(.{ 13, 14, 15, 16 });
    const mat: Mat4 = .{ .raw = .{ row0, row1, row2, row3 } };

    const transposed = mat.transpose();

    try expectApproxEqAbs(5, transposed.raw[0].raw[1], epsilon);
    try expectApproxEqAbs(2, transposed.raw[1].raw[0], epsilon);
    try expectApproxEqAbs(15, transposed.raw[2].raw[3], epsilon);

    const vec = Vec4.init(.{ 1, 1, 1, 1 });
    const result = mat.mulVec(vec);
    try expectApproxEqAbs(10, result.raw[0], epsilon);
    try expectApproxEqAbs(26, result.raw[1], epsilon);
    try expectApproxEqAbs(42, result.raw[2], epsilon);
    try expectApproxEqAbs(58, result.raw[3], epsilon);
}
