pub const desktop = @import("desktop.zig");
pub const x11 = @import("x11.zig");

pub const Icon = struct {
    size: u16,
    idat_zlib: []const u8,
};

pub const Config = switch (builtin.os.tag) {
    .linux => struct {
        /// id configures:
        /// - desktop file name: <id>.desktop
        /// - the Icon value in the desktop file, which also controls the directory
        ///   name where the icons are stored, i.e.
        id: []const u8,
        /// The startup_wm_class is the name of the WM_CLASS assigned to the x11 window
        /// shown at startup.
        startup_wm_class: []const u8,
        desktop_entry: desktop.Entry,
    },
    else => |os| @compileError("os " ++ @tagName(os) ++ " has no Config"),
};

const builtin = @import("builtin");
