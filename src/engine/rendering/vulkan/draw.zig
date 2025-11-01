const std = @import("std");

const vulkan = @import("vulkan.zig");
const vk = vulkan.lib;

const core = @import("core");

const glfw = @import("../glfw.zig");

const launcher = @import("../../launcher.zig");

const pipeline = @import("pipeline.zig");
const buffer_ = @import("buffer.zig");

const box = @import("../sph/box.zig");
const particle = @import("../sph/particle.zig");

pub const max_frames_in_flight = 2;

pub const Command = struct {
    pool: vk.CommandPool = undefined,
    buffers: []vk.CommandBuffer = undefined,
    compute_buffers: []vk.CommandBuffer = undefined,

    pub fn init(stone: *launcher.Stone) !Command {
        var self: Command = .{
            .pool = stone.command.pool,
        };

        // Graphics pass
        self.buffers = try stone.allocator.alloc(vk.CommandBuffer, max_frames_in_flight);
        const compute_alloc_info: vk.CommandBufferAllocateInfo = .{
            .command_pool = stone.command.pool,
            .level = .primary,
            .command_buffer_count = @intCast(self.buffers.len),
        };

        try stone.logical_device.allocateCommandBuffers(
            &compute_alloc_info,
            self.buffers.ptr,
        );

        // Compute pass
        // TODO: Bring me back when https://github.com/ziglang/zig/pull/24681
        if (false) {
            self.compute_buffers = try stone.allocator.alloc(vk.CommandBuffer, max_frames_in_flight);
            const graphics_alloc_info: vk.CommandBufferAllocateInfo = .{
                .command_pool = stone.command.pool,
                .level = .primary,
                .command_buffer_count = @intCast(self.compute_buffers.len),
            };

            try stone.logical_device.allocateCommandBuffers(
                &graphics_alloc_info,
                self.compute_buffers.ptr,
            );
        }

        return self;
    }

    pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        allocator.free(self.buffers);

        // TODO: Bring me back when https://github.com/ziglang/zig/pull/24681
        if (false) {
            allocator.free(self.compute_buffers);
        }
    }

    /// Writes the commands wanted to execute to the command buffer.
    pub fn recordBuffer(
        stone: *launcher.Stone,
        buffer: vk.CommandBuffer,
        image_idx: u32,
        current_frame: u32,
    ) !void {
        // Kick off the command buffer, flags van be used to specify usage constraints
        try stone.logical_device.beginCommandBuffer(
            buffer,
            &.{},
        );

        const clear_colors = [_]vk.ClearValue{
            .{ .color = .{ .float_32 = .{ 0.0, 0.0, 0.0, 1.0 } } },
        };

        // Drawing starts with a configured render pass
        std.debug.assert(image_idx < stone.swapchain_lists.framebuffers.len);
        const render_pass_info: vk.RenderPassBeginInfo = .{
            .render_pass = stone.render_pass,
            .framebuffer = stone.swapchain_lists.framebuffers[image_idx],
            .render_area = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = stone.swapchain.extent,
            },
            .clear_value_count = clear_colors.len,
            .p_clear_values = &clear_colors,
        };

        // All vkCmd functions do not throw errors and must be handled until done recording
        stone.logical_device.cmdBeginRenderPass(
            buffer,
            &render_pass_info,
            .@"inline",
        );

        stone.logical_device.cmdBindPipeline(
            buffer,
            .graphics,
            stone.graphics_pipeline_quad.pipeline,
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

        std.debug.assert(viewports.len == stone.graphics_pipeline_quad.viewport_count);
        stone.logical_device.cmdSetViewport(
            buffer,
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

        std.debug.assert(scissors.len == stone.graphics_pipeline_quad.scissor_count);
        stone.logical_device.cmdSetScissor(
            buffer,
            0,
            scissors.len,
            &scissors,
        );

        // Now we can finally draw and end the render pass
        const vertex_buffers = [_]vk.Buffer{
            stone.vertex_buffer.buffer.handle,
        };
        const offsets = [_]vk.DeviceSize{0};
        stone.logical_device.cmdBindVertexBuffers(
            buffer,
            0,
            1,
            &vertex_buffers,
            &offsets,
        );

        stone.logical_device.cmdBindIndexBuffer(
            buffer,
            stone.index_buffer.buffer.handle,
            0,
            box.index_type,
        );

        stone.logical_device.cmdBindDescriptorSets(
            buffer,
            .graphics,
            stone.graphics_pipeline_quad.layout,
            0,
            1,
            @ptrCast(&stone.descriptor_sets[current_frame]),
            0,
            null,
        );

        stone.logical_device.cmdDrawIndexed(
            buffer,
            @intCast(box.indices.len),
            1,
            0,
            0,
            0,
        );

        // Draw the points now
        stone.logical_device.cmdBindPipeline(
            buffer,
            .graphics,
            stone.graphics_pipeline_point.pipeline,
        );

        const particle_vertex_buffers = [_]vk.Buffer{
            stone.particle_vertex_buffer.buffer.handle,
        };

        stone.logical_device.cmdBindVertexBuffers(
            buffer,
            0,
            1,
            &particle_vertex_buffers,
            &offsets,
        );

        stone.logical_device.cmdDraw(
            buffer,
            @intCast(stone.sph.total_particles),
            1,
            0,
            0,
        );

        stone.logical_device.cmdEndRenderPass(buffer);
        try stone.logical_device.endCommandBuffer(buffer);
    }

    pub fn recordComputeCommandBuffer(
        stone: *launcher.Stone,
        buffer: vk.CommandBuffer,
        current_frame: u32,
    ) !void {
        try stone.logical_device.beginCommandBuffer(
            buffer,
            &.{},
        );

        stone.logical_device.cmdBindPipeline(
            buffer,
            .compute,
            stone.compute_pipeline.pipeline,
        );

        stone.logical_device.cmdBindDescriptorSets(
            buffer,
            .compute,
            stone.compute_pipeline.layout,
            0,
            1,
            @ptrCast(&stone.descriptor_sets[current_frame]),
            0,
            null,
        );

        stone.logical_device.cmdDispatch(
            buffer,
            buffer_.max_particles / 256,
            1,
            1,
        );

        try stone.logical_device.endCommandBuffer(buffer);
    }
};

