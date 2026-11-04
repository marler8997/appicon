pub const x11 = @import("x11");

pub const RequestSink = x11.RequestSink;
pub const Window = x11.Window;
pub const Atom = x11.Atom;

/// Set _NET_WM_ICON on a window using the provided icon data.
/// Call this after window creation, passing the interned _NET_WM_ICON atom.
pub fn setWmIcons(
    sink: *x11.RequestSink,
    window: x11.Window,
    net_wm_icon_atom: x11.Atom,
    icon_entries: []const appicon.Icon,
) error{WriteFailed}!void {
    for (icon_entries, 0..) |icon, i| {
        const mode: x11.change_property.Mode = if (i == 0) .replace else .append;
        try setWmIcon(sink, window, net_wm_icon_atom, mode, icon.size, icon.idat_zlib);
    }
}

/// Decompress a zlib-compressed PNG IDAT, undo row filters, convert RGBA→ARGB,
/// and send as a _NET_WM_ICON ChangeProperty chunk.
fn setWmIcon(
    sink: *x11.RequestSink,
    window: x11.Window,
    icon_atom: x11.Atom,
    mode: x11.change_property.Mode,
    size: u16,
    idat_zlib: []const u8,
) error{WriteFailed}!void {
    const num_u32s: u32 = 2 + @as(u32, size) * size;
    const msg_len: u32 = 6 + num_u32s;
    var offset: usize = 0;
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        @backingInt(x11.Opcode.change_property),
        @backingInt(mode),
    });
    try x11.writeInt(sink.writer, &offset, u16, @intCast(msg_len));
    try x11.writeInt(sink.writer, &offset, u32, @backingInt(window));
    try x11.writeInt(sink.writer, &offset, u32, @backingInt(icon_atom));
    try x11.writeInt(sink.writer, &offset, u32, @backingInt(x11.Atom.CARDINAL));
    try x11.writeAll(sink.writer, &offset, &[_]u8{ 32, 0, 0, 0 });
    try x11.writeInt(sink.writer, &offset, u32, num_u32s);
    // width, height
    try x11.writeInt(sink.writer, &offset, u32, size);
    try x11.writeInt(sink.writer, &offset, u32, size);

    // Decompress zlib IDAT data, strip filter bytes, convert RGBA→ARGB
    var input_reader: std.Io.Reader = .fixed(idat_zlib);
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&input_reader, .zlib, &decompress_buf);

    for (0..size) |_| {
        // Skip PNG filter byte (we only use filter 0 = none)
        var filter_buf: [1]u8 = undefined;
        decompressor.reader.readSliceAll(&filter_buf) catch return error.WriteFailed;

        // Read RGBA pixels for this row, write as ARGB u32s
        for (0..size) |_| {
            var rgba: [4]u8 = undefined;
            decompressor.reader.readSliceAll(&rgba) catch return error.WriteFailed;
            const argb: u32 = @as(u32, rgba[3]) << 24 | @as(u32, rgba[0]) << 16 | @as(u32, rgba[1]) << 8 | rgba[2];
            try x11.writeInt(sink.writer, &offset, u32, argb);
        }
    }

    sink.sequence +%= 1;
}

const std = @import("std");
const appicon = @import("appicon.zig");
