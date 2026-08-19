const std = @import("std");
const html = @import("html/parser.zig");
const cascade = @import("css/cascade.zig");
const layout = @import("layout/engine.zig");
const render = @import("render/text.zig");
const thememod = @import("render/theme.zig");
const viewer = @import("tui/viewer.zig");
const termmod = @import("tui/term.zig");
const forms = @import("forms/forms.zig");
const cookies = @import("session/cookies.zig");
const dom = @import("dom/node.zig");
const util = @import("util.zig");
const eqAny = util.eqAny;

pub fn main(init: std.process.Init) void {
    run(init) catch std.process.exit(1);
}

fn run(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len >= 2) {
        if (eqAny(argv[1], &.{ "-h", "--help" })) return print(io, help_text);
        if (eqAny(argv[1], &.{ "-v", "--version" })) return print(io, "slyph " ++ version ++ "\n");
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
            loadDenyFile(io, gpa, &policy, d, pf, default_cookie_policy);
    }
    jar.policy = &policy;

    var css_policy: cookies.Policy = .init(gpa);
    defer css_policy.deinit();
    if (cookie_dir) |d| {
        if (std.fmt.allocPrint(arena, "{s}/css.policy", .{d}) catch null) |pf|
            loadDenyFile(io, gpa, &css_policy, d, pf, default_css_policy);
    }
    var fetch_policy: cookies.Policy = .init(gpa);
    defer fetch_policy.deinit();
    if (cookie_dir) |d| {
        if (std.fmt.allocPrint(arena, "{s}/fetch.policy", .{d}) catch null) |pf|
            loadDenyFile(io, gpa, &fetch_policy, d, pf, default_fetch_policy);
    }

    var theme: thememod.Theme = .terminal;
    if (cookie_dir) |d| {
        if (std.fmt.allocPrint(arena, "{s}/theme", .{d}) catch null) |tf| {
            if (std.Io.Dir.cwd().readFileAlloc(io, tf, gpa, .limited(1 << 16))) |bytes| {
                defer gpa.free(bytes);
                theme.loadLines(bytes);
            } else |_| {}
        }
    }

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

    termmod.setOverride(init.environ_map.get("COLUMNS"), init.environ_map.get("LINES"));
    var term = terminalSize(io, std.Io.File.stdout());
    const truecolor = detectTruecolor(init.environ_map);

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    var history: std.ArrayList(Nav) = .empty;
    defer history.deinit(gpa);
    var fwd: std.ArrayList(Nav) = .empty;
    defer fwd.deinit(gpa);
    var nav: Nav = .{ .url = current };

    if (term.tty) try viewer.beginUi(io);
    defer if (term.tty) viewer.endUi(io);

    var redirects: u8 = 0;
    page_loop: while (true) {
        const ui: ?Ui = if (term.tty) .{ .io = io, .cols = term.cols, .rows = term.rows } else null;
        var body: std.Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        var status: u16 = 200;
        if (std.mem.eql(u8, nav.url, start_url)) {
            try buildStartHtml(arena, bookmarks, &body.writer, .{ policy.rules.items.len, css_policy.rules.items.len, fetch_policy.rules.items.len });
        } else if (std.mem.eql(u8, nav.url, viewer.help_url)) {
            try body.writer.writeAll(help_html);
        } else if (blk: {
            showStage(ui, " loading  {s}", .{nav.url});
            break :blk fetch(io, &client, &jar, arena, nav, &body, now, false);
        }) |res| {
            if (res.status >= 300 and res.status < 400) {
                if (res.location) |loc| {
                    if (redirects >= 10) {
                        eprint(io, "too many redirects\n");
                        return;
                    }
                    redirects += 1;
                    nav = .{ .url = try resolveUrl(arena, nav.url, loc) };
                    showStage(ui, " redirect  {s}", .{nav.url});
                    continue :page_loop;
                }
            }
            redirects = 0;
            status = res.status;
        } else |err| {
            if (!term.tty) return;
            redirects = 0;
            status = 0;
            try buildErrorHtml(nav.url, err, &body.writer);
        }

        showStage(ui, " parsing  {d} KB", .{body.writer.buffered().len / 1024});
        var doc = try html.parse(gpa, body.writer.buffered());
        defer doc.deinit();
        const sheets = fetchLinkedCss(io, &client, &jar, doc.alloc(), nav.url, doc.root, now, ui, &fetch_policy);
        showStage(ui, " styling  {d} sheet{s}", .{ sheets.len, if (sheets.len == 1) "" else "s" });
        try cascade.apply(doc.alloc(), &doc, hostPath(nav.url).host, &css_policy, sheets);
        try forms.init(doc.alloc(), doc.root);
        showStage(ui, " rendering", .{});

        if (!term.tty) {
            const pg = try layout.layout(scratch.allocator(), &doc, term.cols);
            const frame = try render.render(scratch.allocator(), pg.root, false, truecolor, &theme);
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
            const frame = try render.render(sa, pg.root, true, truecolor, &theme);
            var b: [512]u8 = undefined;
            const bar = std.fmt.bufPrint(&b, " slyph  {s}  [{d}] {s}  ({d}L {d}F)  ?·f·i·^L·H·L·q", .{ nav.url, status, doc.title, pg.links.len, pg.fields.len }) catch " slyph";

            switch (try viewer.view(gpa, io, frame, pg.links, pg.fields, term.cols, term.rows, bar, &scroll)) {
                .quit => return,
                .back => if (history.pop()) |prev| {
                    try fwd.append(gpa, nav);
                    nav = prev;
                    continue :page_loop;
                },
                .forward => if (fwd.pop()) |next| {
                    try history.append(gpa, nav);
                    nav = next;
                    continue :page_loop;
                },
                .reload => continue :page_loop,
                .resize => term = terminalSize(io, std.Io.File.stdout()),
                .follow => |href| {
                    try history.append(gpa, nav);
                    fwd.clearRetainingCapacity();
                    nav = .{ .url = try resolveUrl(arena, nav.url, href) };
                    continue :page_loop;
                },
                .navigate => |typed| {
                    const url = try absoluteUrl(arena, typed);
                    gpa.free(typed);
                    try history.append(gpa, nav);
                    fwd.clearRetainingCapacity();
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
                    fwd.clearRetainingCapacity();
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

const Ui = struct { io: std.Io, cols: u16, rows: u16 };

fn showStage(ui: ?Ui, comptime fmt: []const u8, args: anytype) void {
    const u = ui orelse return;
    var b: [512]u8 = undefined;
    viewer.progress(u.io, u.cols, u.rows, std.fmt.bufPrint(&b, fmt, args) catch return);
}

const Term = struct { cols: u16, rows: u16, tty: bool };

const Fetched = struct { status: u16, location: ?[]const u8 = null };

fn fetch(io: std.Io, client: *std.http.Client, jar: *cookies.Jar, arena: std.mem.Allocator, nav: Nav, body: *std.Io.Writer.Allocating, now: i64, quiet: bool) !Fetched {
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
        if (!quiet) {
            var buf: [256]u8 = undefined;
            eprint(io, std.fmt.bufPrint(&buf, "bad url: {t}\n", .{err}) catch "bad url\n");
        }
        return err;
    };
    var req = client.request(nav.method, uri, .{
        .redirect_behavior = .unhandled,
        .extra_headers = hdrs[0..n],
    }) catch |err| {
        if (!quiet) {
            var buf: [256]u8 = undefined;
            eprint(io, std.fmt.bufPrint(&buf, "fetch failed: {t}\n", .{err}) catch "fetch failed\n");
            if (err == error.TlsInitializationFailed)
                eprint(io, "  (TLS handshake unsupported for this site — known std.crypto.tls gap)\n");
        }
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
        if (!quiet) {
            var buf: [256]u8 = undefined;
            eprint(io, std.fmt.bufPrint(&buf, "fetch failed: {t}\n", .{err}) catch "fetch failed\n");
            if (err == error.TlsInitializationFailed)
                eprint(io, "  (TLS handshake unsupported for this site — known std.crypto.tls gap)\n");
        }
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
    var left: usize = max_body;
    while (left > 0) {
        left -= reader.stream(&body.writer, .limited(left)) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return response.bodyErr().?,
            else => |e| return e,
        };
    }
    return .{ .status = status, .location = location };
}

const max_sheets = 16;
const max_body = 32 << 20;

fn fetchLinkedCss(io: std.Io, client: *std.http.Client, jar: *cookies.Jar, da: std.mem.Allocator, base: []const u8, root: *dom.Node, now: i64, ui: ?Ui, policy: *const cookies.Policy) []const []const u8 {
    var sheets: std.ArrayList([]const u8) = .empty;
    var count: usize = 0;
    collectCss(io, client, jar, da, base, root, now, &sheets, &count, ui, policy);
    return sheets.toOwnedSlice(da) catch &.{};
}

fn collectCss(io: std.Io, client: *std.http.Client, jar: *cookies.Jar, da: std.mem.Allocator, base: []const u8, node: *dom.Node, now: i64, sheets: *std.ArrayList([]const u8), count: *usize, ui: ?Ui, policy: *const cookies.Policy) void {
    if (count.* >= max_sheets) return;
    if (node.kind == .element and std.ascii.eqlIgnoreCase(node.tag, "link") and isStylesheet(node)) {
        if (node.attr("href")) |href| {
            if (resolveUrl(da, base, href)) |url| {
                if (!fetchDenied(policy, base, url, "css")) {
                    showStage(ui, " stylesheet {d}/{d}  {s}", .{ count.* + 1, max_sheets, url });
                    if (fetchCssOne(io, client, jar, da, base, url, now, policy)) |text| {
                        sheets.append(da, text) catch {};
                        count.* += 1;
                    }
                }
            } else |_| {}
        }
    }
    var child = node.first_child;
    while (child) |c| : (child = c.next_sibling) collectCss(io, client, jar, da, base, c, now, sheets, count, ui, policy);
}

fn fetchDenied(policy: *const cookies.Policy, page_url: []const u8, res_url: []const u8, kind: []const u8) bool {
    const page = hostPath(page_url).host;
    const res = hostPath(res_url);
    if (policy.denied(page, res.host)) return true;
    if (policy.denied(page, res.path)) return true;
    if (policy.denied(page, kind)) return true;
    if (!sameSite(page, res.host) and policy.denied(page, "third-party")) return true;
    return false;
}

fn sameSite(a: []const u8, b: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(a, b)) return true;
    return std.ascii.eqlIgnoreCase(registrable(a), registrable(b));
}

fn registrable(host: []const u8) []const u8 {
    var dot = std.mem.lastIndexOfScalar(u8, host, '.') orelse return host;
    dot = std.mem.lastIndexOfScalar(u8, host[0..dot], '.') orelse return host;
    return host[dot + 1 ..];
}

fn isStylesheet(node: *dom.Node) bool {
    const rel = node.attr("rel") orelse return false;
    var it = std.mem.tokenizeAny(u8, rel, " \t");
    while (it.next()) |t| if (std.ascii.eqlIgnoreCase(t, "stylesheet")) return true;
    return false;
}

fn fetchCssOne(io: std.Io, client: *std.http.Client, jar: *cookies.Jar, da: std.mem.Allocator, base: []const u8, url: []const u8, now: i64, policy: *const cookies.Policy) ?[]const u8 {
    var u = url;
    var hops: u8 = 0;
    while (hops < 5) : (hops += 1) {
        var body: std.Io.Writer.Allocating = .init(da);
        const res = fetch(io, client, jar, da, .{ .url = u }, &body, now, true) catch return null;
        if (res.status >= 300 and res.status < 400) {
            const loc = res.location orelse return null;
            u = resolveUrl(da, u, loc) catch return null;
            if (fetchDenied(policy, base, u, "css")) return null;
            continue;
        }
        if (res.status != 200) return null;
        return body.writer.buffered();
    }
    return null;
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

const default_cookie_policy =
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

const default_fetch_policy =
    \\# ~/.slyph/fetch.policy
    \\# The earliest interception point: a denied sub-resource is never requested at all.
    \\# The page itself is always fetched — this gates only what the page asks slyph to pull.
    \\# Syntax:  deny <page-domain-glob> <what-glob>
    \\#   page-domain-glob: exact (example.com), suffix (*.example.com), or any (*)
    \\#   what-glob matches, in turn, the sub-resource's:
    \\#     host      (*.doubleclick.net, fonts.googleapis.com)
    \\#     path      (/analytics.js, /wp-content/*)
    \\#     kind      (css)
    \\#     the literal word `third-party` when its site differs from the page's
    \\# Edit freely; delete the file to reset.
    \\
    \\# --- known analytics / ad / tag hosts (denied by default) ---
    \\deny * *.doubleclick.net
    \\deny * *.google-analytics.com
    \\deny * *.googletagmanager.com
    \\deny * *.googlesyndication.com
    \\deny * *.scorecardresearch.com
    \\deny * *.hotjar.com
    \\deny * *.segment.io
    \\deny * *.segment.com
    \\deny * *.mixpanel.com
    \\deny * *.amplitude.com
    \\deny * *.newrelic.com
    \\deny * *.branch.io
    \\deny * *.adsrvr.org
    \\deny * *.criteo.com
    \\deny * *.taboola.com
    \\deny * *.outbrain.com
    \\
    \\# --- aggressive options (commented; uncomment to opt in) ---
    \\# deny * third-party        # pull nothing from another site — fast, sometimes ugly
    \\# deny * *.googleapis.com   # web fonts and hosted libs
    \\# deny * *.cloudflare.com
    \\# deny * css                # skip every linked stylesheet, keep inline <style>
    \\
;

const default_css_policy =
    \\# ~/.slyph/css.policy
    \\# The site styles the page; you decide which of its styles slyph obeys.
    \\# slyph's own UA defaults (block/inline, bold headings, link underline) always
    \\# apply — these rules only strip styles the SITE asked for (author + inline css).
    \\# Syntax:  deny <domain-glob> <property-glob>
    \\#   domain-glob:   exact (example.com), suffix (*.nytimes.com), or any (*)
    \\#   property-glob: exact (color), prefix (font-*), suffix (*-style), or any (*)
    \\# Properties slyph renders: color, font-weight, font-style, text-decoration,
    \\#   white-space, display, margin, margin-top, margin-bottom.
    \\# Nothing is stripped by default — uncomment or add rules to opt in.
    \\
    \\# --- examples (commented; edit to taste) ---
    \\# deny * color                 # ignore all author text colors, use terminal default
    \\# deny *.example.com font-*    # drop a site's bold/italic insistence
    \\# deny news.ycombinator.com color
    \\
;

fn loadDenyFile(io: std.Io, gpa: std.mem.Allocator, policy: *cookies.Policy, dir: []const u8, file: []const u8, seed: []const u8) void {
    if (std.Io.Dir.cwd().readFileAlloc(io, file, gpa, .limited(1 << 20))) |bytes| {
        defer gpa.free(bytes);
        policy.loadDenyLines(bytes) catch {};
    } else |_| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = seed }) catch {};
        policy.loadDenyLines(seed) catch {};
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
    writeFileAtomic(io, gpa, file, buf.writer.buffered());
}

fn writeFileAtomic(io: std.Io, gpa: std.mem.Allocator, file: []const u8, data: []const u8) void {
    const tmp = std.fmt.allocPrint(gpa, "{s}.tmp", .{file}) catch {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = data }) catch {};
        return;
    };
    defer gpa.free(tmp);
    const cwd = std.Io.Dir.cwd();
    cwd.writeFile(io, .{ .sub_path = tmp, .data = data }) catch return;
    cwd.rename(tmp, cwd, file, io) catch {
        cwd.writeFile(io, .{ .sub_path = file, .data = data }) catch {};
        cwd.deleteFile(io, tmp) catch {};
    };
}

