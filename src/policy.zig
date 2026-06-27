const std = @import("std");

pub const DenyList = struct {
    alloc: std.mem.Allocator,
    rules: std.ArrayList(Rule) = .empty,

    const Rule = struct { domain: []const u8, key: []const u8 };

    pub fn init(alloc: std.mem.Allocator) DenyList {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *DenyList) void {
        for (self.rules.items) |r| {
            self.alloc.free(r.domain);
            self.alloc.free(r.key);
        }
        self.rules.deinit(self.alloc);
    }

    pub fn loadDenyLines(self: *DenyList, bytes: []const u8) !void {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len == 0 or t[0] == '#') continue;
            var f = std.mem.tokenizeAny(u8, t, " \t");
            const verb = f.next() orelse continue;
            if (!std.mem.eql(u8, verb, "deny")) continue;
            const domain = f.next() orelse continue;
            const key = f.next() orelse continue;
            try self.rules.append(self.alloc, .{
                .domain = try self.alloc.dupe(u8, domain),
                .key = try self.alloc.dupe(u8, key),
            });
        }
    }

    pub fn denied(self: *const DenyList, domain: []const u8, key: []const u8) bool {
        for (self.rules.items) |r| {
            if (domainGlob(r.domain, domain) and keyGlob(r.key, key)) return true;
        }
        return false;
    }
};

pub fn domainGlob(pat: []const u8, domain: []const u8) bool {
    if (std.mem.eql(u8, pat, "*")) return true;
    if (std.mem.startsWith(u8, pat, "*.")) return domainMatch(domain, pat[2..]);
    return std.ascii.eqlIgnoreCase(pat, domain);
}

pub fn keyGlob(pat: []const u8, s: []const u8) bool {
    const star = std.mem.indexOfScalar(u8, pat, '*') orelse return std.mem.eql(u8, pat, s);
    const pre = pat[0..star];
    const suf = pat[star + 1 ..];
    return s.len >= pre.len + suf.len and std.mem.startsWith(u8, s, pre) and std.mem.endsWith(u8, s, suf);
}

fn domainMatch(host: []const u8, domain: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, domain)) return true;
    if (host.len <= domain.len) return false;
    const suffix = host[host.len - domain.len ..];
    return host[host.len - domain.len - 1] == '.' and std.ascii.eqlIgnoreCase(suffix, domain);
}

test "deny glob matching: domain + key globs" {
    var p: DenyList = .init(std.testing.allocator);
    defer p.deinit();
    try p.loadDenyLines(
        \\# trackers
        \\deny * _ga
        \\deny * __utm*
        \\deny *.doubleclick.net *
        \\not-a-rule here
    );
    try std.testing.expect(p.denied("anything.com", "_ga"));
    try std.testing.expect(p.denied("x.com", "__utm_source"));
    try std.testing.expect(!p.denied("x.com", "_gat"));
    try std.testing.expect(p.denied("ads.doubleclick.net", "anyname"));
    try std.testing.expect(!p.denied("x.com", "sid"));
}

test "key glob: prefix, suffix, exact, any" {
    try std.testing.expect(keyGlob("color", "color"));
    try std.testing.expect(!keyGlob("color", "background-color"));
    try std.testing.expect(keyGlob("font-*", "font-weight"));
    try std.testing.expect(keyGlob("*-color", "background-color"));
    try std.testing.expect(keyGlob("*", "anything"));
}
