const std = @import("std");

const core = @import("core");
pub const Vec2 = core.Vector(f32, 2);
pub const Vec3 = core.Vector(f32, 3);

const vulkan = @import("vulkan.zig");
const vk = vulkan.lib;

const glfw = @import("../glfw.zig");

const launcher = @import("../../launcher.zig");

const vertex_shader_bytes align(@alignOf(u32)) = @embedFile("vertex_shader").*;
const fragment_shader_bytes align(@alignOf(u32)) = @embedFile("fragment_shader").*;

const ShaderModuleType = enum {
    vertex,
    fragment,
};

const ShaderModule = struct { [*]const u32, usize };
const vertex_shader: ShaderModule = .{ @ptrCast(&vertex_shader_bytes), vertex_shader_bytes.len };
const fragment_shader: ShaderModule = .{ @ptrCast(&fragment_shader_bytes), fragment_shader_bytes.len };

/// Creates a shader module from the given bytes.
///
/// Must be freed by the logical device when done.
pub fn createShaderModule(
    stone: *launcher.Stone,
    comptime module_type: ShaderModuleType,
) !vk.ShaderModule {
    const module, const len = comptime switch (module_type) {
        .vertex => vertex_shader,
        .fragment => fragment_shader,
    };

    const shader_create_info: vk.ShaderModuleCreateInfo = .{
        .s_type = .shader_module_create_info,
        .code_size = len,
        .p_code = module,
    };

    return try stone.logical_device.createShaderModule(
        &shader_create_info,
        null,
    );
}

