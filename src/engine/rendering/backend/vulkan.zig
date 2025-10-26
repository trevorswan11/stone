pub const lib = @import("vulkan");

const glfw = @import("glfw.zig");

/// Converts a packed vulkan version into its integer representation.
pub fn version(api_version: lib.Version) u32 {
    return @bitCast(api_version);
}

/// Creates vulkan version, immediately converting it its integer representation.
pub fn makeVersion(variant: u3, major: u7, minor: u10, patch: u12) u32 {
    return version(lib.makeApiVersion(variant, major, minor, patch));
}
