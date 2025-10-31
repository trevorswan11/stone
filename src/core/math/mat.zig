const std = @import("std");

const Vector = @import("vec.zig").Vector;

/// A stack-allocated, m x n-dimensional matrix.
/// - The matrix will have m rows
/// - The matrix will have n columns
///
/// Implemented with SIMD in mind.
/// Other than `splat`, this does not wrap any other builtins.
/// Desired operations not provided by this api should access the `mat` field directly.
///
/// T must be a known float or int type.
///
/// Asserts that m and n are strictly positive integers.
pub fn Matrix(comptime T: type, comptime m: comptime_int, comptime n: comptime_int) type {
    switch (@typeInfo(T)) {
        .float, .int => {},
        else => @compileError("T must be a known float or int type"),
    }

    if (n < 1 or m < 1) @compileError("Matrix dimensions m and n must be strictly positive");

    return struct {
        const Self = @This();

        pub const VecType = Vector(T, n);
        pub const MatType = [m]VecType;

        pub const Dimensions = struct {
            numel: usize = m * n,
            rows: usize = m,
            cols: usize = n,
        };

        const default_value: T = switch (@typeInfo(T)) {
            .float => 0.0,
            .int => 0,
            else => unreachable,
        };

        /// Helper for iteration, mutating this does nothing good for you
        dims: Dimensions = .{},
        mat: MatType,

        /// Creates a new matrix with values corresponding the passed values.
        ///
        /// The values are passed in row-major order.
        /// - [1, 2, 3, 4] is parsed as Mat2([1, 2], [3, 4])
        pub fn init(vals: [m * n]T) Self {
            var out: MatType = undefined;
            inline for (0..m) |row| {
                out[row] = .init(vals[row * n .. row * n + n].*);
            }
            return .{ .mat = out };
        }

        /// Creates a matrix with all values set to the given value.
        pub fn splat(val: T) Self {
            return .{ .mat = @splat(VecType.splat(val)) };
        }

        /// Returns the 'identity' matrix for the matrix type.
        /// The diag_val is used for the diagonal, hence the quotes around 'identity'.
        ///
        /// Asserts that the matrix is square.
        pub fn identity(comptime diag_val: T) Self {
            comptime std.debug.assert(m == n);
            var out: Self = .splat(default_value);
            inline for (0..m) |row| {
                out.mat[row].vec[row] = diag_val;
            }

            return out;
        }

        pub fn scale(self: Self, val: T) Self {
            var out: MatType = undefined;
            inline for (0..m) |row| {
                out[row] = self.mat[row].scale(val);
            }
            return .{ .mat = out };
        }

        /// Returns the flattened element index from the 2D index.
        pub fn indexFrom(row: usize, col: usize) usize {
            std.debug.assert(row < m);
            std.debug.assert(col < n);
            return row * n + col;
        }

        /// Returns the {row, col} indices from the flat index.
        pub fn dimsFrom(idx: usize) struct { usize, usize } {
            const row: usize = @divFloor(idx, n);
            const col = idx % n;
            return .{ row, col };
        }

        /// Provides immutable element index into the matrix.
        pub fn at(self: *const Self, idx: usize) T {
            std.debug.assert(idx < self.dims.numel);
            const row, const col = dimsFrom(idx);
            return self.mat[row].vec[col];
        }

        /// Provides mutable element index into the matrix.
        pub fn ptrAt(self: *Self, idx: usize) *T {
            std.debug.assert(idx < self.dims.numel);
            const row, const col = dimsFrom(idx);
            return &self.mat[row].vec[col];
        }

        /// Transposes the (m x n) matrix into an (n x m) matrix.
        pub fn transpose(self: Self) Matrix(T, n, m) {
            const OutMat = Matrix(T, n, m);
            var out: OutMat = comptime OutMat.splat(default_value);

            inline for (0..m) |i| {
                inline for (0..n) |j| {
                    out.mat[j].vec[i] = self.mat[i].vec[j];
                }
            }
            return out;
        }

        /// Multiplies this (m x n) matrix by an n-dimensional vector.
        pub fn mulVec(self: Self, v: VecType) Vector(T, m) {
            const OutVec = Vector(T, m);
            var out: OutVec = undefined;

            inline for (0..m) |i| {
                out.vec[i] = self.mat[i].dot(v);
            }
            return out;
        }

        /// Multiplies this (m x n) matrix by an (n x p) matrix.
        pub fn mul(
            self: Self,
            comptime p: comptime_int,
            other: Matrix(T, n, p),
        ) Matrix(T, m, p) {
            const OutMat = Matrix(T, m, p);
            var out: OutMat = comptime OutMat.splat(default_value);

            const other_T = other.transpose();
            inline for (0..m) |i| {
                inline for (0..p) |k| {
                    out.mat[i].vec[k] = self.mat[i].dot(other_T.mat[k]);
                }
            }
            return out;
        }
    };
}

