const std = @import("std");

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: []const u8,
    expires: i64 = 0,
    secure: bool = false,
    host_only: bool = true,
};

pub const Jar = struct {
    alloc: std.mem.Allocator,
    cookies: std.ArrayList(Cookie) = .empty,
    policy: ?*const Policy = null,

    pub fn init(alloc: std.mem.Allocator) Jar {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Jar) void {
        for (self.cookies.items) |c| self.freeCookie(c);
        self.cookies.deinit(self.alloc);
    }

    fn freeCookie(self: *Jar, c: Cookie) void {
        self.alloc.free(c.name);
        self.alloc.free(c.value);
        self.alloc.free(c.domain);
        self.alloc.free(c.path);
    }

    pub fn setFromHeader(self: *Jar, host: []const u8, path: []const u8, now: i64, header_value: []const u8) !void {
        var it = std.mem.splitScalar(u8, header_value, ';');
        const pair = std.mem.trim(u8, it.first(), " \t");
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return;
        const name = std.mem.trim(u8, pair[0..eq], " \t");
        const value = std.mem.trim(u8, pair[eq + 1 ..], " \t");
        if (name.len == 0) return;

        var domain: []const u8 = host;
        var host_only = true;
        var cpath: ?[]const u8 = null;
        var secure_attr = false;
        var expires: i64 = 0;
        var max_age: ?i64 = null;

        while (it.next()) |raw| {
            const attr = std.mem.trim(u8, raw, " \t");
            const av = std.mem.indexOfScalar(u8, attr, '=');
            const key = if (av) |i| attr[0..i] else attr;
            const val = if (av) |i| std.mem.trim(u8, attr[i + 1 ..], " \t") else "";
            if (eqIgnoreCase(key, "domain")) {
                const d = std.mem.trimStart(u8, val, ".");
                if (d.len == 0) continue;
                if (!domainMatch(host, d)) return;
                domain = d;
                host_only = false;
            } else if (eqIgnoreCase(key, "path")) {
                if (val.len > 0 and val[0] == '/') cpath = val;
            } else if (eqIgnoreCase(key, "max-age")) {
                max_age = std.fmt.parseInt(i64, val, 10) catch null;
            } else if (eqIgnoreCase(key, "expires")) {
                expires = parseHttpDate(val) orelse 0;
            } else if (eqIgnoreCase(key, "secure")) {
                secure_attr = true;
            }
        }
        if (max_age) |ma| expires = now + ma;

        const eff_path = cpath orelse defaultPath(path);
        if (self.policy) |p| if (p.denied(domain, name)) {
            self.remove(name, domain, eff_path);
            return;
        };
        if (expires != 0 and expires <= now) {
            self.remove(name, domain, eff_path);
            return;
        }

        const dup: Cookie = .{
            .name = try self.alloc.dupe(u8, name),
            .value = try self.alloc.dupe(u8, value),
            .domain = try lowerDupe(self.alloc, domain),
            .path = try self.alloc.dupe(u8, eff_path),
            .expires = expires,
            .secure = secure_attr,
            .host_only = host_only,
        };
        if (self.find(dup.name, dup.domain, dup.path)) |idx| {
            self.freeCookie(self.cookies.items[idx]);
            self.cookies.items[idx] = dup;
        } else {
            try self.cookies.append(self.alloc, dup);
        }
    }

    pub fn header(self: *Jar, out: std.mem.Allocator, host: []const u8, path: []const u8, secure: bool, now: i64) !?[]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(out);
        for (self.cookies.items) |c| {
            if (c.expires != 0 and c.expires <= now) continue;
            if (self.policy) |p| if (p.denied(c.domain, c.name)) continue;
            if (c.secure and !secure) continue;
            const dm = if (c.host_only) eqIgnoreCase(host, c.domain) else domainMatch(host, c.domain);
            if (!dm) continue;
            if (!pathMatch(path, c.path)) continue;
            if (buf.items.len > 0) try buf.appendSlice(out, "; ");
            try buf.appendSlice(out, c.name);
            try buf.append(out, '=');
            try buf.appendSlice(out, c.value);
        }
        if (buf.items.len == 0) return null;
        return try buf.toOwnedSlice(out);
    }

    pub fn prune(self: *Jar, now: i64) void {
        var i: usize = 0;
        while (i < self.cookies.items.len) {
            const c = self.cookies.items[i];
            if (c.expires != 0 and c.expires <= now) {
                self.freeCookie(c);
                _ = self.cookies.orderedRemove(i);
            } else i += 1;
        }
    }

    pub fn serialize(self: *Jar, now: i64, w: *std.Io.Writer) !void {
        for (self.cookies.items) |c| {
            if (c.expires == 0 or c.expires <= now) continue;
            try w.print("{s}\t{d}\t{s}\t{d}\t{d}\t{s}\t{s}\n", .{
                c.domain, @intFromBool(c.host_only), c.path, @intFromBool(c.secure), c.expires, c.name, c.value,
            });
        }
    }

    pub fn load(self: *Jar, now: i64, bytes: []const u8) !void {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var f = std.mem.splitScalar(u8, line, '\t');
            const domain = f.next() orelse continue;
            const host_only = (f.next() orelse continue)[0] == '1';
            const path = f.next() orelse continue;
            const secure = (f.next() orelse continue)[0] == '1';
            const expires = std.fmt.parseInt(i64, f.next() orelse continue, 10) catch continue;
            const name = f.next() orelse continue;
            const value = f.rest();
            if (expires != 0 and expires <= now) continue;
            if (self.policy) |p| if (p.denied(domain, name)) continue;
            try self.cookies.append(self.alloc, .{
                .name = try self.alloc.dupe(u8, name),
                .value = try self.alloc.dupe(u8, value),
                .domain = try self.alloc.dupe(u8, domain),
                .path = try self.alloc.dupe(u8, path),
                .expires = expires,
                .secure = secure,
                .host_only = host_only,
            });
        }
    }

    fn find(self: *Jar, name: []const u8, domain: []const u8, path: []const u8) ?usize {
        for (self.cookies.items, 0..) |c, i| {
            if (std.mem.eql(u8, c.name, name) and std.mem.eql(u8, c.domain, domain) and std.mem.eql(u8, c.path, path))
                return i;
        }
        return null;
    }

    fn remove(self: *Jar, name: []const u8, domain: []const u8, path: []const u8) void {
        if (self.find(name, domain, path)) |i| {
            self.freeCookie(self.cookies.items[i]);
            _ = self.cookies.orderedRemove(i);
        }
    }
};

