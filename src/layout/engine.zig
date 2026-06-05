//! Layout engine — turns a styled DOM into a Box tree (cells).
//! Single-column block formatting: block-level children stack vertically with
//! collapsing vertical margins; inline-level content (text + inline elements)
//! is gathered into words and wrapped into `line` boxes at the viewport width.
//! Flex/grid come in v0.3; this is block + inline only.

const std = @import("std");
const dom = @import("../dom/node.zig");
const style = @import("../css/style.zig");
const boxmod = @import("box.zig");
const forms = @import("../forms/forms.zig");

const Box = boxmod.Box;
const Rect = boxmod.Rect;
const ComputedStyle = style.ComputedStyle;

/// A focusable form control the viewer can edit or activate.
pub const Field = struct {
    node: *dom.Node,
    kind: forms.Kind,
};

/// One atomic piece of inline content: a word painted with `cs`, or a forced
/// line break (from <br>). `link` is the 1-based hint number if inside an <a>.
const Word = struct {
    text: []const u8 = "",
    cs: *const ComputedStyle,
    forced_break: bool = false,
    link: u16 = 0,
};

const Ctx = struct {
    a: std.mem.Allocator,
    width: u16,
    links: *std.ArrayList([]const u8), // href table; index+1 = link hint number
    fields: *std.ArrayList(Field), // form controls; index+1 = field hint number
};

/// A laid-out page: the root box plus the tables the viewer drives — links to
/// follow (hint N = links[N-1]) and form fields to edit (hint N = fields[N-1]).
pub const Page = struct {
    root: Box,
    links: []const []const u8,
    fields: []const Field,
};

/// Lay out the whole document at `width` cells.
pub fn layout(a: std.mem.Allocator, doc: *dom.Document, width: u16) !Page {
    var links: std.ArrayList([]const u8) = .empty;
    var fields: std.ArrayList(Field) = .empty;
    var ctx = Ctx{ .a = a, .width = @max(width, 1), .links = &links, .fields = &fields };
    var children: std.ArrayList(Box) = .empty;
    const end_y = try layoutContainer(&ctx, doc.root, 0, ctx.width, 0, null, &children);
    return .{
        .root = .{
            .kind = .block,
            .rect = .{ .x = 0, .y = 0, .w = ctx.width, .h = end_y },
            .node = doc.root,
            .children = try children.toOwnedSlice(a),
        },
        .links = try links.toOwnedSlice(a),
        .fields = try fields.toOwnedSlice(a),
    };
}

/// Lay out the contents of `node` into `out`. Block-level children become block
/// boxes; runs of inline-level content become line boxes. Returns the y just
/// past the last line produced.
fn layoutContainer(
    ctx: *Ctx,
    node: *dom.Node,
    x: u16,
    avail_w: u16,
    start_y: u16,
    bullet: ?*const ComputedStyle, // non-null => seed a "• " marker (list-item)
    out: *std.ArrayList(Box),
) !u16 {
    var y = start_y;
    var pending: std.ArrayList(Word) = .empty;
    defer pending.deinit(ctx.a);
    var seen_content = false;
    var prev_margin_bottom: u16 = 0;

    if (bullet) |bcs| try pending.append(ctx.a, .{ .text = "\u{2022} ", .cs = bcs });

    var child = node.first_child;
    while (child) |c| : (child = c.next_sibling) {
        const cs = c.computed;
        const disp = if (cs) |s| s.display else .inline_;
        if (disp == .none) continue;

        if (disp == .block or disp == .list_item) {
            // flush any pending inline content before the block
            if (pending.items.len > 0) {
                y = try wrapWords(ctx, pending.items, x, avail_w, y, out);
                pending.clearRetainingCapacity();
                prev_margin_bottom = 0;
                seen_content = true;
            }
            const mt: u16 = if (cs) |s| s.margin_top else 0;
            if (seen_content) y += @max(prev_margin_bottom, mt);
            const blk = try layoutBlock(ctx, c, x, avail_w, y);
            try out.append(ctx.a, blk);
            y = blk.rect.y + blk.rect.h;
            prev_margin_bottom = if (cs) |s| s.margin_bottom else 0;
            seen_content = true;
        } else {
            collectInline(ctx, c, 0, &pending) catch {};
        }
    }
    if (pending.items.len > 0) {
        y = try wrapWords(ctx, pending.items, x, avail_w, y, out);
    }
    return y;
}

