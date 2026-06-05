//! Text render backend — walks a Box tree and emits the terminal result.
//! Boxes are already in visual order with absolute cell coords, so a single
//! in-order walk reproduces the page: advance the cursor with spaces/newlines to
//! each run's (x, y), then write it with ANSI styling. ANSI is gated on `ansi`
//! so piping to a file or a dumb terminal yields clean text (DESIGN.md).

const std = @import("std");
const boxmod = @import("../layout/box.zig");
const style = @import("../css/style.zig");

const Box = boxmod.Box;

/// Render `root` to an owned byte buffer. `ansi` enables SGR styling.
pub fn render(a: std.mem.Allocator, root: Box, ansi: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var c = Cursor{ .a = a, .out = &out, .ansi = ansi };
    try c.walk(root);
    try out.append(a, '\n');
    return out.toOwnedSlice(a);
}

const Cursor = struct {
    a: std.mem.Allocator,
    out: *std.ArrayList(u8),
    ansi: bool,
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

    /// Advance the cursor to (x, y) with newlines then spaces.
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
        const sgr = try openSgr(self.a, self.out, cs.?);
        try self.out.appendSlice(self.a, text);
        if (sgr) try self.out.appendSlice(self.a, "\x1b[0m");
    }
};

/// Write the SGR escape opening this style's attributes. Returns true if any
/// were written (so the caller knows to reset afterward).
fn openSgr(a: std.mem.Allocator, out: *std.ArrayList(u8), cs: *const style.ComputedStyle) !bool {
    var w: std.ArrayList(u8) = .empty;
    defer w.deinit(a);
    if (cs.font_weight == .bold) try appendCode(a, &w, "1");
    if (cs.font_style == .italic) try appendCode(a, &w, "3");
    if (cs.underline) try appendCode(a, &w, "4");
    switch (cs.color) {
        .default => {},
        .rgb => |c| try appendCode(a, &w, try std.fmt.allocPrint(a, "38;2;{d};{d};{d}", .{ c.r, c.g, c.b })),
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

// --- tests ---

const testing = std.testing;
const html = @import("../html/parser.zig");
const cascade = @import("../css/cascade.zig");
const layout = @import("../layout/engine.zig");

fn renderHtml(src: []const u8, width: u16, ansi: bool) ![]u8 {
    var doc = try html.parse(testing.allocator, src);
    defer doc.deinit();
    try cascade.apply(doc.alloc(), &doc);
    const page = try layout.layout(doc.alloc(), &doc, width);
    return render(testing.allocator, page.root, ansi);
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
    // bold "hi", then underlined "[1]" hint + underlined "link"
    try testing.expectEqualStrings("\x1b[1mhi\x1b[0m \x1b[4m[1]\x1b[0m \x1b[4mlink\x1b[0m\n", out);
}

test "no ansi escapes leak when ansi disabled even with styles" {
    const out = try renderHtml("<body><p><b>x</b></p></body>", 80, false);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOfScalar(u8, out, '\x1b') == null);
}
