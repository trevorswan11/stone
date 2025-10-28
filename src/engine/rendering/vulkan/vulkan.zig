const std = @import("std");
const builtin = @import("builtin");

const config = @import("config");

pub const lib = @import("vulkan");

const glfw = @import("../glfw.zig");
const swapchain = @import("swapchain.zig");

pub const enable_validation_layers = config.verbose or builtin.mode == .Debug;

pub const validation_layers = [_][*:0]const u8{
    "VK_LAYER_KHRONOS_validation",
};

pub const device_extensions = [_][*:0]const u8{
    lib.extensions.khr_swapchain.name,
};

pub const dynamic_states = [_]lib.DynamicState{
    .viewport,
    .scissor,
};

const severity_strs = [_][:0]const u8{
    "verbose",
    "info",
    "warning",
    "error",
    "unknown",
};

const type_strs = [_][:0]const u8{
    "general",
    "validation",
    "performance",
    "device addr",
    "unknown",
};

pub const debug_create_info: lib.DebugUtilsMessengerCreateInfoEXT = .{
    .message_severity = .{
        .verbose_bit_ext = true,
        .info_bit_ext = true,
        .warning_bit_ext = true,
        .error_bit_ext = true,
    },

    .message_type = .{
        .general_bit_ext = true,
        .validation_bit_ext = true,
        .performance_bit_ext = true,
    },

    .pfn_user_callback = &debugCallback,
    .p_user_data = null,
};

/// Converts a packed vulkan version into its integer representation.
pub fn version(api_version: lib.Version) u32 {
    return @bitCast(api_version);
}

/// Creates vulkan version, immediately converting it its integer representation.
pub fn makeVersion(variant: u3, major: u7, minor: u10, patch: u12) u32 {
    return version(lib.makeApiVersion(variant, major, minor, patch));
}

