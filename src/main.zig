const std = @import("std");
const core = @import("core");

const vert_spv align(@alignOf(u32)) = @embedFile("vertex_shader").*;
const frag_spv align(@alignOf(u32)) = @embedFile("fragment_shader").*;

pub fn main() !void {
    std.debug.print("Hello, World!\n", .{});
}
