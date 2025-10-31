const std = @import("std");
const gpu = std.gpu;

const core = @import("core/root.zig");
const Particle = core.common.Particle;
const UniformBufferObject = core.UniformBufferObject;

pub export const workgroup_size: @Vector(3, u32) = .{ 256, 1, 1 };

extern const ubo: UniformBufferObject addrspace(.uniform);

extern const particles_in: [8192]Particle addrspace(.storage_buffer);
extern var particles_out: [8192]Particle addrspace(.storage_buffer);

export fn main() callconv(.spirv_kernel) void {
    // gpu.executionMode(main, .{
    //     .local_size = .{ .x = 26, .y = 1, .z = 1 },
    // });

    gpu.binding(&ubo, 0, 0);
    gpu.binding(&particles_in, 0, 1);
    gpu.binding(&particles_out, 0, 2);

    const index = gpu.global_invocation_id[0];
    const particle_in = particles_in[index];

    particles_out[index].position = .add(
        particle_in.position,
        particle_in.velocity.scale(ubo.delta_time),
    );

    if (particles_out[index].position.raw[0] <= -1.0 or
        particles_out[index].position.raw[0] >= 1.0)
    {
        particles_out[index].velocity.raw[0] = -particles_out[index].velocity.raw[0];
    }
    if (particles_out[index].position.raw[1] <= -1.0 or
        particles_out[index].position.raw[1] >= 1.0)
    {
        particles_out[index].velocity.raw[1] = -particles_out[index].velocity.raw[1];
    }
}
