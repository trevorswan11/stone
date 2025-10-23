const std = @import("std");
const builtin = @import("builtin");

const ranges = @import("ranges.zig");

/// Dispatches the given worker threads with the provided context to operate on a slice
/// of values specified by the chunks list.
///
/// - Checks that the number of threads is realistic.
/// - Asserts that there are an equal amount of workers with respect to the chunks.
/// - Assumes that none of the threads are active.
/// - Passing 1 thread puts all work on the main thread, passing context as usual.
/// In this case, the thread number is 0.
///
/// Automatically joins all threads before returning.
pub fn @"for"(
    comptime T: type,
    values: []T,
    comptime num_threads: usize,
    chunks: [num_threads][2]usize,
    workers: *[num_threads]std.Thread,
    context: anytype,
    comptime work: fn (ctx: @TypeOf(context), slice: []T, thread_num: usize) anyerror!void,
    spawn_config: std.Thread.SpawnConfig,
) !void {
    comptime {
        if (num_threads != 1 and builtin.single_threaded) {
            @compileError("Cannot interact with parallelization in single-threaded mode");
        }
    }

    const cpu_count = try std.Thread.getCpuCount();
    if (num_threads == 0 or num_threads > cpu_count) {
        return error.NotEnoughCPUs;
    }

    if (comptime num_threads == 1) {
        try work(context, values, 0);
    } else {
        defer {
            for (workers) |*thread| thread.join();
        }

        for (workers, chunks, 0..) |*worker, indices, i| {
            worker.* = try std.Thread.spawn(
                spawn_config,
                work,
                .{ context, values[indices[0]..indices[1]], i },
            );
        }
    }
}

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualSlices = testing.expectEqualSlices;

test "parallel for squares array correctly" {
    var values = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var results: [10]i32 = undefined;

    const num_threads = 3;
    var threads: [num_threads]std.Thread = undefined;

    const chunks = ranges.chunk(i32, values[0..], num_threads);
    const access = ranges.chunk(usize, ranges.increasing(usize, 0, values.len)[0..], num_threads);
    const context = .{ &results, access };

    const worker = struct {
        pub fn afn(ctx: @TypeOf(context), slice: []i32, thread_num: usize) !void {
            for (ctx.@"1"[thread_num][0]..ctx.@"1"[thread_num][1], slice) |i, v| {
                ctx.@"0"[i] = v * v;
            }
        }
    }.afn;

    // Run the parallel for
    try @"for"(
        i32,
        &values,
        num_threads,
        chunks,
        &threads,
        context,
        worker,
        .{},
    );

    // Check results
    const expected = [_]i32{ 1, 4, 9, 16, 25, 36, 49, 64, 81, 100 };
    for (results, 0..) |r, i| {
        try std.testing.expect(r == expected[i]);
    }
}
