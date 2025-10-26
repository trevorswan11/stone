const std = @import("std");

const core = @import("core");
const engine = @import("engine");

const glfw = engine.glfw;
const vk = engine.vk;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var app: engine.example.HelloTriangle = try .init(allocator);
    defer app.deinit();

    try app.run();
}
