pub const Entry = struct {
    Name: []const u8,
    Exec: []const u8,
    // NOTE: Icon set by Config.id
    Comment: ?[]const u8 = null,
    GenericName: ?[]const u8 = null,
    Categories: ?[]const u8 = null,
    // NOTE: StartupWMClass  set by Config.startup_wm_class
    Keywords: ?[]const u8 = null,
    Terminal: ?bool = null,
    MimeType: ?[]const u8 = null,
    NoDisplay: ?bool = null,
    StartupNotify: ?bool = null,
};

pub fn makeDesktopFile(comptime config: appicon.Config) [:0]const u8 {
    const e = config.desktop_entry;
    return "[Desktop Entry]\n" ++
        "Type=Application\n" ++
        "Name=" ++ e.Name ++ "\n" ++
        "Exec=" ++ e.Exec ++ "\n" ++
        "Icon=" ++ config.id ++ "\n" ++
        "StartupWMClass=" ++ config.startup_wm_class ++ "\n" ++
        (if (e.Comment) |v| "Comment=" ++ v ++ "\n" else "") ++
        (if (e.GenericName) |v| "GenericName=" ++ v ++ "\n" else "") ++
        (if (e.Categories) |v| "Categories=" ++ v ++ "\n" else "") ++
        (if (e.Keywords) |v| "Keywords=" ++ v ++ "\n" else "") ++
        (if (e.Terminal) |v| "Terminal=" ++ (if (v) "true" else "false") ++ "\n" else "") ++
        (if (e.MimeType) |v| "MimeType=" ++ v ++ "\n" else "") ++
        (if (e.NoDisplay) |v| "NoDisplay=" ++ (if (v) "true" else "false") ++ "\n" else "") ++
        (if (e.StartupNotify) |v| "StartupNotify=" ++ (if (v) "true" else "false") ++ "\n" else "");
}

pub fn install(
    io: std.Io,
    environ: std.process.Environ,
    comptime config: appicon.Config,
    icons: []const appicon.Icon,
) !void {
    var data_home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const data_home = environ.getPosix("XDG_DATA_HOME") orelse blk: {
        const home = environ.getPosix("HOME") orelse {
            std.log.warn("can't install desktop files, no $HOME or $XDG_DATA_HOME environment variable", .{});
            return;
        };
        break :blk std.fmt.bufPrint(&data_home_buf, "{s}/.local/share", .{home}) catch
            return error.HomePathTooLong;
    };

    var icons_changed = false;
    for (icons) |entry| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/icons/hicolor/{}x{}/apps/{s}.png", .{ data_home, entry.size, entry.size, config.id }) catch
            return error.DataHomePathTooLong;
        if (try installFile(io, path, .{ .png = PngIterator.init(entry.size, entry.idat_zlib) }))
            icons_changed = true;
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const desktop_path = std.fmt.bufPrint(
        &path_buf,
        "{s}/applications/{s}.desktop",
        .{ data_home, config.id },
    ) catch return error.DataHomePathTooLong;

    const desktop_file_content = makeDesktopFile(config);
    const desktop_changed = try installFile(io, desktop_path, .{ .slice = desktop_file_content });

    if (icons_changed) {
        var icon_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const icon_dir = std.fmt.bufPrint(&icon_dir_buf, "{s}/icons/hicolor", .{data_home}) catch
            return error.DataHomePathTooLong;
        runCacheUpdate(io, "gtk-update-icon-cache", icon_dir);
    }
    if (desktop_changed) {
        var apps_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const apps_dir = std.fmt.bufPrint(&apps_dir_buf, "{s}/applications", .{data_home}) catch
            return error.DataHomePathTooLong;
        runCacheUpdate(io, "update-desktop-database", apps_dir);
    }
}

fn installFile(io: std.Io, path: []const u8, content: ContentIterator) !bool {
    const changed: FileChanged = switch (try fileStatus(io, path, content)) {
        .up_to_date => {
            std.log.info("{s}: already installed", .{path});
            return false;
        },
        .not_found => .not_found,
        .outdated => .outdated,
    };

    const dir_path = std.fs.path.dirname(path) orelse return false;
    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var iter = content;
    while (iter.next()) |chunk| {
        try file.writeStreamingAll(io, chunk);
    }
    std.log.info("{s}: {s}", .{
        path,
        switch (changed) {
            .not_found => "newly installed",
            .outdated => "updated",
        },
    });
    return true;
}

