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
