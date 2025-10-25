const std = @import("std");

const Self = @This();

const us_per_s: comptime_float = @floatFromInt(std.time.us_per_s);

last_frame_time_us: i64,

pub fn init() Self {
    return .{ .last_frame_time_us = std.time.microTimestamp() };
}

/// Returns the time elapsed since the last frame in seconds.
///
/// T must be a known float type.
pub fn deltaTime(self: *Self, comptime T: type) T {
    comptime switch (@typeInfo(T)) {
        .float => {},
        else => @compileError("T must be a known float type"),
    };

    const old = self.last_frame_time_us;
    self.last_frame_time_us = std.time.microTimestamp();
    const dt = self.last_frame_time_us - old;

    const dt_f: T = @floatFromInt(dt);
    return dt_f / us_per_s;
}

const testing = std.testing;
const expectApproxEqlAbs = testing.expectApproxEqAbs;

test "deltaTime returns seconds" {
    var timer = Self.init();
    std.Thread.sleep(10_000);
    const dt = timer.deltaTime(f64);
    try expectApproxEqlAbs(0.00001, dt, 0.0001);
}
