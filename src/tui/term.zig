const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;

pub const Size = struct { cols: u16, rows: u16, tty: bool };

pub const Poll = union(enum) { byte: u8, timeout, eof };

pub const Raw = if (is_windows) Windows.State else Posix.State;

pub fn enterRaw() !Raw {
    return if (is_windows) Windows.enterRaw() else Posix.enterRaw();
}

pub fn restore(saved: Raw) void {
    if (is_windows) Windows.restore(saved) else Posix.restore(saved);
}

pub fn pollByte(timeout_ms: i32) Poll {
    return if (is_windows) Windows.pollByte(timeout_ms) else Posix.pollByte(timeout_ms);
}

pub fn readByte() ?u8 {
    return if (is_windows) Windows.readByte() else Posix.readByte();
}

pub fn size(io: std.Io, file: std.Io.File) Size {
    const fallback = Size{ .cols = 80, .rows = 24, .tty = false };
    const measured = if (is_windows) Windows.size(file) orelse fallback else Posix.size(io, file) orelse fallback;
    return applyEnvOverride(measured);
}

var forced_cols: ?u16 = null;
var forced_rows: ?u16 = null;

pub fn setOverride(cols: ?[]const u8, rows: ?[]const u8) void {
    forced_cols = parseDim(cols);
    forced_rows = parseDim(rows);
}

const max_dim = 1000;

fn parseDim(raw: ?[]const u8) ?u16 {
    const text = raw orelse return null;
    const n = std.fmt.parseInt(u16, std.mem.trim(u8, text, " \t\r\n"), 10) catch return null;
    return if (n >= 2 and n <= max_dim) n else null;
}

fn applyEnvOverride(measured: Size) Size {
    var out = measured;
    if (forced_cols) |c| out.cols = if (measured.tty) @min(c, measured.cols) else c;
    if (forced_rows) |r| out.rows = if (measured.tty) @min(r, measured.rows) else r;
    return out;
}

const Posix = struct {
    const posix = std.posix;

    const State = posix.termios;

    fn enterRaw() !State {
        const saved = try posix.tcgetattr(posix.STDIN_FILENO);
        var raw = saved;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
        return saved;
    }

    fn restore(saved: State) void {
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, saved) catch {};
    }

    fn pollByte(timeout_ms: i32) Poll {
        var fds = [_]posix.pollfd{.{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 }};
        const n = posix.poll(&fds, timeout_ms) catch return .eof;
        if (n == 0) return .timeout;
        var b: [1]u8 = undefined;
        const r = posix.read(posix.STDIN_FILENO, &b) catch return .eof;
        return if (r == 0) .eof else .{ .byte = b[0] };
    }

    fn readByte() ?u8 {
        var b: [1]u8 = undefined;
        const n = posix.read(posix.STDIN_FILENO, &b) catch return null;
        return if (n == 0) null else b[0];
    }

    fn size(io: std.Io, file: std.Io.File) ?Size {
        var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const r = io.operate(.{ .device_io_control = .{
            .file = file,
            .code = posix.T.IOCGWINSZ,
            .arg = &ws,
        } }) catch return null;
        if (r.device_io_control >= 0 and ws.col > 0) return .{ .cols = ws.col, .rows = ws.row, .tty = true };
        return null;
    }
};