/// Rotates the matrix in 3D space about the vector representing the axis of rotation.
/// Preserves the final component of the output.
///
/// Implementation from glm: https://github.com/g-truc/glm
///
/// T must be a float, and the angle should be in radians.
pub fn rotate(
    comptime T: type,
    mat: Matrix(T, 4, 4),
    angle: T,
    rotation_axis: Vector(T, 3),
) Matrix(T, 4, 4) {
    comptime if (@typeInfo(T) != .float) {
        @compileError("rotate is only defined for floats");
    };
    const Mat = Matrix(T, 4, 4);

    const cos: T = @cos(angle);
    const sin: T = @sin(angle);
    const axis = rotation_axis.normalize();
    const temp = axis.scale(1.0 - cos);

    var rotated: Mat = .splat(0.0);

    rotated.mat[0].vec[0] = cos + temp.vec[0] * axis.vec[0];
    rotated.mat[0].vec[1] = temp.vec[0] * axis.vec[1] + sin * axis.vec[2];
    rotated.mat[0].vec[2] = temp.vec[0] * axis.vec[2] - sin * axis.vec[1];

    rotated.mat[1].vec[0] = temp.vec[1] * axis.vec[0] - sin * axis.vec[2];
    rotated.mat[1].vec[1] = cos + temp.vec[1] * axis.vec[1];
    rotated.mat[1].vec[2] = temp.vec[1] * axis.vec[2] + sin * axis.vec[0];

    rotated.mat[2].vec[0] = temp.vec[2] * axis.vec[0] + sin * axis.vec[1];
    rotated.mat[2].vec[1] = temp.vec[2] * axis.vec[1] - sin * axis.vec[0];
    rotated.mat[2].vec[2] = cos + temp.vec[2] * axis.vec[2];

    rotated.mat[3].vec[3] = 1.0;
    return mat.mul(4, rotated);
}

/// Computes the RHS view matrix.
///
/// Implementation from glm: https://github.com/g-truc/glm
///
/// T must be a float.
pub fn lookAt(
    comptime T: type,
    eye: Vector(T, 3),
    center: Vector(T, 3),
    up: Vector(T, 3),
) Matrix(T, 4, 4) {
    comptime if (@typeInfo(T) != .float) {
        @compileError("lookAt is only defined for floats");
    };

    const Mat = Matrix(T, 4, 4);
    const Vec = Vector(T, 3);

    const f_raw: Vec = .spawn(center.vec - eye.vec);
    const f = f_raw.normalize();
    const s = f.cross(up).normalize();
    const u = s.cross(f);

    var out: Mat = .identity(1.0);

    out.mat[0].vec[0] = s.vec[0];
    out.mat[0].vec[1] = s.vec[1];
    out.mat[0].vec[2] = s.vec[2];

    out.mat[1].vec[0] = u.vec[0];
    out.mat[1].vec[1] = u.vec[1];
    out.mat[1].vec[2] = u.vec[2];

    out.mat[2].vec[0] = -f.vec[0];
    out.mat[2].vec[1] = -f.vec[1];
    out.mat[2].vec[2] = -f.vec[2];

    out.mat[0].vec[3] = -s.dot(eye);
    out.mat[1].vec[3] = -u.dot(eye);
    out.mat[2].vec[3] = f.dot(eye);

    return out;
}

