const std = @import("std");
const builtin = @import("builtin");

const core = @import("core");
const engine = @import("engine");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) @panic("GPA Leaked");
    const allocator = switch (builtin.mode) {
        .Debug => gpa.allocator(),
        else => core.allocator(builtin.single_threaded),
    };

    var app: engine.Stone = try .init(allocator);
    defer app.deinit();

    try app.run();
}