pub const Policy = struct {
    alloc: std.mem.Allocator,
    rules: std.ArrayList(Rule) = .empty,

    const Rule = struct { domain: []const u8, name: []const u8 };

    pub fn init(alloc: std.mem.Allocator) Policy {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Policy) void {
        for (self.rules.items) |r| {
            self.alloc.free(r.domain);
            self.alloc.free(r.name);
        }
        self.rules.deinit(self.alloc);
    }

    pub fn loadDenyLines(self: *Policy, bytes: []const u8) !void {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len == 0 or t[0] == '#') continue;
            var f = std.mem.tokenizeAny(u8, t, " \t");
            const verb = f.next() orelse continue;
            if (!std.mem.eql(u8, verb, "deny")) continue;
            const domain = f.next() orelse continue;
            const name = f.next() orelse continue;
            try self.rules.append(self.alloc, .{
                .domain = try self.alloc.dupe(u8, domain),
                .name = try self.alloc.dupe(u8, name),
            });
        }
    }

    pub fn denied(self: *const Policy, domain: []const u8, name: []const u8) bool {
        for (self.rules.items) |r| {
            if (domainGlob(r.domain, domain) and nameGlob(r.name, name)) return true;
        }
        return false;
    }
};

fn domainGlob(pat: []const u8, domain: []const u8) bool {
    if (std.mem.eql(u8, pat, "*")) return true;
    if (std.mem.startsWith(u8, pat, "*.")) return domainMatch(domain, pat[2..]);
    return eqIgnoreCase(pat, domain);
}

fn nameGlob(pat: []const u8, s: []const u8) bool {
    const star = std.mem.indexOfScalar(u8, pat, '*') orelse return std.mem.eql(u8, pat, s);
    const pre = pat[0..star];
    const suf = pat[star + 1 ..];
    return s.len >= pre.len + suf.len and std.mem.startsWith(u8, s, pre) and std.mem.endsWith(u8, s, suf);
}

fn domainMatch(host: []const u8, domain: []const u8) bool {
    if (eqIgnoreCase(host, domain)) return true;
    if (host.len <= domain.len) return false;
    const suffix = host[host.len - domain.len ..];
    return host[host.len - domain.len - 1] == '.' and eqIgnoreCase(suffix, domain);
}

