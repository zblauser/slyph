const std = @import("std");
const dom = @import("../dom/node.zig");
const tok = @import("tokenizer.zig");

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
                const attrs = try a.alloc(dom.Attr, st.attrs.len);
                for (st.attrs, 0..) |src_attr, i| {
                    attrs[i] = .{ .name = src_attr.name, .value = src_attr.value };
                }
                const el = try doc.createElement(st.name, attrs);
                current.appendChild(el);

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
                try stack.append(a, el);
            },
        }
    }
    return doc;
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
    const set = [_][]const u8{
        "area", "base", "br",    "col",    "embed", "hr",  "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    };
    for (set) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
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

test "stray end tag is ignored" {
    var doc = try parse(std.testing.allocator, "<p>a</span>b</p>");
    defer doc.deinit();
    const p = doc.root.first_child.?;
    try std.testing.expectEqualStrings("p", p.tag);
    try std.testing.expectEqualStrings("a", p.first_child.?.text);
    try std.testing.expectEqualStrings("b", p.first_child.?.next_sibling.?.text);
}
