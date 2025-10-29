const std = @import("std");

const config = @import("config");

const glfw = @import("rendering/glfw.zig");

const vulkan = @import("rendering/vulkan/vulkan.zig");
const swapchain_ = @import("rendering/vulkan/swapchain.zig");
const pipeline = @import("rendering/vulkan/pipeline.zig");
const draw = @import("rendering/vulkan/draw.zig");
const sync = @import("rendering/vulkan/sync.zig");

const vk = vulkan.lib;
const BaseWrapper = vk.BaseWrapper;
const InstanceWrapper = vk.InstanceWrapper;
const DeviceWrapper = vk.DeviceWrapper;

const Instance = vk.InstanceProxy;
const LogicalDevice = vk.DeviceProxy;

const app_name = "Stone";

const window_width: u32 = 800;
const window_height: u32 = 600;

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

    swapchain: swapchain_.Swapchain = undefined,
    swapchain_lists: swapchain_.SwapchainLists = .{},
    framebuffer_resized: bool = false,

    render_pass: vk.RenderPass = undefined,
    graphics_pipeline: pipeline.Graphics = undefined,

    command: draw.Command = undefined,
    syncs: sync.Syncs = undefined,

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
            glfw.destroyWindow(self.window);

            self.swapchain_lists.deinit(self.allocator);
            self.command.deinit(self.allocator);

            self.allocator.destroy(self.logical_device.wrapper);
            self.allocator.destroy(self.instance.wrapper);
            glfw.terminate();
        }

        self.syncs.deinit(self.allocator, &self.logical_device);
        self.logical_device.destroyCommandPool(self.command.pool, null);

        self.graphics_pipeline.deinit(&self.logical_device);
        self.logical_device.destroyRenderPass(self.render_pass, null);

        self.swapchain.deinit(self);
        self.logical_device.destroyDevice(null);
        self.instance.destroySurfaceKHR(self.surface, null);

        if (vulkan.enable_validation_layers) {
            self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
        }
        self.instance.destroyInstance(null);
    }

    pub fn run(self: *Stone) !void {
        while (glfw.windowShouldClose(self.window) != glfw.true) {
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
            window_width,
            window_height,
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
        try self.createGraphicsPipeline();
        try self.createFramebuffers();

        try self.createCommandPool();
        try self.createCommandBuffers();
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
            .s_type = .application_info,
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

        // Use the filtered queue families to create the device - add shader_int_8 to appease the vulkan overlords
        const device_features = self.physical_device.features;
        const vk12_features: vk.PhysicalDeviceVulkan12Features = .{
            .s_type = .physical_device_vulkan_1_2_features,
            .p_next = null,
            .shader_int_8 = .true,
        };

        const device_create_info: vk.DeviceCreateInfo = .{
            .s_type = .device_create_info,
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

        self.graphics_queue = .init(self.logical_device, indices.graphics_family.?);
        self.present_queue = .init(self.logical_device, indices.present_family.?);
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

        // Creates the render pass object for use in the remainder of the program
        const render_pass_info: vk.RenderPassCreateInfo = .{
            .s_type = .render_pass_create_info,
            .attachment_count = @intCast(color_attachment.len),
            .p_attachments = &color_attachment,
            .subpass_count = @intCast(subpass.len),
            .p_subpasses = &subpass,
        };

        self.render_pass = try self.logical_device.createRenderPass(
            &render_pass_info,
            null,
        );
    }

    /// Creates the graphics pipeline for the application.
    fn createGraphicsPipeline(self: *Stone) !void {
        self.graphics_pipeline = try .init(self);
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
                .s_type = .framebuffer_create_info,
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
            .s_type = .command_pool_create_info,
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

    /// Creates the applications command buffer whose lifetime is tied to the command pool.
    fn createCommandBuffers(self: *Stone) !void {
        self.command.buffers = try self.allocator.alloc(vk.CommandBuffer, draw.max_frames_in_flight);
        const alloc_info: vk.CommandBufferAllocateInfo = .{
            .s_type = .command_buffer_allocate_info,
            .command_pool = self.command.pool,
            .level = .primary,
            .command_buffer_count = @intCast(self.command.buffers.len),
        };

        try self.logical_device.allocateCommandBuffers(
            &alloc_info,
            self.command.buffers.ptr,
        );
    }

    /// Creates the synchronous objects required for Vulkan to work properly.
    pub fn createSyncObjects(self: *Stone) !void {
        self.syncs = try .init(self);
    }
};
