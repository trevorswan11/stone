const std = @import("std");

const Self = @This();

const us_per_s: comptime_float = @floatFromInt(std.time.us_per_s);

/// The time of the last frame in microseconds
last_frame_time_us: i64,

/// The last updated delta time in seconds
dt: f32 = 0,

pub fn init() Self {
    return .{ .last_frame_time_us = std.time.microTimestamp() };
}

/// Returns the time elapsed since the last frame in seconds.
/// Also updates the internal last frame time and delta time value.
///
/// T must be a known float type.
pub fn step(self: *Self, comptime T: type) T {
    comptime switch (@typeInfo(T)) {
        .float => {},
        else => @compileError("T must be a known float type"),
    };

    const old = self.last_frame_time_us;
    self.last_frame_time_us = std.time.microTimestamp();
    const dt = self.last_frame_time_us - old;

    const dt_f: T = @floatFromInt(dt);
    const dt_s = dt_f / us_per_s;
    self.dt = @floatCast(dt_s);
    return dt_s;
}