fn pathMatch(req: []const u8, cookie: []const u8) bool {
    if (std.mem.eql(u8, req, cookie)) return true;
    if (!std.mem.startsWith(u8, req, cookie)) return false;
    return cookie[cookie.len - 1] == '/' or req[cookie.len] == '/';
}

fn defaultPath(path: []const u8) []const u8 {
    if (path.len == 0 or path[0] != '/') return "/";
    const last = std.mem.lastIndexOfScalar(u8, path, '/').?;
    return if (last == 0) "/" else path[0..last];
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn lowerDupe(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try alloc.dupe(u8, s);
    for (out) |*ch| ch.* = std.ascii.toLower(ch.*);
    return out;
}

fn parseHttpDate(s: []const u8) ?i64 {
    var toks: [8][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, s, " ,-");
    while (it.next()) |t| : (n += 1) {
        if (n == toks.len) break;
        toks[n] = t;
    }
    if (n < 5) return null;
    const base: usize = if (toks[0].len > 0 and !std.ascii.isDigit(toks[0][0])) 1 else 0;
    if (n < base + 4) return null;
    const day = std.fmt.parseInt(u8, toks[base], 10) catch return null;
    const month = monthNum(toks[base + 1]) orelse return null;
    var year = std.fmt.parseInt(u16, toks[base + 2], 10) catch return null;
    if (year < 100) year += if (year >= 70) 1900 else 2000;
    var hms = std.mem.splitScalar(u8, toks[base + 3], ':');
    const hh = std.fmt.parseInt(u8, hms.next() orelse return null, 10) catch return null;
    const mm = std.fmt.parseInt(u8, hms.next() orelse return null, 10) catch return null;
    const ss = std.fmt.parseInt(u8, hms.next() orelse return null, 10) catch return null;
    if (year < 1970 or month < 1 or month > 12 or day < 1 or day > 31) return null;
    return daysFromCivil(year, month, day) * std.time.s_per_day +
        @as(i64, hh) * std.time.s_per_hour + @as(i64, mm) * std.time.s_per_min + ss;
}

fn monthNum(s: []const u8) ?u8 {
    const names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    for (names, 1..) |m, i| if (eqIgnoreCase(s, m)) return @intCast(i);
    return null;
}

fn daysFromCivil(y: u16, m: u8, d: u8) i64 {
    const yy: i64 = @as(i64, y) - @intFromBool(m <= 2);
    const era = @divFloor(if (yy >= 0) yy else yy - 399, 400);
    const yoe = yy - era * 400;
    const mp: i64 = @mod(@as(i64, m) + 9, 12);
    const doy = @divTrunc(153 * mp + 2, 5) + @as(i64, d) - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

test "set and replay a simple cookie" {
    var jar: Jar = .init(std.testing.allocator);
    defer jar.deinit();
    try jar.setFromHeader("example.com", "/", 1000, "sid=abc123");
    const h = (try jar.header(std.testing.allocator, "example.com", "/", true, 1000)).?;
    defer std.testing.allocator.free(h);
    try std.testing.expectEqualStrings("sid=abc123", h);
}

test "host-only cookie not sent to other hosts; domain cookie reaches subdomain" {
    var jar: Jar = .init(std.testing.allocator);
    defer jar.deinit();
    try jar.setFromHeader("example.com", "/", 0, "a=1");
    try jar.setFromHeader("example.com", "/", 0, "b=2; Domain=example.com");
    try std.testing.expect((try jar.header(std.testing.allocator, "other.com", "/", true, 0)) == null);
    const sub = (try jar.header(std.testing.allocator, "www.example.com", "/", true, 0)).?;
    defer std.testing.allocator.free(sub);
    try std.testing.expectEqualStrings("b=2", sub);
}

test "server cannot set a cookie for an unrelated domain" {
    var jar: Jar = .init(std.testing.allocator);
    defer jar.deinit();
    try jar.setFromHeader("evil.com", "/", 0, "x=1; Domain=google.com");
    try std.testing.expectEqual(@as(usize, 0), jar.cookies.items.len);
}

test "path scoping and secure flag" {
    var jar: Jar = .init(std.testing.allocator);
    defer jar.deinit();
    try jar.setFromHeader("x.com", "/admin/panel", 0, "s=1; Path=/admin");
    try jar.setFromHeader("x.com", "/", 0, "t=2; Secure");
    try std.testing.expect((try jar.header(std.testing.allocator, "x.com", "/public", false, 0)) == null);
    const adm = (try jar.header(std.testing.allocator, "x.com", "/admin/panel", false, 0)).?;
    defer std.testing.allocator.free(adm);
    try std.testing.expectEqualStrings("s=1", adm);
}

test "max-age expiry deletes and excludes" {
    var jar: Jar = .init(std.testing.allocator);
    defer jar.deinit();
    try jar.setFromHeader("x.com", "/", 100, "k=v; Max-Age=50");
    const live = (try jar.header(std.testing.allocator, "x.com", "/", true, 120)).?;
    std.testing.allocator.free(live);
    try std.testing.expect((try jar.header(std.testing.allocator, "x.com", "/", true, 200)) == null);
    try jar.setFromHeader("x.com", "/", 100, "k=v; Max-Age=0");
    try std.testing.expectEqual(@as(usize, 0), jar.cookies.items.len);
}

test "overwrite same name/domain/path" {
    var jar: Jar = .init(std.testing.allocator);
    defer jar.deinit();
    try jar.setFromHeader("x.com", "/", 0, "k=old");
    try jar.setFromHeader("x.com", "/", 0, "k=new");
    try std.testing.expectEqual(@as(usize, 1), jar.cookies.items.len);
    const h = (try jar.header(std.testing.allocator, "x.com", "/", true, 0)).?;
    defer std.testing.allocator.free(h);
    try std.testing.expectEqualStrings("k=new", h);
}

test "expires date parsing" {
    try std.testing.expectEqual(@as(?i64, 784111777), parseHttpDate("Sun, 06 Nov 1994 08:49:37 GMT"));
    try std.testing.expectEqual(@as(?i64, 784111777), parseHttpDate("Sunday, 06-Nov-94 08:49:37 GMT"));
    try std.testing.expectEqual(@as(?i64, 0), daysFromCivil(1970, 1, 1) * std.time.s_per_day);
    try std.testing.expectEqual(@as(?i64, null), parseHttpDate("garbage"));
}

test "serialize drops session cookies, round-trips persistent ones" {
    var jar: Jar = .init(std.testing.allocator);
    defer jar.deinit();
    try jar.setFromHeader("x.com", "/", 0, "sess=1");
    try jar.setFromHeader("x.com", "/app", 100, "keep=2; Max-Age=10000; Domain=x.com");
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try jar.serialize(100, &buf.writer);
    try std.testing.expect(std.mem.indexOf(u8, buf.writer.buffered(), "sess") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.writer.buffered(), "keep") != null);

    var jar2: Jar = .init(std.testing.allocator);
    defer jar2.deinit();
    try jar2.load(100, buf.writer.buffered());
    const h = (try jar2.header(std.testing.allocator, "www.x.com", "/app/x", true, 200)).?;
    defer std.testing.allocator.free(h);
    try std.testing.expectEqualStrings("keep=2", h);
}

test "policy glob matching" {
    var p: Policy = .init(std.testing.allocator);
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

test "jar honors policy on store and send" {
    var p: Policy = .init(std.testing.allocator);
    defer p.deinit();
    try p.loadDenyLines("deny * _ga\n");
    var jar: Jar = .init(std.testing.allocator);
    defer jar.deinit();
    jar.policy = &p;
    try jar.setFromHeader("x.com", "/", 0, "_ga=track");
    try jar.setFromHeader("x.com", "/", 0, "sid=keep");
    try std.testing.expectEqual(@as(usize, 1), jar.cookies.items.len);
    const h = (try jar.header(std.testing.allocator, "x.com", "/", true, 0)).?;
    defer std.testing.allocator.free(h);
    try std.testing.expectEqualStrings("sid=keep", h);
}

test "policy purges a cookie loaded before the rule existed" {
    var jar: Jar = .init(std.testing.allocator);
    defer jar.deinit();
    try jar.load(0, "x.com\t1\t/\t0\t9999999999\t_ga\told\n");
    try std.testing.expectEqual(@as(usize, 1), jar.cookies.items.len);
    var p: Policy = .init(std.testing.allocator);
    defer p.deinit();
    try p.loadDenyLines("deny * _ga\n");
    jar.policy = &p;
    try jar.setFromHeader("x.com", "/", 0, "_ga=new");
    try std.testing.expectEqual(@as(usize, 0), jar.cookies.items.len);
}
