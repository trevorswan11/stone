const std = @import("std");

const config = @import("config");

const glfw = @import("rendering/glfw.zig");

const vulkan = @import("rendering/vulkan/vulkan.zig");
const swapchain_ = @import("rendering/vulkan/swapchain.zig");
const pipeline = @import("rendering/vulkan/pipeline.zig");

const vk = vulkan.lib;
const BaseWrapper = vk.BaseWrapper;
const InstanceWrapper = vk.InstanceWrapper;
const DeviceWrapper = vk.DeviceWrapper;

const Instance = vk.InstanceProxy;
const LogicalDevice = vk.DeviceProxy;

const vertex_shader align(@alignOf(u32)) = @embedFile("vertex_shader").*;
const fragment_shader align(@alignOf(u32)) = @embedFile("fragment_shader").*;

const app_name = "Stone";

const window_width: u32 = 800;
const window_height: u32 = 600;

pub const Stone = struct {
    allocator: std.mem.Allocator,

    window: *glfw.Window = undefined,

    vkb: BaseWrapper = undefined,
    instance: Instance = undefined,
    debug_messenger: vk.DebugUtilsMessengerEXT = undefined,
    surface: vk.SurfaceKHR = undefined,

    physical_device: vulkan.DeviceCandidate = undefined,
    logical_device: LogicalDevice = undefined,

    graphics_queue: vulkan.Queue = undefined,
    present_queue: vulkan.Queue = undefined,

    swapchain: swapchain_.Swapchain = undefined,
    swapchain_images: std.ArrayList(vk.Image) = .empty,
    swapchain_image_views: std.ArrayList(vk.ImageView) = .empty,

    pipeline_layout: vk.PipelineLayout = undefined,

    pub fn init(allocator: std.mem.Allocator) !Stone {
        var self: Stone = .{
            .allocator = allocator,
        };

        try self.initWindow();
        self.vkb = .load(glfw.getInstanceProcAddress);
        try self.initVulkan();

        return self;
    }

    pub fn deinit(self: *Stone) void {
        defer {
            self.swapchain_images.deinit(self.allocator);
            self.swapchain_image_views.deinit(self.allocator);

            self.allocator.destroy(self.logical_device.wrapper);
            self.allocator.destroy(self.instance.wrapper);
            glfw.terminate();
        }

        self.logical_device.destroyPipelineLayout(self.pipeline_layout, null);
        for (self.swapchain_image_views.items) |image_view| {
            self.logical_device.destroyImageView(image_view, null);
        }

        self.swapchain.deinit(&self.logical_device);
        self.logical_device.destroyDevice(null);
        self.instance.destroySurfaceKHR(self.surface, null);

        if (vulkan.enable_validation_layers) {
            self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
        }
        self.instance.destroyInstance(null);

        glfw.destroyWindow(self.window);
    }

    pub fn run(self: *Stone) !void {
        while (glfw.windowShouldClose(self.window) != glfw.true) {
            glfw.pollEvents();
        }
    }

    /// Initializes the GLFW window without an OpenGL context.
    fn initWindow(self: *Stone) glfw.Error!void {
        if (glfw.init() != glfw.true) {
            return error.LibraryInitFailed;
        }

        if (glfw.vulkanSupported() != glfw.true) {
            std.log.err("GLFW could not find libvulkan", .{});
            return error.NoVulkan;
        }

        glfw.windowHint(glfw.client_api, glfw.no_api);
        glfw.windowHint(glfw.resizable, glfw.false);

        self.window = glfw.createWindow(
            window_width,
            window_height,
            app_name,
            null,
            null,
        ) orelse return error.WindowInitializationFailed;
    }

    /// Initializes vulkan and required objects.
    fn initVulkan(self: *Stone) !void {
        try self.createInstance();
        try self.setupDebugMessenger();

        try self.createSurface();
        try self.pickPhysicalDevice();
        try self.createLogicalDevice();

        try self.createSwapchain();
        try self.createImageViews();
        try self.createGraphicsPipeline();
    }

    /// Creates the instance proxy with extension and validation layer validation.
    fn createInstance(self: *Stone) !void {
        if (vulkan.enable_validation_layers and !(try vulkan.checkValidationLayerSupport(
            self.allocator,
            self.vkb,
        ))) {
            return error.RequestedUnavailableValidationLayers;
        }

        const app_info: vk.ApplicationInfo = .{
            .s_type = .application_info,
            .p_application_name = app_name,
            .application_version = vulkan.makeVersion(0, 1, 0, 0),
            .p_engine_name = "No Engine",
            .engine_version = vulkan.makeVersion(0, 1, 0, 0),
            .api_version = vulkan.version(vk.API_VERSION_1_0),
        };

        var extensions = try self.getRequiredExtensions();
        defer extensions.deinit(self.allocator);

        const instance = try self.vkb.createInstance(
            &.{
                .p_application_info = &app_info,
                .enabled_extension_count = @intCast(extensions.items.len),
                .pp_enabled_extension_names = extensions.items.ptr,
                .enabled_layer_count = @intCast(vulkan.validation_layers.len),
                .pp_enabled_layer_names = &vulkan.validation_layers,
                .flags = .{
                    .enumerate_portability_bit_khr = true,
                },
                .p_next = if (config.verbose) &vulkan.debug_create_info else null,
            },
            null,
        );

        const vki = try self.allocator.create(InstanceWrapper);
        vki.* = .load(instance, self.vkb.dispatch.vkGetInstanceProcAddr.?);
        self.instance = .init(instance, vki);
    }

    /// Gets all required extensions in a way that fulfills the vulkan API type requirements.
    fn getRequiredExtensions(self: *Stone) !std.ArrayList([*:0]const u8) {
        var glfw_extension_count: u32 = 0;
        const glfw_extensions = glfw.getRequiredInstanceExtensions(&glfw_extension_count);
        var all_extensions: std.ArrayList([*:0]const u8) = .empty;

        if (vulkan.enable_validation_layers) {
            try all_extensions.append(self.allocator, vk.extensions.ext_debug_utils.name);
        }

        try all_extensions.append(self.allocator, vk.extensions.khr_portability_enumeration.name);
        try all_extensions.append(self.allocator, vk.extensions.khr_get_physical_device_properties_2.name);
        try all_extensions.appendSlice(self.allocator, @ptrCast(glfw_extensions[0..glfw_extension_count]));

        return all_extensions;
    }

    /// Initializes the internal debug messenger.
    ///
    /// Must be deinitialized if validations layers are enabled.
    fn setupDebugMessenger(self: *Stone) !void {
        if (!vulkan.enable_validation_layers) return;
        self.debug_messenger = try self.instance.createDebugUtilsMessengerEXT(
            &vulkan.debug_create_info,
            null,
        );
    }

    /// Creates a platform agnostic window surface.
    fn createSurface(self: *Stone) !void {
        if (glfw.createWindowSurface(
            self.instance.handle,
            self.window,
            null,
            &self.surface,
        ) != .success) {
            return error.SurfaceInitFailed;
        }
    }

    /// Looks for and selects the graphics card on the system that supports the needed features.
    ///
    /// Could theoretically select multiple graphics cards, but only one is necessary here.
    fn pickPhysicalDevice(self: *Stone) !void {
        const devices = try self.instance.enumeratePhysicalDevicesAlloc(self.allocator);
        defer self.allocator.free(devices);

        // Heapify the devices once converted to candidates for efficient ordering
        var device_heap = std.PriorityQueue(
            vulkan.DeviceCandidate,
            void,
            vulkan.DeviceCandidate.compare,
        ).init(self.allocator, {});
        defer device_heap.deinit();

        for (devices) |device| {
            try device_heap.add(.init(self.allocator, &self.instance, &self.surface, device));
        }

        // Removing items here is slow, we don't need that now
        var best_candidate: vulkan.DeviceCandidate = undefined;
        for (device_heap.items) |*candidate| {
            if (try candidate.suitable()) {
                best_candidate = candidate.*;
                break;
            }
        } else return error.NoSuitableDevice;

        if (best_candidate.device == .null_handle) {
            return error.NoSuitableDevice;
        }
        self.physical_device = best_candidate;
    }

    /// Choses a logical device to interface with the chosen physical device.
    fn createLogicalDevice(self: *Stone) !void {
        const indices = try self.physical_device.findQueueFamilies();
        std.debug.assert(indices.complete());

        // Create queues from both families, skipping duplicates
        var queue_create_infos: std.ArrayList(vk.DeviceQueueCreateInfo) = .empty;
        defer queue_create_infos.deinit(self.allocator);

        var unique_queue_families = std.AutoArrayHashMap(u32, void).init(self.allocator);
        defer unique_queue_families.deinit();
        try unique_queue_families.put(indices.graphics_family.?, {});
        try unique_queue_families.put(indices.present_family.?, {});

        const queue_priority: f32 = 1.0;
        for (unique_queue_families.keys()) |queue_family| {
            try queue_create_infos.append(self.allocator, .{
                .s_type = .device_queue_create_info,
                .queue_family_index = queue_family,
                .queue_count = 1,
                .p_queue_priorities = @ptrCast(&queue_priority),
            });
        }

        // Use the filtered queue families to create the device
        const device_features = self.physical_device.features;
        const device_create_info: vk.DeviceCreateInfo = .{
            .s_type = .device_create_info,
            .queue_create_info_count = @intCast(queue_create_infos.items.len),
            .p_queue_create_infos = queue_create_infos.items.ptr,
            .p_enabled_features = &device_features,
            .enabled_layer_count = @intCast(vulkan.validation_layers.len),
            .pp_enabled_layer_names = &vulkan.validation_layers,
            .enabled_extension_count = @intCast(vulkan.device_extensions.len),
            .pp_enabled_extension_names = &vulkan.device_extensions,
        };

        const device = try self.instance.createDevice(
            self.physical_device.device,
            &device_create_info,
            null,
        );

        const vkd = try self.allocator.create(DeviceWrapper);
        vkd.* = DeviceWrapper.load(device, self.instance.wrapper.dispatch.vkGetDeviceProcAddr.?);
        self.logical_device = LogicalDevice.init(device, vkd);

        self.graphics_queue = .init(self.logical_device, indices.graphics_family.?);
        self.present_queue = .init(self.logical_device, indices.present_family.?);
    }

    /// Creates a working swap chain based off of the window properties and chosen logical device.
    pub fn createSwapchain(self: *Stone) !void {
        var swapchain_support: swapchain_.SwapchainSupportDetails = try .init(&self.physical_device);
        defer swapchain_support.deinit();
        self.swapchain = try .init(self, swapchain_support);

        const swapchain_images = try self.logical_device.getSwapchainImagesAllocKHR(
            self.swapchain.handle,
            self.allocator,
        );
        defer self.allocator.free(swapchain_images);

        try self.swapchain_images.appendSlice(self.allocator, swapchain_images);
    }

    /// Creates all swapchain image views for every image for target usage.
    pub fn createImageViews(self: *Stone) !void {
        try self.swapchain_image_views.resize(self.allocator, self.swapchain_images.items.len);
        for (
            self.swapchain_image_views.items,
            self.swapchain_images.items,
        ) |*image_view, image| {
            const image_view_create_info: vk.ImageViewCreateInfo = .{
                .s_type = .image_view_create_info,
                .image = image,
                .view_type = .@"2d",
                .format = self.swapchain.image_format,
                .components = .{
                    .r = .identity,
                    .g = .identity,
                    .b = .identity,
                    .a = .identity,
                },
                .subresource_range = .{
                    .aspect_mask = .{
                        .color_bit = true,
                    },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            };

            image_view.* = try self.logical_device.createImageView(
                &image_view_create_info,
                null,
            );
        }
    }

    /// Creates the graphics pipeline for the application.
    ///
    /// Note that Vulkan pipelines are practically immutable and changes require full reinitialization.
    /// This does allow for more aggressive optimizations, however.
    pub fn createGraphicsPipeline(self: *Stone) !void {
        const vert = try pipeline.createShaderModule(self, &vertex_shader);
        defer self.logical_device.destroyShaderModule(vert, null);

        const vert_stage_info: vk.PipelineShaderStageCreateInfo = .{
            .s_type = .pipeline_shader_stage_create_info,
            .stage = .{
                .vertex_bit = true,
            },
            .module = vert,
            .p_name = "main",
        };

        const frag = try pipeline.createShaderModule(self, &fragment_shader);
        defer self.logical_device.destroyShaderModule(frag, null);

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
        _ = shader_stages;

        // TODO: Update when vertex shader is not hard-coded
        const vertex_input_info: vk.PipelineVertexInputStateCreateInfo = .{
            .s_type = .pipeline_vertex_input_state_create_info,
            .vertex_binding_description_count = 0,
            .p_vertex_binding_descriptions = null,
            .vertex_attribute_description_count = 0,
            .p_vertex_attribute_descriptions = null,
        };
        _ = vertex_input_info;

        // TODO: Update when drawing more than just triangles
        const input_assembly: vk.PipelineInputAssemblyStateCreateInfo = .{
            .s_type = .pipeline_input_assembly_state_create_info,
            .topology = .triangle_list,
            .primitive_restart_enable = .false,
        };
        _ = input_assembly;

        // TODO: Set in createCommandBuffers
        // const viewport: vk.Viewport = .{
        //     .x = 0.0,
        //     .y = 0.0,
        //     .width = @floatFromInt(self.swapchain.extent.width),
        //     .height = @floatFromInt(self.swapchain.extent.height),
        //     .min_depth = 0.0,
        //     .max_depth = 1.0,
        // };

        // // The scissor acts as a filter for the rasterizer to ignore
        // const scissor: vk.Rect2D = .{
        //     .extent = self.swapchain.extent,
        //     .offset = .{
        //         .x = 0,
        //         .y = 0,
        //     },
        // };

        // This allows us to change a small subset of the pipeline with recreating it
        const dynamic_state: vk.PipelineDynamicStateCreateInfo = .{
            .s_type = .pipeline_dynamic_state_create_info,
            .dynamic_state_count = @intCast(vulkan.dynamic_states.len),
            .p_dynamic_states = &vulkan.dynamic_states,
        };
        _ = dynamic_state;

        // Since dynamic states are used, we need only specify viewport/scissor at creation time
        const viewport_state: vk.PipelineViewportStateCreateInfo = .{
            .s_type = .pipeline_viewport_state_create_info,
            .viewport_count = 1,
            .scissor_count = 1,
        };
        _ = viewport_state;

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
        _ = rasterizer;

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
        _ = multisampling;

        const color_blend_attachment: vk.PipelineColorBlendAttachmentState = .{
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
        };

        const color_blending: vk.PipelineColorBlendStateCreateInfo = .{
            .s_type = .pipeline_color_blend_state_create_info,
            .logic_op_enable = .false,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&color_blend_attachment),
            .blend_constants = .{ 0.0, 0.0, 0.0, 0.0 },
        };
        _ = color_blending;

        const pipeline_layout_info: vk.PipelineLayoutCreateInfo = .{
            .s_type = .pipeline_layout_create_info,
            .set_layout_count = 0,
            .p_set_layouts = null,
            .push_constant_range_count = 0,
            .p_push_constant_ranges = null,
        };

        self.pipeline_layout = try self.logical_device.createPipelineLayout(
            &pipeline_layout_info,
            null,
        );
    }
};
