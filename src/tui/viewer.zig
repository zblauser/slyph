const std = @import("std");
const term = @import("term.zig");
const safeByte = @import("../util.zig").safeByte;
const engine = @import("../layout/engine.zig");
const forms = @import("../forms/forms.zig");

pub const Action = union(enum) {
    quit,
    back,
    forward,
    reload,
    resize,
    follow: []const u8,
    navigate: []const u8,
    edit: struct { field: usize, value: []const u8 },
    toggle: usize,
    submit: usize,
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
    scroll: *usize,
) !Action {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, frame, '\n');
    while (it.next()) |line| try lines.append(gpa, line);

    const out = std.Io.File.stdout();

    const page: u16 = if (rows > 1) rows - 1 else 1;
    const max_scroll: usize = if (lines.items.len > page) lines.items.len - page else 0;
    scroll.* = @min(scroll.*, max_scroll);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    while (true) {
        if (resized(io, cols, rows)) return .resize;
        try draw(gpa, io, out, &buf, lines.items, scroll.*, cols, page, bar);
        const b = switch (term.pollByte(tick_ms)) {
            .byte => |c| c,
            .timeout => continue,
            .eof => break,
        };
        switch (b) {
            'Q' => return .quit,
            'q' => {
                if (try promptText(gpa, io, out, &buf, cols, rows, "quit? y/n", "")) |a| {
                    defer gpa.free(a);
                    if (a.len > 0 and (a[0] == 'y' or a[0] == 'Y')) return .quit;
                }
            },
            '?' => return .{ .navigate = try gpa.dupe(u8, help_url) },
            'H' => return .back,
            'L' => return .forward,
            'r' => return .reload,
            'j' => scroll.* = @min(scroll.* + 1, max_scroll),
            'k' => scroll.* -|= 1,
            'd', ' ' => scroll.* = @min(scroll.* + page / 2, max_scroll),
            'u', 'b' => scroll.* -|= page / 2,
            'g' => scroll.* = 0,
            'G' => scroll.* = max_scroll,
            0x1b => {
                const intro = switch (term.pollByte(esc_ms)) {
                    .byte => |c| c,
                    else => continue,
                };
                if (intro != '[' and intro != 'O') continue;
                const code = switch (term.pollByte(esc_ms)) {
                    .byte => |c| c,
                    else => continue,
                };
                switch (code) {
                    'A' => scroll.* -|= 1,
                    'B' => scroll.* = @min(scroll.* + 1, max_scroll),
                    'H' => scroll.* = 0,
                    'F' => scroll.* = max_scroll,
                    '5' => {
                        _ = term.pollByte(esc_ms);
                        scroll.* -|= page;
                    },
                    '6' => {
                        _ = term.pollByte(esc_ms);
                        scroll.* = @min(scroll.* + page, max_scroll);
                    },
                    else => {},
                }
            },
            'f' => {
                if (try promptIndex(gpa, io, out, &buf, cols, rows, "follow link", links.len)) |n|
                    return .{ .follow = links[n - 1] };
            },
            0x0c, ':' => {
                if (try promptText(gpa, io, out, &buf, cols, rows, "url", "")) |u| {
                    if (u.len > 0) return .{ .navigate = u };
                    gpa.free(u);
                }
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
    const pos = position(scroll, lines.len, page);
    try statusBar(gpa, buf, bar, &pos, cols);
    try out.writeStreamingAll(io, buf.items);
}

fn position(scroll: usize, total: usize, page: u16) [6]u8 {
    if (total <= page) return "  ALL ".*;
    const max = total - page;
    if (scroll == 0) return "  TOP ".*;
    if (scroll >= max) return "  BOT ".*;
    var out: [6]u8 = "  ??  ".*;
    _ = std.fmt.bufPrint(&out, " {d:>3}% ", .{scroll * 100 / max}) catch {};
    return out;
}

fn statusBar(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), text: []const u8, right: []const u8, cols: u16) !void {
    try buf.appendSlice(gpa, "\x1b[7m");
    const right_w: u16 = @min(@as(u16, @intCast(right.len)), cols);
    const left_max = cols - right_w;
    var w: u16 = 0;
    for (text) |c| {
        if (w >= left_max) break;
        try buf.append(gpa, safeByte(c));
        w += 1;
    }
    while (w < left_max) : (w += 1) try buf.append(gpa, ' ');
    for (right[0..right_w]) |c| try buf.append(gpa, safeByte(c));
    try buf.appendSlice(gpa, "\x1b[0m");
}

fn promptIndex(gpa: std.mem.Allocator, io: std.Io, out: std.Io.File, buf: *std.ArrayList(u8), cols: u16, rows: u16, label: []const u8, count: usize) !?usize {
    const s = (try promptText(gpa, io, out, buf, cols, rows, label, "")) orelse return null;
    defer gpa.free(s);
    const n = std.fmt.parseInt(usize, s, 10) catch return null;
    return if (n >= 1 and n <= count) n else null;
}

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
        try statusBar(gpa, buf, prompt.items, "", cols);
        try out.writeStreamingAll(io, buf.items);

        switch (term.readByte() orelse return null) {
            '\r', '\n' => return try text.toOwnedSlice(gpa),
            0x1b => return null,
            0x7f, 0x08 => if (text.items.len > 0) {
                _ = text.pop();
            },
            else => |c| if (c >= 0x20 and c < 0x7f) try text.append(gpa, c),
        }
    }
}

