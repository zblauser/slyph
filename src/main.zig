const std = @import("std");
const html = @import("html/parser.zig");
const cascade = @import("css/cascade.zig");
const layout = @import("layout/engine.zig");
const render = @import("render/text.zig");
const viewer = @import("tui/viewer.zig");
const forms = @import("forms/forms.zig");
const cookies = @import("session/cookies.zig");

pub fn main(init: std.process.Init) void {
    run(init) catch std.process.exit(1);
}

fn run(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len >= 2) {
        if (eqlAny(argv[1], &.{ "-h", "--help" })) return print(io, help_text);
        if (eqlAny(argv[1], &.{ "-v", "--version" })) return print(io, "slyph " ++ version ++ "\n");
    }
    const current: []const u8 = if (argv.len < 2) start_url else try absoluteUrl(arena, argv[1]);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const now = std.Io.Clock.real.now(io).toSeconds();
    var jar: cookies.Jar = .init(gpa);
    defer jar.deinit();
    const cookie_dir: ?[]const u8 = if (init.environ_map.get("HOME")) |home|
        std.fmt.allocPrint(arena, "{s}/.slyph", .{home}) catch null
    else
        null;
    const cookie_file: ?[]const u8 = if (cookie_dir) |d|
        std.fmt.allocPrint(arena, "{s}/cookies.txt", .{d}) catch null
    else
        null;
    var policy: cookies.Policy = .init(gpa);
    defer policy.deinit();
    if (cookie_dir) |d| {
        if (std.fmt.allocPrint(arena, "{s}/cookies.policy", .{d}) catch null) |pf|
            loadPolicy(io, gpa, &policy, d, pf);
    }
    jar.policy = &policy;
    if (cookie_file) |f| loadCookies(io, gpa, &jar, f, now);
    defer if (cookie_dir) |d| saveCookies(io, gpa, &jar, d, cookie_file.?, now);

    const start_file: ?[]const u8 = if (cookie_dir) |d|
        std.fmt.allocPrint(arena, "{s}/start", .{d}) catch null
    else
        null;
    const bookmarks: []const Bookmark = if (cookie_dir != null and start_file != null)
        loadStart(io, gpa, arena, cookie_dir.?, start_file.?) catch &start_seed
    else
        &start_seed;

    const term = terminalSize(io, std.Io.File.stdout());

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    var history: std.ArrayList(Nav) = .empty;
    defer history.deinit(gpa);
    var nav: Nav = .{ .url = current };

    var redirects: u8 = 0;
    page_loop: while (true) {
        var body: std.Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        var status: u16 = 200;
        if (std.mem.eql(u8, nav.url, start_url)) {
            try buildStartHtml(arena, bookmarks, &body.writer);
        } else {
            const res = fetch(io, &client, &jar, arena, nav, &body, now) catch return;
            if (res.status >= 300 and res.status < 400) {
                if (res.location) |loc| {
                    if (redirects >= 10) {
                        eprint(io, "too many redirects\n");
                        return;
                    }
                    redirects += 1;
                    nav = .{ .url = try resolveUrl(arena, nav.url, loc) };
                    continue :page_loop;
                }
            }
            redirects = 0;
            status = res.status;
        }

        var doc = try html.parse(gpa, body.writer.buffered());
        defer doc.deinit();
        try cascade.apply(doc.alloc(), &doc);
        try forms.init(doc.alloc(), doc.root);

        if (!term.tty) {
            const pg = try layout.layout(scratch.allocator(), &doc, term.cols);
            const frame = try render.render(scratch.allocator(), pg.root, false);
            try std.Io.File.stdout().writeStreamingAll(io, frame);
            var b: [128]u8 = undefined;
            eprint(io, std.fmt.bufPrint(&b, "\n[status {d}] {s}\n", .{ status, doc.title }) catch "\n");
            return;
        }

        var scroll: usize = 0;
        while (true) {
            _ = scratch.reset(.retain_capacity);
            const sa = scratch.allocator();
            const pg = try layout.layout(sa, &doc, term.cols);
            const frame = try render.render(sa, pg.root, true);
            var b: [256]u8 = undefined;
            const bar = std.fmt.bufPrint(&b, " slyph [{d}] {s}  ({d} links, {d} fields)  f follow · i field · ^L url · H back · q quit", .{ status, doc.title, pg.links.len, pg.fields.len }) catch " slyph";

            switch (try viewer.view(gpa, io, frame, pg.links, pg.fields, term.cols, term.rows, bar, &scroll)) {
                .quit => return,
                .back => if (history.pop()) |prev| {
                    nav = prev;
                    continue :page_loop;
                },
                .follow => |href| {
                    try history.append(gpa, nav);
                    nav = .{ .url = try resolveUrl(arena, nav.url, href) };
                    continue :page_loop;
                },
                .navigate => |typed| {
                    const url = try absoluteUrl(arena, typed);
                    gpa.free(typed);
                    try history.append(gpa, nav);
                    nav = .{ .url = url };
                    continue :page_loop;
                },
                .edit => |e| {
                    pg.fields[e.field].node.value = try doc.alloc().dupe(u8, e.value);
                    gpa.free(e.value);
                },
                .toggle => |fi| {
                    const node = pg.fields[fi].node;
                    if (forms.isChecked(node)) node.value = "" else forms.setChecked(node);
                },
                .submit => |fi| {
                    try history.append(gpa, nav);
                    nav = try buildSubmit(arena, nav.url, pg.fields[fi].node);
                    continue :page_loop;
                },
            }
        }
    }
}

