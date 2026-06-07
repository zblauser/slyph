const std = @import("std");
const style = @import("../css/style.zig");

pub const Kind = enum { document, element, text, comment };

pub const Attr = struct {
    name: []const u8,
    value: []const u8,
};

pub const Node = struct {
    kind: Kind,
    tag: []const u8 = "",
    attrs: []Attr = &.{},
    text: []const u8 = "",

    parent: ?*Node = null,
    first_child: ?*Node = null,
    last_child: ?*Node = null,
    next_sibling: ?*Node = null,

    computed: ?*style.ComputedStyle = null,
    value: ?[]const u8 = null,

    pub fn appendChild(self: *Node, child: *Node) void {
        child.parent = self;
        if (self.last_child) |last| {
            last.next_sibling = child;
        } else {
            self.first_child = child;
        }
        self.last_child = child;
    }

    pub fn attr(self: *const Node, name: []const u8) ?[]const u8 {
        for (self.attrs) |a| {
            if (std.ascii.eqlIgnoreCase(a.name, name)) return a.value;
        }
        return null;
    }

    pub fn appendText(self: *const Node, a: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        var child = self.first_child;
        while (child) |c| : (child = c.next_sibling) {
            switch (c.kind) {
                .text => try out.appendSlice(a, c.text),
                .element => try c.appendText(a, out),
                else => {},
            }
        }
    }
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: *Node,
    url: []const u8 = "",
    title: []const u8 = "",

    pub fn init(gpa: std.mem.Allocator) !Document {
        var arena = std.heap.ArenaAllocator.init(gpa);
        const root = try arena.allocator().create(Node);
        root.* = .{ .kind = .document };
        return .{ .arena = arena, .root = root };
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }

    pub fn alloc(self: *Document) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn createElement(self: *Document, tag: []const u8, attrs: []Attr) !*Node {
        const n = try self.alloc().create(Node);
        n.* = .{ .kind = .element, .tag = tag, .attrs = attrs };
        return n;
    }

    pub fn createText(self: *Document, text: []const u8) !*Node {
        const n = try self.alloc().create(Node);
        n.* = .{ .kind = .text, .text = text };
        return n;
    }

    pub fn createComment(self: *Document, text: []const u8) !*Node {
        const n = try self.alloc().create(Node);
        n.* = .{ .kind = .comment, .text = text };
        return n;
    }
};

test "appendChild links siblings and parent" {
    var doc = try Document.init(std.testing.allocator);
    defer doc.deinit();
    const a = try doc.createElement("a", &.{});
    const b = try doc.createElement("b", &.{});
    doc.root.appendChild(a);
    doc.root.appendChild(b);
    try std.testing.expect(doc.root.first_child == a);
    try std.testing.expect(doc.root.last_child == b);
    try std.testing.expect(a.next_sibling == b);
    try std.testing.expect(b.parent == doc.root);
}