/// Lay out a single block-level element starting at (x, y).
fn layoutBlock(ctx: *Ctx, node: *dom.Node, x: u16, avail_w: u16, y: u16) std.mem.Allocator.Error!Box {
    var children: std.ArrayList(Box) = .empty;
    const cs = node.computed;
    const is_list_item = cs != null and cs.?.display == .list_item;

    var end_y: u16 = undefined;
    if (cs != null and cs.?.white_space == .pre) {
        end_y = try layoutPre(ctx, node, x, avail_w, y, &children);
    } else {
        end_y = try layoutContainer(ctx, node, x, avail_w, y, if (is_list_item) cs else null, &children);
    }
    return .{
        .kind = .block,
        .rect = .{ .x = x, .y = y, .w = avail_w, .h = end_y - y },
        .node = node,
        .style = cs,
        .children = try children.toOwnedSlice(ctx.a),
    };
}

/// white-space:pre — keep text verbatim, one line box per source line, no wrap.
fn layoutPre(ctx: *Ctx, node: *dom.Node, x: u16, avail_w: u16, start_y: u16, out: *std.ArrayList(Box)) !u16 {
    // text lives in the arena: line boxes keep slices into it.
    var text: std.ArrayList(u8) = .empty;
    node.appendText(ctx.a, &text) catch {};
    const cs = node.computed;

    var y = start_y;
    var it = std.mem.splitScalar(u8, text.items, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        var kids: std.ArrayList(Box) = .empty;
        const w: u16 = @intCast(@min(boxmod.cellWidth(line), avail_w));
        try kids.append(ctx.a, .{
            .kind = .text,
            .rect = .{ .x = x, .y = y, .w = w, .h = 1 },
            .style = cs,
            .text = line,
        });
        try out.append(ctx.a, .{
            .kind = .line,
            .rect = .{ .x = x, .y = y, .w = w, .h = 1 },
            .node = node,
            .children = try kids.toOwnedSlice(ctx.a),
        });
        y += 1;
    }
    return y;
}

/// Walk an inline subtree collecting words. <br> yields a forced break; runs of
/// whitespace become word boundaries (collapsed to single spaces at wrap time).
/// `link` is the enclosing anchor's hint number (0 = none); an <a href> opens a
/// new one, registers its href, and emits a "[n] " hint marker.
fn collectInline(ctx: *Ctx, node: *dom.Node, link: u16, out: *std.ArrayList(Word)) !void {
    switch (node.kind) {
        .text => {
            const cs = node.computed orelse return;
            var it = std.mem.tokenizeAny(u8, node.text, " \t\r\n\x0c");
            while (it.next()) |word| try out.append(ctx.a, .{ .text = word, .cs = cs, .link = link });
        },
        .element => {
            const cs = node.computed;
            if (cs != null and cs.?.display == .none) return;
            if (std.mem.eql(u8, node.tag, "br")) {
                try out.append(ctx.a, .{ .cs = cs orelse return, .forced_break = true });
                return;
            }
            if (isControl(node.tag)) {
                try emitField(ctx, node, cs orelse return, out);
                return; // controls don't descend (value already captured)
            }
            var cur = link;
            if (std.mem.eql(u8, node.tag, "a")) {
                if (node.attr("href")) |href| {
                    try ctx.links.append(ctx.a, href);
                    cur = @intCast(ctx.links.items.len);
                    if (cs) |s| {
                        const hint = try std.fmt.allocPrint(ctx.a, "[{d}]", .{cur});
                        try out.append(ctx.a, .{ .text = hint, .cs = s, .link = cur });
                    }
                }
            }
            var child = node.first_child;
            while (child) |c| : (child = c.next_sibling) try collectInline(ctx, c, cur, out);
        },
        else => {},
    }
}

fn isControl(tag: []const u8) bool {
    return std.mem.eql(u8, tag, "input") or std.mem.eql(u8, tag, "textarea") or
        std.mem.eql(u8, tag, "button");
}

