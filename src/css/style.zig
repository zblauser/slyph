//! ComputedStyle — the output of the cascade, read by layout/ and render/.
//! Pragmatic subset: the properties text-mode layout + the terminal renderer
//! can actually use today. Lengths and box props come when layout/ lands.

const std = @import("std");

pub const Display = enum { block, inline_, inline_block, list_item, none };
pub const FontWeight = enum { normal, bold };
pub const FontStyle = enum { normal, italic };
pub const WhiteSpace = enum { normal, pre };

/// A foreground color. `default` means "terminal default" (don't emit a color).
pub const Color = union(enum) {
    default,
    rgb: struct { r: u8, g: u8, b: u8 },
};

pub const ComputedStyle = struct {
    display: Display = .inline_,
    white_space: WhiteSpace = .normal,
    font_weight: FontWeight = .normal,
    font_style: FontStyle = .normal,
    underline: bool = false,
    color: Color = .default,
    /// Vertical margins in terminal lines (non-inherited). Adjacent margins
    /// collapse to their max during block layout.
    margin_top: u8 = 0,
    margin_bottom: u8 = 0,

    /// Initial values for the document root (no parent to inherit from).
    pub const initial: ComputedStyle = .{};

    /// Start a child's computed style from its parent: inherited properties flow
    /// down, non-inherited reset to their initial value. The cascade then
    /// overrides whatever matched.
    pub fn inheritFrom(parent: ComputedStyle) ComputedStyle {
        return .{
            // inherited properties
            .white_space = parent.white_space,
            .font_weight = parent.font_weight,
            .font_style = parent.font_style,
            .underline = parent.underline,
            .color = parent.color,
            // non-inherited reset to initial
            .display = .inline_,
        };
    }
};

test "inheritFrom keeps inherited props, resets display" {
    const parent: ComputedStyle = .{
        .display = .block,
        .font_weight = .bold,
        .color = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
    };
    const child = ComputedStyle.inheritFrom(parent);
    try std.testing.expectEqual(FontWeight.bold, child.font_weight);
    try std.testing.expectEqual(Color{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, child.color);
    try std.testing.expectEqual(Display.inline_, child.display); // reset
}
