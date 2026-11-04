const std = @import("std");

pub fn build(b: *std.Build) void {
    const icon_gen_exe = b.addExecutable(.{
        .name = "icon_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/icon_gen.zig"),
            .target = b.graph.host,
        }),
    });
    b.installArtifact(icon_gen_exe);

    // only when building appicon itself, so consumers don't load the x11 dependency
    if (b.isRoot()) {
        const test_mod = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = b.graph.host,
        });
        if (b.lazyDependency("x11", .{})) |dep| test_mod.addImport("x11", dep.module("x11"));
        const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = test_mod }));
        b.step("test", "Run unit tests").dependOn(&run_tests.step);
    }
}

pub const ModuleOptions = struct {
    /// Override the x11 module. If null, uses appicon's own x11 dependency.
    x11: ?*std.Build.Module = null,
};

/// Create the appicon module with the code to install the icon via x11 or desktop files/icons.
/// Typical usage would then pass this module to createLinuxIcon or createWindowsIco.
pub fn createModule(
    b: *std.Build,
    appicon_dep: *std.Build.Dependency,
    options: ModuleOptions,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = appicon_dep.path("src/appicon.zig"),
    });
    const maybe_x11_mod: ?*std.Build.Module = blk: {
        if (options.x11) |x11| break :blk x11;
        if (appicon_dep.builder.lazyDependency("x11", .{})) |d| break :blk d.module("x11");
        break :blk null;
    };
    if (maybe_x11_mod) |x11| mod.addImport("x11", x11);
    return mod;
}

pub const IconSource = struct {
    source: std.Build.LazyPath,
    sizes: []const u16,
    /// If set, enforce that the source PNG has this size (max dimension).
    enforce_size: ?u16 = null,
};

/// Create a Linux icon module from source PNGs with desktop/x11 wrapper functions.
pub fn createLinuxIcon(b: *std.Build, appicon_dep: *std.Build.Dependency, appicon_mod: *std.Build.Module, icon_sources: []const IconSource) *std.Build.Module {
    const icon_gen_exe = appicon_dep.artifact("icon_gen");
    const run = b.addRunArtifact(icon_gen_exe);
    const output = run.addOutputFileArg("icon_data.zig");
    addIconArgs(run, icon_sources);
    return b.createModule(.{
        .root_source_file = output,
        .imports = &.{
            .{ .name = "appicon", .module = appicon_mod },
        },
    });
}

/// Create a Windows .ico file from source PNGs.
pub fn createWindowsIco(b: *std.Build, appicon_dep: *std.Build.Dependency, name: []const u8, icon_sources: []const IconSource) std.Build.LazyPath {
    const icon_gen_exe = appicon_dep.artifact("icon_gen");
    const run = b.addRunArtifact(icon_gen_exe);
    const output = run.addOutputFileArg(name);
    addIconArgs(run, icon_sources);
    return output;
}

fn addIconArgs(run: *std.Build.Step.Run, icon_sources: []const IconSource) void {
    for (icon_sources) |src| {
        if (src.enforce_size) |sz| {
            run.addArg("--enforce-size");
            var buf: [16]u8 = undefined;
            run.addArg(std.fmt.bufPrint(&buf, "{}", .{sz}) catch unreachable);
        }
        run.addFileArg(src.source);
        var sizes_buf: [256]u8 = undefined;
        var pos: usize = 0;
        for (src.sizes, 0..) |sz, i| {
            if (i > 0) {
                sizes_buf[pos] = ',';
                pos += 1;
            }
            const s = std.fmt.bufPrint(sizes_buf[pos..], "{}", .{sz}) catch unreachable;
            pos += s.len;
        }
        run.addArg(sizes_buf[0..pos]);
    }
}