fn buildSubmit(arena: std.mem.Allocator, base: []const u8, submit: *dom.Node) !Nav {
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
    \\ .tag { color: #6a6a6a }
    \\ th { color: #5fd7ff }
    \\</style>
    \\<pre class=banner>  ▞▚ S L Y P H ▞▚</pre>
    \\<pre class=tag>  a terminal browser that obeys you, not the page</pre>
    \\
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
    var it = util.lines(bytes);
    while (it.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const name = std.mem.trim(u8, line[0..tab], " \r");
        const url = std.mem.trim(u8, line[tab + 1 ..], " \r");
        if (name.len == 0 or url.len == 0) continue;
        try list.append(arena, .{ .name = name, .url = url });
    }
    return list.toOwnedSlice(arena);
}

fn buildStartHtml(arena: std.mem.Allocator, bookmarks: []const Bookmark, w: *std.Io.Writer, denied: [3]usize) !void {
    try w.writeAll(start_html_head);
    try w.writeAll("<table border=1><tr><th>go</th><th>where</th></tr>");
    for (bookmarks) |b| {
        const href = try absoluteUrl(arena, b.url);
        try w.print("<tr><td><a href=\"{s}\">{s}</a></td><td class=tag>{s}</td></tr>", .{ href, b.name, hostPath(href).host });
    }
    try w.writeAll("</table>");
    try w.print(
        \\<pre class=tag>standing orders — {d} cookie rules · {d} style rules · {d} fetch rules
        \\edit them in ~/.slyph/, they are yours</pre>
        \\<pre class=hint>? keys · ^L url · f follow · i field · H back · q quit</pre>
    , .{ denied[0], denied[1], denied[2] });
}

const help_html =
    \\<style>
    \\ .banner { color: #5fd7ff; font-weight: bold }
    \\ .rule { color: #3a3a3a }
    \\ th { color: #5fd7ff }
    \\ .k { color: #ffaf5f }
    \\ .note { color: #6a6a6a }
    \\</style>
    \\<pre class=banner>▞▚ S L Y P H ▞▚  keys</pre>
    \\<pre class=rule>════════════════════════════════════════════</pre>
    \\<table>
    \\<tr><th>key</th><th>does</th></tr>
    \\<tr><td class=k>j k</td><td>scroll a line (arrows work too)</td></tr>
    \\<tr><td class=k>d u</td><td>half a page down / up (space, b too)</td></tr>
    \\<tr><td class=k>PgDn PgUp</td><td>a whole page</td></tr>
    \\<tr><td class=k>g G</td><td>top / bottom (Home, End too)</td></tr>
    \\<tr><td class=k>f</td><td>follow a link — type the [n] beside it</td></tr>
    \\<tr><td class=k>i</td><td>use a field — type the {n} beside it, then the text</td></tr>
    \\<tr><td class=k>r</td><td>reload</td></tr>
    \\<tr><td class=k>^L or :</td><td>url bar</td></tr>
    \\<tr><td class=k>H L</td><td>back / forward</td></tr>
    \\<tr><td class=k>?</td><td>this page</td></tr>
    \\<tr><td class=k>q</td><td>quit, after a y/n check</td></tr>
    \\<tr><td class=k>Q</td><td>quit at once, no check</td></tr>
    \\</table>
    \\<pre class=rule>════════════════════════════════════════════</pre>
    \\<pre class=note>[n] is a link, {n} is a form field. Both are typed as plain numbers.
    \\A checkbox or radio toggles with i; a submit button submits with i.</pre>
    \\<pre class=rule>════════════════════════════════════════════</pre>
    \\<pre class=note>Config lives in ~/.slyph/ — each file is plain text you can edit:
    \\  start          your start-page links
    \\  theme          colors, by role
    \\  cookies.txt    saved cookies
    \\  cookies.policy which cookies are allowed
    \\  css.policy     which site styles are obeyed
    \\  fetch.policy   which sub-resources are fetched at all
    \\
    \\LINES / COLUMNS override the terminal size slyph draws to.
    \\Press H to go back.</pre>
;

fn buildErrorHtml(url: []const u8, err: anyerror, w: *std.Io.Writer) !void {
    const note: []const u8 = if (err == error.TlsInitializationFailed)
        "TLS handshake unsupported for this site (known std.crypto.tls gap)."
    else
        "";
    try w.print(
        \\<style> .err {{ color:#ff8787 }} .k {{ color:#6a6a6a }} </style>
        \\<pre class=err>could not load</pre>
        \\<pre>{s}</pre>
        \\<pre>{t}</pre>
        \\<pre>{s}</pre>
        \\<pre class=k>H back · L forward · ^L url · r retry · q quit</pre>
    , .{ url, err, note });
}

fn absoluteUrl(arena: std.mem.Allocator, typed: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, typed, "about:")) return arena.dupe(u8, typed);
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

const version = "0.1.4";

const help_text =
    \\slyph — terminal web browser (pure zig, own engine)
    \\
    \\usage:
    \\  slyph                open the start page
    \\  slyph <url>          load a url (bare host assumes https)
    \\  slyph <url> | less   pipe for a plain-text dump
    \\
    \\keys:
    \\  j/k or arrows scroll   d/u half-page   PgUp/PgDn page   g/G top/bottom
    \\  f follow link    i edit/activate field    r reload
    \\  ^L or :  url bar   H back   L forward   ? keys   q quit (Q now)
    \\
    \\LINES / COLUMNS override the detected terminal size (useful when an
    \\on-screen keyboard covers part of the screen, e.g. under ish on ios)
    \\
    \\config in ~/.slyph/ : start, theme, cookies.txt,
    \\                     cookies.policy, css.policy, fetch.policy
    \\
;

fn detectTruecolor(env: anytype) bool {
    const ct = env.get("COLORTERM") orelse return false;
    return std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit");
}

fn terminalSize(io: std.Io, file: std.Io.File) Term {
    const sz = termmod.size(io, file);
    return .{ .cols = sz.cols, .rows = sz.rows, .tty = sz.tty };
}

fn findSubmit(node: *dom.Node) ?*dom.Node {
    if (node.kind == .element and forms.kind(node) == .submit) return node;
    var c = node.first_child;
    while (c) |n| : (c = n.next_sibling) {
        if (findSubmit(n)) |s| return s;
    }
    return null;
}

test "registrable domain and same-site comparison" {
    try std.testing.expectEqualStrings("example.com", registrable("a.b.example.com"));
    try std.testing.expectEqualStrings("example.com", registrable("example.com"));
    try std.testing.expectEqualStrings("localhost", registrable("localhost"));
    try std.testing.expect(sameSite("example.com", "cdn.example.com"));
    try std.testing.expect(sameSite("a.example.com", "b.example.com"));
    try std.testing.expect(!sameSite("example.com", "doubleclick.net"));
}

test "fetch policy gates sub-resources by host, path, kind and third-party" {
    var p: cookies.Policy = .init(std.testing.allocator);
    defer p.deinit();
    try p.loadDenyLines(
        \\deny * *.google-analytics.com
        \\deny shop.example.com /track/*
        \\deny noskin.example.com css
        \\deny strict.example.com third-party
    );

    const page = "https://shop.example.com/a";
    try std.testing.expect(p.denied("shop.example.com", "www.google-analytics.com"));
    try std.testing.expect(fetchDenied(&p, page, "https://www.google-analytics.com/x.css", "css"));
    try std.testing.expect(fetchDenied(&p, page, "https://shop.example.com/track/a.css", "css"));
    try std.testing.expect(!fetchDenied(&p, page, "https://shop.example.com/site.css", "css"));
    try std.testing.expect(!fetchDenied(&p, page, "https://cdn.example.com/site.css", "css"));

    try std.testing.expect(fetchDenied(&p, "https://noskin.example.com/a", "https://noskin.example.com/s.css", "css"));

    const strict = "https://strict.example.com/a";
    try std.testing.expect(fetchDenied(&p, strict, "https://cdn.other.net/s.css", "css"));
    try std.testing.expect(!fetchDenied(&p, strict, "https://cdn.example.com/s.css", "css"));
}

test "seeded fetch policy denies known trackers, leaves ordinary hosts alone" {
    var p: cookies.Policy = .init(std.testing.allocator);
    defer p.deinit();
    try p.loadDenyLines(default_fetch_policy);

    const page = "https://news.example.com/a";
    try std.testing.expect(fetchDenied(&p, page, "https://www.googletagmanager.com/gtm.js", "css"));
    try std.testing.expect(fetchDenied(&p, page, "https://static.doubleclick.net/a.css", "css"));
    try std.testing.expect(!fetchDenied(&p, page, "https://fonts.googleapis.com/css?family=x", "css"));
    try std.testing.expect(!fetchDenied(&p, page, "https://news.example.com/site.css", "css"));
    try std.testing.expect(!fetchDenied(&p, page, "https://cdn.jsdelivr.net/x.css", "css"));
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
    _ = @import("util.zig");
    _ = @import("policy.zig");
    _ = @import("dom/node.zig");
    _ = @import("html/tokenizer.zig");
    _ = @import("html/parser.zig");
    _ = @import("css/style.zig");
    _ = @import("css/parser.zig");
    _ = @import("css/cascade.zig");
    _ = @import("layout/box.zig");
    _ = @import("layout/engine.zig");
    _ = @import("render/text.zig");
    _ = @import("render/theme.zig");
    _ = @import("forms/forms.zig");
    _ = @import("session/cookies.zig");
    _ = @import("tui/viewer.zig");
    _ = @import("tui/term.zig");
}
