const std = @import("std");

const Self = @This();

const us_per_s: comptime_float = @floatFromInt(std.time.us_per_s);
const max_dt = 1.0 / 30.0;

/// The time of the first recorded frame in microseconds
start_time_us: i64,

/// The time of the last frame in microseconds
last_frame_time_us: i64,

/// The clamped true last updated delta time in seconds
dt: f32 = 0,

/// The true last updated delta time in seconds
true_dt: f32 = 0,

pub fn init() Self {
    const t = std.time.microTimestamp();
    return .{
        .start_time_us = t,
        .last_frame_time_us = t,
    };
}

/// Returns the time elapsed since the last frame in seconds.
/// Also updates the internal last frame time and delta time value.
///
/// The last recorded frame time is always accurate, but dt is clamped to a minimum
/// of 30fps to prevent physics from blowing up on move.
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
    const true_dt = dt_f / us_per_s;
    const dt_s = @min(max_dt, true_dt);

    self.dt = @floatCast(dt_s);
    self.true_dt = @floatCast(true_dt);
    return dt_s;
}

/// Returns the total elapsed time since the very first record frame in seconds.
///
/// T must be a known float type.
pub fn elapsed(self: *const Self, comptime T: type) T {
    comptime switch (@typeInfo(T)) {
        .float => {},
        else => @compileError("T must be a known float type"),
    };

    const now = std.time.microTimestamp();
    const dt_us: T = @floatFromInt(now - self.start_time_us);

    return dt_us / us_per_s;
}
