# appicon

Takes PNG files of your app icon at build time and repackages them for your native app.

Supports unique PNG files for each size or, can take any PNG and scale it at build time using a box filter.

On Windows, it generates a ".ico" file that should be embedded into your app as a resource (see example).

On Linux, the icons are zlib-compressed and embedded in the binary. You can then call the `installDesktop` function which writes the icons as PNG files along with a .desktop entry. It also provides the function `setWmIcons` which decompresses the icon data on the fly to send to the X server's `_NET_WM_ICON` property.

## Usage

```zig
// build.zig
const appicon_dep = b.dependency("appicon", .{});
const appicon_mod = appicon.createModule(b, appicon_dep, .{ .x11 = x11_mod });

// Linux
const myicon = appicon.createLinuxIcon(b, appicon_dep, appicon_mod, &.{
    .{ .source = b.path("img/icon16.png"), .sizes = &.{ 16 }, .enforce_size = 16 },
    .{ .source = b.path("img/icon32.png"), .sizes = &.{ 32 }, .enforce_size = 32 },
    .{ .source = b.path("img/icon256.png"), .sizes = &.{ 48, 128 }, .enforce_size = 256 },
});
exe.root_module.addImport("myicon", myicon);

// Windows
const ico = appicon.createWindowsIco(b, appicon_dep, "myapp.ico", &.{
    .{ .source = b.path("img/icon256.png"), .sizes = &.{ 16, 32, 48, 128 } },
});
exe.root_module.addWin32ResourceFile(.{
    .file = b.path("src/myapp.rc"),
    .include_paths = &.{ico.dirname()},
});
```

```zig
// app code (Linux)
const myicon = @import("myicon");

const config: myicon.Config = .{
    .id = "myapp",
    .startup_wm_class = "MyApp",
    .desktop_entry = .{
        .Name = "My App",
        .Exec = "myapp",
        .Categories = "Development;",
    },
};

// Install desktop files and icons
try myicon.installDesktop(io, environ, config);

// Send icons to X server
try myicon.setWmIcons(&sink, window, net_wm_icon_atom);
```

See `example/` for a complete working example.
