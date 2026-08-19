const std = @import("std");

pub const Display = enum {
    block,
    inline_,
    inline_block,
    list_item,
    table,
    table_row_group,
    table_row,
    table_cell,
    none,

    pub fn isBlockLevel(self: Display) bool {
        return switch (self) {
            .block, .list_item, .table, .table_row_group, .table_row, .table_cell => true,
            .inline_, .inline_block, .none => false,
        };
    }
};
pub const FontWeight = enum { normal, bold };
pub const FontStyle = enum { normal, italic };
pub const WhiteSpace = enum { normal, pre };

pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const Role = enum {
    text,
    background,
    link,
    heading,
    marker,
    rule,
};

pub const Color = union(enum) {
    default,
    role: Role,
    rgb: Rgb,
};

pub const Var = struct { name: []const u8, value: []const u8 };

pub const ComputedStyle = struct {
    display: Display = .inline_,
    white_space: WhiteSpace = .normal,
    font_weight: FontWeight = .normal,
    font_style: FontStyle = .normal,
    underline: bool = false,
    border: ?bool = null,
    color: Color = .default,
    color_role: Role = .text,
    background: Color = .default,
    background_role: Role = .background,
    margin_top: u8 = 0,
    margin_bottom: u8 = 0,
    indent: u8 = 0,
    vars: []const Var = &.{},

    pub const initial: ComputedStyle = .{};

    pub fn inheritFrom(parent: ComputedStyle) ComputedStyle {
        return .{
            .white_space = parent.white_space,
            .font_weight = parent.font_weight,
            .font_style = parent.font_style,
            .underline = parent.underline,
            .color = parent.color,
            .color_role = parent.color_role,
            .background = parent.background,
            .background_role = parent.background_role,
            .vars = parent.vars,
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
    try std.testing.expectEqual(Display.inline_, child.display);
}
