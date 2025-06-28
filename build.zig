const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const shared = b.option(bool, "shared", "Build as a shared library") orelse false;

    const use_x11 = b.option(bool, "x11", "Build with X11. Only useful on Linux") orelse true;
    const use_wl = b.option(bool, "wayland", "Build with Wayland. Only useful on Linux") orelse true;

    const use_opengl = b.option(bool, "opengl", "Build with OpenGL; deprecated on MacOS") orelse false;
    const use_gles = b.option(bool, "gles", "Build with GLES; not supported on MacOS") orelse false;
    const use_metal = b.option(bool, "metal", "Build with Metal; only supported on MacOS") orelse true;

    const module = b.addModule("glfw", .{
        .optimize = optimize,
        .target = target,
        .link_libc = true,
    });

    const lib = b.addLibrary(.{
        .name = "glfw",
        .linkage = if (shared) .dynamic else .static,
        .root_module = module,
    });
    lib.installHeadersDirectory(b.path("include/GLFW"), "GLFW", .{});

    module.addIncludePath(b.path("include"));

    if (shared) module.addCMacro("_GLFW_BUILD_DLL", "1");

    if (target.result.os.tag.isDarwin()) {
        // MacOS: this must be defined for macOS 13.3 and older.
        module.addCMacro("__kernel_ptr_semantics", "");
    }

    const include_src_flag = "-Isrc";

    switch (target.result.os.tag) {
        .windows => {
            module.linkSystemLibrary("gdi32", .{});
            module.linkSystemLibrary("user32", .{});
            module.linkSystemLibrary("shell32", .{});

            if (use_opengl) {
                module.linkSystemLibrary("opengl32", .{});
            }

            if (use_gles) {
                module.linkSystemLibrary("GLESv3", .{});
            }

            const flags = [_][]const u8{ "-D_GLFW_WIN32", include_src_flag };
            module.addCSourceFiles(.{
                .files = &base_sources,
                .flags = &flags,
            });
            module.addCSourceFiles(.{
                .files = &windows_sources,
                .flags = &flags,
            });
        },
        .macos => {
            const xcode_frameworks_deps = b.dependency("xcode_frameworks", .{ .target = target, .optimize = optimize });
            module.addSystemFrameworkPath(xcode_frameworks_deps.path("Frameworks"));
            module.addSystemIncludePath(xcode_frameworks_deps.path("include"));
            module.addLibraryPath(xcode_frameworks_deps.path("lib"));

            // Transitive dependencies, explicit linkage of these works around
            // ziglang/zig#17130
            module.linkFramework("CFNetwork", .{});
            module.linkFramework("ApplicationServices", .{});
            module.linkFramework("ColorSync", .{});
            module.linkFramework("CoreText", .{});
            module.linkFramework("ImageIO", .{});

            // Direct dependencies
            module.linkSystemLibrary("objc", .{});
            module.linkFramework("IOKit", .{});
            module.linkFramework("CoreFoundation", .{});
            module.linkFramework("AppKit", .{});
            module.linkFramework("CoreServices", .{});
            module.linkFramework("CoreGraphics", .{});
            module.linkFramework("Foundation", .{});

            if (use_metal) {
                module.linkFramework("Metal", .{});
            }

            if (use_opengl) {
                module.linkFramework("OpenGL", .{});
            }

            const flags = [_][]const u8{ "-D_GLFW_COCOA", include_src_flag };
            module.addCSourceFiles(.{
                .files = &base_sources,
                .flags = &flags,
            });
            module.addCSourceFiles(.{
                .files = &macos_sources,
                .flags = &flags,
            });
        },

        // everything that isn't windows or mac is linux :P
        else => {
            var sources = std.BoundedArray([]const u8, 64).init(0) catch unreachable;
            var flags = std.BoundedArray([]const u8, 16).init(0) catch unreachable;

            sources.appendSlice(&base_sources) catch unreachable;
            sources.appendSlice(&linux_sources) catch unreachable;

            if (use_x11) {
                sources.appendSlice(&linux_x11_sources) catch unreachable;
                flags.append("-D_GLFW_X11") catch unreachable;
            }

            if (use_wl) {
                module.addCMacro("WL_MARSHAL_FLAG_DESTROY", "1");

                sources.appendSlice(&linux_wl_sources) catch unreachable;
                flags.append("-D_GLFW_WAYLAND") catch unreachable;
                flags.append("-Wno-implicit-function-declaration") catch unreachable;
            }

            flags.append(include_src_flag) catch unreachable;

            module.addCSourceFiles(.{
                .files = sources.slice(),
                .flags = flags.slice(),
            });
        },
    }

    // GLFW headers depend on these headers, so they must be distributed too.
    if (b.lazyDependency("vulkan_headers", .{
        .target = target,
        .optimize = optimize,
    })) |vulkan_headers_dep| {
        lib.installLibraryHeaders(vulkan_headers_dep.artifact("vulkan-headers"));
    }

    if (target.result.os.tag == .linux) {
        if (b.lazyDependency("x11_headers", .{
            .target = target,
            .optimize = optimize,
        })) |x11_headers_dep| {
            lib.linkLibrary(x11_headers_dep.artifact("x11-headers"));
            lib.installLibraryHeaders(x11_headers_dep.artifact("x11-headers"));
        }

        if (b.lazyDependency("wayland_headers", .{
            .target = target,
            .optimize = optimize,
        })) |wayland_headers_dep| {
            lib.addIncludePath(wayland_headers_dep.path("wayland"));
            lib.addIncludePath(wayland_headers_dep.path("wayland-protocols"));
            lib.addIncludePath(wayland_headers_dep.path("libdecor"));
        }
    }

    b.installArtifact(lib);
}

const base_sources = [_][]const u8{
    "src/context.c",
    "src/egl_context.c",
    "src/init.c",
    "src/input.c",
    "src/monitor.c",
    "src/null_init.c",
    "src/null_joystick.c",
    "src/null_monitor.c",
    "src/null_window.c",
    "src/osmesa_context.c",
    "src/platform.c",
    "src/vulkan.c",
    "src/window.c",
};

const linux_sources = [_][]const u8{
    "src/linux_joystick.c",
    "src/posix_module.c",
    "src/posix_poll.c",
    "src/posix_thread.c",
    "src/posix_time.c",
    "src/xkb_unicode.c",
};

const linux_wl_sources = [_][]const u8{
    "src/wl_init.c",
    "src/wl_monitor.c",
    "src/wl_window.c",
};

const linux_x11_sources = [_][]const u8{
    "src/glx_context.c",
    "src/x11_init.c",
    "src/x11_monitor.c",
    "src/x11_window.c",
};

const windows_sources = [_][]const u8{
    "src/wgl_context.c",
    "src/win32_init.c",
    "src/win32_joystick.c",
    "src/win32_module.c",
    "src/win32_monitor.c",
    "src/win32_thread.c",
    "src/win32_time.c",
    "src/win32_window.c",
};

const macos_sources = [_][]const u8{
    // C sources
    "src/cocoa_time.c",
    "src/posix_module.c",
    "src/posix_thread.c",

    // ObjC sources
    "src/cocoa_init.m",
    "src/cocoa_joystick.m",
    "src/cocoa_monitor.m",
    "src/cocoa_window.m",
    "src/nsgl_context.m",
};
