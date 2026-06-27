const std = @import("std");
const dom = @import("../dom/node.zig");
const style = @import("style.zig");
const css = @import("parser.zig");
const DenyList = @import("../policy.zig").DenyList;

const ComputedStyle = style.ComputedStyle;

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

const TaggedRule = struct {
    origin: Origin,
    order: u32,
    rule: css.Rule,
};

const Candidate = struct {
    origin: Origin,
    specificity: u32,
    order: u32,
    decls: []css.Declaration,

    fn lessThan(_: void, a: Candidate, b: Candidate) bool {
        if (a.origin != b.origin) return @intFromEnum(a.origin) < @intFromEnum(b.origin);
        if (a.specificity != b.specificity) return a.specificity < b.specificity;
        return a.order < b.order;
    }
};

pub fn apply(a: std.mem.Allocator, doc: *dom.Document, host: []const u8, css_policy: ?*const DenyList, extra_sheets: []const []const u8) !void {
    var rules: std.ArrayList(TaggedRule) = .empty;
    defer rules.deinit(a);
    var order: u32 = 0;

    const ua = try css.parse(a, ua_css);
    for (ua.rules) |r| {
        try rules.append(a, .{ .origin = .ua, .order = order, .rule = r });
        order += 1;
    }
    for (extra_sheets) |sheet| {
        const ss = try css.parse(a, sheet);
        for (ss.rules) |r| {
            try rules.append(a, .{ .origin = .author, .order = order, .rule = r });
            order += 1;
        }
    }
    try collectStyleElements(a, doc.root, &rules, &order);

    const styler = Styler{ .a = a, .rules = rules.items, .host = host, .policy = css_policy };
    try styler.styleNode(doc.root, ComputedStyle.initial);
}

fn collectStyleElements(a: std.mem.Allocator, node: *dom.Node, rules: *std.ArrayList(TaggedRule), order: *u32) !void {
    if (node.kind == .element and std.mem.eql(u8, node.tag, "style")) {
        var text: std.ArrayList(u8) = .empty;
        try node.appendText(a, &text);
        const ss = try css.parse(a, text.items);
        for (ss.rules) |r| {
            try rules.append(a, .{ .origin = .author, .order = order.*, .rule = r });
            order.* += 1;
        }
        return;
    }
    var child = node.first_child;
    while (child) |c| : (child = c.next_sibling) try collectStyleElements(a, c, rules, order);
}

