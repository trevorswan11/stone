const std = @import("std");

const core = @import("core");
const engine = @import("engine");

const glfw = engine.glfw;
const vk = engine.vk;

fn ensureVulkan() void {
    const recommended_vulkan = "1.4.309.0";
    if (!std.process.hasEnvVarConstant("VULKAN_SDK")) {
        std.debug.panic(
            \\Sorry, it looks like you don't have the Vulkan SDK installed. :-(
            \\
            \\Stone requires Vulkan to be installed with "VULKAN_SDK" pointing to the installation directory.
            \\While other versions are likely acceptable, Stone has been tested with version {s}
            \\
            \\https://vulkan.lunarg.com/
            \\
        , .{recommended_vulkan});
    }
}

pub fn main() !void {
    ensureVulkan();

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) @panic("GPA Leaked");
    const allocator = gpa.allocator();

    var app: engine.Stone = try .init(allocator);
    defer app.deinit();

    try app.run();
}
