const std = @import("std");

const vulkan = @import("vulkan.zig");
const vk = vulkan.lib;

const glfw = @import("../glfw.zig");

const launcher = @import("../../launcher.zig");

const pipeline = @import("pipeline.zig");
const draw = @import("draw.zig");

const particle = @import("../sph/particle.zig");

/// A generic buffer implementation.
///
/// Simply determines and allocates memory based on initialization properties.
pub const Buffer = struct {
    handle: vk.Buffer,
    mem: vk.DeviceMemory,

    /// Creates a generic Buffer.
    pub fn init(
        logical_device: vk.DeviceProxy,
        instance: vk.InstanceProxy,
        p_dev: vk.PhysicalDevice,
        size: vk.DeviceSize,
        usage: vk.BufferUsageFlags,
        properties: vk.MemoryPropertyFlags,
    ) !Buffer {
        const buffer_info: vk.BufferCreateInfo = .{
            .size = size,
            .usage = usage,
            .sharing_mode = .exclusive,
        };

        const buffer = try logical_device.createBuffer(
            &buffer_info,
            null,
        );

        // Allocate the memory for the buffer - coherent set to prevent caching from messing with memory
        const memory_requirements = logical_device.getBufferMemoryRequirements(buffer);
        const alloc_info: vk.MemoryAllocateInfo = .{
            .allocation_size = memory_requirements.size,
            .memory_type_index = try findMemoryType(
                instance,
                p_dev,
                memory_requirements.memory_type_bits,
                properties,
            ),
        };

        const mem = try logical_device.allocateMemory(
            &alloc_info,
            null,
        );

        // Now we can bind the buffer and proceed with mapping the actual data
        try logical_device.bindBufferMemory(buffer, mem, 0);
        return .{
            .handle = buffer,
            .mem = mem,
        };
    }

    pub fn deinit(self: *Buffer, logical_device: vk.DeviceProxy) void {
        logical_device.destroyBuffer(self.handle, null);
        logical_device.freeMemory(self.mem, null);
    }

    /// Copies all resources from the source buffer to the destination buffer.
    ///
    /// The buffer's allocated memory is not interfered with.
    pub fn copy(
        logical_device: vk.DeviceProxy,
        command_pool: vk.CommandPool,
        graphics_queue: vk.Queue,
        source: Buffer,
        dest: Buffer,
        size: vk.DeviceSize,
    ) !void {
        const alloc_info: vk.CommandBufferAllocateInfo = .{
            .level = .primary,
            .command_pool = command_pool,
            .command_buffer_count = 1,
        };

        // Create a temporary command buffer for proper copying
        var command_buffer: vk.CommandBuffer = undefined;
        try logical_device.allocateCommandBuffers(&alloc_info, @ptrCast(&command_buffer));
        defer logical_device.freeCommandBuffers(command_pool, 1, @ptrCast(&command_buffer));

        const begin_info: vk.CommandBufferBeginInfo = .{
            .flags = .{
                .one_time_submit_bit = true,
            },
        };
        try logical_device.beginCommandBuffer(command_buffer, &begin_info);

        const copy_regions = [_]vk.BufferCopy{.{
            .src_offset = 0,
            .dst_offset = 0,
            .size = size,
        }};
        logical_device.cmdCopyBuffer(
            command_buffer,
            source.handle,
            dest.handle,
            @intCast(copy_regions.len),
            &copy_regions,
        );
        try logical_device.endCommandBuffer(command_buffer);

        // Now execute the command buffer to complete the copy
        const submit_infos = [_]vk.SubmitInfo{.{
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&command_buffer),
        }};

        try logical_device.queueSubmit(
            graphics_queue,
            submit_infos.len,
            &submit_infos,
            .null_handle,
        );
        try logical_device.queueWaitIdle(graphics_queue);
    }
};

pub const VertexBuffer = struct {
    buffer: Buffer,

    pub fn init(stone: *launcher.Stone) !VertexBuffer {
        const buffer_size = pipeline.vertices_size;

        // Create a temporary buffer only visible to the host
        var staging_buffer: Buffer = try .init(
            stone.logical_device,
            stone.instance,
            stone.physical_device.device,
            buffer_size,
            .{
                .transfer_src_bit = true,
            },
            .{
                .host_visible_bit = true,
                .host_coherent_bit = true,
            },
        );
        defer staging_buffer.deinit(stone.logical_device);

        // Map and copy the memory from the CPU to GPU
        const data = try stone.logical_device.mapMemory(
            staging_buffer.mem,
            0,
            buffer_size,
            .{},
        ) orelse return error.MemoryMapFailed;
        defer stone.logical_device.unmapMemory(staging_buffer.mem);

        const casted: *@TypeOf(pipeline.vertices) = @ptrCast(@alignCast(data));
        @memcpy(casted, &pipeline.vertices);

        // Create a device local buffer to use as the actual vertex buffer
        const vertex_buffer: Buffer = try .init(
            stone.logical_device,
            stone.instance,
            stone.physical_device.device,
            buffer_size,
            .{
                .transfer_dst_bit = true,
                .vertex_buffer_bit = true,
            },
            .{
                .device_local_bit = true,
            },
        );

        try Buffer.copy(
            stone.logical_device,
            stone.command.pool,
            stone.graphics_queue.handle,
            staging_buffer,
            vertex_buffer,
            buffer_size,
        );

        return .{
            .buffer = .{
                .handle = vertex_buffer.handle,
                .mem = vertex_buffer.mem,
            },
        };
    }

    pub fn deinit(self: *VertexBuffer, logical_device: vk.DeviceProxy) void {
        self.buffer.deinit(logical_device);
    }
};