/// Renders a Frame by following:
/// - Wait for the previous frame to finish
/// - Acquire an image from the swapchain
/// - Record a command buffer which draws that scene onto the image
/// - Submit the recorded command buffer
/// - Present the swapchain image
pub fn drawFrame(stone: *launcher.Stone) !void {
    const current_frame = stone.syncs.current_frame;

    // Compute Submission
    // TODO: Bring me back when https://github.com/ziglang/zig/pull/24681
    if (false) {
        const compute_command_buffers = [_]vk.CommandBuffer{
            stone.command.compute_buffers[current_frame],
        };

        const compute_signal_semaphores = [_]vk.Semaphore{
            stone.syncs.compute_finished_semaphores[current_frame],
        };

        const compute_fences = [_]vk.Fence{
            stone.syncs.compute_in_flight_fences[current_frame],
        };

        _ = try stone.logical_device.waitForFences(
            compute_fences.len,
            &compute_fences,
            .true,
            std.math.maxInt(u64),
        );

        try stone.logical_device.resetFences(compute_fences.len, &compute_fences);

        try stone.logical_device.resetCommandBuffer(stone.command.compute_buffers[current_frame], .{});
        try Command.recordComputeCommandBuffer(
            stone,
            stone.command.compute_buffers[current_frame],
            current_frame,
        );

        const compute_submit_info = [_]vk.SubmitInfo{.{
            .command_buffer_count = @intCast(compute_command_buffers.len),
            .p_command_buffers = &compute_command_buffers,
            .signal_semaphore_count = @intCast(compute_signal_semaphores.len),
            .p_signal_semaphores = &compute_signal_semaphores,
        }};

        try stone.logical_device.queueSubmit(
            stone.compute_queue.handle,
            @intCast(compute_submit_info.len),
            &compute_submit_info,
            stone.syncs.compute_in_flight_fences[current_frame],
        );
    }

    // Graphics Submission
    const graphics_command_buffers = [_]vk.CommandBuffer{
        stone.command.buffers[current_frame],
    };

    const graphics_wait_semaphores = [_]vk.Semaphore{
        stone.syncs.image_available_semaphores[current_frame],
    };
    const graphics_signal_semaphores = [_]vk.Semaphore{
        stone.syncs.render_finished_semaphores[current_frame],
    };

    const graphics_fences = [_]vk.Fence{
        stone.syncs.in_flight_fences[current_frame],
    };

    // We have to wait for the device to be ready before acquiring
    _ = try stone.logical_device.waitForFences(
        1,
        &graphics_fences,
        .true,
        comptime std.math.maxInt(u64),
    );

    const next = try stone.logical_device.acquireNextImageKHR(
        stone.swapchain.handle,
        comptime std.math.maxInt(u64),
        stone.syncs.image_available_semaphores[current_frame],
        .null_handle,
    );

    const image_index = switch (next.result) {
        .success => next.image_index,
        .error_out_of_date_khr => {
            try stone.recreateSwapchain();
            return;
        },
        else => return error.SwapchainPresentFailed,
    };

    updateUniformBuffer(stone, current_frame);
    try stone.sph.updateParticles(stone.timestep.dt, stone.particle_vertex_buffer.mapped);
    std.debug.print("{d} fps @ {d} p\n", .{ 1.0 / stone.timestep.true_dt, stone.sph.particles.len + stone.sph.boundary.len });

    try stone.logical_device.resetFences(graphics_fences.len, &graphics_fences);

    // Now we record the command buffer, but reset first!
    try stone.logical_device.resetCommandBuffer(stone.command.buffers[current_frame], .{});
    try Command.recordBuffer(
        stone,
        stone.command.buffers[current_frame],
        image_index,
        current_frame,
    );

    // Now the buffer is fully recorded and can be submitted
    const graphics_submit_info = [_]vk.SubmitInfo{.{
        .wait_semaphore_count = @intCast(graphics_wait_semaphores.len),
        .p_wait_semaphores = &graphics_wait_semaphores,
        .p_wait_dst_stage_mask = @ptrCast(&vk.PipelineStageFlags{
            .color_attachment_output_bit = true,
        }),
        .command_buffer_count = @intCast(graphics_command_buffers.len),
        .p_command_buffers = &graphics_command_buffers,
        .signal_semaphore_count = @intCast(graphics_signal_semaphores.len),
        .p_signal_semaphores = &graphics_signal_semaphores,
    }};

    try stone.logical_device.queueSubmit(
        stone.graphics_queue.handle,
        @intCast(graphics_submit_info.len),
        &graphics_submit_info,
        stone.syncs.in_flight_fences[current_frame],
    );

    // Now we present!
    const swapchains = [_]vk.SwapchainKHR{stone.swapchain.handle};
    const present_info: vk.PresentInfoKHR = .{
        .wait_semaphore_count = @intCast(graphics_signal_semaphores.len),
        .p_wait_semaphores = &graphics_signal_semaphores,
        .swapchain_count = @intCast(swapchains.len),
        .p_swapchains = &swapchains,
        .p_image_indices = @ptrCast(&image_index),
    };

    const result = stone.logical_device.queuePresentKHR(
        stone.present_queue.handle,
        &present_info,
    ) catch |err| blk: switch (err) {
        error.OutOfDateKHR => {
            stone.framebuffer_resized = false;
            try stone.recreateSwapchain();
            break :blk vk.Result.success;
        },
        else => return err,
    };

    switch (result) {
        .success => {},
        else => |flag| {
            if (flag == .error_out_of_date_khr or flag == .suboptimal_khr or stone.framebuffer_resized) {
                stone.framebuffer_resized = false;
                try stone.recreateSwapchain();
            } else return error.SwapchainPresentFailed;
        },
    }

    stone.syncs.current_frame = (current_frame + 1) % max_frames_in_flight;
}

