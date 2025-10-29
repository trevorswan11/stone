const std = @import("std");

const vulkan = @import("vulkan.zig");
const vk = vulkan.lib;

const glfw = @import("../glfw.zig");

const launcher = @import("../../launcher.zig");

pub const Swapchain = struct {
    handle: vk.SwapchainKHR = undefined,
    image_format: vk.Format = undefined,
    extent: vk.Extent2D = undefined,

    pub fn init(stone: *launcher.Stone, details: SwapchainSupportDetails) !Swapchain {
        var self: Swapchain = undefined;

        const format = details.choseSurfaceFormat();
        self.image_format = format.format;
        self.extent = details.chooseExtent(stone.window);
        const present_mode = details.choosePresentMode();

        // Request an extra image so the driver has some breathing room
        const image_count = @min(
            details.capabilities.min_image_count + 1,
            details.capabilities.max_image_count,
        );

        var create_info: vk.SwapchainCreateInfoKHR = .{
            .s_type = .swapchain_create_info_khr,
            .surface = stone.surface,
            .min_image_count = image_count,
            .image_format = self.image_format,
            .image_color_space = format.color_space,
            .image_extent = self.extent,
            .image_array_layers = 1,
            .image_usage = .{
                .color_attachment_bit = true,
            },

            .image_sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = null,

            .pre_transform = details.capabilities.current_transform,
            .composite_alpha = .{
                .opaque_bit_khr = true,
            },
            .present_mode = present_mode,
            .clipped = .true,
            .old_swapchain = .null_handle,
        };

        // Override the set queue information if the queues are different
        if (stone.graphics_queue.family != stone.present_queue.family) {
            create_info.image_sharing_mode = .concurrent;
            create_info.queue_family_index_count = 2;
            create_info.p_queue_family_indices = &.{
                stone.graphics_queue.family,
                stone.present_queue.family,
            };
        }

        self.handle = try stone.logical_device.createSwapchainKHR(
            &create_info,
            null,
        );
        return self;
    }

    pub fn deinit(self: Swapchain, logical_device: *vk.DeviceProxy) void {
        logical_device.destroySwapchainKHR(self.handle, null);
    }
};

pub const SwapchainLists = struct {
    images: std.ArrayList(vk.Image) = .empty,
    image_views: std.ArrayList(vk.ImageView) = .empty,
    framebuffers: std.ArrayList(vk.Framebuffer) = .empty,

    pub fn deinit(self: *SwapchainLists, allocator: std.mem.Allocator) void {
        self.images.deinit(allocator);
        self.image_views.deinit(allocator);
        self.framebuffers.deinit(allocator);
    }
};

pub const SwapchainSupportDetails = struct {
    device: *vulkan.DeviceCandidate,

    capabilities: vk.SurfaceCapabilitiesKHR = undefined,
    formats: []const vk.SurfaceFormatKHR = undefined,
    present_modes: []const vk.PresentModeKHR = undefined,

    /// Verifies that a device has:
    /// - Basic surface capabilities
    /// - Surface formats (pixel format, color space)
    /// - Available presentation modes
    pub fn init(device: *vulkan.DeviceCandidate) !SwapchainSupportDetails {
        var self: SwapchainSupportDetails = .{
            .device = device,
        };

        const allocator = device.allocator;
        const p_dev = device.device;
        const surface = device.surface.*;

        self.capabilities = try device.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(
            p_dev,
            surface,
        );

        self.formats = try device.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(
            p_dev,
            surface,
            allocator,
        );

        self.present_modes = try device.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(
            p_dev,
            surface,
            allocator,
        );

        return self;
    }

    pub fn deinit(self: *SwapchainSupportDetails) void {
        self.device.allocator.free(self.formats);
        self.device.allocator.free(self.present_modes);
    }

    /// Attempts to select format `VK_FORMAT_B8G8R8A8_SRGB` with color space `VK_COLOR_SPACE_SRGB_NONLINEAR_KHR`.
    /// Defaults to the first entry in the format list if not found.
    ///
    /// Asserts that the format list is not empty.
    pub fn choseSurfaceFormat(self: *const SwapchainSupportDetails) vk.SurfaceFormatKHR {
        std.debug.assert(self.formats.len != 0);
        for (self.formats) |format| {
            if (format.format == .b8g8r8a8_srgb and format.color_space == .srgb_nonlinear_khr) {
                return format;
            }
        } else return self.formats[0];
    }

    /// Attempts to select presentation mode `VK_PRESENT_MODE_MAILBOX_KHR`.
    /// Defaults to `VK_PRESENT_MODE_FIFO_KHR` if the above format is not found.
    ///
    /// Asserts that the presentation list is not empty, as `VK_PRESENT_MODE_FIFO_KHR` should be guaranteed.
    pub fn choosePresentMode(self: *const SwapchainSupportDetails) vk.PresentModeKHR {
        std.debug.assert(self.present_modes.len != 0);
        for (self.present_modes) |present_mode| {
            if (present_mode == .mailbox_khr) {
                return present_mode;
            }
        } else return .fifo_khr;
    }

    /// Chooses the swap chain extent based off of the determined capabilities.
    pub fn chooseExtent(self: *const SwapchainSupportDetails, window: *glfw.Window) vk.Extent2D {
        if (self.capabilities.current_extent.width == std.math.maxInt(u32)) {
            var width: c_int = undefined;
            var height: c_int = undefined;
            glfw.getFramebufferSize(window, &width, &height);

            return .{
                .width = std.math.clamp(
                    @as(u32, @intCast(width)),
                    self.capabilities.min_image_extent.width,
                    self.capabilities.max_image_extent.width,
                ),
                .height = std.math.clamp(
                    @as(u32, @intCast(height)),
                    self.capabilities.min_image_extent.height,
                    self.capabilities.max_image_extent.height,
                ),
            };
        } else return self.capabilities.current_extent;
    }
};
