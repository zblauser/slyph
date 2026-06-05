//! CSS cascade — matches parsed rules against the DOM and writes a
//! ComputedStyle onto every node. Origins are ordered UA < author < inline;
//! within an origin the winner is highest specificity, then source order.
//! Pragmatic: enough properties for text-mode layout + terminal styling.

const std = @import("std");
const dom = @import("../dom/node.zig");
const style = @import("style.zig");
const css = @import("parser.zig");

const ComputedStyle = style.ComputedStyle;

/// Built-in user-agent stylesheet: gives elements their default display and the
/// handful of text decorations the terminal renderer can show.
pub const ua_css =
    \\html, body, div, section, article, header, footer, main, nav, aside,
    \\p, ul, ol, li, dl, dt, dd, table, tr, figure, figcaption, blockquote,
    \\pre, form, fieldset, hr, h1, h2, h3, h4, h5, h6, address { display: block }
    \\li { display: list-item }
    \\head, title, meta, link, script, style, base, noscript { display: none }
    \\b, strong, h1, h2, h3, h4, h5, h6, th { font-weight: bold }
    \\i, em, cite, var, dfn { font-style: italic }
    \\a, u, ins { text-decoration: underline }
    \\pre, textarea { white-space: pre }
    \\p, ul, ol, blockquote, pre, figure, table, form { margin-top: 1; margin-bottom: 1 }
    \\h1, h2, h3, h4, h5, h6 { margin-top: 1; margin-bottom: 1 }
;

const Origin = enum(u2) { ua = 0, author = 1, inline_ = 2 };

/// A rule tagged with where it came from and its source position.
const TaggedRule = struct {
    origin: Origin,
    order: u32,
    rule: css.Rule,
};

/// A declaration that matched an element, with its full cascade sort key.
const Candidate = struct {
    origin: Origin,
    specificity: u32,
    order: u32,
    decls: []css.Declaration,

    /// Ascending order = lowest priority first (applied first, overridden later).
    fn lessThan(_: void, a: Candidate, b: Candidate) bool {
        if (a.origin != b.origin) return @intFromEnum(a.origin) < @intFromEnum(b.origin);
        if (a.specificity != b.specificity) return a.specificity < b.specificity;
        return a.order < b.order;
    }
};

/// Style the whole document in place: every node gets `computed` set.
pub fn apply(a: std.mem.Allocator, doc: *dom.Document) !void {
    var rules: std.ArrayList(TaggedRule) = .empty;
    defer rules.deinit(a);
    var order: u32 = 0;

    // 1. UA stylesheet
    const ua = try css.parse(a, ua_css);
    for (ua.rules) |r| {
        try rules.append(a, .{ .origin = .ua, .order = order, .rule = r });
        order += 1;
    }
    // 2. author <style> elements, in document order
    try collectStyleElements(a, doc.root, &rules, &order);

    const styler = Styler{ .a = a, .rules = rules.items };
    try styler.styleNode(doc.root, ComputedStyle.initial);
}

/// Walk the tree collecting the text of every <style> element and parsing it.
fn collectStyleElements(a: std.mem.Allocator, node: *dom.Node, rules: *std.ArrayList(TaggedRule), order: *u32) !void {
    if (node.kind == .element and std.mem.eql(u8, node.tag, "style")) {
        // text lives in the arena: css.parse keeps slices into it.
        var text: std.ArrayList(u8) = .empty;
        try node.appendText(a, &text);
        const ss = try css.parse(a, text.items);
        for (ss.rules) |r| {
            try rules.append(a, .{ .origin = .author, .order = order.*, .rule = r });
            order.* += 1;
        }
        return; // don't descend into style contents
    }
    var child = node.first_child;
    while (child) |c| : (child = c.next_sibling) try collectStyleElements(a, c, rules, order);
}