fn updateUniformBuffer(stone: *launcher.Stone, current_frame: u32) void {
    const width: f32 = @floatFromInt(stone.swapchain.extent.width);
    const height: f32 = @floatFromInt(stone.swapchain.extent.height);

    const ubo: buffer_.OpUniformBufferObject = .{
        .dt = stone.timestep.dt,
        .particle_size = 2.0,
        .quad_model = core.mat.rotate(
            f32,
            comptime .identity(1.0),
            0.0,
            .init(.{ 0.0, 0.0, 1.0 }),
        ),
        .point_model = core.mat.rotate(
            f32,
            comptime .identity(1.0),
            0.0,
            .init(.{ 0.0, 0.0, 1.0 }),
        ),
        .view = core.mat.lookAt(
            f32,
            comptime .init(.{ 2.0, 2.0, 2.0 }),
            comptime .splat(0.0),
            comptime .init(.{ 0.0, 0.0, 1.0 }),
        ),
        .proj = core.mat.perspective(
            f32,
            std.math.degreesToRadians(45.0),
            width / height,
            0.1,
            10.0,
        ),
    };

    const mem = stone.uniform_buffers.mapped[current_frame];
    const mapped_ubo: *buffer_.NativeUniformBufferObject = @ptrCast(@alignCast(mem));
    mapped_ubo.* = .init(ubo);
}
