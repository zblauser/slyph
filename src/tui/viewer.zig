//! Interactive terminal viewer — the browser chrome (DESIGN.md: keyboard-only,
//! vim-ish, anti-mouse). Scrolls a fully rendered frame in the alternate screen
//! and drives navigation + form editing. Scrolling is a cheap row-slice of the
//! pre-rendered frame — no relayout per keystroke (the Box-tree payoff).
//!
//! Keys: j/k line, d/u or space/b half-page, g/G top/bottom,
//!       f follow a [n] link, i edit/activate a {n} field, H back, q quit.

const std = @import("std");
const posix = std.posix;
const engine = @import("../layout/engine.zig");
const forms = @import("../forms/forms.zig");

/// What the user asked for when the viewer returns.
pub const Action = union(enum) {
    quit,
    back,
    follow: []const u8, // href to navigate to
    edit: struct { field: usize, value: []const u8 }, // set fields[field].value (gpa-owned)
    toggle: usize, // flip a checkbox/radio (index into fields)
    submit: usize, // activate submit field (index into fields)
};

pub fn view(
    gpa: std.mem.Allocator,
    io: std.Io,
    frame: []const u8,
    links: []const []const u8,
    fields: []const engine.Field,
    cols: u16,
    rows: u16,
    bar: []const u8,
    scroll: *usize, // preserved across re-entry (e.g. after an edit)
) !Action {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, frame, '\n');
    while (it.next()) |line| try lines.append(gpa, line);

    const out = std.Io.File.stdout();
    const saved = try enterRaw();
    defer restore(saved);
    try out.writeStreamingAll(io, enter_ui);
    defer out.writeStreamingAll(io, exit_ui) catch {};

    const page: u16 = if (rows > 1) rows - 1 else 1; // reserve status bar
    const max_scroll: usize = if (lines.items.len > page) lines.items.len - page else 0;
    scroll.* = @min(scroll.*, max_scroll);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    while (true) {
        try draw(gpa, io, out, &buf, lines.items, scroll.*, cols, page, bar);
        switch (readByte() orelse break) {
            'q' => return .quit,
            'H' => return .back,
            'j' => scroll.* = @min(scroll.* + 1, max_scroll),
            'k' => scroll.* -|= 1,
            'd', ' ' => scroll.* = @min(scroll.* + page / 2, max_scroll),
            'u', 'b' => scroll.* -|= page / 2,
            'g' => scroll.* = 0,
            'G' => scroll.* = max_scroll,
            'f' => {
                if (try promptIndex(gpa, io, out, &buf, cols, rows, "follow link", links.len)) |n|
                    return .{ .follow = links[n - 1] };
            },
            'i' => {
                if (try promptIndex(gpa, io, out, &buf, cols, rows, "field", fields.len)) |n| {
                    switch (fields[n - 1].kind) {
                        .submit => return .{ .submit = n - 1 },
                        .checkbox, .radio => return .{ .toggle = n - 1 },
                        else => {
                            const initial = fields[n - 1].node.value orelse "";
                            if (try promptText(gpa, io, out, &buf, cols, rows, "value", initial)) |v|
                                return .{ .edit = .{ .field = n - 1, .value = v } };
                        },
                    }
                }
            },
            else => {},
        }
    }
    return .quit;
}

fn draw(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: std.Io.File,
    buf: *std.ArrayList(u8),
    lines: []const []const u8,
    scroll: usize,
    cols: u16,
    page: u16,
    bar: []const u8,
) !void {
    buf.clearRetainingCapacity();
    try buf.appendSlice(gpa, "\x1b[H");
    var i: u16 = 0;
    while (i < page) : (i += 1) {
        const r = scroll + i;
        if (r < lines.len) try buf.appendSlice(gpa, lines[r]);
        try buf.appendSlice(gpa, "\x1b[K\r\n");
    }
    try statusBar(gpa, buf, bar, cols);
    try out.writeStreamingAll(io, buf.items);
}

fn statusBar(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), text: []const u8, cols: u16) !void {
    try buf.appendSlice(gpa, "\x1b[7m");
    var w: u16 = 0;
    for (text) |c| {
        if (w >= cols) break;
        try buf.append(gpa, c);
        w += 1;
    }
    while (w < cols) : (w += 1) try buf.append(gpa, ' ');
    try buf.appendSlice(gpa, "\x1b[0m");
}

/// Prompt for a 1-based index in [1, count]; returns null on cancel/out-of-range.
fn promptIndex(gpa: std.mem.Allocator, io: std.Io, out: std.Io.File, buf: *std.ArrayList(u8), cols: u16, rows: u16, label: []const u8, count: usize) !?usize {
    const s = (try promptText(gpa, io, out, buf, cols, rows, label, "")) orelse return null;
    defer gpa.free(s);
    const n = std.fmt.parseInt(usize, s, 10) catch return null;
    return if (n >= 1 and n <= count) n else null;
}

/// Edit a line of text on the status bar. Enter confirms (returns a gpa-owned
/// copy), Esc cancels (null). Backspace edits; printable bytes append.
fn promptText(gpa: std.mem.Allocator, io: std.Io, out: std.Io.File, buf: *std.ArrayList(u8), cols: u16, rows: u16, label: []const u8, initial: []const u8) !?[]u8 {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, initial);

    while (true) {
        buf.clearRetainingCapacity();
        var seq: [16]u8 = undefined;
        try buf.appendSlice(gpa, std.fmt.bufPrint(&seq, "\x1b[{d};1H", .{rows}) catch "");
        var prompt: std.ArrayList(u8) = .empty;
        defer prompt.deinit(gpa);
        try prompt.appendSlice(gpa, label);
        try prompt.appendSlice(gpa, ": ");
        try prompt.appendSlice(gpa, text.items);
        try statusBar(gpa, buf, prompt.items, cols);
        try out.writeStreamingAll(io, buf.items);

        switch (readByte() orelse return null) {
            '\r', '\n' => return try text.toOwnedSlice(gpa),
            0x1b => return null, // Esc
            0x7f, 0x08 => if (text.items.len > 0) {
                _ = text.pop();
            },
            else => |c| if (c >= 0x20 and c < 0x7f) try text.append(gpa, c),
        }
    }
}

// --- terminal control ---

const enter_ui = "\x1b[?1049h\x1b[?25l"; // alt screen, hide cursor
const exit_ui = "\x1b[?25h\x1b[?1049l"; // show cursor, leave alt screen

/// cbreak mode: keys read unbuffered, no echo. ISIG stays on so Ctrl-C works.
fn enterRaw() !posix.termios {
    const saved = try posix.tcgetattr(posix.STDIN_FILENO);
    var raw = saved;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
    return saved;
}

fn restore(saved: posix.termios) void {
    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, saved) catch {};
}

fn readByte() ?u8 {
    var b: [1]u8 = undefined;
    const n = posix.read(posix.STDIN_FILENO, &b) catch return null;
    return if (n == 0) null else b[0];
}
