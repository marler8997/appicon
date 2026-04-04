const global = struct {
    var icons: Icons = undefined;
};

pub fn main() !void {
    const dpi: XY(u32) = blk: {
        const monitor = win32.MonitorFromPoint(.{ .x = 0, .y = 0 }, win32.MONITOR_DEFAULTTOPRIMARY);
        var dpi: XY(u32) = undefined;
        const hr = win32.GetDpiForMonitor(
            monitor,
            win32.MDT_EFFECTIVE_DPI,
            &dpi.x,
            &dpi.y,
        );
        if (hr < 0) {
            std.log.warn("GetDpiForMonitor failed, hresult=0x{x}", .{@as(u32, @bitCast(hr))});
            break :blk .{ .x = 96, .y = 96 };
        }
        std.log.debug("primary monitor dpi {}x{}", .{ dpi.x, dpi.y });
        break :blk dpi;
    };

    global.icons = getIcons(dpi);

    const CLASS_NAME = win32.L("AppIconExample");

    {
        const wc = win32.WNDCLASSEXW{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            .style = .{ .VREDRAW = 1, .HREDRAW = 1 },
            .lpfnWndProc = WndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = win32.GetModuleHandleW(null),
            .hIcon = global.icons.large,
            .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = CLASS_NAME,
            .hIconSm = global.icons.small,
        };
        if (0 == win32.RegisterClassExW(&wc)) win32.panicWin32(
            "RegisterClass",
            win32.GetLastError(),
        );
    }

    const hwnd = win32.CreateWindowExW(
        .{ .APPWINDOW = 1 },
        CLASS_NAME,
        win32.L("appicon example"),
        win32.WS_OVERLAPPEDWINDOW,
        0,
        0,
        500,
        300,
        null, // parent window
        null, // menu
        win32.GetModuleHandleW(null),
        null,
    ) orelse win32.panicWin32("CreateWindow", win32.GetLastError());

    if (0 == win32.UpdateWindow(hwnd)) win32.panicWin32("UpdateWindow", win32.GetLastError());
    _ = win32.ShowWindow(hwnd, .{ .SHOWNORMAL = 1 });

    // try some things to bring our window to the top
    const HWND_TOP: ?win32.HWND = null;
    _ = win32.SetWindowPos(hwnd, HWND_TOP, 0, 0, 0, 0, .{ .NOMOVE = 1, .NOSIZE = 1 });
    _ = win32.SetForegroundWindow(hwnd);
    _ = win32.BringWindowToTop(hwnd);

    while (true) {
        var msg: win32.MSG = undefined;
        const result = win32.GetMessageW(&msg, null, 0, 0);
        if (result < 0) win32.panicWin32("GetMessage", win32.GetLastError());
        if (result == 0) break; // means WM_QUIT
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
}

fn WndProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_CLOSE, win32.WM_DESTROY => {
            win32.PostQuitMessage(0);
            return 0;
        },
        win32.WM_ERASEBKGND => return 1,
        win32.WM_PAINT => {
            const dc, var ps = win32.beginPaint(hwnd);
            defer win32.endPaint(hwnd, &ps);
            win32.fillRect(dc, ps.rcPaint, @ptrCast(win32.GetStockObject(win32.WHITE_BRUSH)));
            win32.textOutW(dc, 10, 10, win32.L("appicon example"));
            return 0;
        },
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

const Icons = struct {
    small: win32.HICON,
    large: win32.HICON,
};

fn getIcons(dpi: XY(u32)) Icons {
    const small_x = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXSMICON), dpi.x);
    const small_y = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYSMICON), dpi.y);
    const large_x = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXICON), dpi.x);
    const large_y = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYICON), dpi.y);
    std.log.debug("icons small={}x{} large={}x{} at dpi {}x{}", .{
        small_x, small_y,
        large_x, large_y,
        dpi.x,   dpi.y,
    });
    const small = win32.LoadImageW(
        win32.GetModuleHandleW(null),
        @ptrFromInt(1), // icon 1
        .ICON,
        small_x,
        small_y,
        win32.LR_SHARED,
    ) orelse win32.panicWin32("LoadImage for small icon", win32.GetLastError());
    const large = win32.LoadImageW(
        win32.GetModuleHandleW(null),
        @ptrFromInt(1), // icon 1
        .ICON,
        large_x,
        large_y,
        win32.LR_SHARED,
    ) orelse win32.panicWin32("LoadImage for large icon", win32.GetLastError());
    return .{ .small = @ptrCast(small), .large = @ptrCast(large) };
}

fn XY(comptime T: type) type {
    return struct {
        x: T,
        y: T,
    };
}

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

const std = @import("std");
const win32 = @import("win32").everything;
