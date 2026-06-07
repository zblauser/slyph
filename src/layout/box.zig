const std = @import("std");
const dom = @import("../dom/node.zig");
const style = @import("../css/style.zig");

pub const Rect = struct { x: u16, y: u16, w: u16, h: u16 };

pub const BoxKind = enum {
    block,
    line,
    text,
};

pub const Box = struct {
    kind: BoxKind,
    rect: Rect,
    node: ?*dom.Node = null,
    style: ?*const style.ComputedStyle = null,
    text: []const u8 = "",
    link: u16 = 0,
    children: []Box = &.{},
};

pub fn cellWidth(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}
