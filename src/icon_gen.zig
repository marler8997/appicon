const std = @import("std");
const flate = std.compress.flate;

const IconInput = struct {
    decoded: DecodedPng,
    target_size: u16,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4 or (args.len - 2) % 2 != 0) {
        printUsage();
        std.process.exit(1);
    }
    const out_path = args[1];
    const mode: enum { zig, ico } = if (std.mem.endsWith(u8, out_path, ".zig"))
        .zig
    else if (std.mem.endsWith(u8, out_path, ".ico"))
        .ico
    else {
        std.log.err("output must end in .zig or .ico, got: {s}", .{out_path});
        std.process.exit(1);
    };

    // Parse: [--enforce-size N] FILE.png SIZES [--enforce-size N] FILE.png SIZES ...
    var inputs: std.ArrayList(IconInput) = .empty;
    var arg_idx: usize = 2;
    while (arg_idx < args.len) {
        var enforce_size: ?u16 = null;
        if (std.mem.eql(u8, args[arg_idx], "--enforce-size")) {
            arg_idx += 1;
            if (arg_idx >= args.len) {
                std.log.err("--enforce-size requires a size argument", .{});
                std.process.exit(1);
            }
            enforce_size = std.fmt.parseInt(u16, args[arg_idx], 10) catch {
                std.log.err("invalid --enforce-size value: {s}", .{args[arg_idx]});
                std.process.exit(1);
            };
            arg_idx += 1;
        }

        if (arg_idx + 1 >= args.len) {
            printUsage();
            std.process.exit(1);
        }

        const path = args[arg_idx];
        const sizes_str = args[arg_idx + 1];
        arg_idx += 2;

        const png_data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(10 * 1024 * 1024)) catch |err| {
            std.log.err("failed to read '{s}': {}", .{ path, err });
            std.process.exit(1);
        };
        const decoded = decodePng(arena, png_data) catch |err| {
            std.log.err("failed to decode '{s}': {}", .{ path, err });
            std.process.exit(1);
        };

        if (enforce_size) |expected| {
            const actual = @max(decoded.width, decoded.height);
            if (actual != expected) {
                std.log.err("'{s}': expected size {}, got {}x{}", .{ path, expected, decoded.width, decoded.height });
                std.process.exit(1);
            }
        }

        var size_iter = std.mem.splitScalar(u8, sizes_str, ',');
        while (size_iter.next()) |size_str| {
            const target_size = std.fmt.parseInt(u16, size_str, 10) catch 0;
            const max_size: u16 = switch (mode) {
                .zig => std.math.maxInt(u16),
                .ico => 256,
            };
            if (target_size == 0 or target_size > max_size) {
                std.log.err("invalid size '{s}' in '{s}' (must be 1 to {})", .{ size_str, sizes_str, max_size });
                std.process.exit(1);
            }
            try inputs.append(arena, .{ .decoded = decoded, .target_size = target_size });
        }
    }

    if (inputs.items.len == 0) {
        printUsage();
        std.process.exit(1);
    }

    switch (mode) {
        .zig => try writeZigIcons(io, out_path, inputs.items),
        .ico => {
            const file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
            defer file.close(io);
            var buf: [4096]u8 = undefined;
            var file_writer = file.writer(io, &buf);
            writeIco(&file_writer.interface, inputs.items) catch return file_writer.err.?;
        },
    }
}

fn printUsage() void {
    std.log.err("usage: icon_gen <output.zig|output.ico> <file.png> <sizes> [<file.png> <sizes>] ...", .{});
}

fn writeZigIcons(io: std.Io, out_path: []const u8, inputs: []const IconInput) !void {
    const out_dir_path = std.fs.path.dirname(out_path) orelse ".";
    const out_dir = try std.Io.Dir.cwd().openDir(io, out_dir_path, .{});

    for (inputs) |input| {
        var filename_buf: [32]u8 = undefined;
        const filename = std.fmt.bufPrint(&filename_buf, "icon_{}.zlib", .{input.target_size}) catch unreachable;

        const idat_file = try out_dir.createFile(io, filename, .{});
        defer idat_file.close(io);
        var file_writer_buf: [4096]u8 = undefined;
        var file_writer = idat_file.writer(io, &file_writer_buf);
        writeIdatZlib(&file_writer.interface, input.decoded, input.target_size) catch return file_writer.err.?;
        file_writer.interface.flush() catch return file_writer.err.?;
    }

    const zig_file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer zig_file.close(io);
    var zig_writer_buf: [4096]u8 = undefined;
    var zig_writer = zig_file.writer(io, &zig_writer_buf);
    writeZig(&zig_writer.interface, inputs) catch return zig_writer.err.?;
}