/// Render a form control as a single inline atom: a "{n}" hint plus a bracketed
/// value/label box, and register it as field n. Hidden inputs are submitted but
/// not shown or focusable.
fn emitField(ctx: *Ctx, node: *dom.Node, cs: *const ComputedStyle, out: *std.ArrayList(Word)) !void {
    const k = forms.kind(node);
    if (k == .hidden) return;
    try ctx.fields.append(ctx.a, .{ .node = node, .kind = k });
    const n = ctx.fields.items.len;
    const val = node.value orelse "";

    const text = switch (k) {
        .submit => blk: {
            const label = if (val.len > 0) val else "Submit";
            break :blk try std.fmt.allocPrint(ctx.a, "{{{d}}}[ {s} ]", .{ n, label });
        },
        .checkbox, .radio => try std.fmt.allocPrint(ctx.a, "{{{d}}}[{s}]", .{ n, if (forms.isChecked(node)) "x" else " " }),
        .password => blk: {
            var stars: std.ArrayList(u8) = .empty;
            try stars.appendNTimes(ctx.a, '*', boxmod.cellWidth(val));
            break :blk try fieldBox(ctx.a, n, stars.items, node);
        },
        else => try fieldBox(ctx.a, n, val, node),
    };
    // one atom (may contain spaces) so wrapping treats the field as a unit
    try out.append(ctx.a, .{ .text = text, .cs = cs });
}

/// "{n}[value padded to the field's size]" — gives an empty field visible width.
fn fieldBox(a: std.mem.Allocator, n: usize, val: []const u8, node: *dom.Node) ![]const u8 {
    const size: usize = if (node.attr("size")) |s| (std.fmt.parseInt(usize, s, 10) catch 20) else 20;
    const shown = @max(size, boxmod.cellWidth(val));
    var inner: std.ArrayList(u8) = .empty;
    try inner.appendSlice(a, val);
    try inner.appendNTimes(a, ' ', shown - boxmod.cellWidth(val));
    return std.fmt.allocPrint(a, "{{{d}}}[{s}]", .{ n, inner.items });
}

/// Greedy line-breaking: place words left→right, wrapping when the next word
/// would overflow `avail_w`. Emits one `line` box per visual line.
fn wrapWords(ctx: *Ctx, words: []const Word, x: u16, avail_w: u16, start_y: u16, out: *std.ArrayList(Box)) !u16 {
    var y = start_y;
    var line: std.ArrayList(Box) = .empty;
    defer line.deinit(ctx.a);
    var cur_x = x;

    for (words) |w| {
        if (w.forced_break) {
            if (line.items.len > 0) {
                try emitLine(ctx, &line, x, cur_x, y, out);
                y += 1;
                cur_x = x;
            } else {
                y += 1; // blank line
            }
            continue;
        }
        const ww: u16 = @intCast(boxmod.cellWidth(w.text));
        const space: u16 = if (line.items.len > 0) 1 else 0;
        if (line.items.len > 0 and (cur_x - x) + space + ww > avail_w) {
            try emitLine(ctx, &line, x, cur_x, y, out);
            y += 1;
            cur_x = x;
        }
        if (line.items.len > 0) cur_x += 1; // the collapsed space
        try line.append(ctx.a, .{
            .kind = .text,
            .rect = .{ .x = cur_x, .y = y, .w = ww, .h = 1 },
            .style = w.cs,
            .text = w.text,
            .link = w.link,
        });
        cur_x += ww;
    }
    if (line.items.len > 0) {
        try emitLine(ctx, &line, x, cur_x, y, out);
        y += 1;
    }
    return y;
}

fn emitLine(ctx: *Ctx, line: *std.ArrayList(Box), x: u16, cur_x: u16, y: u16, out: *std.ArrayList(Box)) !void {
    try out.append(ctx.a, .{
        .kind = .line,
        .rect = .{ .x = x, .y = y, .w = cur_x - x, .h = 1 },
        .children = try line.toOwnedSlice(ctx.a),
    });
}

// --- tests ---

const testing = std.testing;
const html = @import("../html/parser.zig");
const cascade = @import("../css/cascade.zig");

