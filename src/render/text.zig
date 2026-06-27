const std = @import("std");
const boxmod = @import("../layout/box.zig");
const style = @import("../css/style.zig");

const Box = boxmod.Box;

pub fn render(a: std.mem.Allocator, root: Box, ansi: bool, truecolor: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var c = Cursor{ .a = a, .out = &out, .ansi = ansi, .truecolor = truecolor };
    try c.walk(root);
    try out.append(a, '\n');
    return out.toOwnedSlice(a);
}

const Cursor = struct {
    a: std.mem.Allocator,
    out: *std.ArrayList(u8),
    ansi: bool,
    truecolor: bool = false,
    row: u16 = 0,
    col: u16 = 0,

    fn walk(self: *Cursor, box: Box) !void {
        if (box.kind == .text) {
            try self.moveTo(box.rect.x, box.rect.y);
            try self.emit(box.text, box.style);
            self.col += @intCast(boxmod.cellWidth(box.text));
        }
        for (box.children) |child| try self.walk(child);
    }

    fn moveTo(self: *Cursor, x: u16, y: u16) !void {
        while (self.row < y) : (self.row += 1) {
            try self.out.append(self.a, '\n');
            self.col = 0;
        }
        while (self.col < x) : (self.col += 1) try self.out.append(self.a, ' ');
    }

    fn emit(self: *Cursor, text: []const u8, cs: ?*const style.ComputedStyle) !void {
        if (!self.ansi or cs == null) {
            try self.out.appendSlice(self.a, text);
            return;
        }
        const sgr = try openSgr(self.a, self.out, cs.?, self.truecolor);
        try self.out.appendSlice(self.a, text);
        if (sgr) try self.out.appendSlice(self.a, "\x1b[0m");
    }
};

fn openSgr(a: std.mem.Allocator, out: *std.ArrayList(u8), cs: *const style.ComputedStyle, truecolor: bool) !bool {
    var w: std.ArrayList(u8) = .empty;
    defer w.deinit(a);
    if (cs.font_weight == .bold) try appendCode(a, &w, "1");
    if (cs.font_style == .italic) try appendCode(a, &w, "3");
    if (cs.underline) try appendCode(a, &w, "4");
    switch (cs.color) {
        .default => {},
        .rgb => |c| {
            var buf: [20]u8 = undefined;
            const code = if (truecolor)
                std.fmt.bufPrint(&buf, "38;2;{d};{d};{d}", .{ c.r, c.g, c.b }) catch unreachable
            else
                std.fmt.bufPrint(&buf, "38;5;{d}", .{rgbTo256(c.r, c.g, c.b)}) catch unreachable;
            try appendCode(a, &w, code);
        },
    }
    if (w.items.len == 0) return false;
    try out.appendSlice(a, "\x1b[");
    try out.appendSlice(a, w.items);
    try out.append(a, 'm');
    return true;
}

fn appendCode(a: std.mem.Allocator, w: *std.ArrayList(u8), code: []const u8) !void {
    if (w.items.len > 0) try w.append(a, ';');
    try w.appendSlice(a, code);
}

fn rgbTo256(r: u8, g: u8, b: u8) u8 {
    if (r == g and g == b) {
        if (r < 8) return 16;
        if (r > 248) return 231;
        return @intCast(232 + (@as(u16, r) - 8) / 10);
    }
    return @intCast(16 + 36 * cube(r) + 6 * cube(g) + cube(b));
}

fn cube(c: u8) u16 {
    if (c < 48) return 0;
    if (c < 115) return 1;
    return (@as(u16, c) - 35) / 40;
}

const testing = std.testing;
const html = @import("../html/parser.zig");
const cascade = @import("../css/cascade.zig");
const layout = @import("../layout/engine.zig");