fn writeZig(writer: *std.Io.Writer, inputs: []const IconInput) error{WriteFailed}!void {
    try writer.writeAll(
        \\const std = @import("std");
        \\const appicon = @import("appicon");
        \\pub const Config = appicon.Config;
        \\pub const entries = [_]appicon.Icon{
        \\
    );
    for (inputs) |input| {
        var filename_buf: [32]u8 = undefined;
        const filename = std.fmt.bufPrint(&filename_buf, "icon_{}.zlib", .{input.target_size}) catch unreachable;
        try writer.print(
            \\    .{{ .size = {}, .idat_zlib = @embedFile("{s}") }},
            \\
        , .{ input.target_size, filename });
    }
    try writer.writeAll(
        \\};
        \\
        \\pub fn installDesktop(io: std.Io, environ: std.process.Environ, comptime config: Config) !void {
        \\    return appicon.desktop.install(io, environ, config, &entries);
        \\}
        \\
        \\pub fn setWmIcons(
        \\    sink: *appicon.x11.RequestSink,
        \\    window: appicon.x11.Window,
        \\    net_wm_icon_atom: appicon.x11.Atom,
        \\) error{WriteFailed}!void {
        \\    return appicon.x11.setWmIcons(sink, window, net_wm_icon_atom, &entries);
        \\}
        \\
    );
    try writer.flush();
}

/// Write the zlib-compressed PNG image data (IDAT) for the source image
/// box-filtered to `sz`. `writer` needs a buffer bigger than 8 bytes.
pub fn writeIdatZlib(writer: *std.Io.Writer, decoded: DecodedPng, sz: u16) error{WriteFailed}!void {
    var compress_buf: [flate.max_window_len]u8 = undefined;
    var compressor = try flate.Compress.init(writer, &compress_buf, .zlib, .best);
    try writeFilteredRows(&compressor.writer, decoded, sz);
    try compressor.finish();
}

/// Write PNG-filtered rows (filter byte 0 + RGBA pixels) for the source image
/// box-filtered to `sz`.
fn writeFilteredRows(writer: *std.Io.Writer, decoded: DecodedPng, sz: u16) error{WriteFailed}!void {
    const src_w = decoded.width;
    const src_h = decoded.height;
    const src_side = @max(src_w, src_h);
    const pad_x = (src_side - src_w) / 2;
    const pad_y = (src_side - src_h) / 2;

    for (0..sz) |out_y| {
        // PNG row filter byte: 0 = None
        try writer.writeAll(&[_]u8{0});
        for (0..sz) |out_x| {
            const pixel = boxFilter(decoded.pixels, src_w, src_h, src_side, pad_x, pad_y, out_x, out_y, sz);
            try writer.writeAll(&pixel);
        }
    }
}

/// Box-filter a single output pixel from the source image.
fn boxFilter(
    pixels: []const [4]u8,
    src_w: usize,
    src_h: usize,
    src_side: usize,
    pad_x: usize,
    pad_y: usize,
    out_x: usize,
    out_y: usize,
    sz: u16,
) [4]u8 {
    const src_x0 = out_x * src_side / sz;
    const src_y0 = out_y * src_side / sz;
    // when upscaling the range can be empty, take at least one source pixel
    const src_x1 = @max(src_x0 + 1, (out_x + 1) * src_side / sz);
    const src_y1 = @max(src_y0 + 1, (out_y + 1) * src_side / sz);

    var r_sum: u64 = 0;
    var g_sum: u64 = 0;
    var b_sum: u64 = 0;
    var a_sum: u64 = 0;
    var count: u64 = 0;

    for (src_y0..src_y1) |sy| {
        for (src_x0..src_x1) |sx| {
            const real_x = @as(i32, @intCast(sx)) - @as(i32, @intCast(pad_x));
            const real_y = @as(i32, @intCast(sy)) - @as(i32, @intCast(pad_y));
            if (real_x >= 0 and real_x < src_w and real_y >= 0 and real_y < src_h) {
                const idx = @as(usize, @intCast(real_y)) * src_w + @as(usize, @intCast(real_x));
                const rgba = pixels[idx];
                r_sum += rgba[0];
                g_sum += rgba[1];
                b_sum += rgba[2];
                a_sum += rgba[3];
            }
            count += 1;
        }
    }

    return .{
        @intCast(r_sum / count),
        @intCast(g_sum / count),
        @intCast(b_sum / count),
        @intCast(a_sum / count),
    };
}

