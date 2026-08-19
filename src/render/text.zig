const std = @import("std");
const boxmod = @import("../layout/box.zig");
const style = @import("../css/style.zig");
const thememod = @import("theme.zig");
const safeByte = @import("../util.zig").safeByte;

const Box = boxmod.Box;
const Theme = thememod.Theme;

pub fn render(a: std.mem.Allocator, root: Box, ansi: bool, truecolor: bool, theme: *const Theme) ![]u8 {
    var runs: std.ArrayList(Box) = .empty;
    defer runs.deinit(a);
    try collect(a, root, &runs);
    std.mem.sort(Box, runs.items, {}, beforeInFlow);

    var out: std.ArrayList(u8) = .empty;
    var c = Cursor{ .a = a, .out = &out, .ansi = ansi, .truecolor = truecolor, .theme = theme };
    for (runs.items) |run| try c.paint(run);
    try out.append(a, '\n');
    return out.toOwnedSlice(a);
}

fn collect(a: std.mem.Allocator, box: Box, out: *std.ArrayList(Box)) !void {
    if (box.kind == .text) try out.append(a, box);
    for (box.children) |child| try collect(a, child, out);
}

fn beforeInFlow(_: void, a: Box, b: Box) bool {
    if (a.rect.y != b.rect.y) return a.rect.y < b.rect.y;
    return a.rect.x < b.rect.x;
}

const Cursor = struct {
    a: std.mem.Allocator,
    out: *std.ArrayList(u8),
    ansi: bool,
    truecolor: bool = false,
    theme: *const Theme,
    row: u16 = 0,
    col: u16 = 0,

    fn paint(self: *Cursor, box: Box) !void {
        try self.moveTo(box.rect.x, box.rect.y);
        try self.emit(box.text, box.style);
        self.col += @intCast(boxmod.cellWidth(box.text));
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
            try self.append(text);
            return;
        }
        const sgr = try openSgr(self.a, self.out, cs.?, self.truecolor, self.theme);
        try self.append(text);
        if (sgr) try self.out.appendSlice(self.a, "\x1b[0m");
    }

    fn append(self: *Cursor, text: []const u8) !void {
        for (text) |c| try self.out.append(self.a, safeByte(c));
    }
};

fn openSgr(a: std.mem.Allocator, out: *std.ArrayList(u8), cs: *const style.ComputedStyle, truecolor: bool, theme: *const Theme) !bool {
    var w: std.ArrayList(u8) = .empty;
    defer w.deinit(a);
    if (cs.font_weight == .bold) try appendCode(a, &w, "1");
    if (cs.font_style == .italic) try appendCode(a, &w, "3");
    if (cs.underline) try appendCode(a, &w, "4");
    var fg_buf: [20]u8 = undefined;
    var bg_buf: [20]u8 = undefined;
    if (theme.resolve(cs.color, cs.color_role)) |c| try appendCode(a, &w, colorCode(&fg_buf, true, c, truecolor));
    if (theme.resolve(cs.background, cs.background_role)) |c| try appendCode(a, &w, colorCode(&bg_buf, false, c, truecolor));
    if (w.items.len == 0) return false;
    try out.appendSlice(a, "\x1b[");
    try out.appendSlice(a, w.items);
    try out.append(a, 'm');
    return true;
}

fn colorCode(buf: []u8, fg: bool, c: thememod.Rgb, truecolor: bool) []const u8 {
    const lead: u8 = if (fg) '3' else '4';
    return if (truecolor)
        std.fmt.bufPrint(buf, "{c}8;2;{d};{d};{d}", .{ lead, c.r, c.g, c.b }) catch unreachable
    else
        std.fmt.bufPrint(buf, "{c}8;5;{d}", .{ lead, rgbTo256(c.r, c.g, c.b) }) catch unreachable;
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
    return render(testing.allocator, page.root, ansi, true, &thememod.Theme.terminal);
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
    return render(testing.allocator, page.root, true, true, &thememod.Theme.terminal);
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
    const out = try render(testing.allocator, page.root, true, false, &thememod.Theme.terminal);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "38;5;137") != null);
    try testing.expect(std.mem.indexOf(u8, out, "38;2;") == null);
}