fn renderHtml(src: []const u8, width: u16, ansi: bool) ![]u8 {
    var doc = try html.parse(testing.allocator, src);
    defer doc.deinit();
    try cascade.apply(doc.alloc(), &doc, "", null, &.{});
    const page = try layout.layout(doc.alloc(), &doc, width);
    return render(testing.allocator, page.root, ansi, true);
}

const DenyList = @import("../policy.zig").DenyList;

fn renderHtmlPolicy(src: []const u8, host: []const u8, deny: []const u8) ![]u8 {
    var doc = try html.parse(testing.allocator, src);
    defer doc.deinit();
    var p: DenyList = .init(testing.allocator);
    defer p.deinit();
    try p.loadDenyLines(deny);
    try cascade.apply(doc.alloc(), &doc, host, &p, &.{});
    const page = try layout.layout(doc.alloc(), &doc, 80);
    return render(testing.allocator, page.root, true, true);
}

test "plain text output, no ansi when disabled" {
    const out = try renderHtml("<body><p>hello world</p></body>", 80, false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello world\n", out);
}

test "blocks separated by blank line" {
    const out = try renderHtml("<body><p>one</p><p>two</p></body>", 80, false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("one\n\ntwo\n", out);
}

test "wrapping inserts newline at width" {
    const out = try renderHtml("<body><p>aaa bbb ccc ddd</p></body>", 7, false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("aaa bbb\nccc ddd\n", out);
}

test "ansi wraps bold and underline, link gets [n] hint" {
    const out = try renderHtml("<body><p><b>hi</b> <a href=x>link</a></p></body>", 80, true);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\x1b[1mhi\x1b[0m \x1b[4m[1]\x1b[0m \x1b[4mlink\x1b[0m\n", out);
}

test "no ansi escapes leak when ansi disabled even with styles" {
    const out = try renderHtml("<body><p><b>x</b></p></body>", 80, false);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOfScalar(u8, out, '\x1b') == null);
}

test "var() custom property renders as ansi color (mithraeum pattern)" {
    const src =
        "<html><head><style>:root{--gold:#b89656} a{color:var(--gold)}</style></head>" ++
        "<body><a href=x>link</a></body></html>";
    const out = try renderHtml(src, 80, true);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "38;2;184;150;86") != null);
}

test "non-truecolor terminals get 256-color (38;5), not 24-bit (38;2)" {
    var doc = try html.parse(testing.allocator, "<body><p style=\"color:#b89656\">x</p></body>");
    defer doc.deinit();
    try cascade.apply(doc.alloc(), &doc, "", null, &.{});
    const page = try layout.layout(doc.alloc(), &doc, 80);
    const out = try render(testing.allocator, page.root, true, false);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "38;5;137") != null);
    try testing.expect(std.mem.indexOf(u8, out, "38;2;") == null);
}

test "rgbTo256 maps cube and grayscale corners" {
    try testing.expectEqual(@as(u8, 16), rgbTo256(0, 0, 0));
    try testing.expectEqual(@as(u8, 231), rgbTo256(255, 255, 255));
    try testing.expectEqual(@as(u8, 196), rgbTo256(255, 0, 0));
    try testing.expectEqual(@as(u8, 21), rgbTo256(0, 0, 255));
}

test "css policy strips author color from rendered ansi, keeps bold" {
    const src = "<body><p style=\"color:#0000ff\"><b>hi</b></p></body>";
    const blue = "38;2;0;0;255";

    const lit = try renderHtmlPolicy(src, "ban.example", "deny other.host color\n");
    defer testing.allocator.free(lit);
    try testing.expect(std.mem.indexOf(u8, lit, blue) != null);
    try testing.expect(std.mem.indexOf(u8, lit, "\x1b[1") != null);

    const stripped = try renderHtmlPolicy(src, "ban.example", "deny ban.example color\n");
    defer testing.allocator.free(stripped);
    try testing.expect(std.mem.indexOf(u8, stripped, blue) == null);
    try testing.expect(std.mem.indexOf(u8, stripped, "\x1b[1m") != null);
}