const Styler = struct {
    a: std.mem.Allocator,
    rules: []const TaggedRule,

    /// Recursively compute styles top-down so inheritance flows from parents.
    fn styleNode(self: Styler, node: *dom.Node, parent: ComputedStyle) !void {
        const cs = try self.a.create(ComputedStyle);
        cs.* = ComputedStyle.inheritFrom(parent);

        if (node.kind == .element) {
            try self.cascadeInto(cs, node);
        }
        node.computed = cs;

        var child = node.first_child;
        while (child) |c| : (child = c.next_sibling) try self.styleNode(c, cs.*);
    }

    /// Gather all matching declarations for `node`, sort by cascade order, apply.
    fn cascadeInto(self: Styler, cs: *ComputedStyle, node: *dom.Node) !void {
        var cands: std.ArrayList(Candidate) = .empty;
        defer cands.deinit(self.a);

        for (self.rules) |tr| {
            var best: ?u32 = null; // best specificity among this rule's matching selectors
            for (tr.rule.selectors) |sel| {
                if (matches(sel, node)) {
                    const sp = sel.specificity();
                    if (best == null or sp > best.?) best = sp;
                }
            }
            if (best) |sp| try cands.append(self.a, .{
                .origin = tr.origin,
                .specificity = sp,
                .order = tr.order,
                .decls = tr.rule.decls,
            });
        }

        // inline style="" attribute — highest origin
        if (node.attr("style")) |inline_css| {
            const ss = try css.parse(self.a, try std.fmt.allocPrint(self.a, "*{{{s}}}", .{inline_css}));
            if (ss.rules.len > 0) try cands.append(self.a, .{
                .origin = .inline_,
                .specificity = 0,
                .order = 0,
                .decls = ss.rules[0].decls,
            });
        }

        std.mem.sort(Candidate, cands.items, {}, Candidate.lessThan);
        for (cands.items) |c| {
            for (c.decls) |d| applyDecl(cs, d);
        }
    }
};

// --- selector matching ---

fn matches(sel: css.Selector, el: *dom.Node) bool {
    return matchFrom(sel, sel.compounds.len - 1, el);
}

fn matchFrom(sel: css.Selector, idx: usize, el: *dom.Node) bool {
    if (!compoundMatches(sel.compounds[idx], el)) return false;
    if (idx == 0) return true;
    const comb = sel.compounds[idx].combinator;
    switch (comb) {
        .child => {
            const p = elementParent(el) orelse return false;
            return matchFrom(sel, idx - 1, p);
        },
        .descendant => {
            var anc = elementParent(el);
            while (anc) |a| : (anc = elementParent(a)) {
                if (matchFrom(sel, idx - 1, a)) return true;
            }
            return false;
        },
    }
}

fn elementParent(el: *dom.Node) ?*dom.Node {
    var p = el.parent;
    while (p) |node| : (p = node.parent) {
        if (node.kind == .element) return node;
    }
    return null;
}

fn compoundMatches(c: css.Compound, el: *dom.Node) bool {
    if (el.kind != .element) return false;
    if (c.tag.len > 0 and !std.mem.eql(u8, c.tag, "*")) {
        if (!std.mem.eql(u8, c.tag, el.tag)) return false;
    }
    if (c.id.len > 0) {
        const id = el.attr("id") orelse return false;
        if (!std.mem.eql(u8, id, c.id)) return false;
    }
    if (c.classes.len > 0) {
        const class_attr = el.attr("class") orelse return false;
        for (c.classes) |want| {
            if (!hasClass(class_attr, want)) return false;
        }
    }
    return true;
}

fn hasClass(class_attr: []const u8, want: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, class_attr, " \t\r\n");
    while (it.next()) |cls| {
        if (std.mem.eql(u8, cls, want)) return true;
    }
    return false;
}

// --- property application ---

fn applyDecl(cs: *ComputedStyle, d: css.Declaration) void {
    const v = d.value;
    if (eq(d.name, "display")) {
        if (eq(v, "block")) cs.display = .block else if (eq(v, "inline")) cs.display = .inline_ else if (eq(v, "inline-block")) cs.display = .inline_block else if (eq(v, "list-item")) cs.display = .list_item else if (eq(v, "none")) cs.display = .none;
    } else if (eq(d.name, "white-space")) {
        cs.white_space = if (std.mem.startsWith(u8, v, "pre")) .pre else .normal;
    } else if (eq(d.name, "font-weight")) {
        if (eq(v, "bold") or eq(v, "bolder")) cs.font_weight = .bold else if (eq(v, "normal") or eq(v, "lighter")) cs.font_weight = .normal else if (std.fmt.parseInt(u16, v, 10) catch null) |n| {
            cs.font_weight = if (n >= 600) .bold else .normal;
        }
    } else if (eq(d.name, "font-style")) {
        cs.font_style = if (eq(v, "italic") or eq(v, "oblique")) .italic else .normal;
    } else if (eq(d.name, "text-decoration") or eq(d.name, "text-decoration-line")) {
        cs.underline = std.mem.indexOf(u8, v, "underline") != null;
    } else if (eq(d.name, "color")) {
        if (parseColor(v)) |col| cs.color = col;
    } else if (eq(d.name, "margin")) {
        // shorthand: first token applies to top+bottom (our line-based model)
        if (firstLineCount(v)) |n| {
            cs.margin_top = n;
            cs.margin_bottom = n;
        }
    } else if (eq(d.name, "margin-top")) {
        if (firstLineCount(v)) |n| cs.margin_top = n;
    } else if (eq(d.name, "margin-bottom")) {
        if (firstLineCount(v)) |n| cs.margin_bottom = n;
    }
}

