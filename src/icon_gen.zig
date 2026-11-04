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
            const target_size = std.fmt.parseInt(u16, size_str, 10) catch {
                std.log.err("invalid size '{s}' in '{s}'", .{ size_str, sizes_str });
                std.process.exit(1);
            };
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

        var compress_buf: [flate.max_window_len]u8 = undefined;
        var compressor = flate.Compress.init(&file_writer.interface, &compress_buf, .zlib, .best) catch |err| switch (err) {
            error.WriteFailed => return file_writer.err.?,
        };
        writeFilteredRows(&compressor.writer, input.decoded, input.target_size) catch return file_writer.err.?;
        compressor.finish() catch return file_writer.err.?;
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

/// Write PNG-filtered rows (filter byte 0 + RGBA pixels) for a box-filtered
/// downscale of the source image.
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
    pixels: [][4]u8,
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
    const src_x1 = (out_x + 1) * src_side / sz;
    const src_y1 = (out_y + 1) * src_side / sz;

    var r_sum: u32 = 0;
    var g_sum: u32 = 0;
    var b_sum: u32 = 0;
    var a_sum: u32 = 0;
    var count: u32 = 0;

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
        if (count > 0) @intCast(r_sum / count) else 0,
        if (count > 0) @intCast(g_sum / count) else 0,
        if (count > 0) @intCast(b_sum / count) else 0,
        if (count > 0) @intCast(a_sum / count) else 0,
    };
}

/// Write a multi-size ICO file with BMP/DIB entries.
fn writeIco(w: *std.Io.Writer, inputs: []const IconInput) error{WriteFailed}!void {
    const num_entries: u16 = @intCast(inputs.len);

    // Pre-calculate entry sizes and offsets.
    const header_size: u32 = 6 + @as(u32, num_entries) * 16;
    var entry_data_sizes: [64]u32 = undefined;
    var offsets: [64]u32 = undefined;
    var offset: u32 = header_size;
    for (inputs, 0..) |input, i| {
        const sz: u32 = input.target_size;
        const and_mask_row: u32 = (sz + 31) / 32 * 4;
        entry_data_sizes[i] = 40 + sz * sz * 4 + and_mask_row * sz;
        offsets[i] = offset;
        offset += entry_data_sizes[i];
    }

    // ICONDIR
    try w.writeInt(u16, 0, .little); // reserved
    try w.writeInt(u16, 1, .little); // type: icon
    try w.writeInt(u16, num_entries, .little);

    // ICONDIRENTRY for each size
    for (inputs, 0..) |input, i| {
        const sz = input.target_size;
        try w.writeAll(&.{
            if (sz >= 256) 0 else @as(u8, @intCast(sz)), // width
            if (sz >= 256) 0 else @as(u8, @intCast(sz)), // height
            0, // color count
            0, // reserved
        });
        try w.writeInt(u16, 1, .little); // color planes
        try w.writeInt(u16, 32, .little); // bits per pixel
        try w.writeInt(u32, entry_data_sizes[i], .little);
        try w.writeInt(u32, offsets[i], .little);
    }

    // BMP/DIB data for each size
    for (inputs) |input| {
        const sz = input.target_size;
        const and_mask_row: u32 = (@as(u32, sz) + 31) / 32 * 4;
        // BITMAPINFOHEADER
        try w.writeInt(u32, 40, .little); // header size
        try w.writeInt(i32, @intCast(sz), .little); // width
        try w.writeInt(i32, @as(i32, @intCast(sz)) * 2, .little); // height (doubled for ICO: XOR + AND)
        try w.writeInt(u16, 1, .little); // planes
        try w.writeInt(u16, 32, .little); // bit count
        try w.writeInt(u32, 0, .little); // compression (BI_RGB)
        try w.writeInt(u32, @as(u32, sz) * sz * 4 + and_mask_row * sz, .little); // image size
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

const DecodedPng = struct {
    width: usize,
    height: usize,
    pixels: [][4]u8,
};

/// Minimal PNG decoder for 8-bit RGBA non-interlaced images.
fn decodePng(allocator: std.mem.Allocator, data: []const u8) !DecodedPng {
    if (!std.mem.eql(u8, data[0..8], &.{ 137, 80, 78, 71, 13, 10, 26, 10 }))
        return error.InvalidPngSignature;

    var pos: usize = 8;

    // Read IHDR
    pos += 4; // chunk length
    if (!std.mem.eql(u8, data[pos..][0..4], "IHDR")) return error.ExpectedIhdr;
    pos += 4;
    const width: usize = std.mem.readInt(u32, data[pos..][0..4], .big);
    pos += 4;
    const height: usize = std.mem.readInt(u32, data[pos..][0..4], .big);
    pos += 4;
    const bit_depth = data[pos];
    const color_type = data[pos + 1];
    const interlace = data[pos + 4];
    pos += 5 + 4; // 5 bytes (depth, color, comp, filter, interlace) + CRC

    if (bit_depth != 8 or color_type != 6 or interlace != 0)
        return error.UnsupportedPngFormat;

    // Find the single IDAT chunk (error if multiple)
    var idat_data: ?[]const u8 = null;
    while (pos < data.len) {
        const chunk_len: usize = std.mem.readInt(u32, data[pos..][0..4], .big);
        const chunk_type = data[pos + 4 ..][0..4];
        pos += 8;
        if (std.mem.eql(u8, chunk_type, "IDAT")) {
            if (idat_data != null) return error.MultipleIdatChunksNotSupported;
            idat_data = data[pos..][0..chunk_len];
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        }
        pos += chunk_len + 4; // data + CRC
    }
    const compressed = idat_data orelse return error.NoIdatChunk;

    // Skip 2-byte zlib header, decompress the raw deflate stream
    var input_reader: std.Io.Reader = .fixed(compressed[2..]);
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&input_reader, .raw, &decompress_buf);

    const stride = width * 4;
    const pixels = try allocator.alloc([4]u8, width * height);
    var cur_row = try allocator.alloc(u8, stride);
    var prev_row = try allocator.alloc(u8, stride);
    @memset(prev_row, 0);

    for (0..height) |y| {
        var filter_buf: [1]u8 = undefined;
        try decompressor.reader.readSliceAll(&filter_buf);
        const filter_type = filter_buf[0];
        try decompressor.reader.readSliceAll(cur_row);

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
            pixels[y * width + x] = .{
                cur_row[x * 4 + 0],
                cur_row[x * 4 + 1],
                cur_row[x * 4 + 2],
                cur_row[x * 4 + 3],
            };
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
