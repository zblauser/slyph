const std = @import("std");
const dom = @import("../dom/node.zig");
const tok = @import("tokenizer.zig");
const eqAny = @import("../util.zig").eqAny;

pub fn parse(gpa: std.mem.Allocator, src: []const u8) !dom.Document {
    var doc = try dom.Document.init(gpa);
    errdefer doc.deinit();
    const a = doc.alloc();

    var stack: std.ArrayList(*dom.Node) = .empty;
    defer stack.deinit(a);
    try stack.append(a, doc.root);

    var t = tok.Tokenizer.init(a, src);
    while (try t.next()) |token| {
        const current = stack.items[stack.items.len - 1];
        switch (token) {
            .doctype => {},
            .comment => |c| current.appendChild(try doc.createComment(c)),
            .text => |raw| {
                const decoded = try decodeEntities(a, raw);
                current.appendChild(try doc.createText(decoded));
            },
            .end_tag => |name| closeElement(&stack, name),
            .start_tag => |st| {
                implyClose(&stack, st.name);
                const attrs = try a.alloc(dom.Attr, st.attrs.len);
                for (st.attrs, 0..) |src_attr, i| {
                    attrs[i] = .{ .name = src_attr.name, .value = src_attr.value };
                }
                const el = try doc.createElement(st.name, attrs);
                stack.items[stack.items.len - 1].appendChild(el);

                if (std.mem.eql(u8, st.name, "title")) {
                    const body = t.rawTextUntil(st.name);
                    doc.title = try decodeEntities(a, std.mem.trim(u8, body, " \t\r\n"));
                    el.appendChild(try doc.createText(doc.title));
                    continue;
                }
                if (tok.isRawText(st.name)) {
                    const body = t.rawTextUntil(st.name);
                    el.appendChild(try doc.createText(body));
                    continue;
                }
                if (st.self_closing or isVoid(st.name)) continue;
                if (stack.items.len < max_depth) try stack.append(a, el);
            },
        }
    }
    return doc;
}

const max_depth = 256;

fn implyClose(stack: *std.ArrayList(*dom.Node), start: []const u8) void {
    while (stack.items.len > 1) {
        const open = stack.items[stack.items.len - 1].tag;
        if (!autoCloses(start, open)) return;
        _ = stack.pop();
    }
}

fn autoCloses(start: []const u8, open: []const u8) bool {
    if (eqAny(start, &.{"li"})) return eqAny(open, &.{"li"});
    if (eqAny(start, &.{ "dt", "dd" })) return eqAny(open, &.{ "dt", "dd" });
    if (eqAny(start, &.{"option"})) return eqAny(open, &.{"option"});
    if (eqAny(start, &.{ "td", "th" })) return eqAny(open, &.{ "td", "th" });
    if (eqAny(start, &.{"tr"})) return eqAny(open, &.{ "td", "th", "tr" });
    if (eqAny(start, &.{ "thead", "tbody", "tfoot" }))
        return eqAny(open, &.{ "td", "th", "tr", "thead", "tbody", "tfoot" });
    if (eqAny(start, &.{ "p", "div", "ul", "ol", "dl", "table", "form", "section", "article", "header", "footer", "nav", "aside", "main", "blockquote", "pre", "figure", "hr", "h1", "h2", "h3", "h4", "h5", "h6" }))
        return eqAny(open, &.{"p"});
    return false;
}

fn closeElement(stack: *std.ArrayList(*dom.Node), name: []const u8) void {
    var i = stack.items.len;
    while (i > 1) {
        i -= 1;
        if (std.mem.eql(u8, stack.items[i].tag, name)) {
            stack.shrinkRetainingCapacity(i);
            return;
        }
    }
}

