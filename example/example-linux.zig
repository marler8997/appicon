const exampleicon = @import("exampleicon");
const x11 = @import("x11");
const std = @import("std");

const window_width = 500;
const window_height = 300;

const config: exampleicon.Config = .{
    .id = "appicon-example",
    .startup_wm_class = "AppiconExample",
    .desktop_entry = .{
        .Name = "Appicon Example",
        .Comment = "Test icon integration",
        .Exec = "appicon-example",
        .Categories = "Development;",
    },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const environ = init.minimal.environ;

    // GNOME matches windows to .desktop files via StartupWMClass, but only if it
    // can find the Exec binary in PATH. Ensure we're symlinked there so the icon
    // shows up in the taskbar. Real apps would handle this via their installer.
    try ensureSelfExeInPath(io, environ, config.desktop_entry.Exec);

    exampleicon.installDesktop(io, environ, config) catch |err| {
        std.debug.print("failed to install desktop files: {}\n", .{err});
    };

    const stream: std.Io.net.Stream, const ids: Ids, const root: Root = blk: {
        var read_buffer: [1000]u8 = undefined;
        var socket_reader, const used_auth = try x11.draft.connect(io, environ, &read_buffer);
        errdefer x11.disconnect(io, socket_reader.stream);
        _ = used_auth;
        const setup = x11.readSetupSuccess(&socket_reader.interface) catch |err| switch (err) {
            error.ReadFailed => return socket_reader.err.?,
            error.EndOfStream, error.Protocol => |e| return e,
        };
        std.log.info("setup reply {f}", .{setup});
        var source: x11.Source = .initFinishSetup(&socket_reader.interface, &setup);
        const screen = (x11.draft.readSetupDynamic(&source, &setup, .{}) catch |err| switch (err) {
            error.ReadFailed => return socket_reader.err.?,
            error.EndOfStream, error.Protocol => |e| return e,
        }) orelse {
            std.log.err("no screen?", .{});
            std.process.exit(0xff);
        };
        const id_range = try x11.IdRange.init(setup.resource_id_base, setup.resource_id_mask);
        if (id_range.capacity() < Ids.needed_capacity) {
            std.log.err("X server id range capacity {} is less than needed {}", .{ id_range.capacity(), Ids.needed_capacity });
            std.process.exit(0xff);
        }
        break :blk .{
            socket_reader.stream, .{ .range = id_range },
            .{
                .window = screen.root,
                .visual = screen.root_visual,
                .depth = x11.Depth.init(screen.root_depth) orelse std.debug.panic(
                    "unsupported depth {}",
                    .{screen.root_depth},
                ),
            },
        };
    };
    defer x11.disconnect(io, stream);

    var write_buffer: [1000]u8 = undefined;
    var read_buffer: [1000]u8 = undefined;
    var socket_writer = stream.writer(io, &write_buffer);
    var socket_reader = stream.reader(io, &read_buffer);
    var sink: x11.RequestSink = .{ .writer = &socket_writer.interface };
    var source: x11.Source = .initAfterSetup(&socket_reader.interface);
    run(ids, &root, &sink, &source) catch |err| switch (err) {
        error.WriteFailed => |e| return x11.onWriteError(e, socket_writer.err.?),
        error.ReadFailed, error.EndOfStream, error.Protocol => |e| return source.onReadError(e, socket_reader.err),
        error.UnexpectedMessage => |e| return e,
    };
}

fn run(
    ids: Ids,
    root: *const Root,
    sink: *x11.RequestSink,
    source: *x11.Source,
) error{ WriteFailed, ReadFailed, EndOfStream, Protocol, UnexpectedMessage }!void {
    try sink.InternAtom(.{ .only_if_exists = false, .name = .initComptime("_NET_WM_ICON") });
    try sink.writer.flush();
    const reply, _ = try source.readSynchronousReplyFull(sink.sequence, .InternAtom);

    try sink.CreateWindow(
        .{
            .window_id = ids.window(),
            .parent_window_id = root.window,
            .depth = 0,
            .x = 0,
            .y = 0,
            .width = window_width,
            .height = window_height,
            .border_width = 0,
            .class = .input_output,
            .visual_id = root.visual,
        },
        .{
            .bg_pixel = root.depth.rgbFrom24(0x333333),
            .event_mask = .{ .Exposure = 1 },
        },
    );
    // Set WM_CLASS so the desktop environment matches the window to its .desktop file
    try sink.ChangeProperty(
        .replace,
        ids.window(),
        .WM_CLASS,
        .STRING,
        u8,
        .initComptime(config.id ++ "\x00" ++ config.startup_wm_class ++ "\x00"),
    );
    try exampleicon.setWmIcons(sink, ids.window(), reply.atom);
    try sink.CreateGc(
        ids.gc(),
        ids.window().drawable(),
        .{
            .background = root.depth.rgbFrom24(0x333333),
            .foreground = root.depth.rgbFrom24(0xffffff),
        },
    );

    try sink.MapWindow(ids.window());

    while (true) {
        try sink.writer.flush();
        const msg_kind = try source.readKind();
        switch (msg_kind) {
            .Expose => {
                _ = try source.read2(.Expose);
                try render(sink, ids.window(), ids.gc());
            },
            .MappingNotify => {
                const notify = try source.read2(.MappingNotify);
                std.log.info("ignoring {}", .{notify});
            },
            else => std.debug.panic("unexpected {f}", .{source.readFmtDropError()}),
        }
    }
}