/// Creates the perspective matrix from the scene parameters.
/// You do not need to invert [1][1] in the result.
///
/// Implementation from glm: https://github.com/g-truc/glm
///
/// T must be a float.
pub fn perspective(
    comptime T: type,
    fovy: T,
    aspect: T,
    z_near: T,
    z_far: T,
) Matrix(T, 4, 4) {
    comptime if (@typeInfo(T) != .float) {
        @compileError("perspective is only defined for floats");
    };

    const Mat = Matrix(T, 4, 4);

    const tan_half_fovy = @tan(fovy / 2.0);
    var out: Mat = .splat(0.0);

    out.mat[0].vec[0] = 1.0 / (aspect * tan_half_fovy);
    out.mat[1].vec[1] = -1.0 / tan_half_fovy;
    out.mat[2].vec[2] = -(z_far + z_near) / (z_far - z_near);
    out.mat[3].vec[2] = -1.0;
    out.mat[2].vec[3] = -(2.0 * z_far * z_near) / (z_far - z_near);

    return out;
}

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualSlices = testing.expectEqualSlices;
const expectApproxEqAbs = testing.expectApproxEqAbs;

test "Matrix initialization and scalar multiplication" {
    const Mat2 = Matrix(f32, 2, 2);

    const row1: Mat2.VecType = .init(.{ 0.0, 1.0 });
    const row2: Mat2.VecType = .init(.{ 2.0, 3.0 });
    const actual_diff: Mat2 = .init(.{ 0.0, 1.0, 2.0, 3.0 });
    for (0..actual_diff.dims.rows, [_]Mat2.VecType{ row1, row2 }) |row, expected| {
        try expectEqual(expected, actual_diff.mat[row]);
    }

    const expected_m2_ident = [_]f32{ 1.0, 0.0, 0.0, 1.0 };
    const actual_m2_ident = comptime Mat2.identity(1.0);
    inline for (0..4) |i| {
        try expectEqual(expected_m2_ident[i], actual_m2_ident.at(i));
    }

    const Mat4 = Matrix(f32, 4, 4);

    const expected_rows = [_]Mat4.VecType{
        .init(.{ 10.0, 10.0, 10.0, 10.0 }),
        .init(.{ 10.0, 10.0, 10.0, 10.0 }),
        .init(.{ 10.0, 10.0, 10.0, 10.0 }),
        .init(.{ 10.0, 10.0, 10.0, 10.0 }),
    };
    const actual_splat: Mat4 = .splat(10.0);
    try expectEqualSlices(Mat4.VecType, &expected_rows, &actual_splat.mat);

    const expected_scaled_rows = [_]Mat4.VecType{
        .init(.{ 40.0, 40.0, 40.0, 40.0 }),
        .init(.{ 40.0, 40.0, 40.0, 40.0 }),
        .init(.{ 40.0, 40.0, 40.0, 40.0 }),
        .init(.{ 40.0, 40.0, 40.0, 40.0 }),
    };
    const actual_scaled = actual_splat.scale(4.0);
    try expectEqualSlices(Mat4.VecType, &expected_scaled_rows, &actual_scaled.mat);

    const Mat67 = Matrix(i16, 6, 7);

    const expected_mat67 = [_]Mat67.VecType{
        .init(.{ 0, 1, 2, 3, 4, 5, 6 }),
        .init(.{ 7, 8, 9, 10, 11, 12, 13 }),
        .init(.{ 14, 15, 16, 17, 18, 19, 20 }),
        .init(.{ 21, 22, 23, 24, 25, 26, 27 }),
        .init(.{ 28, 29, 30, 31, 32, 33, 34 }),
        .init(.{ 35, 36, 37, 38, 39, 40, 41 }),
    };

    const init_vals67 = [_]i16{
        0,  1,  2,  3,  4,  5,  6,
        7,  8,  9,  10, 11, 12, 13,
        14, 15, 16, 17, 18, 19, 20,
        21, 22, 23, 24, 25, 26, 27,
        28, 29, 30, 31, 32, 33, 34,
        35, 36, 37, 38, 39, 40, 41,
    };

    var actual_67: Mat67 = .init(init_vals67);
    try expectEqualSlices(Mat67.VecType, &expected_mat67, &actual_67.mat);

    var idx: usize = 0;
    for (0..6) |row| {
        for (0..7) |col| {
            try expectEqual(
                init_vals67[idx],
                actual_67.at(Mat67.indexFrom(row, col)),
            );
            idx += 1;
        }
    }

    const Mat76 = Matrix(i32, 7, 6);

    const expected_mat76 = [_]Mat76.VecType{
        .init(.{ 0, 1, 2, 3, 4, 5 }),
        .init(.{ 6, 7, 8, 9, 10, 11 }),
        .init(.{ 12, 13, 14, 15, 16, 17 }),
        .init(.{ 18, 19, 20, 21, 22, 23 }),
        .init(.{ 24, 25, 26, 27, 28, 29 }),
        .init(.{ 30, 31, 32, 33, 34, 35 }),
        .init(.{ 36, 37, 38, 39, 40, 41 }),
    };

    var init_vals76 = [_]i32{
        0,  1,  2,  3,  4,  5,
        6,  7,  8,  9,  10, 11,
        12, 13, 14, 15, 16, 17,
        18, 19, 20, 21, 22, 23,
        24, 25, 26, 27, 28, 29,
        30, 31, 32, 33, 34, 35,
        36, 37, 38, 39, 40, 41,
    };

    var actual_76: Mat76 = .init(init_vals76);
    try expectEqualSlices(Mat76.VecType, &expected_mat76, &actual_76.mat);

    for (init_vals76, 0..) |val, i| {
        try expectEqual(val, actual_76.ptrAt(i).*);
    }

    init_vals76[9] = -200.0;
    actual_76.ptrAt(9).* = -200.0;
    for (init_vals76, 0..) |val, i| {
        try expectEqual(val, actual_76.ptrAt(i).*);
    }
}