const Nav = struct {
    url: []const u8,
    method: std.http.Method = .GET,
    body: ?[]const u8 = null,
};

const Term = struct { cols: u16, rows: u16, tty: bool };

const Fetched = struct { status: u16, location: ?[]const u8 = null };

fn fetch(io: std.Io, client: *std.http.Client, jar: *cookies.Jar, arena: std.mem.Allocator, nav: Nav, body: *std.Io.Writer.Allocating, now: i64) !Fetched {
    const hp = hostPath(nav.url);
    const cookie_hdr = jar.header(arena, hp.host, hp.path, hp.secure, now) catch null;

    var hdrs: [4]std.http.Header = undefined;
    var n: usize = 0;
    hdrs[n] = .{ .name = "user-agent", .value = "slyph/0.1 (+terminal)" };
    n += 1;
    hdrs[n] = .{ .name = "accept", .value = "text/html" };
    n += 1;
    if (nav.method == .POST) {
        hdrs[n] = .{ .name = "content-type", .value = "application/x-www-form-urlencoded" };
        n += 1;
    }
    if (cookie_hdr) |ch| {
        hdrs[n] = .{ .name = "cookie", .value = ch };
        n += 1;
    }

    const uri = std.Uri.parse(nav.url) catch |err| {
        var buf: [256]u8 = undefined;
        eprint(io, std.fmt.bufPrint(&buf, "bad url: {t}\n", .{err}) catch "bad url\n");
        return err;
    };
    var req = client.request(nav.method, uri, .{
        .redirect_behavior = .unhandled,
        .extra_headers = hdrs[0..n],
    }) catch |err| {
        var buf: [256]u8 = undefined;
        eprint(io, std.fmt.bufPrint(&buf, "fetch failed: {t}\n", .{err}) catch "fetch failed\n");
        if (err == error.TlsInitializationFailed)
            eprint(io, "  (TLS handshake unsupported for this site — known std.crypto.tls gap)\n");
        return err;
    };
    defer req.deinit();

    if (nav.body) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        var b = try req.sendBodyUnflushed(&.{});
        try b.writer.writeAll(payload);
        try b.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    var response = req.receiveHead(&.{}) catch |err| {
        var buf: [256]u8 = undefined;
        eprint(io, std.fmt.bufPrint(&buf, "fetch failed: {t}\n", .{err}) catch "fetch failed\n");
        if (err == error.TlsInitializationFailed)
            eprint(io, "  (TLS handshake unsupported for this site — known std.crypto.tls gap)\n");
        return err;
    };

    var hit = response.head.iterateHeaders();
    while (hit.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "set-cookie"))
            jar.setFromHeader(hp.host, hp.path, now, h.value) catch {};
    }
    const status: u16 = @intFromEnum(response.head.status);
    const location: ?[]const u8 = if (response.head.location) |l| try arena.dupe(u8, l) else null;

    if (status >= 300 and status < 400) {
        const reader = response.reader(&.{});
        _ = reader.discardRemaining() catch {};
        return .{ .status = status, .location = location };
    }

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try arena.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try arena.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = reader.streamRemaining(&body.writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };
    return .{ .status = status, .location = location };
}

