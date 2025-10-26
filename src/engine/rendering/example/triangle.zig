const std = @import("std");
const builtin = @import("builtin");

const glfw = @import("../backend/glfw.zig");
const vulkan = @import("../backend/vulkan.zig");

const vk = vulkan.lib;
const BaseWrapper = vk.BaseWrapper;
const InstanceWrapper = vk.InstanceWrapper;
const DeviceWrapper = vk.DeviceWrapper;

const Instance = vk.InstanceProxy;
const Device = vk.DeviceProxy;

const app_name = "Hello Triangle";

const window_width: u32 = 800;
const window_height: u32 = 600;

pub const HelloTriangle = struct {
    allocator: std.mem.Allocator,

    vkb: BaseWrapper,
    instance: Instance = undefined,
    debug_messenger: vk.DebugUtilsMessengerEXT = undefined,
    surface: vk.SurfaceKHR = undefined,
    pdev: vk.PhysicalDevice = undefined,
    props: vk.PhysicalDeviceProperties = undefined,
    mem_props: vk.PhysicalDeviceMemoryProperties = undefined,

    window: *glfw.Window = undefined,
    dev: Device,

    pub fn init(allocator: std.mem.Allocator) !HelloTriangle {
        var self: HelloTriangle = .{
            .allocator = allocator,
            .vkb = .load(glfw.getInstanceProcAddress),
        };

        try self.initWindow();
        try self.initVulkan();
        return self;
    }

    pub fn deinit(self: *HelloTriangle) void {
        defer {
            self.allocator.destroy(self.instance.wrapper);
            glfw.terminate();
        }

        self.cleanup();
    }

    pub fn run(self: *HelloTriangle) !void {
        try self.mainLoop();
    }

    fn initWindow(self: *HelloTriangle) glfw.Error!void {
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

    fn createInstance(self: *HelloTriangle) !void {
        const app_info: vk.ApplicationInfo = .{
            .s_type = .application_info,
            .p_application_name = app_name,
            .application_version = vulkan.makeVersion(0, 1, 0, 0),
            .p_engine_name = "No Engine",
            .engine_version = vulkan.makeVersion(0, 1, 0, 0),
            .api_version = vulkan.version(vk.API_VERSION_1_0),
        };

        var glfw_extension_count: u32 = 0;
        const glfw_extensions = glfw.getRequiredInstanceExtensions(&glfw_extension_count);

        var extensions: std.ArrayList([*:0]const u8) = .empty;
        defer extensions.deinit(self.allocator);

        try extensions.append(self.allocator, vk.extensions.ext_debug_utils.name);
        try extensions.append(self.allocator, vk.extensions.khr_portability_enumeration.name);
        try extensions.append(self.allocator, vk.extensions.khr_get_physical_device_properties_2.name);
        try extensions.appendSlice(self.allocator, @ptrCast(glfw_extensions[0..glfw_extension_count]));

        const instance = try self.vkb.createInstance(&.{
            .p_application_info = &app_info,
            .enabled_extension_count = @intCast(extensions.items.len),
            .pp_enabled_extension_names = extensions.items.ptr,
            .flags = .{
                .enumerate_portability_bit_khr = true,
            },
        }, null);

        const vki = try self.allocator.create(InstanceWrapper);
        errdefer self.allocator.destroy(vki);
        vki.* = InstanceWrapper.load(instance, self.vkb.dispatch.vkGetInstanceProcAddr.?);
        self.instance = Instance.init(instance, vki);
        errdefer self.instance.destroyInstance(null);

        self.debug_messenger = try self.instance.createDebugUtilsMessengerEXT(&.{
            .message_severity = .{
                //.verbose_bit_ext = true,
                //.info_bit_ext = true,
                .warning_bit_ext = true,
                .error_bit_ext = true,
            },
            .message_type = .{
                .general_bit_ext = true,
                .validation_bit_ext = true,
                .performance_bit_ext = true,
            },
            .pfn_user_callback = &debugUtilsMessengerCallback,
            .p_user_data = null,
        }, null);
    }

    fn initVulkan(self: *HelloTriangle) !void {
        try self.createInstance();
    }

    fn mainLoop(self: *HelloTriangle) !void {
        while (glfw.windowShouldClose(self.window) != glfw.true) {
            glfw.pollEvents();
        }
    }

    fn cleanup(self: *HelloTriangle) void {
        self.instance.destroyInstance(null);
        glfw.destroyWindow(self.window);
    }
};

fn debugUtilsMessengerCallback(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    msg_type: vk.DebugUtilsMessageTypeFlagsEXT,
    callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(.c) vk.Bool32 {
    const severity_str = if (severity.verbose_bit_ext)
        "verbose"
    else if (severity.info_bit_ext)
        "info"
    else if (severity.warning_bit_ext)
        "warning"
    else if (severity.error_bit_ext)
        "error"
    else
        "unknown";

    const type_str = if (msg_type.general_bit_ext)
        "general"
    else if (msg_type.validation_bit_ext)
        "validation"
    else if (msg_type.performance_bit_ext)
        "performance"
    else if (msg_type.device_address_binding_bit_ext)
        "device addr"
    else
        "unknown";

    const message: [*c]const u8 = if (callback_data) |cb_data|
        cb_data.p_message
    else
        "NO MESSAGE!";
    std.debug.print("[{s}][{s}]. Message:\n  {s}\n", .{ severity_str, type_str, message });

    return .false;
}