test "Matrix transposition" {
    const Mat23 = Matrix(f32, 2, 3);
    const Mat32 = Matrix(f32, 3, 2);
    const m23: Mat23 = .init(.{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 });

    const m32 = m23.transpose();
    const expected_m32_data = [_]f32{ 1.0, 4.0, 2.0, 5.0, 3.0, 6.0 };
    const expected_m32: Mat32 = .init(expected_m32_data);

    try expectEqualSlices(Mat32.VecType, &expected_m32.mat, &m32.mat);
    try expect(@TypeOf(m23) != @TypeOf(m32));
    try expect(@TypeOf(m32) == Mat32);
}

test "Matrix-vector multiplication" {
    const Mat33 = Matrix(f32, 3, 3);
    const m33: Mat33 = .init(.{
        1.0, 2.0, 3.0,
        4.0, 5.0, 6.0,
        7.0, 8.0, 9.0,
    });
    const vec3: Mat33.VecType = .init(.{ 2.0, 3.0, 4.0 });

    const out_vec = m33.mulVec(vec3);
    const expected_vec: @Vector(3, f32) = .{
        (1.0 * 2.0 + 2.0 * 3.0 + 3.0 * 4.0),
        (4.0 * 2.0 + 5.0 * 3.0 + 6.0 * 4.0),
        (7.0 * 2.0 + 8.0 * 3.0 + 9.0 * 4.0),
    };

    inline for (0..3) |i| {
        try expectEqual(expected_vec[i], out_vec.vec[i]);
    }
    try expect(@TypeOf(out_vec) == Vector(f32, 3));
}

