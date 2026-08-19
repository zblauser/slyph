const std = @import("std");

pub fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub fn eqAny(s: []const u8, set: []const []const u8) bool {
    for (set) |item| if (std.mem.eql(u8, s, item)) return true;
    return false;
}

pub fn lower(a: std.mem.Allocator, s: []const u8) []const u8 {
    const out = a.alloc(u8, s.len) catch return s;
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

pub fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}

pub fn domainMatch(host: []const u8, domain: []const u8) bool {
    if (eq(host, domain)) return true;
    if (host.len <= domain.len) return false;
    const suffix = host[host.len - domain.len ..];
    return host[host.len - domain.len - 1] == '.' and eq(suffix, domain);
}

pub const LineIter = struct {
    it: std.mem.SplitIterator(u8, .scalar),

    pub fn next(self: *LineIter) ?[]const u8 {
        while (self.it.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len == 0 or t[0] == '#') continue;
            return t;
        }
        return null;
    }
};

pub fn lines(bytes: []const u8) LineIter {
    return .{ .it = std.mem.splitScalar(u8, bytes, '\n') };
}

pub fn safeByte(c: u8) u8 {
    return if (c < 0x20 or c == 0x7f) ' ' else c;
}

pub fn hexRgb(v: []const u8) ?[3]u8 {
    const h = if (v.len > 0 and v[0] == '#') v[1..] else v;
    if (h.len == 3 or h.len == 4) {
        var out: [3]u8 = undefined;
        for (&out, h[0..3]) |*c, n| c.* = (std.fmt.charToDigit(n, 16) catch return null) * 17;
        return out;
    }
    if (h.len == 6 or h.len == 8) {
        var out: [3]u8 = undefined;
        for (&out, 0..) |*c, i| c.* = std.fmt.parseInt(u8, h[i * 2 ..][0..2], 16) catch return null;
        return out;
    }
    return null;
}

const testing = std.testing;

test "safeByte neutralizes control bytes, keeps printable and utf8" {
    try testing.expectEqual(@as(u8, ' '), safeByte(0x1b));
    try testing.expectEqual(@as(u8, ' '), safeByte(0x07));
    try testing.expectEqual(@as(u8, ' '), safeByte('\t'));
    try testing.expectEqual(@as(u8, ' '), safeByte(0x7f));
    try testing.expectEqual(@as(u8, 'x'), safeByte('x'));
    try testing.expectEqual(@as(u8, 0xc3), safeByte(0xc3));
}

test "hexRgb parses 3, 4, 6 and 8 digit forms with or without #" {
    try testing.expectEqual([3]u8{ 0x11, 0x22, 0x33 }, hexRgb("#123").?);
    try testing.expectEqual([3]u8{ 0x11, 0x22, 0x33 }, hexRgb("1234").?);
    try testing.expectEqual([3]u8{ 0xb8, 0x96, 0x56 }, hexRgb("#b89656").?);
    try testing.expectEqual([3]u8{ 0xb8, 0x96, 0x56 }, hexRgb("#b89656ff").?);
    try testing.expect(hexRgb("#xyz") == null);
    try testing.expect(hexRgb("#12345") == null);
}

test "eqAny matches set members only" {
    try testing.expect(eqAny("td", &.{ "td", "th" }));
    try testing.expect(!eqAny("tr", &.{ "td", "th" }));
    try testing.expect(!eqAny("td", &.{}));
}

test "domainMatch covers exact and dot-boundary suffixes" {
    try testing.expect(domainMatch("example.com", "example.com"));
    try testing.expect(domainMatch("a.example.com", "example.com"));
    try testing.expect(!domainMatch("notexample.com", "example.com"));
    try testing.expect(!domainMatch("example.com", "a.example.com"));
}

test "lines skips blanks and comments, trims edges" {
    var it = lines("\n # note\n  a b \n\nc\n");
    try testing.expectEqualStrings("a b", it.next().?);
    try testing.expectEqualStrings("c", it.next().?);
    try testing.expect(it.next() == null);
}

test "lower and isWs" {
    var buf: [8]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    try testing.expectEqualStrings("abc", lower(fba.allocator(), "AbC"));
    try testing.expect(isWs(' ') and isWs('\n') and !isWs('x'));
}