test "light author backgrounds are suppressed, dark tints survive" {
    const glare = try renderHtml("<body><p style=\"background-color:#f8f8f8\">x</p></body>", 80, true);
    defer testing.allocator.free(glare);
    try testing.expect(std.mem.indexOf(u8, glare, "48;") == null);

    const tint = try renderHtml("<body><p style=\"background-color:#202020\">x</p></body>", 80, true);
    defer testing.allocator.free(tint);
    try testing.expect(std.mem.indexOf(u8, tint, "48;2;32;32;32") != null);
}

test "a declared theme ground judges backgrounds by contrast, not lightness" {
    var doc = try html.parse(testing.allocator, "<body><p style=\"background-color:#f8f8f8\">x</p></body>");
    defer doc.deinit();
    try cascade.apply(doc.alloc(), &doc, "", null, &.{});
    const page = try layout.layout(doc.alloc(), &doc, 80);

    var light: thememod.Theme = .terminal;
    light.set(.background, .{ .r = 0xfa, .g = 0xfa, .b = 0xfa });
    const same = try render(testing.allocator, page.root, true, true, &light);
    defer testing.allocator.free(same);
    try testing.expect(std.mem.indexOf(u8, same, "48;") == null);

    var dark: thememod.Theme = .terminal;
    dark.set(.background, .{ .r = 0x10, .g = 0x10, .b = 0x10 });
    const contrast = try render(testing.allocator, page.root, true, true, &dark);
    defer testing.allocator.free(contrast);
    try testing.expect(std.mem.indexOf(u8, contrast, "48;2;248;248;248") != null);
}

test "background-color emits 48;2 and inherits into descendant text" {
    const src = "<body><div style=\"background-color:#202020\">code <b>x</b></div></body>";
    const out = try renderHtml(src, 80, true);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.count(u8, out, "48;2;32;32;32") == 2);
    try testing.expect(std.mem.indexOf(u8, out, "1;48;2;32;32;32") != null);
}

test "background shorthand takes its color, skips url()" {
    const src = "<body><p style=\"background: url(bg.png) #ff0000 no-repeat\">x</p></body>";
    const out = try renderHtml(src, 80, true);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "48;2;255;0;0") != null);
}

test "background quantizes to 48;5 on non-truecolor terminals" {
    var doc = try html.parse(testing.allocator, "<body><p style=\"background-color:#3a3a3a\">x</p></body>");
    defer doc.deinit();
    try cascade.apply(doc.alloc(), &doc, "", null, &.{});
    const page = try layout.layout(doc.alloc(), &doc, 80);
    const out = try render(testing.allocator, page.root, true, false, &thememod.Theme.terminal);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "48;5;237") != null);
    try testing.expect(std.mem.indexOf(u8, out, "48;2;") == null);
}

test "terminal theme emits nothing for UA roles, a theme colors them" {
    const src = "<body><h1>head</h1><a href=x>link</a></body>";

    const bare = try renderHtml(src, 80, true);
    defer testing.allocator.free(bare);
    try testing.expect(std.mem.indexOf(u8, bare, "38;2;") == null);

    var doc = try html.parse(testing.allocator, src);
    defer doc.deinit();
    try cascade.apply(doc.alloc(), &doc, "", null, &.{});
    const page = try layout.layout(doc.alloc(), &doc, 80);
    var t: thememod.Theme = .terminal;
    t.set(.link, .{ .r = 0xb8, .g = 0x96, .b = 0x56 });
    t.set(.heading, .{ .r = 255, .g = 255, .b = 255 });
    const themed = try render(testing.allocator, page.root, true, true, &t);
    defer testing.allocator.free(themed);
    try testing.expect(std.mem.indexOf(u8, themed, "38;2;184;150;86") != null);
    try testing.expect(std.mem.indexOf(u8, themed, "38;2;255;255;255") != null);
}

test "roles_only theme overrides an author color" {
    var doc = try html.parse(testing.allocator, "<body><a href=x style=\"color:#ff0000\">link</a></body>");
    defer doc.deinit();
    try cascade.apply(doc.alloc(), &doc, "", null, &.{});
    const page = try layout.layout(doc.alloc(), &doc, 80);
    var t: thememod.Theme = .terminal;
    t.set(.link, .{ .r = 0, .g = 0, .b = 255 });
    t.roles_only = true;
    const out = try render(testing.allocator, page.root, true, true, &t);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "38;2;0;0;255") != null);
    try testing.expect(std.mem.indexOf(u8, out, "38;2;255;0;0") == null);
}