const HostPath = struct { host: []const u8, path: []const u8, secure: bool };

fn hostPath(url: []const u8) HostPath {
    const scheme_sep = std.mem.indexOf(u8, url, "://") orelse return .{ .host = "", .path = "/", .secure = false };
    const secure = std.ascii.eqlIgnoreCase(url[0..scheme_sep], "https");
    const auth_start = scheme_sep + 3;
    const auth_end = std.mem.indexOfAnyPos(u8, url, auth_start, "/?#") orelse url.len;
    var authority = url[auth_start..auth_end];
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    const host = authority[0 .. std.mem.indexOfScalar(u8, authority, ':') orelse authority.len];
    var path: []const u8 = "/";
    if (auth_end < url.len and url[auth_end] == '/') {
        const path_end = std.mem.indexOfAnyPos(u8, url, auth_end, "?#") orelse url.len;
        path = url[auth_end..path_end];
    }
    return .{ .host = host, .path = path, .secure = secure };
}

const default_policy =
    \\# ~/.slyph/cookies.policy
    \\# slyph decides what cookies are necessary — you decide here, deeper than any browser.
    \\# Syntax:  deny <domain-glob> <name-glob>
    \\#   domain-glob: exact (example.com), suffix (*.tracker.net), or any (*)
    \\#   name-glob:   exact (_ga), prefix (_gat*), suffix (*_id), or any (*)
    \\# Anything not denied is accepted + persisted as before. Edit freely; delete to reset.
    \\
    \\# --- common analytics / ad trackers (first- and third-party) ---
    \\deny * _ga
    \\deny * _ga_*
    \\deny * _gid
    \\deny * _gat*
    \\deny * __utm*
    \\deny * _fbp
    \\deny * _fbc
    \\deny * _gcl_*
    \\deny * _hj*
    \\deny * __qca
    \\deny * _scid
    \\deny *.doubleclick.net *
    \\deny *.google-analytics.com *
    \\
;

fn loadPolicy(io: std.Io, gpa: std.mem.Allocator, policy: *cookies.Policy, dir: []const u8, file: []const u8) void {
    if (std.Io.Dir.cwd().readFileAlloc(io, file, gpa, .limited(1 << 20))) |bytes| {
        defer gpa.free(bytes);
        policy.loadDenyLines(bytes) catch {};
    } else |_| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = default_policy }) catch {};
        policy.loadDenyLines(default_policy) catch {};
    }
}

fn loadCookies(io: std.Io, gpa: std.mem.Allocator, jar: *cookies.Jar, file: []const u8, now: i64) void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, file, gpa, .limited(1 << 20)) catch return;
    defer gpa.free(bytes);
    jar.load(now, bytes) catch {};
}

fn saveCookies(io: std.Io, gpa: std.mem.Allocator, jar: *cookies.Jar, dir: []const u8, file: []const u8, now: i64) void {
    jar.prune(now);
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    jar.serialize(now, &buf.writer) catch return;
    if (buf.writer.buffered().len == 0) return;
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = buf.writer.buffered() }) catch {};
}

fn buildSubmit(arena: std.mem.Allocator, base: []const u8, submit: *@import("dom/node.zig").Node) !Nav {
    const form = forms.formFor(submit) orelse return .{ .url = base };
    const action = try resolveUrl(arena, base, form.attr("action") orelse "");
    const encoded = try forms.encode(arena, form, submit);
    if (forms.method(form) == .post)
        return .{ .url = action, .method = .POST, .body = encoded };
    const path = action[0 .. std.mem.indexOfScalar(u8, action, '?') orelse action.len];
    return .{ .url = try std.fmt.allocPrint(arena, "{s}?{s}", .{ path, encoded }) };
}