/// Write a multi-size ICO file with BMP/DIB entries.
fn writeIco(w: *std.Io.Writer, inputs: []const IconInput) error{WriteFailed}!void {
    const num_entries: u16 = @intCast(inputs.len);

    // ICONDIR
    try w.writeInt(u16, 0, .little); // reserved
    try w.writeInt(u16, 1, .little); // type: icon
    try w.writeInt(u16, num_entries, .little);

    // ICONDIRENTRY for each size
    var offset: u32 = 6 + @as(u32, num_entries) * 16;
    for (inputs) |input| {
        const sz = input.target_size;
        std.debug.assert(sz <= 256);
        const data_size = icoEntryDataSize(sz);
        try w.writeAll(&.{
            if (sz >= 256) 0 else @as(u8, @intCast(sz)), // width
            if (sz >= 256) 0 else @as(u8, @intCast(sz)), // height
            0, // color count
            0, // reserved
        });
        try w.writeInt(u16, 1, .little); // color planes
        try w.writeInt(u16, 32, .little); // bits per pixel
        try w.writeInt(u32, data_size, .little);
        try w.writeInt(u32, offset, .little);
        offset += data_size;
    }

    // BMP/DIB data for each size
    for (inputs) |input| {
        const sz = input.target_size;
        const and_mask_row = icoAndMaskRowLen(sz);
        // BITMAPINFOHEADER
        try w.writeInt(u32, 40, .little); // header size
        try w.writeInt(i32, @intCast(sz), .little); // width
        try w.writeInt(i32, @as(i32, @intCast(sz)) * 2, .little); // height (doubled for ICO: XOR + AND)
        try w.writeInt(u16, 1, .little); // planes
        try w.writeInt(u16, 32, .little); // bit count
        try w.writeInt(u32, 0, .little); // compression (BI_RGB)
        try w.writeInt(u32, icoEntryDataSize(sz) - 40, .little); // image size
        try w.writeInt(i32, 0, .little); // x pixels per meter
        try w.writeInt(i32, 0, .little); // y pixels per meter
        try w.writeInt(u32, 0, .little); // colors used
        try w.writeInt(u32, 0, .little); // important colors
        // Pixel data: bottom-up rows, BGRA byte order
        try writeBmpPixels(w, input.decoded, sz);
        // AND mask: all zeros (alpha channel handles transparency)
        try w.splatByteAll(0, sz * and_mask_row);
    }

    try w.flush();
}

fn icoAndMaskRowLen(sz: u16) u32 {
    return (@as(u32, sz) + 31) / 32 * 4;
}
/// BITMAPINFOHEADER + BGRA pixels + AND mask
fn icoEntryDataSize(sz: u16) u32 {
    return 40 + @as(u32, sz) * sz * 4 + icoAndMaskRowLen(sz) * sz;
}

/// Write box-filtered, bottom-up BGRA pixel data for ICO BMP entries.
fn writeBmpPixels(w: *std.Io.Writer, decoded: DecodedPng, sz: u16) error{WriteFailed}!void {
    const src_w = decoded.width;
    const src_h = decoded.height;
    const src_side = @max(src_w, src_h);
    const pad_x = (src_side - src_w) / 2;
    const pad_y = (src_side - src_h) / 2;

    // Bottom-up row order
    var out_y: usize = sz;
    while (out_y > 0) {
        out_y -= 1;
        for (0..sz) |out_x| {
            const pixel = boxFilter(decoded.pixels, src_w, src_h, src_side, pad_x, pad_y, out_x, out_y, sz);
            try w.writeAll(&[_]u8{ pixel[2], pixel[1], pixel[0], pixel[3] }); // BGRA
        }
    }
}

pub const DecodedPng = struct {
    width: usize,
    height: usize,
    pixels: [][4]u8,
};

