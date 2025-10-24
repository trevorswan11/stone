const std = @import("std");
const builtin = @import("builtin");

var initialized = false;

/// Returns a thread-safe allocator with different behavior depending on threadedness.
///
/// When running in single-threaded mode, this is simply the c_allocator.
/// In multi-threaded builds, the allocator is the SmpAllocator.
/// In this mode, the single threaded arg must match the builtin single threaded value.
///
/// The multi-threaded allocator is similar to a singleton and cannot be called more than once.
/// As a result, this variant has an error return type to prevent panics.
pub fn allocator(comptime single_threaded: bool) std.mem.Allocator {
    comptime {
        if (single_threaded != builtin.single_threaded) {
            @compileError("arg single_threaded does not agree with builtin.single_threaded");
        }
    }

    if ((comptime !single_threaded) and initialized) {
        @panic("cannot hold more than one smp allocator");
    }

    initialized = true;
    return if (single_threaded) std.heap.c_allocator else std.heap.smp_allocator;
}
