const std = @import("std");

const vulkan = @import("vulkan.zig");
const vk = vulkan.lib;

const glfw = @import("../glfw.zig");

const launcher = @import("../../launcher.zig");

/// Synchronization 'manager', holding:
/// - One semaphore to signal that an image has been acquired from the swapchain
/// - Another semaphore to signal that rendering has finished
/// - A fence to make sure only one frame is rendered at a time
pub const Syncs = struct {
    image_available_semaphore: vk.Semaphore = undefined,
    render_finished_semaphore: vk.Semaphore = undefined,
    in_flight_fence: vk.Fence = undefined,

    pub fn init(stone: *launcher.Stone) !Syncs {
        const semaphore_info: vk.SemaphoreCreateInfo = .{};
        const fence_info: vk.FenceCreateInfo = .{
            .s_type = .fence_create_info,
            .flags = .{
                .signaled_bit = true,
            },
        };

        var self: Syncs = undefined;
        self.image_available_semaphore = try stone.logical_device.createSemaphore(
            &semaphore_info,
            null,
        );
        self.render_finished_semaphore = try stone.logical_device.createSemaphore(
            &semaphore_info,
            null,
        );
        self.in_flight_fence = try stone.logical_device.createFence(
            &fence_info,
            null,
        );

        return self;
    }

    pub fn deinit(self: *Syncs, logical_device: *vk.DeviceProxy) void {
        logical_device.destroySemaphore(self.image_available_semaphore, null);
        logical_device.destroySemaphore(self.render_finished_semaphore, null);
        logical_device.destroyFence(self.in_flight_fence, null);
    }
};
