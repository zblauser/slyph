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

const testing = std.testing;

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

test "lower and isWs" {
    var buf: [8]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    try testing.expectEqualStrings("abc", lower(fba.allocator(), "AbC"));
    try testing.expect(isWs(' ') and isWs('\n') and !isWs('x'));
}