pub const help_url = "about:help";

const enter_ui = "\x1b[?1049h\x1b[?25l";
const exit_ui = "\x1b[?25h\x1b[?1049l";

const tick_ms: i32 = 100;
const esc_ms: i32 = 50;

var ui_raw: term.Raw = undefined;

pub fn progress(io: std.Io, cols: u16, rows: u16, text: []const u8) void {
    var buf: [1024]u8 = undefined;
    std.Io.File.stdout().writeStreamingAll(io, progressBytes(&buf, cols, rows, text)) catch {};
}

fn progressBytes(buf: []u8, cols: u16, rows: u16, text: []const u8) []u8 {
    const tail = "\x1b[0m";
    const head = std.fmt.bufPrint(buf, "\x1b[{d};1H\x1b[7m", .{rows}) catch return buf[0..0];
    var n = head.len;
    if (n + tail.len >= buf.len) return buf[0..0];
    const width: usize = @min(@as(usize, cols), buf.len - n - tail.len);
    var w: usize = 0;
    while (w < width) : (w += 1) {
        buf[n] = if (w < text.len) safeByte(text[w]) else ' ';
        n += 1;
    }
    @memcpy(buf[n..][0..tail.len], tail);
    return buf[0 .. n + tail.len];
}

pub fn beginUi(io: std.Io) !void {
    ui_raw = try term.enterRaw();
    try std.Io.File.stdout().writeStreamingAll(io, enter_ui);
}

pub fn endUi(io: std.Io) void {
    std.Io.File.stdout().writeStreamingAll(io, exit_ui) catch {};
    term.restore(ui_raw);
}

const Poll = term.Poll;

fn resized(io: std.Io, cols: u16, rows: u16) bool {
    const sz = currentSize(io) orelse return false;
    return sz[0] != cols or sz[1] != rows;
}

fn currentSize(io: std.Io) ?[2]u16 {
    const sz = term.size(io, std.Io.File.stdout());
    return if (sz.tty) .{ sz.cols, sz.rows } else null;
}

test "progress line targets the last row, pads to width, resets sgr" {
    var buf: [1024]u8 = undefined;
    const out = progressBytes(&buf, 12, 24, " loading");
    try std.testing.expectEqualStrings("\x1b[24;1H\x1b[7m loading    \x1b[0m", out);
}

test "progress truncates text longer than the terminal" {
    var buf: [1024]u8 = undefined;
    const out = progressBytes(&buf, 5, 3, " loading https://example.com/very/long");
    try std.testing.expectEqualStrings("\x1b[3;1H\x1b[7m load\x1b[0m", out);
}