/// The debug message callback for logging.
pub fn debugCallback(
    severity: lib.DebugUtilsMessageSeverityFlagsEXT,
    message_type: lib.DebugUtilsMessageTypeFlagsEXT,
    p_callback_data: ?*const lib.DebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(.c) lib.Bool32 {
    _ = p_user_data;

    // Extract the severity level based on the 'bit flags' (pseudo-ordering)
    const first_severity = std.mem.indexOfScalar(
        bool,
        &.{
            severity.verbose_bit_ext,
            severity.info_bit_ext,
            severity.warning_bit_ext,
            severity.error_bit_ext,
        },
        true,
    ) orelse severity_strs.len - 1;
    const severity_str = severity_strs[first_severity];

    // Extract the message type using the same principle
    const first_type = std.mem.indexOfScalar(
        bool,
        &.{
            message_type.general_bit_ext,
            message_type.validation_bit_ext,
            message_type.performance_bit_ext,
            message_type.device_address_binding_bit_ext,
        },
        true,
    ) orelse type_strs.len - 1;
    const type_str = type_strs[first_type];

    // Construct and print the message using the builtin logger
    const message = blk: {
        if (p_callback_data) |cb_data| {
            break :blk cb_data.p_message;
        } else {
            break :blk "NO MESSAGE!";
        }
    } orelse "NO MESSAGE!";

    const log_format = "[{s}][{s}]. Message:\n  {s}\n";
    const log_args = .{ severity_str, type_str, message };

    switch (first_severity) {
        0 => std.log.debug(log_format, log_args),
        1 => std.log.info(log_format, log_args),
        2 => std.log.warn(log_format, log_args),
        3 => std.log.err(log_format, log_args),
        else => std.log.debug(log_format, log_args),
    }

    return .false;
}

/// Verifies the specified validation layers are present for the instance.
///
/// An error can only occur from layer property allocation, the boolean return type is the descriptive payload.
pub fn checkValidationLayerSupport(allocator: std.mem.Allocator, vkb: lib.BaseWrapper) !bool {
    const available_layers = try vkb.enumerateInstanceLayerPropertiesAlloc(allocator);
    defer allocator.free(available_layers);

    for (validation_layers) |layer_name| {
        for (available_layers) |layer_properties| {
            const layer_name_slice: []const u8 = std.mem.span(layer_name);
            if (std.mem.eql(u8, layer_name_slice, layer_properties.layer_name[0..layer_name_slice.len])) {
                break;
            }
        } else return false;
    }

    return true;
}

pub const DeviceCandidate = struct {
    allocator: std.mem.Allocator,

    device: lib.PhysicalDevice,
    properties: lib.PhysicalDeviceProperties,
    features: lib.PhysicalDeviceFeatures,

    instance: *const lib.InstanceProxy,
    surface: *const lib.SurfaceKHR,

    /// Creates a candidate out of a device.
    pub fn init(
        allocator: std.mem.Allocator,
        instance: *const lib.InstanceProxy,
        surface: *const lib.SurfaceKHR,
        device: lib.PhysicalDevice,
    ) DeviceCandidate {
        return .{
            .allocator = allocator,
            .device = device,
            .properties = instance.getPhysicalDeviceProperties(device),
            .features = instance.getPhysicalDeviceFeatures(device),
            .instance = instance,
            .surface = surface,
        };
    }

    /// Provides a bias to a candidate for ordering
    pub fn score(self: DeviceCandidate) u32 {
        var accumulator: u32 = 0;

        switch (self.properties.device_type) {
            .other => accumulator += 100,
            .integrated_gpu => accumulator += 100_000,
            .discrete_gpu => accumulator += 1_000_000,
            .virtual_gpu => accumulator += 10_000,
            .cpu => accumulator += 1_000,
            _ => accumulator += 0,
        }

        return accumulator;
    }

    /// Returns .gt if b is greater than a, fulfilling the max-heap property.
    pub fn compare(context: void, a: DeviceCandidate, b: DeviceCandidate) std.math.Order {
        _ = context;
        return std.math.order(b.score(), a.score());
    }

    pub fn findQueueFamilies(self: DeviceCandidate) !QueueFamilyIndices {
        var indices: QueueFamilyIndices = .{};

        const queue_families = try self.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(
            self.device,
            self.allocator,
        );
        defer self.allocator.free(queue_families);

        for (queue_families, 0..) |queue_family, i| {
            const i_casted: u32 = @intCast(i);
            if (queue_family.queue_flags.graphics_bit) {
                indices.graphics_family = i_casted;
            }

            if ((try self.instance.getPhysicalDeviceSurfaceSupportKHR(
                self.device,
                i_casted,
                self.surface.*,
            )) == .true) {
                indices.present_family = i_casted;
            }

            if (indices.complete()) break;
        }

        return indices;
    }

    /// Verifies the specified extensions are present for the device.
    pub fn checkDeviceExtensionSupport(self: DeviceCandidate) !bool {
        const available_extensions = try self.instance.enumerateDeviceExtensionPropertiesAlloc(
            self.device,
            null,
            self.allocator,
        );
        defer self.allocator.free(available_extensions);

        for (device_extensions) |extension_name| {
            for (available_extensions) |extension_properties| {
                const ext_name_slice: []const u8 = std.mem.span(extension_name);
                if (std.mem.eql(u8, ext_name_slice, extension_properties.extension_name[0..ext_name_slice.len])) {
                    break;
                }
            } else return false;
        }

        return true;
    }

    /// Checks if the device is suitable for the application.
    ///
    /// This is not considered when ordering the devices.
    pub fn suitable(self: *DeviceCandidate) !bool {
        const indices = try self.findQueueFamilies();
        const supported_exts = try self.checkDeviceExtensionSupport();

        // Only check for the swap chain support if extensions pass
        var swapchain_ok = false;
        if (supported_exts) {
            var swapchain_support: swapchain.SwapchainSupportDetails = try .init(self);
            defer swapchain_support.deinit();

            swapchain_ok = swapchain_support.formats.len != 0 and swapchain_support.present_modes.len != 0;
        }

        return indices.complete() and supported_exts and swapchain_ok;
    }
};

pub const QueueFamilyIndices = struct {
    graphics_family: ?u32 = null,
    present_family: ?u32 = null,

    pub fn complete(self: QueueFamilyIndices) bool {
        return self.graphics_family != null and self.present_family != null;
    }
};

pub const Queue = struct {
    handle: lib.Queue,
    family: u32,

    pub fn init(device: lib.DeviceProxy, family: u32) Queue {
        return .{
            .handle = device.getDeviceQueue(family, 0),
            .family = family,
        };
    }
};
