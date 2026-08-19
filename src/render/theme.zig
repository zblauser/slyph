const std = @import("std");
const style = @import("../css/style.zig");
const util = @import("../util.zig");

pub const Rgb = style.Rgb;
pub const Role = style.Role;

pub const slot_count = @typeInfo(Role).@"enum".fields.len;

pub const Theme = struct {
    name: []const u8 = "terminal",
    slots: [slot_count]?Rgb = @splat(null),
    roles_only: bool = false,

    pub const terminal: Theme = .{};

    pub fn slot(self: *const Theme, role: Role) ?Rgb {
        return self.slots[@intFromEnum(role)];
    }

    pub fn set(self: *Theme, role: Role, rgb: ?Rgb) void {
        self.slots[@intFromEnum(role)] = rgb;
    }

    pub fn loadLines(self: *Theme, bytes: []const u8) void {
        var it = util.lines(bytes);
        while (it.next()) |t| {
            var f = std.mem.tokenizeAny(u8, t, " \t");
            const key = f.next() orelse continue;
            if (std.ascii.eqlIgnoreCase(key, "roles-only")) {
                self.roles_only = true;
                continue;
            }
            const role = roleByName(key) orelse continue;
            const value = f.next() orelse continue;
            if (std.ascii.eqlIgnoreCase(value, "default")) {
                self.set(role, null);
            } else if (parseHex(value)) |rgb| {
                self.set(role, rgb);
            }
        }
    }

    pub fn resolve(self: *const Theme, color: style.Color, fallback: ?Role) ?Rgb {
        const picked: ?Rgb = switch (color) {
            .default => if (fallback) |role| self.slot(role) else null,
            .role => |role| self.slot(role),
            .rgb => |rgb| if (self.roles_only)
                (if (fallback) |role| self.slot(role) else null)
            else
                rgb,
        };
        if (color != .rgb or fallback != .background) return picked;
        const rgb = picked orelse return null;
        return if (self.worthPainting(rgb)) rgb else null;
    }

    fn worthPainting(self: *const Theme, rgb: Rgb) bool {
        const lum = luminance(rgb);
        const ground = self.slot(.background) orelse return lum <= 64;
        const base = luminance(ground);
        return (if (lum > base) lum - base else base - lum) >= 24;
    }
};

fn luminance(c: Rgb) u16 {
    return (@as(u16, c.r) * 54 + @as(u16, c.g) * 183 + @as(u16, c.b) * 19) >> 8;
}

fn roleByName(name: []const u8) ?Role {
    inline for (@typeInfo(Role).@"enum".fields) |f| {
        if (std.ascii.eqlIgnoreCase(name, f.name)) return @field(Role, f.name);
    }
    return null;
}

fn parseHex(v: []const u8) ?Rgb {
    if (v.len == 0 or v[0] != '#') return null;
    const c = util.hexRgb(v) orelse return null;
    return .{ .r = c[0], .g = c[1], .b = c[2] };
}

test "terminal theme leaves author colors alone and resolves nothing by default" {
    const t: Theme = .terminal;
    const gold: style.Color = .{ .rgb = .{ .r = 0xb8, .g = 0x96, .b = 0x56 } };
    try std.testing.expectEqual(Rgb{ .r = 0xb8, .g = 0x96, .b = 0x56 }, t.resolve(gold, .text).?);
    try std.testing.expect(t.resolve(.default, .text) == null);
    try std.testing.expect(t.resolve(.{ .role = .link }, null) == null);
}

test "theme slots drive roles, and roles_only overrides author literals" {
    var t: Theme = .terminal;
    t.set(.text, .{ .r = 1, .g = 2, .b = 3 });
    t.set(.link, .{ .r = 4, .g = 5, .b = 6 });

    try std.testing.expectEqual(Rgb{ .r = 4, .g = 5, .b = 6 }, t.resolve(.{ .role = .link }, .text).?);
    try std.testing.expectEqual(Rgb{ .r = 1, .g = 2, .b = 3 }, t.resolve(.default, .text).?);

    const gold: style.Color = .{ .rgb = .{ .r = 0xb8, .g = 0x96, .b = 0x56 } };
    try std.testing.expectEqual(Rgb{ .r = 0xb8, .g = 0x96, .b = 0x56 }, t.resolve(gold, .text).?);
    t.roles_only = true;
    try std.testing.expectEqual(Rgb{ .r = 1, .g = 2, .b = 3 }, t.resolve(gold, .text).?);
    try std.testing.expect(t.resolve(gold, .background) == null);
}

test "loadLines fills slots, honors roles-only, ignores junk" {
    var t: Theme = .terminal;
    t.loadLines(
        \\# a theme
        \\text #c8c2b2
        \\background #140
        \\link  #b89656
        \\heading default
        \\nonsense #ffffff
        \\rule notahex
        \\roles-only
    );
    try std.testing.expectEqual(Rgb{ .r = 0xc8, .g = 0xc2, .b = 0xb2 }, t.slot(.text).?);
    try std.testing.expectEqual(Rgb{ .r = 0x11, .g = 0x44, .b = 0x00 }, t.slot(.background).?);
    try std.testing.expectEqual(Rgb{ .r = 0xb8, .g = 0x96, .b = 0x56 }, t.slot(.link).?);
    try std.testing.expect(t.slot(.heading) == null);
    try std.testing.expect(t.slot(.rule) == null);
    try std.testing.expect(t.roles_only);
}