test "bordered table draws box rules" {
    const src =
        "<body><table border=1><tr><th>id</th><th>name</th></tr>" ++
        "<tr><td>7</td><td>zig</td></tr></table></body>";
    const out = try renderHtml(src, 40, false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\┌──┬────┐
        \\│id│name│
        \\├──┼────┤
        \\│7 │zig │
        \\└──┴────┘
        \\
    , out);
}

test "table without a border attribute stays rule-free" {
    const src = "<body><table><tr><td>id</td><td>name</td></tr></table></body>";
    const out = try renderHtml(src, 40, false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("id name\n", out);
}

test "border:none overrides the border attribute" {
    const src = "<body><table border=1 style=\"border:none\"><tr><td>a</td><td>b</td></tr></table></body>";
    const out = try renderHtml(src, 40, false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a b\n", out);
}

test "colspan suppresses the vertical rule it crosses" {
    const src =
        "<body><table border=1><tr><td colspan=2>wide</td></tr>" ++
        "<tr><td>a</td><td>b</td></tr></table></body>";
    const out = try renderHtml(src, 40, false);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "│wide") != null);
    try testing.expect(std.mem.indexOf(u8, out, "│a") != null);
}

test "pre keeps inline styling on descendants" {
    const out = try renderHtml("<body><pre>plain <b>bold</b></pre></body>", 80, true);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("plain \x1b[1mbold\x1b[0m\n", out);
}

test "pre keeps links followable with their [n] hint" {
    const src = "<body><pre>see <a href=/x>docs</a> here</pre></body>";
    const out = try renderHtml(src, 80, false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("see [1]docs here\n", out);
}

test "pre preserves whitespace, blank lines and line structure" {
    const src = "<body><pre>a   b\n\n  indented</pre></body>";
    const out = try renderHtml(src, 80, false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a   b\n\n  indented\n", out);
}

test "pre honors br as a line break" {
    const out = try renderHtml("<body><pre>one<br>two</pre></body>", 80, false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("one\ntwo\n", out);
}

test "marker role colors list bullets without touching item text" {
    var doc = try html.parse(testing.allocator, "<body><ul><li>item</li></ul></body>");
    defer doc.deinit();
    try cascade.apply(doc.alloc(), &doc, "", null, &.{});
    const page = try layout.layout(doc.alloc(), &doc, 80);
    var t: thememod.Theme = .terminal;
    t.set(.marker, .{ .r = 255, .g = 0, .b = 0 });
    const out = try render(testing.allocator, page.root, true, true, &t);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("    \x1b[38;2;255;0;0m\u{2022}\x1b[0m item\n", out);
}

test "author color on a list item keeps its own bullet color" {
    var doc = try html.parse(testing.allocator, "<body><ul><li style=\"color:#00ff00\">item</li></ul></body>");
    defer doc.deinit();
    try cascade.apply(doc.alloc(), &doc, "", null, &.{});
    const page = try layout.layout(doc.alloc(), &doc, 80);
    var t: thememod.Theme = .terminal;
    t.set(.marker, .{ .r = 255, .g = 0, .b = 0 });
    const out = try render(testing.allocator, page.root, true, true, &t);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "38;2;255;0;0") == null);
    try testing.expect(std.mem.indexOf(u8, out, "38;2;0;255;0") != null);
}

test "rgbTo256 maps cube and grayscale corners" {
    try testing.expectEqual(@as(u8, 16), rgbTo256(0, 0, 0));
    try testing.expectEqual(@as(u8, 231), rgbTo256(255, 255, 255));
    try testing.expectEqual(@as(u8, 196), rgbTo256(255, 0, 0));
    try testing.expectEqual(@as(u8, 21), rgbTo256(0, 0, 255));
}

test "table renders as aligned text columns" {
    const src = "<body><table><tr><td>id</td><td>name</td></tr><tr><td>7</td><td>zig</td></tr></table></body>";
    const out = try renderHtml(src, 80, false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("id name\n7  zig\n", out);
}

test "cells emit in reading order across a row, not per-cell" {
    const src = "<body><table><tr><td>aa bb</td><td>right</td></tr></table></body>";
    const out = try renderHtml(src, 9, false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("aa  right\nbb\n", out);
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
