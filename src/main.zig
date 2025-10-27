const std = @import("std");

const core = @import("core");
const engine = @import("engine");

const glfw = engine.glfw;
const vk = engine.vk;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer if (gpa.deinit() == .leak) @panic("GPA Leaked");
    const allocator = gpa.allocator();

    var app: engine.Stone = try .init(allocator);
    defer app.deinit();

    try app.run();
}
