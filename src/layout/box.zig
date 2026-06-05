//! Box tree — the output of layout/, the input to render/ (see ARCH.md).
//! Geometry is in terminal cells. Block boxes stack vertically; a block's inline
//! content is laid into `line` boxes whose children are `text` runs carrying the
//! ComputedStyle the renderer paints with.

const std = @import("std");
const dom = @import("../dom/node.zig");
const style = @import("../css/style.zig");

pub const Rect = struct { x: u16, y: u16, w: u16, h: u16 };

pub const BoxKind = enum {
    block, // block-level container, stacks children vertically
    line, // one visual line of inline content
    text, // a leaf run of text painted with `style`
};

pub const Box = struct {
    kind: BoxKind,
    rect: Rect,
    node: ?*dom.Node = null,
    /// Set on text runs; the renderer reads it for bold/italic/underline/color.
    style: ?*const style.ComputedStyle = null,
    /// Text runs only.
    text: []const u8 = "",
    /// Set on runs inside an <a href>; the 1-based hint number into Page.links.
    /// 0 = not a link. Lets the viewer highlight/locate links.
    link: u16 = 0,
    children: []Box = &.{},
};

/// Display width of a string in terminal cells. Approximated as the UTF-8
/// codepoint count (CJK double-width handled later). Shared by layout + render
/// so wrapping math and cursor advance always agree.
pub fn cellWidth(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}