pub const Graphics = struct {
    pipeline: vk.Pipeline = undefined,
    layout: vk.PipelineLayout = undefined,

    viewport_count: usize = undefined,
    scissor_count: usize = undefined,

    /// Fully builds the graphics pipeline from scratch.
    ///
    /// Note that Vulkan pipelines are practically immutable and changes require full reinitialization.
    /// This does allow for more aggressive optimizations, however.
    pub fn init(stone: *launcher.Stone) !Graphics {
        var self: Graphics = undefined;

        const vert = try createShaderModule(stone, .vertex);
        defer stone.logical_device.destroyShaderModule(vert, null);

        const vert_stage_info: vk.PipelineShaderStageCreateInfo = .{
            .s_type = .pipeline_shader_stage_create_info,
            .stage = .{
                .vertex_bit = true,
            },
            .module = vert,
            .p_name = "main",
        };

        const frag = try createShaderModule(stone, .fragment);
        defer stone.logical_device.destroyShaderModule(frag, null);

        const frag_stage_info: vk.PipelineShaderStageCreateInfo = .{
            .s_type = .pipeline_shader_stage_create_info,
            .stage = .{
                .fragment_bit = true,
            },
            .module = frag,
            .p_name = "main",
        };

        const shader_stages = [_]vk.PipelineShaderStageCreateInfo{
            vert_stage_info,
            frag_stage_info,
        };

        const binding = Vertex.bindingDescription();
        const attributes = Vertex.attributeDescriptions();
        const vertex_input_info: vk.PipelineVertexInputStateCreateInfo = .{
            .s_type = .pipeline_vertex_input_state_create_info,
            .vertex_binding_description_count = 1,
            .p_vertex_binding_descriptions = @ptrCast(&binding),
            .vertex_attribute_description_count = attributes.len,
            .p_vertex_attribute_descriptions = &attributes,
        };

        // TODO: Update when drawing more than just triangles?
        const input_assembly: vk.PipelineInputAssemblyStateCreateInfo = .{
            .s_type = .pipeline_input_assembly_state_create_info,
            .topology = .triangle_list,
            .primitive_restart_enable = .false,
        };

        // This allows us to change a small subset of the pipeline with recreating it
        const dynamic_state: vk.PipelineDynamicStateCreateInfo = .{
            .s_type = .pipeline_dynamic_state_create_info,
            .dynamic_state_count = @intCast(vulkan.dynamic_states.len),
            .p_dynamic_states = &vulkan.dynamic_states,
        };

        // Since dynamic states are used, we need only specify viewport/scissor at creation time
        self.viewport_count = 1;
        self.scissor_count = 1;
        const viewport_state: vk.PipelineViewportStateCreateInfo = .{
            .s_type = .pipeline_viewport_state_create_info,
            .viewport_count = @intCast(self.viewport_count),
            .scissor_count = @intCast(self.scissor_count),
        };

        const rasterizer: vk.PipelineRasterizationStateCreateInfo = .{
            .s_type = .pipeline_rasterization_state_create_info,
            .depth_clamp_enable = .false,
            .rasterizer_discard_enable = .false,

            .polygon_mode = .fill,
            .line_width = 1.0,

            .cull_mode = .{
                .back_bit = true,
            },
            .front_face = .clockwise,

            .depth_bias_enable = .false,
            .depth_bias_constant_factor = 0.0,
            .depth_bias_clamp = 0.0,
            .depth_bias_slope_factor = 0.0,
        };

        // Configures multisampling - approach to anti-aliasing. Disabled for now
        const multisampling: vk.PipelineMultisampleStateCreateInfo = .{
            .s_type = .pipeline_multisample_state_create_info,
            .sample_shading_enable = .false,
            .rasterization_samples = .{
                .@"1_bit" = true,
            },
            .min_sample_shading = 1.0,
            .p_sample_mask = null,
            .alpha_to_coverage_enable = .false,
            .alpha_to_one_enable = .false,
        };

        const color_blend_attachment = [_]vk.PipelineColorBlendAttachmentState{.{
            .color_write_mask = .{
                .r_bit = true,
                .g_bit = true,
                .b_bit = true,
                .a_bit = true,
            },
            // TODO: Decide if blending is desired, the settings below are good
            .blend_enable = .false,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .zero,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .zero,
            .alpha_blend_op = .add,
        }};

        const color_blending: vk.PipelineColorBlendStateCreateInfo = .{
            .s_type = .pipeline_color_blend_state_create_info,
            .logic_op_enable = .false,
            .logic_op = .copy,
            .attachment_count = @intCast(color_blend_attachment.len),
            .p_attachments = &color_blend_attachment,
            .blend_constants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        const pipeline_layout_info: vk.PipelineLayoutCreateInfo = .{
            .s_type = .pipeline_layout_create_info,
            .set_layout_count = 0,
            .p_set_layouts = null,
            .push_constant_range_count = 0,
            .p_push_constant_ranges = null,
        };

        // Create the pipeline layout but destroy if we fail at some point
        self.layout = try stone.logical_device.createPipelineLayout(
            &pipeline_layout_info,
            null,
        );

        const pipeline_info = [_]vk.GraphicsPipelineCreateInfo{.{
            .s_type = .graphics_pipeline_create_info,
            .stage_count = 2,
            .p_stages = &shader_stages,
            .p_vertex_input_state = &vertex_input_info,
            .p_input_assembly_state = &input_assembly,
            .p_viewport_state = &viewport_state,
            .p_rasterization_state = &rasterizer,
            .p_multisample_state = &multisampling,
            .p_depth_stencil_state = null,
            .p_color_blend_state = &color_blending,
            .p_dynamic_state = &dynamic_state,
            .layout = self.layout,
            .render_pass = stone.render_pass,
            .subpass = 0,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        }};

        const result = try stone.logical_device.createGraphicsPipelines(
            .null_handle,
            @intCast(pipeline_info.len),
            &pipeline_info,
            null,
            @ptrCast(&self.pipeline),
        );

        return if (result != .success) error.PipelineCreateFailed else self;
    }

    pub fn deinit(self: *Graphics, logical_device: *vk.DeviceProxy) void {
        logical_device.destroyPipeline(self.pipeline, null);
        logical_device.destroyPipelineLayout(self.layout, null);
    }
};

pub const Vertex = struct {
    pos: Vec2.VecType,
    color: Vec3.VecType,

    fn bindingDescription() vk.VertexInputBindingDescription {
        return .{
            .binding = 0,
            .stride = @sizeOf(Vertex),
            .input_rate = .vertex,
        };
    }

    fn attributeDescriptions() [2]vk.VertexInputAttributeDescription {
        return .{
            .{
                .binding = 0,
                .location = 0,
                .format = .r32g32_sfloat,
                .offset = @offsetOf(Vertex, "pos"),
            },
            .{
                .binding = 0,
                .location = 1,
                .format = .r32g32b32_sfloat,
                .offset = @offsetOf(Vertex, "color"),
            },
        };
    }
};

pub const vertices = [_]Vertex{
    .{
        .pos = Vec2.decay(.{ 0.0, -0.5 }),
        .color = Vec3.decay(.{ 1.0, 1.0, 1.0 }),
    },
    .{
        .pos = Vec2.decay(.{ 0.5, 0.5 }),
        .color = Vec3.decay(.{ 0.0, 1.0, 0.0 }),
    },
    .{
        .pos = Vec2.decay(.{ -0.5, 0.5 }),
        .color = Vec3.decay(.{ 0.0, 0.0, 1.0 }),
    },
};
pub const vertices_size = @sizeOf(@TypeOf(vertices));