const Root = struct {
    window: x11.Window,
    visual: x11.Visual,
    depth: x11.Depth,
};

const Ids = struct {
    range: x11.IdRange,
    pub fn window(self: Ids) x11.Window {
        return self.range.addAssumeCapacity(0).window();
    }
    pub fn gc(self: Ids) x11.GraphicsContext {
        return self.range.addAssumeCapacity(1).graphicsContext();
    }
    const needed_capacity = 2;
};

/// Ensure the current binary is accessible via the given name in PATH.
/// If not found or pointing to a different binary, symlinks it into a writable PATH directory.
fn ensureSelfExeInPath(io: std.Io, environ: std.process.Environ, name: []const u8) !void {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = exe_buf[0 .. std.process.executablePath(io, &exe_buf) catch |err| {
        std.log.warn("can't get self exe path: {}", .{err});
        return;
    }];
    const path_env = environ.getPosix("PATH") orelse "";
    if (isCurrentExeInPath(io, path_env, name, exe_path)) {
        std.log.info("'{s}' already in PATH pointing to current exe", .{name});
        return;
    }
    var path_iter = std.mem.splitScalar(u8, path_env, ':');
    while (path_iter.next()) |dir| {
        switch (try symlink(io, exe_path, dir, name)) {
            .access_denied => continue,
            .created => {
                std.debug.assert(isCurrentExeInPath(io, path_env, name, exe_path));
                return;
            },
        }
    }
    std.log.warn("failed to install '{s}' into any PATH directory", .{name});
}

/// Check if name exists in PATH and is a symlink pointing to exe_path.
fn isCurrentExeInPath(io: std.Io, path_env: []const u8, name: []const u8, exe_path: []const u8) bool {
    var path_iter = std.mem.splitScalar(u8, path_env, ':');
    while (path_iter.next()) |dir| {
        var check_buf: [std.fs.max_path_bytes]u8 = undefined;
        const check_path = std.fmt.bufPrint(&check_buf, "{s}/{s}", .{ dir, name }) catch continue;
        var target_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target = target_buf[0 .. std.Io.Dir.cwd().readLink(io, check_path, &target_buf) catch continue];
        if (std.mem.eql(u8, target, exe_path)) return true;
    }
    return false;
}

fn symlink(io: std.Io, exe_path: []const u8, dir: []const u8, name: []const u8) !enum { created, access_denied } {
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link_path = try std.fmt.bufPrint(&link_buf, "{s}/{s}", .{ dir, name });

    // Remove existing file/symlink if present
    if (std.Io.Dir.cwd().deleteFile(io, link_path)) {
        std.log.info("deleted symlink '{s}'", .{link_path});
    } else |err| switch (err) {
        error.FileNotFound => {},
        error.AccessDenied => return .access_denied,
        else => |e| return reportErr(e, "delete '{s}' failed with {t}", .{ link_path, err }),
    }
    std.Io.Dir.cwd().symLink(io, exe_path, link_path, .{}) catch |err| switch (err) {
        error.AccessDenied => return .access_denied,
        else => |e| return reportErr(
            e,
            "symlink '{s}' -> '{s}' failed with {t}",
            .{ link_path, exe_path, e },
        ),
    };
    std.log.info("symlinked {s} -> {s}", .{ link_path, exe_path });
    return .created;
}

fn render(sink: *x11.RequestSink, window: x11.Window, gc: x11.GraphicsContext) !void {
    try sink.ClearArea(
        window,
        .{
            .x = 0,
            .y = 0,
            .width = window_width,
            .height = window_height,
        },
        .{ .exposures = false },
    );
    try sink.ImageText8(
        window.drawable(),
        gc,
        .{ .x = 20, .y = window_height / 2 },
        .initComptime("appicon example"),
    );
}

fn reportErr(e: anytype, comptime fmt: []const u8, args: anytype) @TypeOf(e) {
    std.log.err(fmt, args);
    return e;
}
