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
        const MatType = [m]VecType;

        /// Helper for iteration, mutating this does nothing good for you
        dims: struct {
            numel: usize = m * n,
            rows: usize = m,
            cols: usize = n,
        } = .{},
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

        pub fn scale(self: Self, val: T) Self {
            var out: MatType = undefined;
            inline for (0..m) |row| {
                out[row] = self.mat[row].scale(val);
            }
            return .{ .mat = out };
        }

        /// Returns the flattened element index into the matrix.
        pub fn index(row: usize, col: usize) usize {
            std.debug.assert(row < m);
            std.debug.assert(col < n);
            return row * n + col;
        }

        /// Provides mutable element index into the matrix.
        pub fn element(self: *Self, idx: usize) *T {
            std.debug.assert(idx < (m * n));

            const row: usize = @divFloor(idx, n);
            const col = idx % n;

            return &self.mat[row].vec[col];
        }
    };
}

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualSlices = testing.expectEqualSlices;

test "Matrix initialization and scalar multiplication" {
    const Mat2 = Matrix(f32, 2, 2);

    const row1 = Mat2.VecType.init(.{ 0.0, 1.0 });
    const row2 = Mat2.VecType.init(.{ 2.0, 3.0 });
    const actual_diff = Mat2.init(.{ 0.0, 1.0, 2.0, 3.0 });
    for (0..actual_diff.dims.rows, [_]Mat2.VecType{ row1, row2 }) |row, expected| {
        try expectEqual(expected, actual_diff.mat[row]);
    }

    const Mat4 = Matrix(f32, 4, 4);

    const expected_rows = [_]Mat4.VecType{
        .init(.{ 10.0, 10.0, 10.0, 10.0 }),
        .init(.{ 10.0, 10.0, 10.0, 10.0 }),
        .init(.{ 10.0, 10.0, 10.0, 10.0 }),
        .init(.{ 10.0, 10.0, 10.0, 10.0 }),
    };
    const actual_splat = Mat4.splat(10.0);
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

    var actual_67 = Mat67.init(init_vals67);
    try expectEqualSlices(Mat67.VecType, &expected_mat67, &actual_67.mat);

    var idx: usize = 0;
    for (0..6) |row| {
        for (0..7) |col| {
            try expectEqual(
                init_vals67[idx],
                actual_67.element(Mat67.index(row, col)).*,
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

    var actual_76 = Mat76.init(init_vals76);
    try expectEqualSlices(Mat76.VecType, &expected_mat76, &actual_76.mat);

    for (init_vals76, 0..) |val, i| {
        try expectEqual(val, actual_76.element(i).*);
    }

    init_vals76[9] = -200.0;
    actual_76.element(9).* = -200.0;
    for (init_vals76, 0..) |val, i| {
        try expectEqual(val, actual_76.element(i).*);
    }
}
