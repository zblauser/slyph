const std = @import("std");
const dom = @import("../dom/node.zig");

pub const Kind = enum { text, password, checkbox, radio, submit, hidden };

pub const Method = enum { get, post };

pub fn init(a: std.mem.Allocator, node: *dom.Node) !void {
    if (node.kind == .element and node.value == null) {
        if (std.mem.eql(u8, node.tag, "input")) {
            const k = kind(node);
            node.value = if (k == .checkbox or k == .radio)
                (if (node.attr("checked") != null) node.attr("value") orelse "on" else "")
            else
                node.attr("value") orelse "";
        } else if (std.mem.eql(u8, node.tag, "textarea")) {
            var buf: std.ArrayList(u8) = .empty;
            try node.appendText(a, &buf);
            node.value = buf.items;
        }
    }
    var child = node.first_child;
    while (child) |c| : (child = c.next_sibling) try init(a, c);
}

pub fn kind(node: *const dom.Node) Kind {
    if (std.mem.eql(u8, node.tag, "textarea")) return .text;
    if (std.mem.eql(u8, node.tag, "button")) return .submit;
    const t = node.attr("type") orelse "text";
    if (eq(t, "password")) return .password;
    if (eq(t, "checkbox")) return .checkbox;
    if (eq(t, "radio")) return .radio;
    if (eq(t, "hidden")) return .hidden;
    if (eq(t, "submit") or eq(t, "button") or eq(t, "image")) return .submit;
    return .text;
}

pub fn setChecked(node: *dom.Node) void {
    const on = node.attr("value") orelse "on";
    if (kind(node) == .radio) {
        if (formFor(node)) |form| {
            if (node.attr("name")) |name| uncheckGroup(form, name);
        }
    }
    node.value = on;
}

fn uncheckGroup(node: *dom.Node, name: []const u8) void {
    if (node.kind == .element and kind(node) == .radio) {
        if (node.attr("name")) |n| if (eq(n, name)) {
            node.value = "";
        };
    }
    var child = node.first_child;
    while (child) |c| : (child = c.next_sibling) uncheckGroup(c, name);
}

pub fn isChecked(node: *const dom.Node) bool {
    const v: []const u8 = node.value orelse "";
    return v.len > 0;
}

pub fn formFor(node: *dom.Node) ?*dom.Node {
    var p = node.parent;
    while (p) |n| : (p = n.parent) {
        if (n.kind == .element and std.mem.eql(u8, n.tag, "form")) return n;
    }
    return null;
}

pub fn method(form: *dom.Node) Method {
    const m = form.attr("method") orelse "get";
    return if (eq(m, "post")) .post else .get;
}

pub fn encode(a: std.mem.Allocator, form: *dom.Node, activated: ?*dom.Node) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try appendControls(a, form, activated, &out);
    return out.items;
}

fn appendControls(a: std.mem.Allocator, node: *dom.Node, activated: ?*dom.Node, out: *std.ArrayList(u8)) !void {
    if (node.kind == .element) {
        const tag = node.tag;
        const is_control = std.mem.eql(u8, tag, "input") or
            std.mem.eql(u8, tag, "textarea") or std.mem.eql(u8, tag, "button");
        if (is_control) {
            if (node.attr("name")) |name| {
                const k = kind(node);
                const include = switch (k) {
                    .submit => node == activated,
                    .checkbox, .radio => isChecked(node),
                    else => true,
                };
                if (include) {
                    const val = node.value orelse node.attr("value") orelse "";
                    if (out.items.len > 0) try out.append(a, '&');
                    try percentEncode(a, name, out);
                    try out.append(a, '=');
                    try percentEncode(a, val, out);
                }
            }
        }
    }
    var child = node.first_child;
    while (child) |c| : (child = c.next_sibling) try appendControls(a, c, activated, out);
}

fn percentEncode(a: std.mem.Allocator, s: []const u8, out: *std.ArrayList(u8)) !void {
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(a, c);
        } else if (c == ' ') {
            try out.append(a, '+');
        } else {
            try out.appendSlice(a, &.{ '%', hex[c >> 4], hex[c & 0xf] });
        }
    }
}

fn eq(x: []const u8, y: []const u8) bool {
    return std.ascii.eqlIgnoreCase(x, y);
}

const testing = std.testing;
const html = @import("../html/parser.zig");

test "init seeds input value attr and textarea content" {
    var doc = try html.parse(testing.allocator, "<form><input name=q value=hi><textarea name=b>body text</textarea></form>");
    defer doc.deinit();
    try init(doc.alloc(), doc.root);
    const form = doc.root.first_child.?;
    const input = form.first_child.?;
    try testing.expectEqualStrings("hi", input.value.?);
    const textarea = input.next_sibling.?;
    try testing.expectEqualStrings("body text", textarea.value.?);
}

test "encode gathers named controls, skips unpressed submits, urlencodes" {
    var doc = try html.parse(testing.allocator,
        \\<form method=post>
        \\  <input name=q value="a b&c">
        \\  <input type=hidden name=tok value=xyz>
        \\  <input type=submit name=go value=Search>
        \\</form>
    );
    defer doc.deinit();
    try init(doc.alloc(), doc.root);
    const form = doc.root.first_child.?;
    try testing.expectEqual(Method.post, method(form));

    var submit: ?*dom.Node = null;
    var c = form.first_child;
    while (c) |n| : (c = n.next_sibling) {
        if (n.kind == .element and kind(n) == .submit) submit = n;
    }
    const body = try encode(doc.alloc(), form, submit);
    try testing.expectEqualStrings("q=a+b%26c&tok=xyz&go=Search", body);
}

test "encode omits submit name when not activated" {
    var doc = try html.parse(testing.allocator, "<form><input name=q value=x><input type=submit name=go value=Go></form>");
    defer doc.deinit();
    try init(doc.alloc(), doc.root);
    const form = doc.root.first_child.?;
    const body = try encode(doc.alloc(), form, null);
    try testing.expectEqualStrings("q=x", body);
}