const start_url = "about:start";

const Bookmark = struct { name: []const u8, url: []const u8 };

const start_seed = [_]Bookmark{
    .{ .name = "Hacker News", .url = "https://news.ycombinator.com" },
    .{ .name = "Ziggit", .url = "https://ziggit.dev" },
    .{ .name = "GitHub", .url = "https://github.com" },
};

const start_header =
    \\# ~/.slyph/start — your start page links.  Format:  name<TAB>url
    \\# Edit freely; one per line. Lines starting with # are ignored.
    \\
;

const start_html_head =
    \\<style>
    \\ .banner { color: #5fd7ff; font-weight: bold }
    \\ .rule { color: #3a3a3a }
    \\ a { color: #ffaf5f }
    \\ .hint { color: #6a6a6a }
    \\</style>
    \\<pre class=banner>▞▚ S L Y P H ▞▚</pre>
    \\<pre class=rule>════════════════════════════</pre>
    \\
;
const start_html_foot =
    \\<pre class=rule>════════════════════════════</pre>
    \\<pre class=hint>^L url · f follow · q quit</pre>
;

fn loadStart(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, dir: []const u8, file: []const u8) ![]const Bookmark {
    if (std.Io.Dir.cwd().readFileAlloc(io, file, arena, .limited(1 << 20))) |bytes| {
        return parseStart(arena, bytes);
    } else |_| {
        var buf: std.Io.Writer.Allocating = .init(gpa);
        defer buf.deinit();
        buf.writer.writeAll(start_header) catch {};
        for (start_seed) |b| buf.writer.print("{s}\t{s}\n", .{ b.name, b.url }) catch {};
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = buf.writer.buffered() }) catch {};
        return arena.dupe(Bookmark, &start_seed);
    }
}

fn parseStart(arena: std.mem.Allocator, bytes: []const u8) ![]const Bookmark {
    var list: std.ArrayList(Bookmark) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const name = std.mem.trim(u8, line[0..tab], " \r");
        const url = std.mem.trim(u8, line[tab + 1 ..], " \r");
        if (name.len == 0 or url.len == 0) continue;
        try list.append(arena, .{ .name = name, .url = url });
    }
    return list.toOwnedSlice(arena);
}

fn buildStartHtml(arena: std.mem.Allocator, bookmarks: []const Bookmark, w: *std.Io.Writer) !void {
    try w.writeAll(start_html_head);
    for (bookmarks) |b| {
        const href = try absoluteUrl(arena, b.url);
        try w.print("<div><a href=\"{s}\">{s}</a></div>", .{ href, b.name });
    }
    try w.writeAll(start_html_foot);
}

fn absoluteUrl(arena: std.mem.Allocator, typed: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, typed, "://") == null)
        return std.fmt.allocPrint(arena, "https://{s}", .{typed});
    return arena.dupe(u8, typed);
}

fn resolveUrl(arena: std.mem.Allocator, base: []const u8, href: []const u8) ![]const u8 {
    if (href.len == 0 or href[0] == '#') return base;
    if (std.mem.indexOf(u8, href, "://") != null) return arena.dupe(u8, href);

    const scheme_sep = std.mem.indexOf(u8, base, "://") orelse return arena.dupe(u8, href);
    if (std.mem.startsWith(u8, href, "//"))
        return std.fmt.allocPrint(arena, "{s}:{s}", .{ base[0..scheme_sep], href });

    const auth_start = scheme_sep + 3;
    const auth_end = std.mem.indexOfAnyPos(u8, base, auth_start, "/?#") orelse base.len;
    const origin = base[0..auth_end];
    if (href[0] == '/') return std.fmt.allocPrint(arena, "{s}{s}", .{ origin, href });

    const last_slash = std.mem.lastIndexOfScalar(u8, base[auth_end..], '/');
    const dir = if (last_slash) |i| base[0 .. auth_end + i + 1] else null;
    if (dir) |d| return std.fmt.allocPrint(arena, "{s}{s}", .{ d, href });
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ origin, href });
}