/// Minimal PNG decoder for 8-bit RGBA non-interlaced images.
pub fn decodePng(allocator: std.mem.Allocator, data: []const u8) !DecodedPng {
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], &.{ 137, 80, 78, 71, 13, 10, 26, 10 }))
        return error.InvalidPngSignature;

    var pos: usize = 8;
    var ihdr: ?[]const u8 = null;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(allocator);
    while (true) {
        if (data.len - pos < 12) return error.TruncatedPng;
        const chunk_len: usize = std.mem.readInt(u32, data[pos..][0..4], .big);
        if (data.len - pos - 12 < chunk_len) return error.TruncatedPng;
        const type_and_data = data[pos + 4 ..][0 .. 4 + chunk_len];
        const crc = std.mem.readInt(u32, data[pos + 8 + chunk_len ..][0..4], .big);
        if (std.hash.Crc32.hash(type_and_data) != crc) return error.BadPngChunkCrc;
        pos += 12 + chunk_len;

        const chunk_type = type_and_data[0..4];
        const chunk_data = type_and_data[4..];
        if (ihdr == null) {
            if (!std.mem.eql(u8, chunk_type, "IHDR")) return error.ExpectedIhdr;
            if (chunk_data.len != 13) return error.BadIhdrLength;
            ihdr = chunk_data;
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            try idat.appendSlice(allocator, chunk_data);
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        }
    }

    const width: usize = std.mem.readInt(u32, ihdr.?[0..4], .big);
    const height: usize = std.mem.readInt(u32, ihdr.?[4..8], .big);
    const bit_depth = ihdr.?[8];
    const color_type = ihdr.?[9];
    const interlace = ihdr.?[12];
    if (bit_depth != 8 or color_type != 6 or interlace != 0)
        return error.UnsupportedPngFormat;
    if (width == 0 or height == 0) return error.EmptyPng;
    // icon sizes are u16, and this keeps a tiny PNG from claiming gigabytes
    if (width > std.math.maxInt(u16) or height > std.math.maxInt(u16)) return error.PngTooLarge;
    if (idat.items.len == 0) return error.NoIdatChunk;

    var input_reader: std.Io.Reader = .fixed(idat.items);
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&input_reader, .zlib, &decompress_buf);

    const stride = try std.math.mul(usize, width, 4);
    const pixels = try allocator.alloc([4]u8, try std.math.mul(usize, width, height));
    errdefer allocator.free(pixels);
    var cur_row = try allocator.alloc(u8, stride);
    defer allocator.free(cur_row);
    var prev_row = try allocator.alloc(u8, stride);
    defer allocator.free(prev_row);
    @memset(prev_row, 0);

    for (0..height) |y| {
        var filter_buf: [1]u8 = undefined;
        decompressor.reader.readSliceAll(&filter_buf) catch return decompressor.err orelse error.TruncatedPngData;
        const filter_type = filter_buf[0];
        decompressor.reader.readSliceAll(cur_row) catch return decompressor.err orelse error.TruncatedPngData;

        for (0..stride) |i| {
            const a: u8 = if (i >= 4) cur_row[i - 4] else 0;
            const b_val: u8 = prev_row[i];
            const c: u8 = if (i >= 4) prev_row[i - 4] else 0;

            cur_row[i] = switch (filter_type) {
                0 => cur_row[i],
                1 => cur_row[i] +% a,
                2 => cur_row[i] +% b_val,
                3 => cur_row[i] +% @as(u8, @intCast((@as(u16, a) + b_val) / 2)),
                4 => cur_row[i] +% paethPredictor(a, b_val, c),
                else => return error.UnsupportedFilter,
            };
        }

        for (0..width) |x| {
            pixels[y * width + x] = cur_row[x * 4 ..][0..4].*;
        }

        const tmp = prev_row;
        prev_row = cur_row;
        cur_row = tmp;
    }

    return .{ .width = width, .height = height, .pixels = pixels };
}

