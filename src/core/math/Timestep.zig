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
