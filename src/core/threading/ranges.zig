const std = @import("std");

/// Returns a monotonically decreasing array of [start..0].
///
/// Asserts that T is a known integer type.
pub fn decreasing(comptime T: type, comptime start: usize, comptime end: usize) [start - end]T {
    comptime std.debug.assert(start > end);
    return switch (@typeInfo(T)) {
        .int => {
            var result: [start]T = undefined;
            var i: usize = start;
            while (i > 0) : (i -= 1) {
                result[start - i] = @intCast(i);
            }

            return result;
        },
        else => @compileError("T must be a known integer type"),
    };
}

/// Returns a monotonically increasing array of [0..start].
///
/// Asserts that T is a known integer type.
pub fn increasing(comptime T: type, comptime start: usize, comptime end: usize) [end - start]T {
    comptime std.debug.assert(start < end);
    return switch (@typeInfo(T)) {
        .int => {
            var result: [end]T = undefined;
            for (0..end) |i| {
                result[i] = @intCast(i);
            }

            return result;
        },
        else => @compileError("T must be a known integer type"),
    };
}

/// Chunks values by index into pairs of bounds for threads to iterate over.
///
/// Does not check if the number of threads is realistic.
pub fn chunk(comptime T: type, values: []const T, comptime num_threads: usize) [num_threads][2]usize {
    var bounds: [num_threads][2]usize = undefined;

    const n = values.len;
    const base: usize = @divTrunc(n, num_threads);
    const rem = n % num_threads;

    var start: usize = 0;
    for (0..num_threads) |t| {
        const extra: usize = if (t < rem) 1 else 0;
        bounds[t][0] = start;
        bounds[t][1] = start + base + extra;
        start += base + extra;
    }

    return bounds;
}

const testing = std.testing;
const expectEqual = testing.expectEqual;

test "Decreasing array generator" {
    const expected = [_]usize{ 4, 3, 2, 1 };
    const actual = decreasing(usize, @sizeOf(u32), 0);
    for (expected, actual) |e, a| {
        try expectEqual(e, a);
    }
}

test "Increasing array generator" {
    const expected = [_]usize{ 0, 1, 2, 3 };
    const actual = increasing(usize, 0, @sizeOf(u32));
    for (expected, actual) |e, a| {
        try expectEqual(e, a);
    }
}

test "chunk splits array into thread bounds" {
    const arr = [_]i32{ 1, 2, 3, 4, 5, 6, 7 };
    const result = chunk(i32, arr[0..], 3);

    try expectEqual(0, result[0][0]);
    try expectEqual(3, result[0][1]);
    try expectEqual(3, result[1][0]);
    try expectEqual(5, result[1][1]);
    try expectEqual(5, result[2][0]);
    try expectEqual(7, result[2][1]);

    var total: usize = 0;
    for (result) |b| {
        total += b[1] - b[0];
    }
    try expectEqual(arr.len, total);
}