const FileChanged = enum { not_found, outdated };
const FileStatus = enum { not_found, outdated, up_to_date };

fn fileStatus(io: std.Io, path: []const u8, content: ContentIterator) !FileStatus {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .not_found,
        else => return err,
    };
    defer file.close(io);

    var iter = content;
    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const reader = &file_reader.interface;

    while (iter.next()) |expected_chunk| {
        var chunk_pos: usize = 0;
        while (chunk_pos < expected_chunk.len) {
            const actual = reader.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => return .outdated,
                error.ReadFailed => return file_reader.err.?,
            };
            const avail = @min(actual.len, expected_chunk.len - chunk_pos);
            if (!std.mem.eql(u8, actual[0..avail], expected_chunk[chunk_pos..][0..avail]))
                return .outdated;
            reader.toss(avail);
            chunk_pos += avail;
        }
    }

    // Check file has no extra bytes
    _ = reader.peekByte() catch |err| switch (err) {
        error.EndOfStream => return .up_to_date,
        error.ReadFailed => return file_reader.err.?,
    };
    return .outdated;
}

const ContentIterator = union(enum) {
    slice: ?[]const u8,
    png: PngIterator,

    fn next(self: *ContentIterator) ?[]const u8 {
        switch (self.*) {
            .slice => |*s| {
                const data = s.* orelse return null;
                s.* = null;
                return data;
            },
            .png => |*p| return p.next(),
        }
    }
};

fn runCacheUpdate(io: std.Io, cmd: []const u8, dir: []const u8) void {
    var child = std.process.spawn(io, .{ .argv = &.{ cmd, dir } }) catch |err| {
        std.log.warn("failed to run {s}: {}", .{ cmd, err });
        return;
    };
    const term = child.wait(io) catch |err| {
        std.log.warn("failed to wait for {s}: {}", .{ cmd, err });
        return;
    };
    if (term.success()) {
        std.log.info("{s}: success", .{cmd});
    } else {
        std.log.warn("{s}: {f}", .{ cmd, term });
    }
}

const PngIterator = struct {
    state: u8 = 0,
    idat_zlib: []const u8,
    ihdr: [13]u8,
    buf: [4]u8 = undefined,

    fn init(size: u16, idat_zlib: []const u8) PngIterator {
        var ihdr: [13]u8 = undefined;
        std.mem.writeInt(u32, ihdr[0..4], size, .big);
        std.mem.writeInt(u32, ihdr[4..8], size, .big);
        ihdr[8] = 8; // bit depth
        ihdr[9] = 6; // color type: RGBA
        ihdr[10] = 0; // compression
        ihdr[11] = 0; // filter
        ihdr[12] = 0; // interlace
        return .{ .idat_zlib = idat_zlib, .ihdr = ihdr };
    }

    fn next(self: *PngIterator) ?[]const u8 {
        defer self.state += 1;
        return switch (self.state) {
            0 => &.{ 137, 80, 78, 71, 13, 10, 26, 10 }, // PNG signature
            1 => self.int(u32, 13), // IHDR length
            2 => "IHDR",
            3 => &self.ihdr,
            4 => self.crc("IHDR", &self.ihdr),
            5 => self.int(u32, @intCast(self.idat_zlib.len)), // IDAT length
            6 => "IDAT",
            7 => self.idat_zlib,
            8 => self.crc("IDAT", self.idat_zlib),
            9 => self.int(u32, 0), // IEND length
            10 => "IEND",
            11 => self.crc("IEND", &.{}),
            else => null,
        };
    }

    fn int(self: *PngIterator, comptime T: type, value: T) []const u8 {
        std.mem.writeInt(T, &self.buf, value, .big);
        return &self.buf;
    }

    fn crc(self: *PngIterator, chunk_type: *const [4]u8, data: []const u8) []const u8 {
        var h = std.hash.Crc32.init();
        h.update(chunk_type);
        h.update(data);
        std.mem.writeInt(u32, &self.buf, h.final(), .big);
        return &self.buf;
    }
};

const std = @import("std");
const appicon = @import("appicon.zig");
