const std = @import("std");

pub const Combinator = enum { descendant, child };

pub const Compound = struct {
    tag: []const u8 = "",
    id: []const u8 = "",
    classes: []const []const u8 = &.{},
    combinator: Combinator = .descendant,
};

pub const Selector = struct {
    compounds: []Compound,

    pub fn specificity(self: Selector) u32 {
        var ids: u32 = 0;
        var classes: u32 = 0;
        var tags: u32 = 0;
        for (self.compounds) |c| {
            if (c.id.len > 0) ids += 1;
            classes += @intCast(c.classes.len);
            if (c.tag.len > 0 and !std.mem.eql(u8, c.tag, "*")) tags += 1;
        }
        const i: u32 = @min(ids, 255);
        const c: u32 = @min(classes, 255);
        const t: u32 = @min(tags, 255);
        return (i << 16) | (c << 8) | t;
    }
};

pub const Declaration = struct {
    name: []const u8,
    value: []const u8,
};

pub const Rule = struct {
    selectors: []Selector,
    decls: []Declaration,
};

pub const Stylesheet = struct {
    rules: []Rule,
};

pub fn parse(a: std.mem.Allocator, src: []const u8) !Stylesheet {
    var p = Parser{ .a = a, .src = src };
    var rules: std.ArrayList(Rule) = .empty;
    while (p.pos < p.src.len) {
        p.skipTrivia();
        if (p.pos >= p.src.len) break;
        if (p.src[p.pos] == '@') {
            p.skipAtRule();
            continue;
        }
        if (try p.rule()) |r| try rules.append(a, r);
    }
    return .{ .rules = try rules.toOwnedSlice(a) };
}

const Parser = struct {
    a: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,

    fn rule(self: *Parser) !?Rule {
        const sel_start = self.pos;
        while (self.pos < self.src.len and self.src[self.pos] != '{') {
            if (self.src[self.pos] == '}') return null;
            self.advancePastComments();
            if (self.pos < self.src.len and self.src[self.pos] != '{') self.pos += 1;
        }
        if (self.pos >= self.src.len) return null;
        const sel_text = self.src[sel_start..self.pos];
        self.pos += 1;

        const decls = try self.declarations();
        const selectors = try self.selectorList(sel_text);
        if (selectors.len == 0) return null;
        return .{ .selectors = selectors, .decls = decls };
    }

    fn declarations(self: *Parser) ![]Declaration {
        var out: std.ArrayList(Declaration) = .empty;
        while (self.pos < self.src.len and self.src[self.pos] != '}') {
            self.skipTrivia();
            if (self.pos >= self.src.len or self.src[self.pos] == '}') break;
            const name_start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != ':' and
                self.src[self.pos] != ';' and self.src[self.pos] != '}') self.pos += 1;
            if (self.pos >= self.src.len or self.src[self.pos] != ':') {
                while (self.pos < self.src.len and self.src[self.pos] != ';' and
                    self.src[self.pos] != '}') self.pos += 1;
                if (self.pos < self.src.len and self.src[self.pos] == ';') self.pos += 1;
                continue;
            }
            const name = std.mem.trim(u8, self.src[name_start..self.pos], " \t\r\n");
            self.pos += 1;
            const val_start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != ';' and
                self.src[self.pos] != '}') self.pos += 1;
            const value = std.mem.trim(u8, self.src[val_start..self.pos], " \t\r\n");
            if (self.pos < self.src.len and self.src[self.pos] == ';') self.pos += 1;
            if (name.len > 0) try out.append(self.a, .{ .name = lower(self.a, name), .value = value });
        }
        if (self.pos < self.src.len and self.src[self.pos] == '}') self.pos += 1;
        return out.toOwnedSlice(self.a);
    }

    fn selectorList(self: *Parser, text: []const u8) ![]Selector {
        var out: std.ArrayList(Selector) = .empty;
        var it = std.mem.splitScalar(u8, text, ',');
        while (it.next()) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len == 0) continue;
            if (try self.selector(trimmed)) |s| try out.append(self.a, s);
        }
        return out.toOwnedSlice(self.a);
    }

    fn selector(self: *Parser, text: []const u8) !?Selector {
        var compounds: std.ArrayList(Compound) = .empty;
        var i: usize = 0;
        var next_combinator: Combinator = .descendant;
        while (i < text.len) {
            while (i < text.len and isWs(text[i])) i += 1;
            if (i >= text.len) break;
            if (text[i] == '>') {
                next_combinator = .child;
                i += 1;
                continue;
            }
            const tok_start = i;
            while (i < text.len and !isWs(text[i]) and text[i] != '>') i += 1;
            const tok = text[tok_start..i];
            if (tok.len == 0) continue;
            const c = try self.compound(tok, next_combinator);
            try compounds.append(self.a, c);
            next_combinator = .descendant;
        }
        if (compounds.items.len == 0) return null;
        return .{ .compounds = try compounds.toOwnedSlice(self.a) };
    }

    fn compound(self: *Parser, tok: []const u8, comb: Combinator) !Compound {
        var c = Compound{ .combinator = comb };
        var classes: std.ArrayList([]const u8) = .empty;
        var i: usize = 0;
        if (tok[0] != '.' and tok[0] != '#') {
            const start = i;
            while (i < tok.len and tok[i] != '.' and tok[i] != '#') i += 1;
            c.tag = lower(self.a, tok[start..i]);
        }
        while (i < tok.len) {
            const kind = tok[i];
            i += 1;
            const start = i;
            while (i < tok.len and tok[i] != '.' and tok[i] != '#') i += 1;
            const name = tok[start..i];
            if (name.len == 0) continue;
            if (kind == '.') {
                try classes.append(self.a, name);
            } else if (kind == '#') {
                c.id = name;
            }
        }
        c.classes = try classes.toOwnedSlice(self.a);
        return c;
    }

    fn skipTrivia(self: *Parser) void {
        while (self.pos < self.src.len) {
            if (isWs(self.src[self.pos])) {
                self.pos += 1;
            } else if (self.startsAt("/*")) {
                self.skipComment();
            } else break;
        }
    }

    fn advancePastComments(self: *Parser) void {
        if (self.startsAt("/*")) self.skipComment();
    }

    fn skipComment(self: *Parser) void {
        self.pos += 2;
        const end = std.mem.indexOfPos(u8, self.src, self.pos, "*/") orelse self.src.len;
        self.pos = if (end < self.src.len) end + 2 else self.src.len;
    }

    fn skipAtRule(self: *Parser) void {
        while (self.pos < self.src.len and self.src[self.pos] != ';' and self.src[self.pos] != '{') self.pos += 1;
        if (self.pos >= self.src.len) return;
        if (self.src[self.pos] == ';') {
            self.pos += 1;
            return;
        }
        var depth: usize = 0;
        while (self.pos < self.src.len) {
            const ch = self.src[self.pos];
            if (ch == '{') depth += 1;
            if (ch == '}') {
                depth -= 1;
                self.pos += 1;
                if (depth == 0) return;
                continue;
            }
            self.pos += 1;
        }
    }

    fn startsAt(self: *Parser, s: []const u8) bool {
        return self.pos + s.len <= self.src.len and std.mem.eql(u8, self.src[self.pos .. self.pos + s.len], s);
    }
};

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}