const Styler = struct {
    a: std.mem.Allocator,
    rules: []const TaggedRule,
    host: []const u8,
    policy: ?*const DenyList,

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

    fn cascadeInto(self: Styler, cs: *ComputedStyle, node: *dom.Node) !void {
        var cands: std.ArrayList(Candidate) = .empty;
        defer cands.deinit(self.a);

        for (self.rules) |tr| {
            var best: ?u32 = null;
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

        var locals: std.ArrayList(style.Var) = .empty;
        for (cands.items) |c| {
            for (c.decls) |d| {
                if (!std.mem.startsWith(u8, d.name, "--")) continue;
                if (c.origin != .ua and self.denies(d.name)) continue;
                try locals.append(self.a, .{ .name = d.name, .value = d.value });
            }
        }
        if (locals.items.len > 0) {
            try locals.appendSlice(self.a, cs.vars);
            cs.vars = try locals.toOwnedSlice(self.a);
        }

        for (cands.items) |c| {
            for (c.decls) |d| {
                if (std.mem.startsWith(u8, d.name, "--")) continue;
                if (c.origin != .ua and self.denies(d.name)) continue;
                const value = try resolveVars(self.a, d.value, cs.vars);
                applyDecl(cs, .{ .name = d.name, .value = value });
            }
        }
    }

    fn denies(self: Styler, prop: []const u8) bool {
        const p = self.policy orelse return false;
        return p.denied(self.host, prop);
    }
};

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
        if (std.mem.eql(u8, c.tag, ":root")) {
            if (!std.mem.eql(u8, el.tag, "html")) return false;
        } else if (!std.mem.eql(u8, c.tag, el.tag)) return false;
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

fn resolveVars(a: std.mem.Allocator, value: []const u8, vars: []const style.Var) ![]const u8 {
    if (std.mem.indexOf(u8, value, "var(") == null) return value;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < value.len) {
        if (std.mem.startsWith(u8, value[i..], "var(")) {
            const rel = std.mem.indexOfScalar(u8, value[i + 4 ..], ')') orelse {
                try out.appendSlice(a, value[i..]);
                break;
            };
            const close = i + 4 + rel;
            const inner = value[i + 4 .. close];
            const comma = std.mem.indexOfScalar(u8, inner, ',');
            const name = std.mem.trim(u8, if (comma) |k| inner[0..k] else inner, " \t");
            const fallback = if (comma) |k| std.mem.trim(u8, inner[k + 1 ..], " \t") else "";
            try out.appendSlice(a, lookupVar(vars, name) orelse fallback);
            i = close + 1;
        } else {
            try out.append(a, value[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}

fn lookupVar(vars: []const style.Var, name: []const u8) ?[]const u8 {
    for (vars) |v| if (std.ascii.eqlIgnoreCase(v.name, name)) return v.value;
    return null;
}

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

const testing = std.testing;
const html = @import("../html/parser.zig");

fn styleDoc(doc: *dom.Document) !void {
    try apply(doc.alloc(), doc, "", null, &.{});
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

    const b = p.first_child.?.next_sibling.?;
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
    var p = body.first_child;
    while (p) |n| : (p = n.next_sibling) {
        if (n.kind == .element and std.mem.eql(u8, n.tag, "p")) break;
    }
    const pn = p.?;
    try testing.expectEqual(style.Display.inline_, pn.computed.?.display);
    try testing.expectEqual(style.Color{ .rgb = .{ .r = 0, .g = 0, .b = 255 } }, pn.computed.?.color);
}

test "css policy strips denied author property, leaves UA + other props" {
    var doc = try html.parse(testing.allocator,
        \\<html><head><style>
        \\  p { color: red; font-weight: bold }
        \\</style></head><body><p style="color: blue"><b>x</b></p></body></html>
    );
    defer doc.deinit();

    var p: DenyList = .init(testing.allocator);
    defer p.deinit();
    try p.loadDenyLines("deny ban.example color\n");
    try apply(doc.alloc(), &doc, "ban.example", &p, &.{});

    const body = doc.root.first_child.?.first_child.?.next_sibling.?;
    var pn = body.first_child;
    while (pn) |n| : (pn = n.next_sibling) {
        if (n.kind == .element and std.mem.eql(u8, n.tag, "p")) break;
    }
    const para = pn.?;
    try testing.expectEqual(style.Color.default, para.computed.?.color);
    try testing.expectEqual(style.FontWeight.bold, para.computed.?.font_weight);
    const b = para.first_child.?;
    try testing.expectEqualStrings("b", b.tag);
    try testing.expectEqual(style.FontWeight.bold, b.computed.?.font_weight);
}

test "custom properties on :root resolve via var() on descendants" {
    var doc = try html.parse(testing.allocator,
        \\<html><head><style>
        \\  :root { --gold: #b89656; --bone: #c8c2b2 }
        \\  body { color: var(--bone) }
        \\  a { color: var(--gold) }
        \\</style></head><body><a href=x>link</a></body></html>
    );
    defer doc.deinit();
    try styleDoc(&doc);

    const htmlnode = doc.root.first_child.?;
    const body = htmlnode.first_child.?.next_sibling.?;
    try testing.expectEqual(style.Color{ .rgb = .{ .r = 0xc8, .g = 0xc2, .b = 0xb2 } }, body.computed.?.color);
    const a = body.first_child.?;
    try testing.expectEqualStrings("a", a.tag);
    try testing.expectEqual(style.Color{ .rgb = .{ .r = 0xb8, .g = 0x96, .b = 0x56 } }, a.computed.?.color);
}

test "var() falls back when custom property is undefined" {
    var doc = try html.parse(testing.allocator,
        \\<html><body><p style="color: var(--nope, #ff0000)">x</p></body></html>
    );
    defer doc.deinit();
    try styleDoc(&doc);
    const para = doc.root.first_child.?.first_child.?.first_child.?;
    try testing.expectEqual(style.Color{ .rgb = .{ .r = 255, .g = 0, .b = 0 } }, para.computed.?.color);
}

test "external (linked) stylesheet applies as author css" {
    var doc = try html.parse(testing.allocator, "<html><body><p class=hi>x</p></body></html>");
    defer doc.deinit();
    const sheets = [_][]const u8{"p.hi { color: #00ff00 }"};
    try apply(doc.alloc(), &doc, "x.com", null, &sheets);

    const para = doc.root.first_child.?.first_child.?.first_child.?;
    try testing.expectEqualStrings("p", para.tag);
    try testing.expectEqual(style.Color{ .rgb = .{ .r = 0, .g = 255, .b = 0 } }, para.computed.?.color);
}

test "css policy also strips a denied property from a linked sheet" {
    var doc = try html.parse(testing.allocator, "<html><body><p>x</p></body></html>");
    defer doc.deinit();
    const sheets = [_][]const u8{"p { color: #ff0000 }"};
    var p: DenyList = .init(testing.allocator);
    defer p.deinit();
    try p.loadDenyLines("deny * color\n");
    try apply(doc.alloc(), &doc, "x.com", &p, &sheets);

    const para = doc.root.first_child.?.first_child.?.first_child.?;
    try testing.expectEqual(style.Color.default, para.computed.?.color);
}

test "css policy host-scoped: other host unaffected" {
    var doc = try html.parse(testing.allocator,
        \\<html><body><p style="color:#0000ff">x</p></body></html>
    );
    defer doc.deinit();
    var p: DenyList = .init(testing.allocator);
    defer p.deinit();
    try p.loadDenyLines("deny ban.example color\n");
    try apply(doc.alloc(), &doc, "other.example", &p, &.{});

    const para = doc.root.first_child.?.first_child.?.first_child.?;
    try testing.expectEqual(style.Color{ .rgb = .{ .r = 0, .g = 0, .b = 255 } }, para.computed.?.color);
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
    try testing.expectEqual(green, span.computed.?.color);
    try testing.expectEqual(style.Display.inline_, span.computed.?.display);
}