pub const IndexBuffer = struct {
    buffer: Buffer,

    pub fn init(stone: *launcher.Stone) !IndexBuffer {
        const buffer_size = pipeline.indices_size;

        // Create a temporary buffer only visible to the host
        var staging_buffer: Buffer = try .init(
            stone.logical_device,
            stone.instance,
            stone.physical_device.device,
            buffer_size,
            .{
                .transfer_src_bit = true,
            },
            .{
                .host_visible_bit = true,
                .host_coherent_bit = true,
            },
        );
        defer staging_buffer.deinit(stone.logical_device);

        // Map and copy the memory from the CPU to GPU
        const data = try stone.logical_device.mapMemory(
            staging_buffer.mem,
            0,
            buffer_size,
            .{},
        ) orelse return error.MemoryMapFailed;
        defer stone.logical_device.unmapMemory(staging_buffer.mem);

        const casted: *@TypeOf(pipeline.indices) = @ptrCast(@alignCast(data));
        @memcpy(casted, &pipeline.indices);

        // Create a device local buffer to use as the actual index buffer
        const index_buffer: Buffer = try .init(
            stone.logical_device,
            stone.instance,
            stone.physical_device.device,
            buffer_size,
            .{
                .transfer_dst_bit = true,
                .index_buffer_bit = true,
            },
            .{
                .device_local_bit = true,
            },
        );

        try Buffer.copy(
            stone.logical_device,
            stone.command.pool,
            stone.graphics_queue.handle,
            staging_buffer,
            index_buffer,
            buffer_size,
        );

        return .{
            .buffer = .{
                .handle = index_buffer.handle,
                .mem = index_buffer.mem,
            },
        };
    }

    pub fn deinit(self: *IndexBuffer, logical_device: vk.DeviceProxy) void {
        self.buffer.deinit(logical_device);
    }
};

pub const NativeMat4 = [4]pipeline.Mat4.VecType.VecType;
pub const NativeUniformBufferObject = struct {
    dt: f32 align(16),
    quad_model: NativeMat4 align(16),
    point_model: NativeMat4 align(16),
    view: NativeMat4 align(16),
    proj: NativeMat4 align(16),

    pub fn init(op: OpUniformBufferObject) NativeUniformBufferObject {
        return .{
            .dt = op.dt,
            .quad_model = opToNative(op.quad_model),
            .point_model = opToNative(op.point_model),
            .view = opToNative(op.view),
            .proj = opToNative(op.proj),
        };
    }

    fn opToNative(op: OpMat4) NativeMat4 {
        var out: NativeMat4 = undefined;
        for (op.mat, &out) |v, *r| {
            r.* = v.vec;
        }
        return out;
    }
};

pub const OpMat4 = pipeline.Mat4;
pub const OpUniformBufferObject = struct {
    dt: f32 = 0.0,
    quad_model: OpMat4 = .splat(0.0),
    point_model: OpMat4 = .splat(0.0),
    view: OpMat4 = .splat(0.0),
    proj: OpMat4 = .splat(0.0),
};

pub const UniformBuffers = struct {
    buffers: []Buffer,
    mapped: []*anyopaque,

    pub fn init(stone: *launcher.Stone) !UniformBuffers {
        const buffer_size = @sizeOf(NativeUniformBufferObject);

        var self: UniformBuffers = undefined;
        self.buffers = try stone.allocator.alloc(Buffer, draw.max_frames_in_flight);
        self.mapped = try stone.allocator.alloc(*anyopaque, draw.max_frames_in_flight);

        for (self.buffers, self.mapped) |*buf, *map| {
            buf.* = try .init(
                stone.logical_device,
                stone.instance,
                stone.physical_device.device,
                buffer_size,
                .{
                    .uniform_buffer_bit = true,
                },
                .{
                    .host_visible_bit = true,
                    .host_coherent_bit = true,
                },
            );

            map.* = try stone.logical_device.mapMemory(
                buf.mem,
                0,
                buffer_size,
                .{},
            ) orelse return error.MemoryMapFailed;
        }

        return self;
    }

    pub fn deinit(self: *UniformBuffers, allocator: std.mem.Allocator, logical_device: vk.DeviceProxy) void {
        defer {
            allocator.free(self.buffers);
            allocator.free(self.mapped);
        }

        for (self.buffers) |*buf| {
            logical_device.unmapMemory(buf.mem);
            buf.deinit(logical_device);
        }
    }
};