fn eprint(io: std.Io, msg: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

fn print(io: std.Io, msg: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, msg) catch {};
}

fn eqlAny(s: []const u8, opts: []const []const u8) bool {
    for (opts) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}

const version = "0.1.0";

const help_text =
    \\slyph — terminal web browser (pure zig, own engine)
    \\
    \\usage:
    \\  slyph                open the start page
    \\  slyph <url>          load a url (bare host assumes https)
    \\  slyph <url> | less   pipe for a plain-text dump
    \\
    \\keys:
    \\  j/k scroll   d/u half-page   g/G top/bottom
    \\  f follow link    i edit/activate field
    \\  ^L or :  url bar     H back     q quit
    \\
    \\config in ~/.slyph/ : start, cookies.txt, cookies.policy
    \\
;

fn terminalSize(io: std.Io, file: std.Io.File) Term {
    var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const r = io.operate(.{ .device_io_control = .{
        .file = file,
        .code = std.posix.T.IOCGWINSZ,
        .arg = &ws,
    } }) catch return .{ .cols = 80, .rows = 24, .tty = false };
    if (r.device_io_control >= 0 and ws.col > 0) return .{ .cols = ws.col, .rows = ws.row, .tty = true };
    return .{ .cols = 80, .rows = 24, .tty = false };
}

fn findSubmit(node: *@import("dom/node.zig").Node) ?*@import("dom/node.zig").Node {
    if (node.kind == .element and forms.kind(node) == .submit) return node;
    var c = node.first_child;
    while (c) |n| : (c = n.next_sibling) {
        if (findSubmit(n)) |s| return s;
    }
    return null;
}

test "buildSubmit makes GET query and POST body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var get_doc = try html.parse(std.testing.allocator, "<form action=/search method=get><input name=q value=\"hi there\"><input type=submit name=go value=Go></form>");
    defer get_doc.deinit();
    try forms.init(get_doc.alloc(), get_doc.root);
    const get_nav = try buildSubmit(a, "https://x.com/page", findSubmit(get_doc.root).?);
    try std.testing.expectEqual(std.http.Method.GET, get_nav.method);
    try std.testing.expectEqualStrings("https://x.com/search?q=hi+there&go=Go", get_nav.url);

    var post_doc = try html.parse(std.testing.allocator, "<form action=/login method=post><input name=u value=zb><input type=submit value=In></form>");
    defer post_doc.deinit();
    try forms.init(post_doc.alloc(), post_doc.root);
    const post_nav = try buildSubmit(a, "https://x.com/", findSubmit(post_doc.root).?);
    try std.testing.expectEqual(std.http.Method.POST, post_nav.method);
    try std.testing.expectEqualStrings("https://x.com/login", post_nav.url);
    try std.testing.expectEqualStrings("u=zb", post_nav.body.?);
}

test "resolveUrl handles absolute, root, scheme and directory-relative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "https://example.com/docs/page.html";
    try std.testing.expectEqualStrings("https://other.com/x", try resolveUrl(a, base, "https://other.com/x"));
    try std.testing.expectEqualStrings("https://example.com/top", try resolveUrl(a, base, "/top"));
    try std.testing.expectEqualStrings("https://example.com/docs/next.html", try resolveUrl(a, base, "next.html"));
    try std.testing.expectEqualStrings("https://cdn.net/x", try resolveUrl(a, base, "//cdn.net/x"));
    try std.testing.expectEqualStrings(base, try resolveUrl(a, base, "#frag"));
    try std.testing.expectEqualStrings("https://example.com/p", try resolveUrl(a, "https://example.com", "p"));
}

test {
    _ = @import("dom/node.zig");
    _ = @import("html/tokenizer.zig");
    _ = @import("html/parser.zig");
    _ = @import("css/style.zig");
    _ = @import("css/parser.zig");
    _ = @import("css/cascade.zig");
    _ = @import("layout/box.zig");
    _ = @import("layout/engine.zig");
    _ = @import("render/text.zig");
    _ = @import("forms/forms.zig");
    _ = @import("session/cookies.zig");
}