/// We model vertical margins in whole terminal lines. The UA sheet uses bare
/// integers ("1"); author values in px/em we can't map to cells yet, so they're
/// ignored (treated as 0) until real length handling lands.
fn firstLineCount(v: []const u8) ?u8 {
    var it = std.mem.tokenizeAny(u8, v, " \t");
    const first = it.next() orelse return null;
    return std.fmt.parseInt(u8, first, 10) catch null;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn parseColor(v: []const u8) ?style.Color {
    if (v.len > 0 and v[0] == '#') return parseHex(v[1..]);
    const named = .{
        .{ "black", 0, 0, 0 },        .{ "white", 255, 255, 255 },
        .{ "red", 255, 0, 0 },        .{ "green", 0, 128, 0 },
        .{ "blue", 0, 0, 255 },       .{ "yellow", 255, 255, 0 },
        .{ "gray", 128, 128, 128 },   .{ "grey", 128, 128, 128 },
        .{ "silver", 192, 192, 192 }, .{ "maroon", 128, 0, 0 },
        .{ "navy", 0, 0, 128 },       .{ "orange", 255, 165, 0 },
    };
    inline for (named) |n| {
        if (eq(v, n[0])) return .{ .rgb = .{ .r = n[1], .g = n[2], .b = n[3] } };
    }
    return null;
}

fn parseHex(h: []const u8) ?style.Color {
    if (h.len == 3) {
        const r = hexNibble(h[0]) orelse return null;
        const g = hexNibble(h[1]) orelse return null;
        const b = hexNibble(h[2]) orelse return null;
        return .{ .rgb = .{ .r = r * 17, .g = g * 17, .b = b * 17 } };
    }
    if (h.len == 6) {
        const r = std.fmt.parseInt(u8, h[0..2], 16) catch return null;
        const g = std.fmt.parseInt(u8, h[2..4], 16) catch return null;
        const b = std.fmt.parseInt(u8, h[4..6], 16) catch return null;
        return .{ .rgb = .{ .r = r, .g = g, .b = b } };
    }
    return null;
}

fn hexNibble(c: u8) ?u8 {
    return std.fmt.charToDigit(c, 16) catch null;
}

// --- tests ---

const testing = std.testing;
const html = @import("../html/parser.zig");

fn styleDoc(doc: *dom.Document) !void {
    try apply(doc.alloc(), doc);
}

test "UA stylesheet sets block/none/bold defaults" {
    var doc = try html.parse(testing.allocator, "<html><head><title>t</title></head><body><p>hi <b>bold</b></p></body></html>");
    defer doc.deinit();
    try styleDoc(&doc);

    const htmlnode = doc.root.first_child.?;
    const head = htmlnode.first_child.?;
    const body = head.next_sibling.?;
    const p = body.first_child.?;
    try testing.expectEqual(style.Display.block, p.computed.?.display);
    try testing.expectEqual(style.Display.none, head.computed.?.display);

    const b = p.first_child.?.next_sibling.?; // text "hi ", then <b>
    try testing.expectEqualStrings("b", b.tag);
    try testing.expectEqual(style.FontWeight.bold, b.computed.?.font_weight);
}

test "author style overrides UA, specificity + inline win" {
    var doc = try html.parse(testing.allocator,
        \\<html><head><style>
        \\  p { color: red; display: inline }
        \\  p.hi { color: green }
        \\</style></head><body>
        \\  <p class="hi" style="color: blue">x</p>
        \\</body></html>
    );
    defer doc.deinit();
    try styleDoc(&doc);

    const body = doc.root.first_child.?.first_child.?.next_sibling.?;
    // first element child of body is the <p>
    var p = body.first_child;
    while (p) |n| : (p = n.next_sibling) {
        if (n.kind == .element and std.mem.eql(u8, n.tag, "p")) break;
    }
    const pn = p.?;
    try testing.expectEqual(style.Display.inline_, pn.computed.?.display); // from UA-overriding author
    // inline style wins over both author rules
    try testing.expectEqual(style.Color{ .rgb = .{ .r = 0, .g = 0, .b = 255 } }, pn.computed.?.color);
}

test "inherited color flows to descendants, display does not" {
    var doc = try html.parse(testing.allocator,
        \\<html><body><div style="color:#0f0"><span>hi</span></div></body></html>
    );
    defer doc.deinit();
    try styleDoc(&doc);

    const body = doc.root.first_child.?.first_child.?;
    const div = body.first_child.?;
    const span = div.first_child.?;
    const green = style.Color{ .rgb = .{ .r = 0, .g = 255, .b = 0 } };
    try testing.expectEqual(green, div.computed.?.color);
    try testing.expectEqual(green, span.computed.?.color); // inherited
    try testing.expectEqual(style.Display.inline_, span.computed.?.display); // not inherited
}