fn styledDoc(src: []const u8) !dom.Document {
    var doc = try html.parse(testing.allocator, src);
    errdefer doc.deinit();
    try cascade.apply(doc.alloc(), &doc);
    return doc;
}

/// Collect all text-run boxes in tree order.
fn collectText(box: Box, out: *std.ArrayList(Box)) !void {
    if (box.kind == .text) try out.append(testing.allocator, box);
    for (box.children) |c| try collectText(c, out);
}

test "inline text wraps at width" {
    var doc = try styledDoc("<body><p>aaa bbb ccc ddd</p></body>");
    defer doc.deinit();
    // width 7 fits "aaa bbb" (7) then wraps "ccc ddd"
    const root = (try layout(doc.alloc(), &doc, 7)).root;
    var runs: std.ArrayList(Box) = .empty;
    defer runs.deinit(testing.allocator);
    try collectText(root, &runs);
    try testing.expectEqual(@as(usize, 4), runs.items.len);
    // first two words on row 0, next two on row 1
    try testing.expectEqual(@as(u16, 0), runs.items[0].rect.y);
    try testing.expectEqual(@as(u16, 0), runs.items[1].rect.y);
    try testing.expectEqual(@as(u16, 1), runs.items[2].rect.y);
    try testing.expectEqualStrings("ccc", runs.items[2].text);
    try testing.expectEqual(@as(u16, 0), runs.items[2].rect.x); // wrapped to col 0
}

test "blocks stack with collapsing margins" {
    var doc = try styledDoc("<body><p>one</p><p>two</p></body>");
    defer doc.deinit();
    const root = (try layout(doc.alloc(), &doc, 80)).root;
    var runs: std.ArrayList(Box) = .empty;
    defer runs.deinit(testing.allocator);
    try collectText(root, &runs);
    try testing.expectEqual(@as(usize, 2), runs.items.len);
    try testing.expectEqualStrings("one", runs.items[0].text);
    // "two" sits one blank line below "one" (margins 1+1 collapse to 1)
    try testing.expectEqual(@as(u16, 0), runs.items[0].rect.y);
    try testing.expectEqual(@as(u16, 2), runs.items[1].rect.y);
}

test "list items get a bullet" {
    var doc = try styledDoc("<body><ul><li>x</li><li>y</li></ul></body>");
    defer doc.deinit();
    const root = (try layout(doc.alloc(), &doc, 80)).root;
    var runs: std.ArrayList(Box) = .empty;
    defer runs.deinit(testing.allocator);
    try collectText(root, &runs);
    // each li: bullet run + word run
    try testing.expectEqualStrings("\u{2022} ", runs.items[0].text);
    try testing.expectEqualStrings("x", runs.items[1].text);
    try testing.expectEqualStrings("\u{2022} ", runs.items[2].text);
    try testing.expectEqualStrings("y", runs.items[3].text);
}

test "display:none produces no boxes" {
    var doc = try styledDoc("<body><p>seen</p><script>hidden()</script><style>x{}</style></body>");
    defer doc.deinit();
    const root = (try layout(doc.alloc(), &doc, 80)).root;
    var runs: std.ArrayList(Box) = .empty;
    defer runs.deinit(testing.allocator);
    try collectText(root, &runs);
    try testing.expectEqual(@as(usize, 1), runs.items.len);
    try testing.expectEqualStrings("seen", runs.items[0].text);
}

test "links collected with hint numbers and hrefs" {
    var doc = try styledDoc("<body><p><a href=\"/a\">one</a> <a href=\"http://x/b\">two</a></p></body>");
    defer doc.deinit();
    const pg = try layout(doc.alloc(), &doc, 80);
    try testing.expectEqual(@as(usize, 2), pg.links.len);
    try testing.expectEqualStrings("/a", pg.links[0]);
    try testing.expectEqualStrings("http://x/b", pg.links[1]);

    var runs: std.ArrayList(Box) = .empty;
    defer runs.deinit(testing.allocator);
    try collectText(pg.root, &runs);
    // first run is the "[1]" hint carrying link number 1
    try testing.expectEqualStrings("[1]", runs.items[0].text);
    try testing.expectEqual(@as(u16, 1), runs.items[0].link);
    try testing.expectEqual(@as(u16, 1), runs.items[1].link); // "one"
}
