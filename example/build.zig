const std = @import("std");
const appicon = @import("appicon");

pub fn build(b: *std.Build) void {
    const appicon_dep = b.dependency("appicon", .{});

    // Generate test PNGs at build time
    const gen_png_exe = b.addExecutable(.{
        .name = "gen_test_png",
        .root_module = b.createModule(.{
            .root_source_file = b.path("gen_test_png.zig"),
            .target = b.graph.host,
        }),
    });
    const gen_png = b.addRunArtifact(gen_png_exe);
    gen_png.addArg("16");
    const png16 = gen_png.addOutputFileArg("test_icon_16.png");
    gen_png.addArg("20");
    const png20 = gen_png.addOutputFileArg("test_icon_20.png");
    gen_png.addArg("24");
    const png24 = gen_png.addOutputFileArg("test_icon_24.png");
    gen_png.addArg("32");
    const png32 = gen_png.addOutputFileArg("test_icon_32.png");
    gen_png.addArg("48");
    const png48 = gen_png.addOutputFileArg("test_icon_48.png");
    gen_png.addArg("128");
    const png128 = gen_png.addOutputFileArg("test_icon_128.png");

    const appicon_mod = appicon.createModule(b, appicon_dep, .{});
    const exampleicon = appicon.createLinuxIcon(b, appicon_dep, appicon_mod, &.{
        .{ .source = png16, .sizes = &.{16}, .enforce_size = 16 },
        .{ .source = png32, .sizes = &.{32}, .enforce_size = 32 },
        .{ .source = png48, .sizes = &.{48}, .enforce_size = 48 },
        .{ .source = png128, .sizes = &.{128}, .enforce_size = 128 },
    });

    const target = b.standardTargetOptions(.{});
    const exe = b.addExecutable(.{
        .name = "appicon-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path(switch (target.result.os.tag) {
                .linux => "example-linux.zig",
                .windows => "example-windows.zig",
                else => |os| std.debug.panic("todo: support os {t}", .{os}),
            }),
            .target = target,
            .imports = &.{
                .{ .name = "exampleicon", .module = exampleicon },
            },
        }),
        .win32_manifest = b.path("win32/appicon-example.manifest"),
    });
    if (appicon_dep.builder.lazyDependency("x11", .{})) |dep| {
        exe.root_module.addImport("x11", dep.module("x11"));
    }

    if (target.result.os.tag == .windows) {
        if (b.lazyDependency("win32", .{})) |dep| {
            exe.root_module.addImport("win32", dep.module("win32"));
        }
        const ico = appicon.createWindowsIco(b, appicon_dep, "appicon-example.ico", &.{
            .{ .source = png16, .sizes = &.{16}, .enforce_size = 16 },
            .{ .source = png20, .sizes = &.{20}, .enforce_size = 20 },
            .{ .source = png24, .sizes = &.{24}, .enforce_size = 24 },
            .{ .source = png32, .sizes = &.{32}, .enforce_size = 32 },
            .{ .source = png48, .sizes = &.{48}, .enforce_size = 48 },
            .{ .source = png128, .sizes = &.{128}, .enforce_size = 128 },
        });
        exe.root_module.addWin32ResourceFile(.{
            .file = b.path("win32/appicon-example.rc"),
            .include_paths = &.{ico.dirname()},
        });
    }

    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(&install.step);
    run.addPassthruArgs();
    b.step("run", "").dependOn(&run.step);
}