const Windows = struct {
    const w = std.os.windows;

    const std_input_handle: w.DWORD = @bitCast(@as(i32, -10));
    const std_output_handle: w.DWORD = @bitCast(@as(i32, -11));

    const enable_line_input: w.DWORD = 0x0002;
    const enable_echo_input: w.DWORD = 0x0004;
    const enable_virtual_terminal_input: w.DWORD = 0x0200;
    const enable_processed_output: w.DWORD = 0x0001;
    const wait_object_0: w.DWORD = 0;

    extern "kernel32" fn GetStdHandle(nStdHandle: w.DWORD) callconv(.winapi) w.HANDLE;
    extern "kernel32" fn GetConsoleMode(hConsoleHandle: w.HANDLE, lpMode: *w.DWORD) callconv(.winapi) w.BOOL;
    extern "kernel32" fn SetConsoleMode(hConsoleHandle: w.HANDLE, dwMode: w.DWORD) callconv(.winapi) w.BOOL;
    extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: w.HANDLE, lpInfo: *ScreenBufferInfo) callconv(.winapi) w.BOOL;
    extern "kernel32" fn WaitForSingleObject(hHandle: w.HANDLE, dwMilliseconds: w.DWORD) callconv(.winapi) w.DWORD;
    extern "kernel32" fn ReadFile(
        hFile: w.HANDLE,
        lpBuffer: [*]u8,
        nNumberOfBytesToRead: w.DWORD,
        lpNumberOfBytesRead: *w.DWORD,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) w.BOOL;

    const SmallRect = extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 };
    const ScreenBufferInfo = extern struct {
        dwSize: w.COORD,
        dwCursorPosition: w.COORD,
        wAttributes: w.WORD,
        srWindow: SmallRect,
        dwMaximumWindowSize: w.COORD,
    };

    const State = struct { in: w.DWORD, out: w.DWORD, ok: bool };

    fn enterRaw() !State {
        const hin = GetStdHandle(std_input_handle);
        const hout = GetStdHandle(std_output_handle);
        var in_mode: w.DWORD = 0;
        var out_mode: w.DWORD = 0;
        if (!GetConsoleMode(hin, &in_mode).toBool()) return error.NotATerminal;
        if (!GetConsoleMode(hout, &out_mode).toBool()) return error.NotATerminal;

        const raw_in = (in_mode & ~(enable_line_input | enable_echo_input)) | enable_virtual_terminal_input;
        const raw_out = out_mode | w.ENABLE_VIRTUAL_TERMINAL_PROCESSING | enable_processed_output;
        _ = SetConsoleMode(hin, raw_in);
        _ = SetConsoleMode(hout, raw_out);
        return .{ .in = in_mode, .out = out_mode, .ok = true };
    }

    fn restore(saved: State) void {
        if (!saved.ok) return;
        _ = SetConsoleMode(GetStdHandle(std_input_handle), saved.in);
        _ = SetConsoleMode(GetStdHandle(std_output_handle), saved.out);
    }

    fn pollByte(timeout_ms: i32) Poll {
        const hin = GetStdHandle(std_input_handle);
        const ms: w.DWORD = if (timeout_ms < 0) std.math.maxInt(w.DWORD) else @intCast(timeout_ms);
        if (WaitForSingleObject(hin, ms) != wait_object_0) return .timeout;
        return readOne(hin);
    }

    fn readByte() ?u8 {
        return switch (readOne(GetStdHandle(std_input_handle))) {
            .byte => |b| b,
            else => null,
        };
    }

    fn readOne(hin: w.HANDLE) Poll {
        var b: [1]u8 = undefined;
        var n: w.DWORD = 0;
        if (!ReadFile(hin, &b, 1, &n, null).toBool()) return .eof;
        return if (n == 0) .eof else .{ .byte = b[0] };
    }

    fn size(_: std.Io.File) ?Size {
        var info: ScreenBufferInfo = undefined;
        if (!GetConsoleScreenBufferInfo(GetStdHandle(std_output_handle), &info).toBool()) return null;
        const cols = info.srWindow.Right - info.srWindow.Left + 1;
        const rows = info.srWindow.Bottom - info.srWindow.Top + 1;
        if (cols <= 0 or rows <= 0) return null;
        return .{ .cols = @intCast(cols), .rows = @intCast(rows), .tty = true };
    }
};

test "size override applies LINES/COLUMNS and rejects junk" {
    const base = Size{ .cols = 100, .rows = 40, .tty = true };

    setOverride(null, null);
    try std.testing.expectEqual(base, applyEnvOverride(base));

    setOverride("80", "20");
    try std.testing.expectEqual(Size{ .cols = 80, .rows = 20, .tty = true }, applyEnvOverride(base));

    setOverride("wat", "0");
    try std.testing.expectEqual(base, applyEnvOverride(base));

    setOverride(null, " 24 ");
    try std.testing.expectEqual(Size{ .cols = 100, .rows = 24, .tty = true }, applyEnvOverride(base));

    setOverride("99999", "60000");
    try std.testing.expectEqual(base, applyEnvOverride(base));

    setOverride("5000", "4000");
    try std.testing.expectEqual(base, applyEnvOverride(base));

    setOverride("400", "300");
    try std.testing.expectEqual(base, applyEnvOverride(base));

    const headless = Size{ .cols = 80, .rows = 24, .tty = false };
    setOverride("120", "40");
    try std.testing.expectEqual(Size{ .cols = 120, .rows = 40, .tty = false }, applyEnvOverride(headless));

    setOverride(null, null);
}