fn isVoid(name: []const u8) bool {
    return eqAny(name, &.{
        "area", "base", "br",    "col",    "embed", "hr",  "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    });
}

const Entity = struct { bytes: []const u8, len: usize };

pub fn decodeEntities(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return s;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            if (decodeOne(s[i..])) |e| {
                try out.appendSlice(a, e.bytes);
                i += e.len;
                continue;
            }
        }
        try out.append(a, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

var utf8_scratch: [4]u8 = undefined;

fn decodeOne(s: []const u8) ?Entity {
    const named = .{
        .{ "&amp;", "&" },   .{ "&lt;", "<" },   .{ "&gt;", ">" },
        .{ "&quot;", "\"" }, .{ "&apos;", "'" }, .{ "&nbsp;", " " },
        .{ "&#39;", "'" },
        .{ "&mdash;", "—" },
        .{ "&ndash;", "–" },
        .{ "&hellip;", "…" },
        .{ "&copy;", "©" },
    };
    inline for (named) |p| {
        if (s.len >= p[0].len and std.mem.eql(u8, s[0..p[0].len], p[0]))
            return .{ .bytes = p[1], .len = p[0].len };
    }
    if (s.len >= 3 and s[1] == '#') {
        var j: usize = 2;
        var hex = false;
        if (s[j] == 'x' or s[j] == 'X') {
            hex = true;
            j += 1;
        }
        const digit_start = j;
        while (j < s.len and s[j] != ';') j += 1;
        const digits = s[digit_start..j];
        if (digits.len == 0 or j >= s.len) return null;
        const cp = std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch return null;
        const n = std.unicode.utf8Encode(cp, &utf8_scratch) catch return null;
        return .{ .bytes = utf8_scratch[0..n], .len = j + 1 };
    }
    return null;
}

test "parse builds a tree, decodes entities, sets title" {
    var doc = try parse(std.testing.allocator, "<html><head><title>Hi &amp; Bye</title></head><body><p>x<br>y</p></body></html>");
    defer doc.deinit();
    try std.testing.expectEqualStrings("Hi & Bye", doc.title);

    const html = doc.root.first_child.?;
    try std.testing.expectEqualStrings("html", html.tag);
    const head = html.first_child.?;
    try std.testing.expectEqualStrings("head", head.tag);
    const body = head.next_sibling.?;
    try std.testing.expectEqualStrings("body", body.tag);

    const p = body.first_child.?;
    try std.testing.expectEqualStrings("p", p.tag);
    const x = p.first_child.?;
    try std.testing.expectEqualStrings("x", x.text);
    const br = x.next_sibling.?;
    try std.testing.expectEqualStrings("br", br.tag);
    try std.testing.expect(br.first_child == null);
    try std.testing.expectEqualStrings("y", br.next_sibling.?.text);
}

test "unclosed td and tr are closed implicitly" {
    var doc = try parse(std.testing.allocator, "<table><tr><td>a<td>b<tr><td>c</table>");
    defer doc.deinit();
    const table = doc.root.first_child.?;
    try std.testing.expectEqualStrings("table", table.tag);

    const tr1 = table.first_child.?;
    try std.testing.expectEqualStrings("tr", tr1.tag);
    const td_a = tr1.first_child.?;
    try std.testing.expectEqualStrings("td", td_a.tag);
    try std.testing.expectEqualStrings("a", td_a.first_child.?.text);
    const td_b = td_a.next_sibling.?;
    try std.testing.expectEqualStrings("td", td_b.tag);
    try std.testing.expectEqualStrings("b", td_b.first_child.?.text);

    const tr2 = tr1.next_sibling.?;
    try std.testing.expectEqualStrings("tr", tr2.tag);
    try std.testing.expectEqualStrings("c", tr2.first_child.?.first_child.?.text);
}

test "unclosed p and li are closed by the next sibling start tag" {
    var doc = try parse(std.testing.allocator, "<body><p>one<p>two<ul><li>a<li>b</ul></body>");
    defer doc.deinit();
    const body = doc.root.first_child.?;
    const p1 = body.first_child.?;
    try std.testing.expectEqualStrings("p", p1.tag);
    const p2 = p1.next_sibling.?;
    try std.testing.expectEqualStrings("p", p2.tag);
    try std.testing.expectEqualStrings("two", p2.first_child.?.text);

    const ul = p2.next_sibling.?;
    try std.testing.expectEqualStrings("ul", ul.tag);
    const li_a = ul.first_child.?;
    try std.testing.expectEqualStrings("a", li_a.first_child.?.text);
    try std.testing.expectEqualStrings("b", li_a.next_sibling.?.first_child.?.text);
}

test "stray end tag is ignored" {
    var doc = try parse(std.testing.allocator, "<p>a</span>b</p>");
    defer doc.deinit();
    const p = doc.root.first_child.?;
    try std.testing.expectEqualStrings("p", p.tag);
    try std.testing.expectEqualStrings("a", p.first_child.?.text);
    try std.testing.expectEqualStrings("b", p.first_child.?.next_sibling.?.text);
}

test "runaway nesting is capped so later passes cannot overflow the stack" {
    const a = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "<html><body>");
    for (0..5000) |_| try src.appendSlice(a, "<div>");
    try src.appendSlice(a, "deep");

    var doc = try parse(a, src.items);
    defer doc.deinit();

    var depth: usize = 0;
    var n: ?*dom.Node = doc.root;
    while (n) |cur| : (n = cur.first_child) depth += 1;
    try std.testing.expect(depth <= max_depth + 2);
}