fn lower(a: std.mem.Allocator, s: []const u8) []const u8 {
    const out = a.alloc(u8, s.len) catch return s;
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

test "parse a simple rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ss = try parse(arena.allocator(), "p { color: red; margin: 0 }");
    try std.testing.expectEqual(@as(usize, 1), ss.rules.len);
    const r = ss.rules[0];
    try std.testing.expectEqual(@as(usize, 1), r.selectors.len);
    try std.testing.expectEqualStrings("p", r.selectors[0].compounds[0].tag);
    try std.testing.expectEqual(@as(usize, 2), r.decls.len);
    try std.testing.expectEqualStrings("color", r.decls[0].name);
    try std.testing.expectEqualStrings("red", r.decls[0].value);
    try std.testing.expectEqualStrings("margin", r.decls[1].name);
    try std.testing.expectEqualStrings("0", r.decls[1].value);
}

test "selector groups, classes, ids, descendant + specificity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ss = try parse(arena.allocator(), "a.x, div#main p.y.z { display: none }");
    const r = ss.rules[0];
    try std.testing.expectEqual(@as(usize, 2), r.selectors.len);

    const s0 = r.selectors[0];
    try std.testing.expectEqual(@as(usize, 1), s0.compounds.len);
    try std.testing.expectEqualStrings("a", s0.compounds[0].tag);
    try std.testing.expectEqualStrings("x", s0.compounds[0].classes[0]);
    try std.testing.expectEqual(@as(u32, (0 << 16) | (1 << 8) | 1), s0.specificity());

    const s1 = r.selectors[1];
    try std.testing.expectEqual(@as(usize, 2), s1.compounds.len);
    try std.testing.expectEqualStrings("div", s1.compounds[0].tag);
    try std.testing.expectEqualStrings("main", s1.compounds[0].id);
    try std.testing.expectEqualStrings("p", s1.compounds[1].tag);
    try std.testing.expectEqual(@as(usize, 2), s1.compounds[1].classes.len);
    try std.testing.expectEqual(@as(u32, (1 << 16) | (2 << 8) | 2), s1.specificity());
}

test "comments and at-rules are skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ss = try parse(arena.allocator(),
        \\/* hi */ @media screen { p { color: blue } }
        \\@import "x.css";
        \\b { font-weight: bold }
    );
    try std.testing.expectEqual(@as(usize, 1), ss.rules.len);
    try std.testing.expectEqualStrings("b", ss.rules[0].selectors[0].compounds[0].tag);
}

test "child combinator parsed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ss = try parse(arena.allocator(), "ul > li { display: list-item }");
    const s = ss.rules[0].selectors[0];
    try std.testing.expectEqual(@as(usize, 2), s.compounds.len);
    try std.testing.expectEqual(Combinator.child, s.compounds[1].combinator);
}
