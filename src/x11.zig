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

/// Every X server accepts requests of at least this many 4-byte units.
/// Larger icons are split across several ChangeProperty requests in append mode.
const min_max_request_len = 4096;
const change_property_header_len = 6;

/// Decompress a zlib-compressed PNG IDAT, skip the row filter bytes, convert RGBA→ARGB,
/// and send it as _NET_WM_ICON ChangeProperty requests.
fn setWmIcon(
    sink: *x11.RequestSink,
    window: x11.Window,
    icon_atom: x11.Atom,
    mode: x11.change_property.Mode,
    size: u16,
    idat_zlib: []const u8,
) error{WriteFailed}!void {
    var input_reader: std.Io.Reader = .fixed(idat_zlib);
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&input_reader, .zlib, &decompress_buf);

    const total: u32 = 2 + @as(u32, size) * size;
    var sent: u32 = 0;
    var request_mode = mode;
    while (sent < total) : (request_mode = .append) {
        const count = @min(total - sent, min_max_request_len - change_property_header_len);
        try writeChangePropertyHeader(sink, window, icon_atom, request_mode, count);
        var offset: usize = 0;
        for (sent..sent + count) |i| {
            const value: u32 = if (i < 2) size else blk: {
                // skip the PNG filter byte at the start of each row (we only use filter 0 = none)
                if ((i - 2) % size == 0) {
                    var filter_buf: [1]u8 = undefined;
                    decompressor.reader.readSliceAll(&filter_buf) catch return error.WriteFailed;
                }
                var rgba: [4]u8 = undefined;
                decompressor.reader.readSliceAll(&rgba) catch return error.WriteFailed;
                break :blk @as(u32, rgba[3]) << 24 | @as(u32, rgba[0]) << 16 | @as(u32, rgba[1]) << 8 | rgba[2];
            };
            try x11.writeInt(sink.writer, &offset, u32, value);
        }
        sent += count;
    }
}

fn writeChangePropertyHeader(
    sink: *x11.RequestSink,
    window: x11.Window,
    icon_atom: x11.Atom,
    mode: x11.change_property.Mode,
    count: u32,
) error{WriteFailed}!void {
    var offset: usize = 0;
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        @backingInt(x11.Opcode.change_property),
        @backingInt(mode),
    });
    try x11.writeInt(sink.writer, &offset, u16, @intCast(change_property_header_len + count));
    try x11.writeInt(sink.writer, &offset, u32, @backingInt(window));
    try x11.writeInt(sink.writer, &offset, u32, @backingInt(icon_atom));
    try x11.writeInt(sink.writer, &offset, u32, @backingInt(x11.Atom.CARDINAL));
    try x11.writeAll(sink.writer, &offset, &[_]u8{ 32, 0, 0, 0 });
    try x11.writeInt(sink.writer, &offset, u32, count);
    sink.sequence +%= 1;
}

test "setWmIcons splits large icons into requests every server accepts" {
    const icon_gen = @import("icon_gen.zig");
    const allocator = std.testing.allocator;

    // 2 + 64*64 values needs 2 requests; 2 + 2*2 fits in 1
    var icons: [2]appicon.Icon = undefined;
    var expected: std.ArrayList(u32) = .empty;
    defer expected.deinit(allocator);
    var zlib_bufs: [2]std.Io.Writer.Allocating = .{ try .initCapacity(allocator, 4096), try .initCapacity(allocator, 4096) };
    defer for (&zlib_bufs) |*b| b.deinit();
    for (&icons, &zlib_bufs, [_]u16{ 64, 2 }) |*icon, *zlib_buf, size| {
        const pixels = try allocator.alloc([4]u8, @as(usize, size) * size);
        defer allocator.free(pixels);
        try expected.appendSlice(allocator, &.{ size, size });
        for (pixels, 0..) |*p, i| {
            p.* = .{ @truncate(i), @truncate(i >> 8), @truncate(size), 255 - @as(u8, @truncate(i)) };
            try expected.append(allocator, @as(u32, p[3]) << 24 | @as(u32, p[0]) << 16 | @as(u32, p[1]) << 8 | p[2]);
        }
        try icon_gen.writeIdatZlib(&zlib_buf.writer, .{ .width = size, .height = size, .pixels = pixels }, size);
        icon.* = .{ .size = size, .idat_zlib = zlib_buf.written() };
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var sink: x11.RequestSink = .{ .writer = &out.writer };
    const window: x11.Window = @fromBackingInt(0x123);
    const atom: x11.Atom = @fromBackingInt(0x45);
    try setWmIcons(&sink, window, atom, &icons);
    try std.testing.expectEqual(3, sink.sequence);

    var values: std.ArrayList(u32) = .empty;
    defer values.deinit(allocator);
    var reader: std.Io.Reader = .fixed(out.written());
    for ([_]x11.change_property.Mode{ .replace, .append, .append }) |mode| {
        const e = x11.native_endian;
        try std.testing.expectEqual(@backingInt(x11.Opcode.change_property), try reader.takeByte());
        try std.testing.expectEqual(@backingInt(mode), try reader.takeByte());
        const len = try reader.takeInt(u16, e);
        try std.testing.expect(len <= 4096);
        try std.testing.expectEqual(0x123, try reader.takeInt(u32, e));
        try std.testing.expectEqual(0x45, try reader.takeInt(u32, e));
        try std.testing.expectEqual(@backingInt(x11.Atom.CARDINAL), try reader.takeInt(u32, e));
        try std.testing.expectEqualSlices(u8, &.{ 32, 0, 0, 0 }, try reader.take(4));
        const count = try reader.takeInt(u32, e);
        try std.testing.expectEqual(len - 6, count);
        for (0..count) |_| try values.append(allocator, try reader.takeInt(u32, e));
    }
    try std.testing.expectEqual(0, reader.bufferedLen());
    try std.testing.expectEqualSlices(u32, expected.items, values.items);
    // first pixels of the 64px icon: RGBA {0,0,64,255} and {1,0,64,254}
    try std.testing.expectEqualSlices(u32, &.{ 64, 64, 0xff000040, 0xfe010040 }, values.items[0..4]);
}

const std = @import("std");
const appicon = @import("appicon.zig");
