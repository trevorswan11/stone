

// launcher.zig

const std = @import("std");

const config = @import("config");
const core = @import("core");

const glfw = @import("rendering/glfw.zig");

const vulkan = @import("rendering/vulkan/vulkan.zig");
const swapchain_ = @import("rendering/vulkan/swapchain.zig");
const pipeline = @import("rendering/vulkan/pipeline.zig");
const draw = @import("rendering/vulkan/draw.zig");
const sync = @import("rendering/vulkan/sync.zig");
const buffer = @import("rendering/vulkan/buffer.zig");

const vk = vulkan.lib;
const BaseWrapper = vk.BaseWrapper;
const InstanceWrapper = vk.InstanceWrapper;
const DeviceWrapper = vk.DeviceWrapper;

const Instance = vk.InstanceProxy;
const LogicalDevice = vk.DeviceProxy;

const app_name = "Stone";

pub const initial_window_width: u32 = 800;
pub const initial_window_height: u32 = 600;

pub fn framebufferResizeCallback(
    window: ?*glfw.Window,
    width: c_int,
    height: c_int,
) callconv(.c) void {
    _ = .{ width, height };
    const app_window = glfw.getWindowUserPointer(window.?).?;
    const stone: *Stone = @ptrCast(@alignCast(app_window));
    stone.framebuffer_resized = true;
}

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
    compute_queue: vulkan.Queue = undefined,

    swapchain: swapchain_.Swapchain = undefined,
    swapchain_lists: swapchain_.SwapchainLists = .{},
    framebuffer_resized: bool = false,
    render_pass: vk.RenderPass = undefined,

    graphics_pipeline: pipeline.Graphics = undefined,
    compute_pipeline: pipeline.Compute = undefined,

    descriptor_pool: vk.DescriptorPool = undefined,
    descriptor_sets: []vk.DescriptorSet = undefined,
    descriptor_set_layout: vk.DescriptorSetLayout = undefined,

    vertex_buffer: buffer.VertexBuffer = undefined,
    index_buffer: buffer.IndexBuffer = undefined,
    uniform_buffers: buffer.UniformBuffers = undefined,
    storage_buffers: buffer.StorageBuffers = undefined,

    command: draw.Command = undefined,
    syncs: sync.Syncs = undefined,

    timestep: core.Timestep = undefined,

    pub fn init(allocator: std.mem.Allocator) !Stone {
        var self: Stone = .{
            .allocator = allocator,
        };

        try self.initWindow();
        self.vkb = .load(glfw.getInstanceProcAddress);
        try self.initVulkan();

        self.timestep = .init();
        return self;
    }

    pub fn deinit(self: *Stone) void {
        defer {
            glfw.destroyWindow(self.window);

            self.swapchain_lists.deinit(self.allocator);
            self.command.deinit(self.allocator);
            self.allocator.free(self.descriptor_sets);

            self.allocator.destroy(self.logical_device.wrapper);
            self.allocator.destroy(self.instance.wrapper);
            glfw.terminate();
        }

        self.vertex_buffer.deinit(self.logical_device);
        self.index_buffer.deinit(self.logical_device);
        self.uniform_buffers.deinit(self.allocator, self.logical_device);
        // TODO: Bring me back when https://github.com/ziglang/zig/pull/24681
        if (false) {
            self.storage_buffers.deinit(self.allocator, self.logical_device);
        }

        self.syncs.deinit(self.allocator, &self.logical_device);
        self.logical_device.destroyCommandPool(self.command.pool, null);

        self.graphics_pipeline.deinit(&self.logical_device);
        // TODO: Bring me back when https://github.com/ziglang/zig/pull/24681
        if (false) {
            self.compute_pipeline.deinit(&self.logical_device);
        }
        self.logical_device.destroyRenderPass(self.render_pass, null);

        self.swapchain.deinit(self);
        self.logical_device.destroyDescriptorPool(self.descriptor_pool, null);
        self.logical_device.destroyDescriptorSetLayout(self.descriptor_set_layout, null);

        self.logical_device.destroyDevice(null);
        self.instance.destroySurfaceKHR(self.surface, null);

        if (vulkan.enable_validation_layers) {
            self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
        }
        self.instance.destroyInstance(null);
    }

    pub fn run(self: *Stone) !void {
        while (glfw.windowShouldClose(self.window) != glfw.true) {
            _ = self.timestep.step(f32);
            glfw.pollEvents();
            try draw.drawFrame(self);
        }

        try self.logical_device.deviceWaitIdle();
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

        self.window = glfw.createWindow(
            initial_window_width,
            initial_window_height,
            app_name,
            null,
            null,
        ) orelse return error.WindowInitializationFailed;

        glfw.setWindowUserPointer(self.window, self);
        _ = glfw.setFramebufferSizeCallback(
            self.window,
            framebufferResizeCallback,
        );
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
        try self.createRenderPass();
        try self.createDescriptorSetLayout();
        try self.createGraphicsPipeline();
        try self.createComputePipeline();
        try self.createFramebuffers();

        try self.createCommandPool();
        try self.createVertexBuffer();
        try self.createIndexBuffer();
        try self.createUniformBuffers();
        try self.createStorageBuffers();
        try self.createCommandBuffers();
        try self.createDescriptorPool();
        try self.createDescriptorSets();
        try self.createSyncObjects();
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
            .p_application_name = app_name,
            .application_version = vulkan.makeVersion(0, 1, 0, 0),
            .p_engine_name = "No Engine",
            .engine_version = vulkan.makeVersion(0, 1, 0, 0),
            .api_version = vulkan.version(vk.API_VERSION_1_2),
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

        // This doesn't apply any immediate changes but prevents future stale usage
        self.physical_device.surface = self.surface;
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
            try device_heap.add(.init(self.instance, self.surface, device));
        }

        // Removing items here is slow, we don't need that now
        var best_candidate: vulkan.DeviceCandidate = undefined;
        for (device_heap.items) |*candidate| {
            if (try candidate.suitable(self.allocator)) {
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
        const indices = try self.physical_device.findQueueFamilies(self.allocator);
        std.debug.assert(indices.complete());

        // Create queues from both families, skipping duplicates
        var queue_create_infos: std.ArrayList(vk.DeviceQueueCreateInfo) = .empty;
        defer queue_create_infos.deinit(self.allocator);

        var unique_queue_families: std.AutoArrayHashMap(u32, void) = .init(self.allocator);
        defer unique_queue_families.deinit();
        try unique_queue_families.put(indices.graphics_compute_family.?, {});
        try unique_queue_families.put(indices.present_family.?, {});

        const queue_priority: f32 = 1.0;
        for (unique_queue_families.keys()) |queue_family| {
            try queue_create_infos.append(self.allocator, .{
                .queue_family_index = queue_family,
                .queue_count = 1,
                .p_queue_priorities = @ptrCast(&queue_priority),
            });
        }

        // Use the filtered queue families to create the device - add shader_int_8 to appease the vulkan overlords
        const device_features = self.physical_device.features;
        const vk12_features: vk.PhysicalDeviceVulkan12Features = .{
            .p_next = null,
            .shader_int_8 = .true,
        };

        const device_create_info: vk.DeviceCreateInfo = .{
            .queue_create_info_count = @intCast(queue_create_infos.items.len),
            .p_queue_create_infos = queue_create_infos.items.ptr,
            .p_enabled_features = &device_features,
            .enabled_layer_count = @intCast(vulkan.validation_layers.len),
            .pp_enabled_layer_names = &vulkan.validation_layers,
            .enabled_extension_count = @intCast(vulkan.device_extensions.len),
            .pp_enabled_extension_names = &vulkan.device_extensions,
            .p_next = &vk12_features,
        };

        const device = try self.instance.createDevice(
            self.physical_device.device,
            &device_create_info,
            null,
        );

        const vkd = try self.allocator.create(DeviceWrapper);
        vkd.* = DeviceWrapper.load(device, self.instance.wrapper.dispatch.vkGetDeviceProcAddr.?);
        self.logical_device = LogicalDevice.init(device, vkd);

        self.graphics_queue = .init(self.logical_device, indices.graphics_compute_family.?);
        self.present_queue = .init(self.logical_device, indices.present_family.?);
        self.compute_queue = .init(self.logical_device, indices.graphics_compute_family.?);
    }

    /// Creates a working swap chain based off of the window properties and chosen logical device.
    ///
    /// If free_old is true, then all of the swap chain lists and framebuffers are deallocated.
    fn createSwapchain(self: *Stone) !void {
        var swapchain_support: swapchain_.SwapchainSupportDetails = try .init(&self.physical_device, self.allocator);
        defer swapchain_support.deinit(self.allocator);
        self.swapchain = try .init(self, swapchain_support);

        const swapchain_images = try self.logical_device.getSwapchainImagesAllocKHR(
            self.swapchain.handle,
            self.allocator,
        );
        defer self.allocator.free(swapchain_images);

        self.swapchain_lists.images = try self.allocator.alloc(vk.Image, swapchain_images.len);
        for (swapchain_images, self.swapchain_lists.images) |swap_image, *image| {
            image.* = swap_image;
        }
    }

    /// Recreates the swapchain, rebuilding the render pass and pipeline to account for:
    /// - Window resizes
    /// - Minimization
    /// - Standard -> HDR shifts
    pub fn recreateSwapchain(self: *Stone) !void {
        // We only want to resize when the window size is valid (not minimized)
        var width: c_int = undefined;
        var height: c_int = undefined;
        glfw.getFramebufferSize(self.window, &width, &height);
        while (width == 0 or height == 0) {
            glfw.getFramebufferSize(self.window, &width, &height);
            glfw.waitEvents();
        }

        try self.logical_device.deviceWaitIdle();

        // Clean up everything that depends on the old swapchain
        self.swapchain.deinit(self);
        self.swapchain_lists.deinit(self.allocator);

        self.instance.destroySurfaceKHR(self.surface, null);
        self.graphics_pipeline.deinit(&self.logical_device);
        self.logical_device.destroyRenderPass(self.render_pass, null);

        // Rebuild the swapchain
        try self.createSurface();

        try self.createSwapchain();
        try self.createImageViews();

        try self.createRenderPass();
        try self.createGraphicsPipeline();
        try self.createFramebuffers();
    }

    /// Creates all swapchain image views for every image for target usage.
    fn createImageViews(self: *Stone) !void {
        self.swapchain_lists.image_views = try self.allocator.alloc(
            vk.ImageView,
            self.swapchain_lists.images.len,
        );

        for (
            self.swapchain_lists.image_views,
            self.swapchain_lists.images,
        ) |*image_view, image| {
            const image_view_create_info: vk.ImageViewCreateInfo = .{
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

    /// Tells vulkan about the framebuffer attachments that will be used.
    fn createRenderPass(self: *Stone) !void {
        const color_attachment = [_]vk.AttachmentDescription{.{
            .format = self.swapchain.image_format,
            .samples = .{
                .@"1_bit" = true,
            },
            .load_op = .clear,
            .store_op = .store,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .undefined,
            .final_layout = .present_src_khr,
        }};

        const color_attachment_ref = [_]vk.AttachmentReference{.{
            .attachment = 0,
            .layout = .color_attachment_optimal,
        }};

        const subpass = [_]vk.SubpassDescription{.{
            .pipeline_bind_point = .graphics,
            .color_attachment_count = @intCast(color_attachment_ref.len),
            .p_color_attachments = &color_attachment_ref,
        }};

        const subpass_dependencies = [_]vk.SubpassDependency{.{
            .src_subpass = ~@as(u32, 0),
            .dst_subpass = 0,
            .src_stage_mask = .{
                .color_attachment_output_bit = true,
            },
            .src_access_mask = .{},
            .dst_stage_mask = .{
                .color_attachment_output_bit = true,
            },
            .dst_access_mask = .{
                .color_attachment_write_bit = true,
            },
        }};

        // Creates the render pass object for use in the remainder of the program
        const render_pass_info: vk.RenderPassCreateInfo = .{
            .attachment_count = color_attachment.len,
            .p_attachments = &color_attachment,
            .subpass_count = subpass.len,
            .p_subpasses = &subpass,
            .dependency_count = subpass_dependencies.len,
            .p_dependencies = &subpass_dependencies,
        };

        self.render_pass = try self.logical_device.createRenderPass(
            &render_pass_info,
            null,
        );
    }

    /// Sets up the descriptor for the ubo in the vertex shader.
    fn createDescriptorSetLayout(self: *Stone) !void {
        const layout_bindings = [_]vk.DescriptorSetLayoutBinding{
            .{
                .binding = 0,
                .descriptor_type = .uniform_buffer,
                .descriptor_count = 1,
                .stage_flags = .{
                    // TODO: Bring me back when https://github.com/ziglang/zig/pull/24681
                    // .compute_bit = true,
                    .vertex_bit = true,
                },
                .p_immutable_samplers = null,
            },
            // TODO: Bring me back when https://github.com/ziglang/zig/pull/24681
            // .{
            //     .binding = 1,
            //     .descriptor_type = .storage_buffer,
            //     .descriptor_count = 1,
            //     .stage_flags = .{
            //         .compute_bit = true,
            //     },
            //     .p_immutable_samplers = null,
            // },
            // .{
            //     .binding = 2,
            //     .descriptor_type = .storage_buffer,
            //     .descriptor_count = 1,
            //     .stage_flags = .{
            //         .compute_bit = true,
            //     },
            //     .p_immutable_samplers = null,
            // },
        };

        const layout_info: vk.DescriptorSetLayoutCreateInfo = .{
            .binding_count = layout_bindings.len,
            .p_bindings = &layout_bindings,
        };

        self.descriptor_set_layout = try self.logical_device.createDescriptorSetLayout(
            &layout_info,
            null,
        );
    }

    /// Creates the graphics pipeline for the application.
    fn createGraphicsPipeline(self: *Stone) !void {
        self.graphics_pipeline = try .init(self);
    }

    /// Create the compute pipeline for the application.
    fn createComputePipeline(self: *Stone) !void {
        self.compute_pipeline = try .init(self);
    }

    /// Creates the swapchain's framebuffers.
    fn createFramebuffers(self: *Stone) !void {
        self.swapchain_lists.framebuffers = try self.allocator.alloc(
            vk.Framebuffer,
            self.swapchain_lists.image_views.len,
        );

        for (
            self.swapchain_lists.framebuffers,
            self.swapchain_lists.image_views,
        ) |*framebuffer, image_view| {
            const attachments = [_]vk.ImageView{image_view};

            const framebuffer_info: vk.FramebufferCreateInfo = .{
                .render_pass = self.render_pass,
                .attachment_count = @intCast(attachments.len),
                .p_attachments = &attachments,
                .width = self.swapchain.extent.width,
                .height = self.swapchain.extent.height,
                .layers = 1,
            };

            framebuffer.* = try self.logical_device.createFramebuffer(
                &framebuffer_info,
                null,
            );
        }
    }

    /// Creates the command pools which manage memory related to buffer storage.
    fn createCommandPool(self: *Stone) !void {
        const pool_info: vk.CommandPoolCreateInfo = .{
            .flags = .{
                .reset_command_buffer_bit = true,
            },
            .queue_family_index = self.graphics_queue.family,
        };

        self.command.pool = try self.logical_device.createCommandPool(
            &pool_info,
            null,
        );
    }

    /// Creates a new vertex buffer for storing GPU memory.
    fn createVertexBuffer(self: *Stone) !void {
        self.vertex_buffer = try .init(self);
    }

    /// Creates an index buffer for indexing into the vertex buffer.
    fn createIndexBuffer(self: *Stone) !void {
        self.index_buffer = try .init(self);
    }

    /// Allocates and sets the per-frame uniform buffers.
    fn createUniformBuffers(self: *Stone) !void {
        self.uniform_buffers = try .init(self);
    }

    /// Allocates and sets the compute shaders storage buffers.
    fn createStorageBuffers(self: *Stone) !void {
        // TODO: Bring me back when https://github.com/ziglang/zig/pull/24681
        if (true) return;
        self.storage_buffers = try .init(self);
    }

    /// Creates the descriptor set for binding uniform buffers in the shader.
    fn createDescriptorPool(self: *Stone) !void {
        const pool_sizes = [_]vk.DescriptorPoolSize{
            .{
                .type = .uniform_buffer,
                .descriptor_count = draw.max_frames_in_flight,
            },
            // TODO: Bring me back when https://github.com/ziglang/zig/pull/24681
            // .{
            //     .type = .storage_buffer,
            //     .descriptor_count = draw.max_frames_in_flight * 2,
            // },
        };

        const pool_info: vk.DescriptorPoolCreateInfo = .{
            .pool_size_count = pool_sizes.len,
            .p_pool_sizes = &pool_sizes,
            .max_sets = draw.max_frames_in_flight,
        };

        self.descriptor_pool = try self.logical_device.createDescriptorPool(
            &pool_info,
            null,
        );
    }

    /// Allocates and populates the pool's sets.
    fn createDescriptorSets(self: *Stone) !void {
        var layouts: [draw.max_frames_in_flight]vk.DescriptorSetLayout = @splat(self.descriptor_set_layout);
        const alloc_info: vk.DescriptorSetAllocateInfo = .{
            .descriptor_pool = self.descriptor_pool,
            .descriptor_set_count = draw.max_frames_in_flight,
            .p_set_layouts = &layouts,
        };

        self.descriptor_sets = try self.allocator.alloc(vk.DescriptorSet, draw.max_frames_in_flight);
        try self.logical_device.allocateDescriptorSets(
            &alloc_info,
            self.descriptor_sets.ptr,
        );

        inline for (0..draw.max_frames_in_flight) |i| {
            const ubo_buffer_info = [_]vk.DescriptorBufferInfo{.{
                .buffer = self.uniform_buffers.buffers[i].handle,
                .offset = 0,
                .range = @sizeOf(buffer.NativeUniformBufferObject),
            }};

            // TODO: Bring me back when https://github.com/ziglang/zig/pull/24681
            if (false) {
                const last_frame_buffer_info = [_]vk.DescriptorBufferInfo{.{
                    .buffer = self.storage_buffers.buffers[(i + draw.max_frames_in_flight - 1) % draw.max_frames_in_flight].handle,
                    .offset = 0,
                    .range = @sizeOf(buffer.NativeParticle) * buffer.max_particles,
                }};
                _ = last_frame_buffer_info;

                const current_frame_buffer_info = [_]vk.DescriptorBufferInfo{.{
                    .buffer = self.storage_buffers.buffers[i].handle,
                    .offset = 0,
                    .range = @sizeOf(buffer.NativeParticle) * buffer.max_particles,
                }};
                _ = current_frame_buffer_info;
            }

            const descriptor_writes = [_]vk.WriteDescriptorSet{
                .{
                    .dst_set = self.descriptor_sets[i],
                    .dst_binding = 0,
                    .dst_array_element = 0,
                    .descriptor_type = .uniform_buffer,
                    .descriptor_count = ubo_buffer_info.len,
                    .p_buffer_info = &ubo_buffer_info,
                    .p_image_info = @ptrCast(@alignCast(&undefined)),
                    .p_texel_buffer_view = @ptrCast(@alignCast(&undefined)),
                },
                // TODO: Bring me back when https://github.com/ziglang/zig/pull/24681
                // .{
                //     .dst_set = self.descriptor_sets[i],
                //     .dst_binding = 1,
                //     .dst_array_element = 0,
                //     .descriptor_type = .storage_buffer,
                //     .descriptor_count = last_frame_buffer_info.len,
                //     .p_buffer_info = &last_frame_buffer_info,
                //     .p_image_info = @ptrCast(@alignCast(&undefined)),
                //     .p_texel_buffer_view = @ptrCast(@alignCast(&undefined)),
                // },
                // .{
                //     .dst_set = self.descriptor_sets[i],
                //     .dst_binding = 2,
                //     .dst_array_element = 0,
                //     .descriptor_type = .storage_buffer,
                //     .descriptor_count = current_frame_buffer_info.len,
                //     .p_buffer_info = &current_frame_buffer_info,
                //     .p_image_info = @ptrCast(@alignCast(&undefined)),
                //     .p_texel_buffer_view = @ptrCast(@alignCast(&undefined)),
                // },
            };

            self.logical_device.updateDescriptorSets(
                descriptor_writes.len,
                &descriptor_writes,
                0,
                null,
            );
        }
    }

    /// Creates the applications command buffer whose lifetime is tied to the command pool.
    fn createCommandBuffers(self: *Stone) !void {
        self.command = try .init(self);
    }

    /// Creates the synchronous objects required for Vulkan to work properly.
    pub fn createSyncObjects(self: *Stone) !void {
        self.syncs = try .init(self);
    }
};



// root.zig

pub const vk = @import("vulkan");

pub const vert_spv align(@alignOf(u32)) = @embedFile("vertex_shader").*;
pub const frag_spv align(@alignOf(u32)) = @embedFile("fragment_shader").*;

pub const glfw = @import("rendering/glfw.zig");
pub const vulkan = @import("rendering/vulkan/vulkan.zig");
pub const Stone = @import("launcher.zig").Stone;



// glfw.zig

const vulkan = @import("vulkan/vulkan.zig");
const vk = vulkan.lib;

pub const c = @cImport({
    @cDefine("GLFW_INCLUDE_NONE", {});
    @cInclude("glfw3.h");
});

pub const Error = error{
    LibraryInitFailed,
    WindowInitializationFailed,
    NoVulkan,
};

pub const @"true" = c.GLFW_TRUE;
pub const @"false" = c.GLFW_FALSE;

pub const client_api = c.GLFW_CLIENT_API;
pub const no_api = c.GLFW_NO_API;
pub const resizable = c.GLFW_RESIZABLE;

pub const Window = c.GLFWwindow;

pub const init = c.glfwInit;
pub const terminate = c.glfwTerminate;
pub const vulkanSupported = c.glfwVulkanSupported;
pub const windowHint = c.glfwWindowHint;
pub const createWindow = c.glfwCreateWindow;
pub const destroyWindow = c.glfwDestroyWindow;
pub const windowShouldClose = c.glfwWindowShouldClose;
pub const getRequiredInstanceExtensions = c.glfwGetRequiredInstanceExtensions;
pub const getFramebufferSize = c.glfwGetFramebufferSize;
pub const pollEvents = c.glfwPollEvents;
pub const waitEvents = c.glfwWaitEvents;
pub const setWindowUserPointer = c.glfwSetWindowUserPointer;
pub const getWindowUserPointer = c.glfwGetWindowUserPointer;
pub const setFramebufferSizeCallback = c.glfwSetFramebufferSizeCallback;

// usually the GLFW vulkan functions are exported if Vulkan is included,
// but since thats not the case here, they are manually imported.

extern fn glfwGetInstanceProcAddress(instance: vk.Instance, procname: [*:0]const u8) vk.PfnVoidFunction;
pub const getInstanceProcAddress = glfwGetInstanceProcAddress;
extern fn glfwGetPhysicalDevicePresentationSupport(instance: vk.Instance, pdev: vk.PhysicalDevice, queuefamily: u32) c_int;
pub const getPhysicalDevicePresentationSupport = glfwGetPhysicalDevicePresentationSupport;
extern fn glfwCreateWindowSurface(instance: vk.Instance, window: *Window, allocation_callbacks: ?*const vk.AllocationCallbacks, surface: *vk.SurfaceKHR) vk.Result;
pub const createWindowSurface = glfwCreateWindowSurface;



// buffer.zig

const std = @import("std");

const vulkan = @import("vulkan.zig");
const vk = vulkan.lib;

const glfw = @import("../glfw.zig");

const launcher = @import("../../launcher.zig");

const pipeline = @import("pipeline.zig");
const draw = @import("draw.zig");

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
    dt: f32,
    model: NativeMat4 align(16),
    view: NativeMat4 align(16),
    proj: NativeMat4 align(16),

    pub fn init(op: OpUniformBufferObject) NativeUniformBufferObject {
        return .{
            .dt = op.dt,
            .model = opToNative(op.model),
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
    model: OpMat4 = .splat(0.0),
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

pub const OpParticle = struct {
    position: pipeline.Vec2,
    velocity: pipeline.Vec2,
    color: pipeline.Vec4,

    /// Creates n particles with random initial conditions.
    ///
    /// The caller is responsible for freeing the slice.
    pub fn spawn(allocator: std.mem.Allocator, seed: u64, n: usize) ![]OpParticle {
        const particles = try allocator.alloc(OpParticle, n);

        var prng: std.Random.DefaultPrng = .init(seed);
        const random = prng.random();

        const h_float: f32 = @floatFromInt(launcher.initial_window_height);
        const w_float: f32 = @floatFromInt(launcher.initial_window_width);

        for (particles) |*particle| {
            const r = 0.25 * @sqrt(random.float(f32));
            const theta = random.float(f32) * 2 * std.math.pi;
            const x = r * @cos(theta) * (h_float / w_float);
            const y = r * @sin(theta);

            const position: pipeline.Vec2 = .init(.{ x, y });
            particle.position = position;
            particle.velocity = position.normalize().scale(0.00025);
            particle.color = .init(.{
                random.float(f32),
                random.float(f32),
                random.float(f32),
                1.0,
            });
        }

        return particles;
    }
};

pub const workgroup_load = 256;
pub const max_particles = workgroup_load * 32;

const NativeVec2 = pipeline.Vec2.VecType;
const NativeVec3 = pipeline.Vec3.VecType;
const NativeVec4 = pipeline.Vec4.VecType;
pub const NativeParticle = struct {
    position: NativeVec2,
    velocity: NativeVec2,
    color: NativeVec4,

    pub fn init(op: OpParticle) NativeParticle {
        return .{
            .position = op.position.vec,
            .velocity = op.velocity.vec,
            .color = op.color.vec,
        };
    }
};

pub const StorageBuffers = struct {
    buffers: []Buffer,

    pub fn init(stone: *launcher.Stone) !StorageBuffers {
        const buffer_size = @sizeOf(NativeParticle) * max_particles;

        var self: StorageBuffers = undefined;
        self.buffers = try stone.allocator.alloc(Buffer, draw.max_frames_in_flight);

        // Initialize particles with random initial positions
        const op_particles = try OpParticle.spawn(
            stone.allocator,
            @bitCast(stone.timestep.start_time_us),
            max_particles,
        );
        defer stone.allocator.free(op_particles);

        const native_particles = try stone.allocator.alloc(
            NativeParticle,
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

        const casted: [*]NativeParticle = @ptrCast(@alignCast(data));
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



// draw.zig

const std = @import("std");

const vulkan = @import("vulkan.zig");
const vk = vulkan.lib;

const core = @import("core");

const glfw = @import("../glfw.zig");

const launcher = @import("../../launcher.zig");

const pipeline = @import("pipeline.zig");
const buffer_ = @import("buffer.zig");

pub const max_frames_in_flight = 2;

pub const Command = struct {
    pool: vk.CommandPool = undefined,
    buffers: []vk.CommandBuffer = undefined,
    compute_buffers: []vk.CommandBuffer = undefined,

    pub fn init(stone: *launcher.Stone) !Command {
        var self: Command = .{};

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

        std.debug.assert(scissors.len == stone.graphics_pipeline.scissor_count);
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
            pipeline.index_type,
        );

        stone.logical_device.cmdBindDescriptorSets(
            buffer,
            .graphics,
            stone.graphics_pipeline.layout,
            0,
            1,
            @ptrCast(&stone.descriptor_sets[current_frame]),
            0,
            null,
        );

        stone.logical_device.cmdDrawIndexed(
            buffer,
            @intCast(pipeline.indices.len),
            1,
            0,
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

    updateUniformBuffer(stone, current_frame);

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
    const dt = stone.timestep.elapsed(f32);

    const width: f32 = @floatFromInt(stone.swapchain.extent.width);
    const height: f32 = @floatFromInt(stone.swapchain.extent.height);

    const ubo: buffer_.OpUniformBufferObject = .{
        .dt = stone.timestep.dt,
        .model = core.mat.rotate(
            f32,
            comptime .identity(1.0),
            @rem(dt * std.math.degreesToRadians(90.0), 360.0),
            .init(.{ 0.0, 0.0, 1.0 }),
        ),
        .view = core.mat.lookAt(
            f32,
            comptime .splat(2.0),
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
    const casted: *buffer_.NativeUniformBufferObject = @ptrCast(@alignCast(mem));
    casted.* = .init(ubo);
}



// pipeline.zig

const std = @import("std");

const core = @import("core");
pub const Vec2 = core.Vector(f32, 2);
pub const Vec3 = core.Vector(f32, 3);
pub const Vec4 = core.Vector(f32, 4);
pub const Mat4 = core.Matrix(f32, 4, 4);

const vulkan = @import("vulkan.zig");
const vk = vulkan.lib;

const glfw = @import("../glfw.zig");

const launcher = @import("../../launcher.zig");

const vertex_shader_bytes align(@alignOf(u32)) = @embedFile("vertex_shader").*;
const fragment_shader_bytes align(@alignOf(u32)) = @embedFile("fragment_shader").*;
const compute_shader_bytes align(@alignOf(u32)) = @embedFile("compute_shader").*;

const ShaderModuleType = enum {
    vertex,
    fragment,
    compute,
};

const ShaderModule = struct { [*]const u32, usize };
const vertex_shader: ShaderModule = .{ @ptrCast(&vertex_shader_bytes), vertex_shader_bytes.len };
const fragment_shader: ShaderModule = .{ @ptrCast(&fragment_shader_bytes), fragment_shader_bytes.len };
const compute_shader: ShaderModule = .{ @ptrCast(&compute_shader_bytes), compute_shader_bytes.len };

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
        .compute => compute_shader,
    };

    const shader_create_info: vk.ShaderModuleCreateInfo = .{
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

        // Create the vertex and fragment shader modules
        const vert = try createShaderModule(stone, .vertex);
        defer stone.logical_device.destroyShaderModule(vert, null);

        const vert_stage_info: vk.PipelineShaderStageCreateInfo = .{
            .stage = .{
                .vertex_bit = true,
            },
            .module = vert,
            .p_name = "main",
        };

        const frag = try createShaderModule(stone, .fragment);
        defer stone.logical_device.destroyShaderModule(frag, null);

        const frag_stage_info: vk.PipelineShaderStageCreateInfo = .{
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

        // Create all graphics pipeline related bindings, attributes, and assemblies
        const binding = Vertex.bindingDescription();
        const attributes = Vertex.attributeDescriptions();
        const vertex_input_info: vk.PipelineVertexInputStateCreateInfo = .{
            .vertex_binding_description_count = 1,
            .p_vertex_binding_descriptions = @ptrCast(&binding),
            .vertex_attribute_description_count = attributes.len,
            .p_vertex_attribute_descriptions = &attributes,
        };

        const input_assembly: vk.PipelineInputAssemblyStateCreateInfo = .{
            .topology = .triangle_list,
            .primitive_restart_enable = .false,
        };

        // This allows us to change a small subset of the pipeline with recreating it
        const dynamic_state: vk.PipelineDynamicStateCreateInfo = .{
            .dynamic_state_count = @intCast(vulkan.dynamic_states.len),
            .p_dynamic_states = &vulkan.dynamic_states,
        };

        // Since dynamic states are used, we need only specify viewport/scissor at creation time
        self.viewport_count = 1;
        self.scissor_count = 1;
        const viewport_state: vk.PipelineViewportStateCreateInfo = .{
            .viewport_count = @intCast(self.viewport_count),
            .scissor_count = @intCast(self.scissor_count),
        };

        const rasterizer: vk.PipelineRasterizationStateCreateInfo = .{
            .depth_clamp_enable = .false,
            .rasterizer_discard_enable = .false,

            .polygon_mode = .fill,
            .line_width = 1.0,

            .cull_mode = .{
                .back_bit = true,
            },
            .front_face = .counter_clockwise,

            .depth_bias_enable = .false,
            .depth_bias_constant_factor = 0.0,
            .depth_bias_clamp = 0.0,
            .depth_bias_slope_factor = 0.0,
        };

        // Configures multisampling - approach to anti-aliasing. Disabled for now
        const multisampling: vk.PipelineMultisampleStateCreateInfo = .{
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
            .logic_op_enable = .false,
            .logic_op = .copy,
            .attachment_count = @intCast(color_blend_attachment.len),
            .p_attachments = &color_blend_attachment,
            .blend_constants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        const pipeline_layout_info: vk.PipelineLayoutCreateInfo = .{
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&stone.descriptor_set_layout),
            .push_constant_range_count = 0,
            .p_push_constant_ranges = null,
        };

        // Create the pipeline layout but destroy if we fail at some point
        self.layout = try stone.logical_device.createPipelineLayout(
            &pipeline_layout_info,
            null,
        );

        const pipeline_info = [_]vk.GraphicsPipelineCreateInfo{.{
            .stage_count = shader_stages.len,
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

pub const Compute = struct {
    pipeline: vk.Pipeline = undefined,
    layout: vk.PipelineLayout = undefined,

    pub fn init(stone: *launcher.Stone) !Compute {
        var self: Compute = undefined;

        // TODO: Bring me back when https://github.com/ziglang/zig/pull/24681
        if (true) {
            return self;
        }

        const compute = try createShaderModule(stone, .compute);
        defer stone.logical_device.destroyShaderModule(compute, null);

        const compute_stage_info: vk.PipelineShaderStageCreateInfo = .{
            .stage = .{
                .compute_bit = true,
            },
            .module = compute,
            .p_name = "main",
        };

        const pipeline_layout_info: vk.PipelineLayoutCreateInfo = .{
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&stone.descriptor_set_layout),
            .push_constant_range_count = 0,
            .p_push_constant_ranges = null,
        };

        self.layout = try stone.logical_device.createPipelineLayout(
            &pipeline_layout_info,
            null,
        );

        const pipeline_info: vk.ComputePipelineCreateInfo = .{
            .layout = self.layout,
            .stage = compute_stage_info,
            .base_pipeline_index = 0,
        };

        const result = try stone.logical_device.createComputePipelines(
            .null_handle,
            1,
            @ptrCast(&pipeline_info),
            null,
            @ptrCast(&self.pipeline),
        );

        return if (result != .success) error.PipelineCreateFailed else self;
    }

    pub fn deinit(self: *Compute, logical_device: *vk.DeviceProxy) void {
        // TODO: Bring me back when https://github.com/ziglang/zig/pull/24681
        if (true) {
            return;
        }

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
        .pos = Vec2.decay(.{ -0.5, -0.5 }),
        .color = Vec3.decay(.{ 1.0, 0.0, 0.0 }),
    },
    .{
        .pos = Vec2.decay(.{ 0.5, -0.5 }),
        .color = Vec3.decay(.{ 0.0, 1.0, 0.0 }),
    },
    .{
        .pos = Vec2.decay(.{ 0.5, 0.5 }),
        .color = Vec3.decay(.{ 0.0, 0.0, 1.0 }),
    },
    .{
        .pos = Vec2.decay(.{ -0.5, 0.5 }),
        .color = Vec3.decay(.{ 1.0, 1.0, 1.0 }),
    },
};
pub const vertices_size = @sizeOf(@TypeOf(vertices));

pub const indices = [_]u16{ 0, 1, 2, 2, 3, 0 };
pub const indices_size = @sizeOf(@TypeOf(indices));
pub const index_type: vk.IndexType = blk: {
    switch (@typeInfo(@TypeOf(indices))) {
        .array => |a| {
            switch (@typeInfo(a.child)) {
                .int => |int| {
                    if (int.signedness == .signed) {
                        @compileError("indices must have unsigned int child type");
                    }

                    break :blk switch (int.bits) {
                        8 => .uint8,
                        16 => .uint16,
                        32 => .uint32,
                        else => @compileError("indices child type must be 8, 16, or 32 bit unsigned int"),
                    };
                },
                else => @compileError("indices must have int child type"),
            }
        },
        else => @compileError("indices must be a compile time array"),
    }
};



// swapchain.zig

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

    pub fn deinit(self: Swapchain, stone: *launcher.Stone) void {
        defer stone.logical_device.destroySwapchainKHR(self.handle, null);

        for (stone.swapchain_lists.framebuffers) |framebuffer| {
            stone.logical_device.destroyFramebuffer(framebuffer, null);
        }

        for (stone.swapchain_lists.image_views) |image_view| {
            stone.logical_device.destroyImageView(image_view, null);
        }
    }
};

pub const SwapchainLists = struct {
    images: []vk.Image = undefined,
    image_views: []vk.ImageView = undefined,
    framebuffers: []vk.Framebuffer = undefined,

    pub fn deinit(self: *SwapchainLists, allocator: std.mem.Allocator) void {
        allocator.free(self.images);
        allocator.free(self.image_views);
        allocator.free(self.framebuffers);
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
    pub fn init(device: *vulkan.DeviceCandidate, allocator: std.mem.Allocator) !SwapchainSupportDetails {
        var self: SwapchainSupportDetails = .{
            .device = device,
        };

        const p_dev = device.device;
        const surface = device.surface;

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

    pub fn deinit(self: *SwapchainSupportDetails, allocator: std.mem.Allocator) void {
        allocator.free(self.formats);
        allocator.free(self.present_modes);
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



// sync.zig

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

    compute_finished_semaphores: []vk.Semaphore = undefined,
    compute_in_flight_fences: []vk.Fence = undefined,

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

        self.compute_finished_semaphores = try stone.allocator.alloc(vk.Semaphore, draw.max_frames_in_flight);
        self.compute_in_flight_fences = try stone.allocator.alloc(vk.Fence, draw.max_frames_in_flight);

        for (
            self.image_available_semaphores,
            self.render_finished_semaphores,
            self.in_flight_fences,
            self.compute_finished_semaphores,
            self.compute_in_flight_fences,
        ) |*ias, *rfs, *iff, *cfs, *cff| {
            // Graphics
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

            // Compute
            cfs.* = try stone.logical_device.createSemaphore(
                &semaphore_info,
                null,
            );

            cff.* = try stone.logical_device.createFence(
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

            allocator.free(self.compute_finished_semaphores);
            allocator.free(self.compute_in_flight_fences);
        }

        for (
            self.image_available_semaphores,
            self.render_finished_semaphores,
            self.in_flight_fences,
            self.compute_finished_semaphores,
            self.compute_in_flight_fences,
        ) |ias, rfs, iff, cfs, cff| {
            logical_device.destroySemaphore(ias, null);
            logical_device.destroySemaphore(rfs, null);
            logical_device.destroyFence(iff, null);

            logical_device.destroySemaphore(cfs, null);
            logical_device.destroyFence(cff, null);
        }
    }
};



// vulkan.zig

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
    device: lib.PhysicalDevice,
    properties: lib.PhysicalDeviceProperties,
    features: lib.PhysicalDeviceFeatures,

    instance: lib.InstanceProxy,
    surface: lib.SurfaceKHR,

    /// Creates a candidate out of a device.
    pub fn init(
        instance: lib.InstanceProxy,
        surface: lib.SurfaceKHR,
        device: lib.PhysicalDevice,
    ) DeviceCandidate {
        return .{
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

    pub fn findQueueFamilies(self: DeviceCandidate, allocator: std.mem.Allocator) !QueueFamilyIndices {
        var indices: QueueFamilyIndices = .{};

        const queue_families = try self.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(
            self.device,
            allocator,
        );
        defer allocator.free(queue_families);

        for (queue_families, 0..) |queue_family, i| {
            const i_casted: u32 = @intCast(i);
            if (queue_family.queue_flags.graphics_bit and queue_family.queue_flags.compute_bit) {
                indices.graphics_compute_family = i_casted;
            }

            if ((try self.instance.getPhysicalDeviceSurfaceSupportKHR(
                self.device,
                i_casted,
                self.surface,
            )) == .true) {
                indices.present_family = i_casted;
            }

            if (indices.complete()) break;
        }

        return indices;
    }

    /// Verifies the specified extensions are present for the device.
    pub fn checkDeviceExtensionSupport(self: DeviceCandidate, allocator: std.mem.Allocator) !bool {
        const available_extensions = try self.instance.enumerateDeviceExtensionPropertiesAlloc(
            self.device,
            null,
            allocator,
        );
        defer allocator.free(available_extensions);

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
    pub fn suitable(self: *DeviceCandidate, allocator: std.mem.Allocator) !bool {
        const indices = try self.findQueueFamilies(allocator);
        const supported_exts = try self.checkDeviceExtensionSupport(allocator);

        // Only check for the swap chain support if extensions pass
        var swapchain_ok = false;
        if (supported_exts) {
            var swapchain_support: swapchain.SwapchainSupportDetails = try .init(self, allocator);
            defer swapchain_support.deinit(allocator);

            swapchain_ok = swapchain_support.formats.len != 0 and swapchain_support.present_modes.len != 0;
        }

        return indices.complete() and supported_exts and swapchain_ok;
    }
};

pub const QueueFamilyIndices = struct {
    graphics_compute_family: ?u32 = null,
    present_family: ?u32 = null,

    pub fn complete(self: QueueFamilyIndices) bool {
        return self.graphics_compute_family != null and self.present_family != null;
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



// compute.zig

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



// fragment.zig

const std = @import("std");
const gpu = std.gpu;

extern const frag_color: @Vector(3, f32) addrspace(.input);
extern var out_color: @Vector(4, f32) addrspace(.output);

export fn main() callconv(.spirv_fragment) void {
    gpu.location(&frag_color, 0);
    gpu.location(&out_color, 0);

    out_color = .{ frag_color[0], frag_color[1], frag_color[2], 1.0 };
}



// vertex.zig

const std = @import("std");
const gpu = std.gpu;

const core = @import("core/root.zig");
const Mat4 = core.common.Mat4;
const Vec4 = core.common.Vec4;
const UniformBufferObject = core.UniformBufferObject;

extern const ubo: UniformBufferObject addrspace(.uniform);

extern const in_position: @Vector(2, f32) addrspace(.input);
extern const in_color: @Vector(3, f32) addrspace(.input);

extern var frag_color: @Vector(3, f32) addrspace(.output);

export fn main() callconv(.spirv_vertex) void {
    gpu.location(&in_position, 0);
    gpu.location(&in_color, 1);
    gpu.location(&frag_color, 0);
    gpu.binding(&ubo, 0, 0);

    const position: Vec4 = .init(.{ in_position[0], in_position[1], 0.0, 1.0 });
    const perspective = ubo.proj.mul(ubo.view).mul(ubo.model);
    gpu.position_out.* = perspective.mulVec(position).raw;

    frag_color = in_color;
}



// root.zig

pub const common = @import("math/common.zig");

pub const UniformBufferObject = extern struct {
    delta_time: f32,
    model: common.Mat4,
    view: common.Mat4,
    proj: common.Mat4,
};

test {
    _ = @import("math/common.zig");
}



// common.zig

pub const Particle = extern struct {
    position: Vec2,
    velocity: Vec2,
    color: Vec4,
};

/// A minimal, SIMD-native 3D Vector representation, aligning with the core module.
pub const Vec2 = extern struct {
    raw: @Vector(2, f32),

    pub fn init(vals: [2]f32) Vec2 {
        var out: Vec2 = undefined;
        inline for (0..2) |i| {
            out.raw[i] = vals[i];
        }
        return out;
    }

    pub fn splat(val: f32) Vec2 {
        return .{ .raw = @splat(val) };
    }

    pub fn dot(self: Vec2, other: Vec2) f32 {
        return @reduce(.Add, self.raw * other.raw);
    }

    pub fn scale(self: Vec2, val: f32) Vec2 {
        return .{
            .raw = self.raw * splat(val).raw,
        };
    }

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .raw = a.raw + b.raw };
    }
};

/// A minimal, SIMD-native 3D Vector representation, aligning with the core module.
pub const Vec3 = extern struct {
    raw: @Vector(3, f32),

    pub fn init(vals: [3]f32) Vec3 {
        var out: Vec3 = undefined;
        inline for (0..3) |i| {
            out.raw[i] = vals[i];
        }
        return out;
    }

    pub fn splat(val: f32) Vec3 {
        return .{ .raw = @splat(val) };
    }

    pub fn dot(self: Vec3, other: Vec3) f32 {
        return @reduce(.Add, self.raw * other.raw);
    }

    pub fn scale(self: Vec3, val: f32) Vec3 {
        return .{
            .raw = self.raw * splat(val).raw,
        };
    }
};

/// A minimal, SIMD-native 4D Vector representation, aligning with the core module.
pub const Vec4 = extern struct {
    raw: @Vector(4, f32),

    pub fn init(vals: [4]f32) Vec4 {
        var out: Vec4 = undefined;
        inline for (0..4) |i| {
            out.raw[i] = vals[i];
        }
        return out;
    }

    pub fn splat(val: f32) Vec4 {
        return .{ .raw = @splat(val) };
    }

    pub fn dot(self: Vec4, other: Vec4) f32 {
        return @reduce(.Add, self.raw * other.raw);
    }

    pub fn scale(self: Vec4, val: f32) Vec4 {
        return .{
            .raw = self.raw * splat(val).raw,
        };
    }
};

/// A minimal, SIMD-native 4D Matrix representation, aligning with the core module.
pub const Mat4 = extern struct {
    raw: [4]Vec4,

    /// Performs matrix-matrix multiplication with the given vec.
    pub fn mulVec(self: Mat4, vec: Vec4) Vec4 {
        var out: Vec4 = undefined;
        inline for (0..4) |i| {
            out.raw[i] = self.raw[i].dot(vec);
        }
        return out;
    }

    /// Performs matrix-matrix multiplication with the given mat.
    pub fn mul(self: Mat4, other: Mat4) Mat4 {
        var out: Mat4 = undefined;
        const other_T = other.transpose();
        inline for (0..4) |i| {
            inline for (0..4) |k| {
                out.raw[i].raw[k] = self.raw[i].dot(other_T.raw[k]);
            }
        }
        return out;
    }

    /// Transposes the matrix, [i][j] maps to [j][i].
    pub fn transpose(self: Mat4) Mat4 {
        var out: Mat4 = undefined;
        inline for (0..4) |i| {
            inline for (0..4) |j| {
                out.raw[j].raw[i] = self.raw[i].raw[j];
            }
        }
        return out;
    }

    fn dimsFrom(idx: usize) struct { usize, usize } {
        const row: usize = @divFloor(idx, 4);
        const col = idx % 4;
        return .{ row, col };
    }

    /// Provides immutable element index into the matrix.
    pub fn at(self: *const Mat4, idx: usize) f32 {
        const row, const col = dimsFrom(idx);
        return self.mat[row].vec[col];
    }

    /// Provides mutable element index into the matrix.
    pub fn ptrAt(self: *Mat4, idx: usize) *f32 {
        const row, const col = dimsFrom(idx);
        return &self.mat[row].vec[col];
    }
};

const testing = @import("std").testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualSlices = testing.expectEqualSlices;
const expectApproxEqAbs = testing.expectApproxEqAbs;

const epsilon = 1e-6;

test "Vec basic operations" {
    const a2: Vec2 = .init(.{ 1.0, 2.0 });
    const b2: Vec2 = .init(.{ 2.0, 0.0 });
    try expectApproxEqAbs(1 * 2 + 2 * 0, a2.dot(b2), epsilon);
    try expectApproxEqAbs(1 * 1 + 2 * 2, a2.dot(a2), epsilon);

    const a3: Vec3 = .init(.{ 1.0, 2.0, 3.0 });
    const b3: Vec3 = .init(.{ 2.0, 0.0, 1.0 });
    try expectApproxEqAbs(1 * 2 + 2 * 0 + 3 * 1, a3.dot(b3), epsilon);
    try expectApproxEqAbs(1 * 1 + 2 * 2 + 3 * 3, a3.dot(a3), epsilon);

    const a4: Vec4 = .init(.{ 1.0, 2.0, 3.0, 4.0 });
    const b4: Vec4 = .init(.{ 2.0, 0.0, 1.0, 3.0 });

    try expectApproxEqAbs(1 * 2 + 2 * 0 + 3 * 1 + 4 * 3, a4.dot(b4), epsilon);
    try expectApproxEqAbs(1 * 1 + 2 * 2 + 3 * 3 + 4 * 4, a4.dot(a4), epsilon);
}

test "Mat4 transpose and multiplication" {
    const row0: Vec4 = .init(.{ 1, 2, 3, 4 });
    const row1: Vec4 = .init(.{ 5, 6, 7, 8 });
    const row2: Vec4 = .init(.{ 9, 10, 11, 12 });
    const row3: Vec4 = .init(.{ 13, 14, 15, 16 });
    const mat: Mat4 = .{ .raw = .{ row0, row1, row2, row3 } };

    const transposed = mat.transpose();

    try expectApproxEqAbs(5, transposed.raw[0].raw[1], epsilon);
    try expectApproxEqAbs(2, transposed.raw[1].raw[0], epsilon);
    try expectApproxEqAbs(15, transposed.raw[2].raw[3], epsilon);

    const vec = Vec4.init(.{ 1, 1, 1, 1 });
    const result = mat.mulVec(vec);
    try expectApproxEqAbs(10, result.raw[0], epsilon);
    try expectApproxEqAbs(26, result.raw[1], epsilon);
    try expectApproxEqAbs(42, result.raw[2], epsilon);
    try expectApproxEqAbs(58, result.raw[3], epsilon);
}

