//! webcli — terminal web browser (pure Zig, own engine).
//! Pipeline: fetch (std.http + std.crypto.tls) → HTML parse → DOM → CSS cascade
//! → block/inline layout → text render (ANSI). Interactive TUI comes next.

const std = @import("std");
const html = @import("html/parser.zig");
const cascade = @import("css/cascade.zig");
const layout = @import("layout/engine.zig");
const render = @import("render/text.zig");
const viewer = @import("tui/viewer.zig");
const forms = @import("forms/forms.zig");

/// Thin wrapper so user-facing failures exit cleanly (no Zig stack trace):
/// run() prints a friendly message before returning the error, main() just
/// exits non-zero.
pub fn main(init: std.process.Init) void {
    run(init) catch std.process.exit(1);
}

fn run(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len < 2) {
        eprint(io, "usage: webcli <url>\n");
        return error.MissingUrl;
    }
    // Bare host like "example.com" → assume https.
    const current: []const u8 = if (std.mem.indexOf(u8, argv[1], "://") == null)
        try std.fmt.allocPrint(arena, "https://{s}", .{argv[1]})
    else
        try arena.dupe(u8, argv[1]);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const term = terminalSize(io, std.Io.File.stdout());

    // Per-page scratch for layout+render output; reset on every repaint so
    // re-laying-out after an edit doesn't accumulate. Page data the loop keeps
    // (urls, edited values) lives in the session arena / doc arena instead.
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    var history: std.ArrayList(Nav) = .empty;
    defer history.deinit(gpa);
    var nav: Nav = .{ .url = current };

    // Outer loop = one network load per page. Inner loop = interaction on that
    // loaded doc (scrolling/editing re-render without refetching).
    page_loop: while (true) {
        var body: std.Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        const status = fetch(io, &client, nav, &body) catch return;

        var doc = try html.parse(gpa, body.writer.buffered());
        defer doc.deinit();
        try cascade.apply(doc.alloc(), &doc);
        try forms.init(doc.alloc(), doc.root);

        if (!term.tty) {
            // piped: one-shot dump (plays nice with | head, redirects, etc.)
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
            const bar = std.fmt.bufPrint(&b, " webcli [{d}] {s}  ({d} links, {d} fields)  f follow · i field · H back · q quit", .{ status, doc.title, pg.links.len, pg.fields.len }) catch " webcli";

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

/// A pending navigation: where to go and how. GET has no body; POST carries the
/// urlencoded form payload.
const Nav = struct {
    url: []const u8,
    method: std.http.Method = .GET,
    body: ?[]const u8 = null,
};

const Term = struct { cols: u16, rows: u16, tty: bool };

/// Perform the request into `body`, returning the HTTP status. Prints a friendly
/// message (no stack trace) and returns the error on failure.
fn fetch(io: std.Io, client: *std.http.Client, nav: Nav, body: *std.Io.Writer.Allocating) !u16 {
    var hdrs: [3]std.http.Header = .{
        .{ .name = "user-agent", .value = "webcli/0.0 (+terminal)" },
        .{ .name = "accept", .value = "text/html" },
        undefined,
    };
    var n: usize = 2;
    if (nav.method == .POST) {
        hdrs[2] = .{ .name = "content-type", .value = "application/x-www-form-urlencoded" };
        n = 3;
    }
    const res = client.fetch(.{
        .location = .{ .url = nav.url },
        .method = nav.method,
        .payload = nav.body,
        .response_writer = &body.writer,
        .extra_headers = hdrs[0..n],
    }) catch |err| {
        var buf: [256]u8 = undefined;
        eprint(io, std.fmt.bufPrint(&buf, "fetch failed: {t}\n", .{err}) catch "fetch failed\n");
        if (err == error.TlsInitializationFailed)
            eprint(io, "  (TLS handshake unsupported for this site — known std.crypto.tls gap)\n");
        return err;
    };
    return @intFromEnum(res.status);
}

/// Turn an activated submit button into the next navigation: resolve the form's
/// action, encode its controls, and choose GET (query string) or POST (body).
fn buildSubmit(arena: std.mem.Allocator, base: []const u8, submit: *@import("dom/node.zig").Node) !Nav {
    const form = forms.formFor(submit) orelse return .{ .url = base };
    const action = try resolveUrl(arena, base, form.attr("action") orelse "");
    const encoded = try forms.encode(arena, form, submit);
    if (forms.method(form) == .post)
        return .{ .url = action, .method = .POST, .body = encoded };
    // GET: replace any existing query with the encoded controls
    const path = action[0 .. std.mem.indexOfScalar(u8, action, '?') orelse action.len];
    return .{ .url = try std.fmt.allocPrint(arena, "{s}?{s}", .{ path, encoded }) };
}

/// Resolve a possibly-relative href against the current page URL. Handles
/// absolute, scheme-relative (//), root-relative (/), fragment (#), and
/// directory-relative forms. Does not collapse "../" yet.
fn resolveUrl(arena: std.mem.Allocator, base: []const u8, href: []const u8) ![]const u8 {
    if (href.len == 0 or href[0] == '#') return base; // same page
    if (std.mem.indexOf(u8, href, "://") != null) return arena.dupe(u8, href);

    const scheme_sep = std.mem.indexOf(u8, base, "://") orelse return arena.dupe(u8, href);
    if (std.mem.startsWith(u8, href, "//"))
        return std.fmt.allocPrint(arena, "{s}:{s}", .{ base[0..scheme_sep], href });

    const auth_start = scheme_sep + 3;
    const auth_end = std.mem.indexOfAnyPos(u8, base, auth_start, "/?#") orelse base.len;
    const origin = base[0..auth_end]; // scheme://host[:port]
    if (href[0] == '/') return std.fmt.allocPrint(arena, "{s}{s}", .{ origin, href });

    // directory-relative: base path up to and including its last '/'
    const last_slash = std.mem.lastIndexOfScalar(u8, base[auth_end..], '/');
    const dir = if (last_slash) |i| base[0 .. auth_end + i + 1] else null;
    if (dir) |d| return std.fmt.allocPrint(arena, "{s}{s}", .{ d, href });
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ origin, href });
}

fn eprint(io: std.Io, msg: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

/// Query the terminal size via TIOCGWINSZ. Success also tells us stdout is a
/// real terminal, so we gate ANSI + the interactive viewer on it: piping to a
/// file/pipe falls back to an 80-column plain-text dump (DESIGN.md: degrade).
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
    // no path in base → join with a slash
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
}