fn paethPredictor(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

test "decodePng: all row filters and several IDAT chunks" {
    // made by ImageMagick (libpng picks all 5 row filters) with its IDAT
    // split into 3 chunks; filters.rgba is the image ImageMagick decodes from it
    const png = @embedFile("testdata/filters.png");
    const expected = @embedFile("testdata/filters.rgba");
    const decoded = try decodePng(std.testing.allocator, png);
    defer std.testing.allocator.free(decoded.pixels);
    try std.testing.expectEqual(48, decoded.width);
    try std.testing.expectEqual(48, decoded.height);
    try std.testing.expectEqualSlices(u8, expected, std.mem.sliceAsBytes(decoded.pixels));
}

test "decodePng: truncated or corrupt input" {
    const png = @embedFile("testdata/filters.png");
    for ([_]usize{ 0, 7, 8, 20, 33, 100, png.len - 13, png.len - 1 }) |len| {
        if (decodePng(std.testing.allocator, png[0..len])) |d| {
            std.testing.allocator.free(d.pixels);
            return error.TestExpectedError;
        } else |_| {}
    }
    var corrupt = png.*;
    corrupt[200] ^= 1;
    try std.testing.expectError(error.BadPngChunkCrc, decodePng(std.testing.allocator, &corrupt));

    // IHDR claiming 65536 x 1, with a valid CRC
    var huge = png.*;
    std.mem.writeInt(u32, huge[16..20], 65536, .big);
    std.mem.writeInt(u32, huge[20..24], 1, .big);
    std.mem.writeInt(u32, huge[29..33], std.hash.Crc32.hash(huge[12..29]), .big);
    try std.testing.expectError(error.PngTooLarge, decodePng(std.testing.allocator, &huge));
}

fn testFilter(pixels: []const [4]u8, w: usize, h: usize, sz: u16) ![]const [4]u8 {
    const out = try std.testing.allocator.alloc([4]u8, @as(usize, sz) * sz);
    const side = @max(w, h);
    for (0..sz) |y| for (0..sz) |x| {
        out[y * sz + x] = boxFilter(pixels, w, h, side, (side - w) / 2, (side - h) / 2, x, y, sz);
    };
    return out;
}

test "boxFilter: non-square source is centered on a transparent square" {
    // 2 wide x 4 high: padded to 4x4 with one transparent column on each side
    const src = [_][4]u8{
        .{ 40, 0, 0, 200 },  .{ 0, 80, 0, 100 },
        .{ 40, 0, 0, 200 },  .{ 0, 80, 0, 100 },
        .{ 0, 0, 120, 255 }, .{ 0, 0, 0, 0 },
        .{ 0, 0, 120, 255 }, .{ 0, 0, 0, 0 },
    };
    const out = try testFilter(&src, 2, 4, 2);
    defer std.testing.allocator.free(out);
    // each output pixel averages a 2x2 block: one padding column, one image column
    try std.testing.expectEqualSlices([4]u8, &.{
        .{ 20, 0, 0, 100 }, .{ 0, 40, 0, 50 },
        .{ 0, 0, 60, 127 }, .{ 0, 0, 0, 0 },
    }, out);
}

test "boxFilter: upscale repeats source pixels" {
    const src = [_][4]u8{ .{ 1, 2, 3, 4 }, .{ 5, 6, 7, 8 }, .{ 9, 10, 11, 12 }, .{ 13, 14, 15, 16 } };
    const out = try testFilter(&src, 2, 2, 4);
    defer std.testing.allocator.free(out);
    const a = src[0];
    const b = src[1];
    const c = src[2];
    const d = src[3];
    try std.testing.expectEqualSlices([4]u8, &.{
        a, a, b, b,
        a, a, b, b,
        c, c, d, d,
        c, c, d, d,
    }, out);
}

test "writeIco layout" {
    var pixels = [_][4]u8{ .{ 1, 2, 3, 4 }, .{ 5, 6, 7, 8 }, .{ 9, 10, 11, 12 }, .{ 13, 14, 15, 16 } };
    const decoded: DecodedPng = .{ .width = 2, .height = 2, .pixels = &pixels };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeIco(&w, &.{ .{ .decoded = decoded, .target_size = 1 }, .{ .decoded = decoded, .target_size = 2 } });
    const ico = w.buffered();

    // 6 header + 2*16 entries, then 40 + 1*1*4 + 4 and-mask, then 40 + 2*2*4 + 2*4 and-mask
    try std.testing.expectEqual(6 + 32 + 48 + 64, ico.len);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 1, 0, 2, 0 }, ico[0..6]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 0, 0, 1, 0, 32, 0, 48, 0, 0, 0, 38, 0, 0, 0 }, ico[6..22]);
    try std.testing.expectEqualSlices(u8, &.{ 2, 2, 0, 0, 1, 0, 32, 0, 64, 0, 0, 0, 86, 0, 0, 0 }, ico[22..38]);

    const read = std.mem.readInt;
    // first entry: 1x1 averages all four pixels (BGRA)
    try std.testing.expectEqual(40, read(u32, ico[38..42], .little));
    try std.testing.expectEqual(1, read(i32, ico[42..46], .little));
    try std.testing.expectEqual(2, read(i32, ico[46..50], .little));
    try std.testing.expectEqual(8, read(u32, ico[58..62], .little));
    try std.testing.expectEqualSlices(u8, &.{ 9, 8, 7, 10, 0, 0, 0, 0 }, ico[78..86]);
    // second entry: bottom-up rows, BGRA
    try std.testing.expectEqual(2, read(i32, ico[90..94], .little));
    try std.testing.expectEqual(4, read(i32, ico[94..98], .little));
    try std.testing.expectEqual(24, read(u32, ico[106..110], .little));
    try std.testing.expectEqualSlices(u8, &.{ 11, 10, 9, 12, 15, 14, 13, 16, 3, 2, 1, 4, 7, 6, 5, 8 }, ico[126..142]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, ico[142..150]);
}