test "Matrix-matrix multiplication" {
    const Mat23 = Matrix(f32, 2, 3);
    const Mat2 = Matrix(f32, 2, 2);

    const m1: Mat23 = .init(.{
        1.0, 2.0, 3.0,
        4.0, 5.0, 6.0,
    });

    const m23: Mat23 = .init(.{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 });
    const m2 = m23.transpose();
    const out_m = m1.mul(2, m2);

    const expected_out_m_data = [_]f32{ 14.0, 32.0, 32.0, 77.0 };
    const expected_out_m: Mat2 = .init(expected_out_m_data);

    try expect(@TypeOf(out_m) == Mat2);
    try expectEqualSlices(Mat2.VecType, &expected_out_m.mat, &out_m.mat);
}

const epsilon = 0.0001;

test "rotate function" {
    const T = f32;
    const Mat4 = Matrix(T, 4, 4);

    const m_in: Mat4 = .identity(1.0);

    const m_out_zero = rotate(T, m_in, 0.0, .init(.{ 0, 1, 0 }));
    for (0..m_in.dims.numel) |i| {
        try expectApproxEqAbs(m_in.at(i), m_out_zero.at(i), epsilon);
    }

    // Pre-multiplication (R * M), so R * I = R
    const angle = std.math.pi / 2.0;
    const c = @cos(angle);
    const s = @sin(angle);
    const m_out_z90 = rotate(T, m_in, angle, .init(.{ 0, 0, 1 }));

    const expected_z90_data = [_]T{
        c,  s, 0, 0,
        -s, c, 0, 0,
        0,  0, 1, 0,
        0,  0, 0, 1,
    };
    const expected_z90: Mat4 = .init(expected_z90_data);
    for (0..expected_z90.dims.numel) |i| {
        try expectApproxEqAbs(expected_z90.at(i), m_out_z90.at(i), epsilon);
    }
}

test "lookAt and its variants" {
    const T = f32;
    const Mat4 = Matrix(T, 4, 4);
    const Vec3 = Vector(T, 3);

    const eye: Vec3 = .init(.{ 0, 0, 1 });
    const center: Vec3 = .init(.{ 0, 0, 0 });
    const up: Vec3 = .init(.{ 0, 1, 0 });

    const mat = lookAt(T, eye, center, up);
    const expected_data = [_]T{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, -1,
        0, 0, 0, 1,
    };
    const expected = Mat4.init(expected_data);
    for (0..expected.dims.numel) |i| {
        try expectApproxEqAbs(expected.at(i), mat.at(i), epsilon);
    }
}

test "perspective" {
    const T = f32;
    const Mat4 = Matrix(T, 4, 4);

    const fovy = std.math.pi / 2.0;
    const aspect = 1.0;
    const znear = 0.1;
    const zfar = 100.0;
    const m_persp = perspective(T, fovy, aspect, znear, zfar);

    const f_minus_n = zfar - znear;
    const f_plus_n = zfar + znear;
    const two_f_n = 2.0 * zfar * znear;

    const tan_half_fovy = @tan(fovy / 2.0);
    const val_00 = 1.0 / (aspect * tan_half_fovy);
    const val_11 = -1.0 / tan_half_fovy;

    const expected_data = [_]T{
        val_00, 0.0,    0.0,                   0.0,
        0.0,    val_11, 0.0,                   0.0,
        0.0,    0.0,    -f_plus_n / f_minus_n, -two_f_n / f_minus_n,
        0.0,    0.0,    -1.0,                  0.0,
    };
    const expected_persp: Mat4 = .init(expected_data);
    for (0..expected_persp.dims.numel) |i| {
        try expectApproxEqAbs(expected_persp.at(i), m_persp.at(i), epsilon);
    }
}
