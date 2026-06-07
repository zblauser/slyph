const std = @import("std");

pub const Attr = struct { name: []const u8, value: []const u8 };

pub const Token = union(enum) {
    text: []const u8,
    start_tag: StartTag,
    end_tag: []const u8,
    comment: []const u8,
    doctype,

    pub const StartTag = struct {
        name: []const u8,
        attrs: []Attr,
        self_closing: bool,
    };
};

pub const Tokenizer = struct {
    src: []const u8,
    pos: usize = 0,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, src: []const u8) Tokenizer {
        return .{ .src = src, .alloc = alloc };
    }

    pub fn next(self: *Tokenizer) !?Token {
        if (self.pos >= self.src.len) return null;

        if (self.src[self.pos] == '<') {
            if (self.peekAt(1)) |c1| {
                if (c1 == '!') return try self.markupDeclaration();
                if (c1 == '/') return try self.endTag();
                if (std.ascii.isAlphabetic(c1)) return try self.startTag();
            }
            return self.textRun();
        }
        return self.textRun();
    }

    fn peekAt(self: *Tokenizer, off: usize) ?u8 {
        const i = self.pos + off;
        return if (i < self.src.len) self.src[i] else null;
    }

    fn textRun(self: *Tokenizer) Token {
        const start = self.pos;
        if (self.src[self.pos] == '<') self.pos += 1;
        while (self.pos < self.src.len and self.src[self.pos] != '<') self.pos += 1;
        return .{ .text = self.src[start..self.pos] };
    }

    fn markupDeclaration(self: *Tokenizer) !Token {
        if (self.startsWithAt(self.pos + 2, "--")) {
            const start = self.pos + 4;
            const close = std.mem.indexOfPos(u8, self.src, start, "-->") orelse self.src.len;
            const body = self.src[start..@min(close, self.src.len)];
            self.pos = if (close < self.src.len) close + 3 else self.src.len;
            return .{ .comment = body };
        }
        self.skipTo('>');
        return .doctype;
    }

    fn endTag(self: *Tokenizer) !Token {
        self.pos += 2;
        const name = self.readName();
        self.skipTo('>');
        return .{ .end_tag = name };
    }

    fn startTag(self: *Tokenizer) !Token {
        self.pos += 1;
        const name = self.readName();

        var attrs: std.ArrayList(Attr) = .empty;
        var self_closing = false;

        while (self.pos < self.src.len) {
            self.skipWhitespace();
            const c = self.src[self.pos];
            if (c == '>') {
                self.pos += 1;
                break;
            }
            if (c == '/') {
                self_closing = true;
                self.pos += 1;
                continue;
            }
            const an_start = self.pos;
            while (self.pos < self.src.len and !isAttrNameEnd(self.src[self.pos])) self.pos += 1;
            const aname = self.src[an_start..self.pos];
            if (aname.len == 0) {
                self.pos += 1;
                continue;
            }
            var avalue: []const u8 = "";
            self.skipWhitespace();
            if (self.pos < self.src.len and self.src[self.pos] == '=') {
                self.pos += 1;
                self.skipWhitespace();
                avalue = self.readAttrValue();
            }
            try attrs.append(self.alloc, .{ .name = lower(self.alloc, aname), .value = avalue });
        }

        const lname = lower(self.alloc, name);
        return .{ .start_tag = .{ .name = lname, .attrs = try attrs.toOwnedSlice(self.alloc), .self_closing = self_closing } };
    }

    pub fn rawTextUntil(self: *Tokenizer, name: []const u8) []const u8 {
        const start = self.pos;
        var i = self.pos;
        while (i < self.src.len) {
            if (self.src[i] == '<' and i + 1 < self.src.len and self.src[i + 1] == '/') {
                const n = i + 2;
                if (n + name.len <= self.src.len and
                    std.ascii.eqlIgnoreCase(self.src[n .. n + name.len], name))
                {
                    self.pos = i;
                    return self.src[start..i];
                }
            }
            i += 1;
        }
        self.pos = self.src.len;
        return self.src[start..];
    }

    fn readName(self: *Tokenizer) []const u8 {
        const start = self.pos;
        while (self.pos < self.src.len and isNameChar(self.src[self.pos])) self.pos += 1;
        return self.src[start..self.pos];
    }

    fn readAttrValue(self: *Tokenizer) []const u8 {
        if (self.pos >= self.src.len) return "";
        const q = self.src[self.pos];
        if (q == '"' or q == '\'') {
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != q) self.pos += 1;
            const v = self.src[start..self.pos];
            if (self.pos < self.src.len) self.pos += 1;
            return v;
        }
        const start = self.pos;
        while (self.pos < self.src.len and !isUnquotedValueEnd(self.src[self.pos])) self.pos += 1;
        return self.src[start..self.pos];
    }

    fn skipWhitespace(self: *Tokenizer) void {
        while (self.pos < self.src.len and isWs(self.src[self.pos])) self.pos += 1;
    }

    fn skipTo(self: *Tokenizer, ch: u8) void {
        while (self.pos < self.src.len and self.src[self.pos] != ch) self.pos += 1;
        if (self.pos < self.src.len) self.pos += 1;
    }

    fn startsWithAt(self: *Tokenizer, i: usize, s: []const u8) bool {
        return i + s.len <= self.src.len and std.mem.eql(u8, self.src[i .. i + s.len], s);
    }
};

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}
fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == ':' or c == '_';
}
fn isAttrNameEnd(c: u8) bool {
    return isWs(c) or c == '=' or c == '>' or c == '/';
}
fn isUnquotedValueEnd(c: u8) bool {
    return isWs(c) or c == '>';
}

pub fn isRawText(name: []const u8) bool {
    const set = [_][]const u8{ "script", "style", "title", "textarea" };
    for (set) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

fn lower(alloc: std.mem.Allocator, s: []const u8) []const u8 {
    const out = alloc.alloc(u8, s.len) catch return s;
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

test "tokenize tags, attrs, text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = Tokenizer.init(arena.allocator(), "<p class=\"x\" id=a>hi</p>");

    const t0 = (try t.next()).?;
    try std.testing.expect(t0 == .start_tag);
    try std.testing.expectEqualStrings("p", t0.start_tag.name);
    try std.testing.expectEqual(@as(usize, 2), t0.start_tag.attrs.len);
    try std.testing.expectEqualStrings("class", t0.start_tag.attrs[0].name);
    try std.testing.expectEqualStrings("x", t0.start_tag.attrs[0].value);
    try std.testing.expectEqualStrings("a", t0.start_tag.attrs[1].value);

    const t1 = (try t.next()).?;
    try std.testing.expectEqualStrings("hi", t1.text);
    const t2 = (try t.next()).?;
    try std.testing.expect(t2 == .end_tag);
    try std.testing.expectEqualStrings("p", t2.end_tag);
    try std.testing.expect((try t.next()) == null);
}

test "raw text body with '<' stays intact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var t = Tokenizer.init(arena.allocator(), "<script>if (a<b) x;</script>");
    const st = (try t.next()).?;
    try std.testing.expectEqualStrings("script", st.start_tag.name);
    const body = t.rawTextUntil("script");
    try std.testing.expectEqualStrings("if (a<b) x;", body);
    const et = (try t.next()).?;
    try std.testing.expectEqualStrings("script", et.end_tag);
}
