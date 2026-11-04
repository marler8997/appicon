/// Generates minimal RGBA PNGs at specified sizes for testing.
/// Usage: gen_test_png <size> <output.png> [<size> <output.png>] ...
const std = @import("std");
const flate = std.compress.flate;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3 or (args.len - 1) % 2 != 0) {
        std.log.err("usage: gen_test_png <size> <output.png> [<size> <output.png>] ...", .{});
        std.process.exit(1);
    }

    var arg_idx: usize = 1;
    while (arg_idx + 1 < args.len) {
        const size = std.fmt.parseInt(u16, args[arg_idx], 10) catch {
            std.log.err("invalid size: {s}", .{args[arg_idx]});
            std.process.exit(1);
        };
        const path = args[arg_idx + 1];
        arg_idx += 2;

        const idat = blk: {
            var a: std.Io.Writer.Allocating = try .initCapacity(arena, 5000);
            defer a.deinit();
            var compress_buf: [flate.max_window_len]u8 = undefined;
            var compressor = flate.Compress.init(&a.writer, &compress_buf, .zlib, .best) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
            };
            writeCompressedPixels(&compressor.writer, size) catch return error.OutOfMemory;
            compressor.finish() catch return error.OutOfMemory;
            break :blk try a.toOwnedSlice();
        };
        defer arena.free(idat);

        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var file_writer = file.writer(io, &buf);
        writePngChunks(&file_writer.interface, size, idat) catch return file_writer.err.?;
    }
}

fn writeCompressedPixels(w: *std.Io.Writer, size: u16) error{WriteFailed}!void {
    // Format the size as a string of digits
    var digits_buf: [8]u8 = undefined;
    const digits = std.fmt.bufPrint(&digits_buf, "{}", .{size}) catch unreachable;

    // Scale font to fit: each glyph is 3x5 in the font, rendered at scale
    const scale: usize = @max(1, size / (6 * digits.len + 2));
    const glyph_w = 3 * scale;
    const glyph_h = 5 * scale;
    const gap = scale;
    const text_w = digits.len * glyph_w + (digits.len - 1) * gap;
    const text_x = (size - text_w) / 2;
    const text_y = (size - glyph_h) / 2;

    const radius: usize = @max(1, size / 4);
    for (0..size) |y| {
        try w.writeAll(&[_]u8{0}); // PNG filter: none
        for (0..size) |x| {
            const in_shape = isInRoundedRect(x, y, size, radius);
            const is_text = if (in_shape) isTextPixel(x, y, text_x, text_y, scale, gap, digits) else false;
            const pixel: [4]u8 = if (!in_shape)
                .{ 0, 0, 0, 0 }
            else if (is_text)
                .{ 255, 255, 255, 255 }
            else
                .{ 91, 75, 188, 255 };
            try w.writeAll(&pixel);
        }
    }
}

fn isInRoundedRect(x: usize, y: usize, size: u16, radius: usize) bool {
    // Check if pixel is inside a rounded rectangle (size x size with given corner radius)
    const cx = if (x < radius) radius - x else if (x >= size - radius) x - (size - radius - 1) else 0;
    const cy = if (y < radius) radius - y else if (y >= size - radius) y - (size - radius - 1) else 0;
    if (cx == 0 or cy == 0) return true;
    return cx * cx + cy * cy <= radius * radius;
}

fn isTextPixel(x: usize, y: usize, text_x: usize, text_y: usize, scale: usize, gap: usize, digits: []const u8) bool {
    if (y < text_y or y >= text_y + 5 * scale) return false;
    if (x < text_x) return false;

    const rel_x = x - text_x;
    const glyph_stride = 3 * scale + gap;

    const digit_idx = rel_x / glyph_stride;
    if (digit_idx >= digits.len) return false;

    const gx = (rel_x - digit_idx * glyph_stride) / scale;
    if (gx >= 3) return false; // in the gap
    const gy = (y - text_y) / scale;

    const glyph = font[digits[digit_idx] - '0'];
    return glyph[gy] & (@as(u8, 1) << @intCast(2 - gx)) != 0;
}

// 3x5 bitmap font for digits 0-9. Each row is 3 bits (MSB = left).
const font = [10][5]u8{
    .{ 0b111, 0b101, 0b101, 0b101, 0b111 }, // 0
    .{ 0b010, 0b110, 0b010, 0b010, 0b111 }, // 1
    .{ 0b111, 0b001, 0b111, 0b100, 0b111 }, // 2
    .{ 0b111, 0b001, 0b111, 0b001, 0b111 }, // 3
    .{ 0b101, 0b101, 0b111, 0b001, 0b001 }, // 4
    .{ 0b111, 0b100, 0b111, 0b001, 0b111 }, // 5
    .{ 0b111, 0b100, 0b111, 0b101, 0b111 }, // 6
    .{ 0b111, 0b001, 0b001, 0b001, 0b001 }, // 7
    .{ 0b111, 0b101, 0b111, 0b101, 0b111 }, // 8
    .{ 0b111, 0b101, 0b111, 0b001, 0b111 }, // 9
};

fn writePngChunks(w: *std.Io.Writer, size: u16, idat: []const u8) error{WriteFailed}!void {
    // PNG signature
    try w.writeAll(&.{ 137, 80, 78, 71, 13, 10, 26, 10 });

    // IHDR
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], size, .big);
    std.mem.writeInt(u32, ihdr[4..8], size, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type: RGBA
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter
    ihdr[12] = 0; // interlace
    try writeChunk(w, "IHDR", &ihdr);

    // IDAT
    try writeChunk(w, "IDAT", idat);

    // IEND
    try writeChunk(w, "IEND", &.{});
    try w.flush();
}

fn writeChunk(w: *std.Io.Writer, chunk_type: *const [4]u8, data: []const u8) error{WriteFailed}!void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    try w.writeAll(&len_buf);
    try w.writeAll(chunk_type);
    try w.writeAll(data);
    var crc_buf: [4]u8 = undefined;
    var h = std.hash.Crc32.init();
    h.update(chunk_type);
    h.update(data);
    std.mem.writeInt(u32, &crc_buf, h.final(), .big);
    try w.writeAll(&crc_buf);
}
