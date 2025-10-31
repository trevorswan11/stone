const std = @import("std");

const vulkan = @import("vulkan.zig");
const vk = vulkan.lib;

const glfw = @import("../glfw.zig");

const launcher = @import("../../launcher.zig");

const draw = @import("draw.zig");

/// Synchronization 'manager', holding:
/// - One semaphore to signal that an image has been acquired from the swapchain
/// - Another semaphore to signal that rendering has finished
/// - A fence to make sure only one frame is rendered at a time
pub const Syncs = struct {
    image_available_semaphores: []vk.Semaphore = undefined,
    render_finished_semaphores: []vk.Semaphore = undefined,
    in_flight_fences: []vk.Fence = undefined,

    current_frame: u32 = 0,

    pub fn init(stone: *launcher.Stone) !Syncs {
        const semaphore_info: vk.SemaphoreCreateInfo = .{};
        const fence_info: vk.FenceCreateInfo = .{
            .flags = .{
                .signaled_bit = true,
            },
        };

        var self: Syncs = .{};
        self.image_available_semaphores = try stone.allocator.alloc(vk.Semaphore, draw.max_frames_in_flight);
        self.render_finished_semaphores = try stone.allocator.alloc(vk.Semaphore, draw.max_frames_in_flight);
        self.in_flight_fences = try stone.allocator.alloc(vk.Fence, draw.max_frames_in_flight);

        for (
            self.image_available_semaphores,
            self.render_finished_semaphores,
            self.in_flight_fences,
        ) |*ias, *rfs, *iff| {
            ias.* = try stone.logical_device.createSemaphore(
                &semaphore_info,
                null,
            );

            rfs.* = try stone.logical_device.createSemaphore(
                &semaphore_info,
                null,
            );

            iff.* = try stone.logical_device.createFence(
                &fence_info,
                null,
            );
        }

        return self;
    }

    pub fn deinit(self: *Syncs, allocator: std.mem.Allocator, logical_device: *vk.DeviceProxy) void {
        defer {
            allocator.free(self.image_available_semaphores);
            allocator.free(self.render_finished_semaphores);
            allocator.free(self.in_flight_fences);
        }

        for (
            self.image_available_semaphores,
            self.render_finished_semaphores,
            self.in_flight_fences,
        ) |ias, rfs, iff| {
            logical_device.destroySemaphore(ias, null);
            logical_device.destroySemaphore(rfs, null);
            logical_device.destroyFence(iff, null);
        }
    }
};
