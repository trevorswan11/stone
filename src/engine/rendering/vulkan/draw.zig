const std = @import("std");

const vulkan = @import("vulkan.zig");
const vk = vulkan.lib;

const glfw = @import("../glfw.zig");

const launcher = @import("../../launcher.zig");

pub const Command = struct {
    pool: vk.CommandPool = undefined,
    buffer: vk.CommandBuffer = undefined,

    /// Writes the commands wanted to execute to the command buffer.
    pub fn recordBuffer(
        stone: *launcher.Stone,
        image_idx: u32,
    ) !void {
        // Kick off the command buffer, flags van be used to specify usage constraints
        const begin_info: vk.CommandBufferBeginInfo = .{
            .s_type = .command_buffer_begin_info,
            .p_inheritance_info = null,
        };

        try stone.logical_device.beginCommandBuffer(
            stone.command.buffer,
            &begin_info,
        );

        const clear_colors = [_]vk.ClearValue{
            .{ .color = .{ .int_32 = .{ 0, 0, 0, 1 } } },
        };

        // Drawing starts with a configured render pass
        std.debug.assert(image_idx < stone.swapchain_lists.framebuffers.items.len);
        const render_pass_info: vk.RenderPassBeginInfo = .{
            .s_type = .render_pass_begin_info,
            .render_pass = stone.render_pass,
            .framebuffer = stone.swapchain_lists.framebuffers.items[image_idx],
            .render_area = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = stone.swapchain.extent,
            },
            .clear_value_count = clear_colors.len,
            .p_clear_values = &clear_colors,
        };

        // All vkCmd functions do not throw errors and must be handled until done recording
        stone.logical_device.cmdBeginRenderPass(
            stone.command.buffer,
            &render_pass_info,
            .@"inline",
        );

        stone.logical_device.cmdBindPipeline(
            stone.command.buffer,
            .graphics,
            stone.graphics_pipeline.pipeline,
        );

        // The view port and scissor state must be created here since they're dynamic
        const viewports = [_]vk.Viewport{.{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(stone.swapchain.extent.width),
            .height = @floatFromInt(stone.swapchain.extent.height),
            .min_depth = 0.0,
            .max_depth = 1.0,
        }};

        std.debug.assert(viewports.len == stone.graphics_pipeline.viewport_count);
        stone.logical_device.cmdSetViewport(
            stone.command.buffer,
            0,
            viewports.len,
            &viewports,
        );

        // The scissor acts as a filter for the rasterizer to ignore
        const scissors = [_]vk.Rect2D{.{
            .extent = stone.swapchain.extent,
            .offset = .{
                .x = 0,
                .y = 0,
            },
        }};

        std.debug.assert(scissors.len == stone.graphics_pipeline.scissor_count);
        stone.logical_device.cmdSetScissor(
            stone.command.buffer,
            0,
            scissors.len,
            &scissors,
        );

        // Now we can finally draw (just a triangle) and end the render pass
        stone.logical_device.cmdDraw(
            stone.command.buffer,
            3,
            1,
            0,
            0,
        );

        stone.logical_device.cmdEndRenderPass(stone.command.buffer);
        try stone.logical_device.endCommandBuffer(stone.command.buffer);
    }
};

/// Renders a Frame by following:
/// - Wait for the previous frame to finish
/// - Acquire an image from the swapchain
/// - Record a command buffer which draws that scene onto the image
/// - Submit the recorded command buffer
/// - Present the swapchain image
pub fn drawFrame(stone: *launcher.Stone) !void {
    const wait_semaphores = [_]vk.Semaphore{
        stone.syncs.image_available_semaphore,
    };
    const signal_semaphores = [_]vk.Semaphore{
        stone.syncs.render_finished_semaphore,
    };

    const fences = [_]vk.Fence{
        stone.syncs.in_flight_fence,
    };

    // We have to wait for the device to be ready before acquiring
    _ = try stone.logical_device.waitForFences(
        fences.len,
        &fences,
        .true,
        comptime std.math.maxInt(u64),
    );
    try stone.logical_device.resetFences(fences.len, &fences);

    const next = try stone.logical_device.acquireNextImageKHR(
        stone.swapchain.handle,
        comptime std.math.maxInt(u64),
        stone.syncs.image_available_semaphore,
        .null_handle,
    );
    const image_index = next.image_index;

    // Now we record the command buffer, but reset first!
    try stone.logical_device.resetCommandBuffer(stone.command.buffer, .{});
    try Command.recordBuffer(stone, image_index);

    const command_buffers = [_]vk.CommandBuffer{
        stone.command.buffer,
    };

    // Now the buffer is fully recorded and can be submitted
    const submit_info = [_]vk.SubmitInfo{.{
        .s_type = .submit_info,
        .wait_semaphore_count = @intCast(wait_semaphores.len),
        .p_wait_semaphores = &wait_semaphores,
        .p_wait_dst_stage_mask = @ptrCast(&vk.PipelineStageFlags{
            .color_attachment_output_bit = true,
        }),
        .command_buffer_count = @intCast(command_buffers.len),
        .p_command_buffers = &command_buffers,
        .signal_semaphore_count = @intCast(signal_semaphores.len),
        .p_signal_semaphores = &signal_semaphores,
    }};

    try stone.logical_device.queueSubmit(
        stone.graphics_queue.handle,
        @intCast(submit_info.len),
        &submit_info,
        stone.syncs.in_flight_fence,
    );

    // Now we present!
    const swapchains = [_]vk.SwapchainKHR{stone.swapchain.handle};
    const present_info: vk.PresentInfoKHR = .{
        .s_type = .present_info_khr,
        .wait_semaphore_count = @intCast(signal_semaphores.len),
        .p_wait_semaphores = &signal_semaphores,
        .swapchain_count = @intCast(swapchains.len),
        .p_swapchains = &swapchains,
        .p_image_indices = @ptrCast(&image_index),
    };

    _ = try stone.logical_device.queuePresentKHR(
        stone.present_queue.handle,
        &present_info,
    );
}