pub const StorageBuffers = struct {
    buffers: []Buffer,

    pub fn init(stone: *launcher.Stone) !StorageBuffers {
        const buffer_size = @sizeOf(particle.NativeParticle) * particle.max_particles;

        var self: StorageBuffers = undefined;
        self.buffers = try stone.allocator.alloc(Buffer, draw.max_frames_in_flight);

        // Initialize particles with random initial positions
        const op_particles = try particle.OpParticle.spawn(
            stone.allocator,
            @bitCast(stone.timestep.start_time_us),
            particle.max_particles,
        );
        defer stone.allocator.free(op_particles);

        const native_particles = try stone.allocator.alloc(
            particle.NativeParticle,
            op_particles.len,
        );
        defer stone.allocator.free(native_particles);
        for (native_particles, op_particles) |*n_particle, o_particle| {
            n_particle.* = .init(o_particle);
        }

        // Create a temporary buffer only visible to the host
        var staging_buffer: Buffer = try .init(
            stone.logical_device,
            stone.instance,
            stone.physical_device.device,
            buffer_size,
            .{
                .transfer_src_bit = true,
            },
            .{
                .host_visible_bit = true,
                .host_coherent_bit = true,
            },
        );
        defer staging_buffer.deinit(stone.logical_device);

        // Map and copy the memory from the CPU to GPU
        const data = try stone.logical_device.mapMemory(
            staging_buffer.mem,
            0,
            buffer_size,
            .{},
        ) orelse return error.MemoryMapFailed;
        defer stone.logical_device.unmapMemory(staging_buffer.mem);

        const casted: [*]particle.NativeParticle = @ptrCast(@alignCast(data));
        @memcpy(casted, native_particles);

        // Initialize storage objects by copying the staging buffer's mem
        for (self.buffers) |*buf| {
            buf.* = try .init(
                stone.logical_device,
                stone.instance,
                stone.physical_device.device,
                buffer_size,
                .{
                    .storage_buffer_bit = true,
                    .vertex_buffer_bit = true,
                    .transfer_dst_bit = true,
                },
                .{
                    .device_local_bit = true,
                },
            );

            // Copy thr buffer from the host to the device
            try Buffer.copy(
                stone.logical_device,
                stone.command.pool,
                stone.graphics_queue.handle,
                staging_buffer,
                buf.*,
                buffer_size,
            );
        }

        return self;
    }

    pub fn deinit(self: *StorageBuffers, allocator: std.mem.Allocator, logical_device: vk.DeviceProxy) void {
        defer allocator.free(self.buffers);

        for (self.buffers) |*buf| {
            buf.deinit(logical_device);
        }
    }
};

pub const ParticleVertexBuffer = struct {
    buffer: Buffer,
    mapped: *anyopaque,
    size: vk.DeviceSize,

    pub fn init(stone: *launcher.Stone) !ParticleVertexBuffer {
        const size = @sizeOf(particle.NativeParticle) * particle.max_particles;

        // Create a buffer for both the host and device
        const buffer = try Buffer.init(
            stone.logical_device,
            stone.instance,
            stone.physical_device.device,
            size,
            .{
                .vertex_buffer_bit = true,
            },
            .{
                .host_visible_bit = true,
                .host_coherent_bit = true,
            },
        );

        // Map it once and keep it mapped
        const mapped = try stone.logical_device.mapMemory(
            buffer.mem,
            0,
            size,
            .{},
        ) orelse return error.MemoryMapFailed;

        return .{
            .buffer = buffer,
            .mapped = mapped,
            .size = size,
        };
    }

    pub fn deinit(self: *ParticleVertexBuffer, logical_device: vk.DeviceProxy) void {
        logical_device.unmapMemory(self.buffer.mem);
        self.buffer.deinit(logical_device);
    }
};

/// Determines the correct GPU memory to use based on the buffer and physical device.
///
/// Necessary as the GPU has different memory regions that allow different operations and performance optimizations.
pub fn findMemoryType(instance: vk.InstanceProxy, p_dev: vk.PhysicalDevice, type_filter: u32, properties: vk.MemoryPropertyFlags) !u32 {
    const memory_properties = instance.getPhysicalDeviceMemoryProperties(p_dev);
    for (0..memory_properties.memory_type_count) |i| {
        const bit_at = type_filter & (@as(u32, 1) << @truncate(i));
        const contains_req = memory_properties.memory_types[i].property_flags.contains(properties);
        if (bit_at != 0 and contains_req) {
            return @intCast(i);
        }
    } else return error.CannotFulfillMemoryRequirements;
}
