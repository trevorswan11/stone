const std = @import("std");

const config = @import("config");

const glfw = @import("rendering/backend/glfw.zig");
const vulkan = @import("rendering/backend/vulkan.zig");

const vk = vulkan.lib;
const BaseWrapper = vk.BaseWrapper;
const InstanceWrapper = vk.InstanceWrapper;
const DeviceWrapper = vk.DeviceWrapper;

const Instance = vk.InstanceProxy;
const LogicalDevice = vk.DeviceProxy;

const app_name = "Stone";

const window_width: u32 = 800;
const window_height: u32 = 600;

pub const Stone = struct {
    allocator: std.mem.Allocator,

    window: *glfw.Window = undefined,

    enabled_layers: std.ArrayList([*:0]const u8) = .empty,

    vkb: BaseWrapper = undefined,
    instance: Instance = undefined,
    debug_messenger: vk.DebugUtilsMessengerEXT = undefined,
    surface: vk.SurfaceKHR = undefined,

    physical_device: vulkan.DeviceCandidate = undefined,
    logical_device: LogicalDevice = undefined,

    graphics_queue: vulkan.Queue = undefined,
    present_queue: vulkan.Queue = undefined,

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
            self.enabled_layers.deinit(self.allocator);
            self.allocator.destroy(self.logical_device.wrapper);
            self.allocator.destroy(self.instance.wrapper);
            glfw.terminate();
        }

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

        try self.enabled_layers.appendSlice(self.allocator, &vulkan.validation_layers);

        var extensions = try self.getRequiredExtensions();
        defer extensions.deinit(self.allocator);

        const instance = try self.vkb.createInstance(
            &.{
                .p_application_info = &app_info,
                .enabled_extension_count = @intCast(extensions.items.len),
                .pp_enabled_extension_names = extensions.items.ptr,
                .enabled_layer_count = @intCast(self.enabled_layers.items.len),
                .pp_enabled_layer_names = self.enabled_layers.items.ptr,
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
            .enabled_layer_count = @intCast(self.enabled_layers.items.len),
            .pp_enabled_layer_names = self.enabled_layers.items.ptr,
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
};
