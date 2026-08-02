const std = @import("std");
const dom = @import("../dom/node.zig");
const style = @import("../css/style.zig");
const boxmod = @import("box.zig");
const forms = @import("../forms/forms.zig");

const Box = boxmod.Box;
const Rect = boxmod.Rect;
const ComputedStyle = style.ComputedStyle;

pub const Field = struct {
    node: *dom.Node,
    kind: forms.Kind,
};

const Word = struct {
    text: []const u8 = "",
    cs: *const ComputedStyle,
    forced_break: bool = false,
    link: u16 = 0,
};

const Ctx = struct {
    a: std.mem.Allocator,
    width: u16,
    links: *std.ArrayList([]const u8),
    fields: *std.ArrayList(Field),
    budget: *u32,
};

const measure_budget = 20000;
const max_content_width = 4096;
const gutter = 1;

pub const Page = struct {
    root: Box,
    links: []const []const u8,
    fields: []const Field,
};

pub fn layout(a: std.mem.Allocator, doc: *dom.Document, width: u16) !Page {
    var links: std.ArrayList([]const u8) = .empty;
    var fields: std.ArrayList(Field) = .empty;
    var budget: u32 = measure_budget;
    var ctx = Ctx{ .a = a, .width = @max(width, 1), .links = &links, .fields = &fields, .budget = &budget };
    var children: std.ArrayList(Box) = .empty;
    const end_y = try layoutContainer(&ctx, doc.root, 0, ctx.width, 0, null, &children);
    return .{
        .root = .{
            .kind = .block,
            .rect = .{ .x = 0, .y = 0, .w = ctx.width, .h = end_y },
            .node = doc.root,
            .children = try children.toOwnedSlice(a),
        },
        .links = try links.toOwnedSlice(a),
        .fields = try fields.toOwnedSlice(a),
    };
}

fn layoutContainer(
    ctx: *Ctx,
    node: *dom.Node,
    x: u16,
    avail_w: u16,
    start_y: u16,
    marker: ?Marker,
    out: *std.ArrayList(Box),
) !u16 {
    var y = start_y;
    var pending: std.ArrayList(Word) = .empty;
    defer pending.deinit(ctx.a);
    var seen_content = false;
    var prev_margin_bottom: u16 = 0;
    var list_index: u16 = 0;

    if (marker) |m| try pending.append(ctx.a, .{ .text = m.text, .cs = m.cs });

    var child = node.first_child;
    while (child) |c| : (child = c.next_sibling) {
        const cs = c.computed;
        const raw_disp = if (cs) |s| s.display else .inline_;
        if (raw_disp == .none) continue;
        const disp: style.Display = if (raw_disp.isBlockLevel() or !hasBlockLevelDescendant(c)) raw_disp else .block;

        if (disp.isBlockLevel()) {
            if (pending.items.len > 0) {
                y = try wrapWords(ctx, pending.items, x, avail_w, y, out);
                pending.clearRetainingCapacity();
                prev_margin_bottom = 0;
                seen_content = true;
            }
            const mt: u16 = if (cs) |s| s.margin_top else 0;
            if (seen_content) y += @max(prev_margin_bottom, mt);
            if (disp == .list_item) list_index += 1;
            const child_marker: ?Marker = if (disp == .list_item and cs != null)
                .{ .text = try markerText(ctx, node, list_index), .cs = cs.? }
            else
                null;
            const ind: u16 = if (cs) |s| s.indent else 0;
            const cx = x + ind;
            const cw = if (avail_w > ind) avail_w - ind else 1;
            const blk = try layoutBlock(ctx, c, cx, cw, y, child_marker);
            try out.append(ctx.a, blk);
            y = blk.rect.y + blk.rect.h;
            prev_margin_bottom = if (cs) |s| s.margin_bottom else 0;
            seen_content = true;
        } else {
            collectInline(ctx, c, 0, &pending) catch {};
        }
    }
    if (pending.items.len > 0) {
        y = try wrapWords(ctx, pending.items, x, avail_w, y, out);
    }
    return y;
}

const Marker = struct { text: []const u8, cs: *const ComputedStyle };

fn markerText(ctx: *Ctx, parent: *dom.Node, index: u16) ![]const u8 {
    if (parent.kind == .element and std.mem.eql(u8, parent.tag, "ol"))
        return std.fmt.allocPrint(ctx.a, "{d}.", .{index + startOf(parent) - 1});
    return "\u{2022}";
}

fn startOf(list: *dom.Node) u16 {
    const raw = list.attr("start") orelse return 1;
    return std.fmt.parseInt(u16, std.mem.trim(u8, raw, " \t"), 10) catch 1;
}

fn layoutRule(ctx: *Ctx, node: *dom.Node, x: u16, avail_w: u16, y: u16, out: *std.ArrayList(Box)) !u16 {
    const w = @max(avail_w, 1);
    var text: std.ArrayList(u8) = .empty;
    var i: u16 = 0;
    while (i < w) : (i += 1) try text.appendSlice(ctx.a, "\u{2500}");

    var kids: std.ArrayList(Box) = .empty;
    try kids.append(ctx.a, .{
        .kind = .text,
        .rect = .{ .x = x, .y = y, .w = w, .h = 1 },
        .style = node.computed,
        .text = try text.toOwnedSlice(ctx.a),
    });
    try out.append(ctx.a, .{
        .kind = .line,
        .rect = .{ .x = x, .y = y, .w = w, .h = 1 },
        .node = node,
        .children = try kids.toOwnedSlice(ctx.a),
    });
    return y + 1;
}

fn hasBlockLevelDescendant(node: *dom.Node) bool {
    if (node.kind != .element) return false;
    var child = node.first_child;
    while (child) |c| : (child = c.next_sibling) {
        if (c.kind != .element) continue;
        const cs = c.computed orelse continue;
        if (cs.display == .none) continue;
        if (cs.display.isBlockLevel()) return true;
        if (hasBlockLevelDescendant(c)) return true;
    }
    return false;
}

fn layoutBlock(ctx: *Ctx, node: *dom.Node, x: u16, avail_w: u16, y: u16, marker: ?Marker) std.mem.Allocator.Error!Box {
    var children: std.ArrayList(Box) = .empty;
    const cs = node.computed;

    var end_y: u16 = undefined;
    if (node.kind == .element and std.mem.eql(u8, node.tag, "hr")) {
        end_y = try layoutRule(ctx, node, x, avail_w, y, &children);
    } else if (cs != null and cs.?.display == .table) {
        end_y = try layoutTable(ctx, node, x, avail_w, y, &children);
    } else if (cs != null and cs.?.white_space == .pre) {
        end_y = try layoutPre(ctx, node, x, avail_w, y, &children);
    } else {
        end_y = try layoutContainer(ctx, node, x, avail_w, y, marker, &children);
    }
    return .{
        .kind = .block,
        .rect = .{ .x = x, .y = y, .w = avail_w, .h = end_y - y },
        .node = node,
        .style = cs,
        .children = try children.toOwnedSlice(ctx.a),
    };
}

const Cell = struct {
    node: *dom.Node,
    col: u16,
    span: u16,
    min: u16 = 0,
    max: u16 = 0,
};

fn layoutTable(ctx: *Ctx, node: *dom.Node, x: u16, avail_w: u16, start_y: u16, out: *std.ArrayList(Box)) std.mem.Allocator.Error!u16 {
    var rows: std.ArrayList(*dom.Node) = .empty;
    defer rows.deinit(ctx.a);
    try collectRows(ctx.a, node, &rows);

    var grid: std.ArrayList([]Cell) = .empty;
    defer grid.deinit(ctx.a);
    var ncols: u16 = 0;
    var held: std.ArrayList(u16) = .empty;
    defer held.deinit(ctx.a);
    for (rows.items) |tr| {
        var cells: std.ArrayList(Cell) = .empty;
        var child = tr.first_child;
        var col: u16 = 0;
        while (child) |c| : (child = c.next_sibling) {
            const cs = c.computed orelse continue;
            if (cs.display != .table_cell) continue;
            while (col < held.items.len and held.items[col] > 0) col += 1;
            const span = spanOf(c, "colspan");
            const rows_held = spanOf(c, "rowspan");
            if (rows_held > 1) {
                try growTo(ctx.a, &held, col + span);
                for (held.items[col .. col + span]) |*h| h.* = @max(h.*, rows_held);
            }
            try cells.append(ctx.a, .{ .node = c, .col = col, .span = span });
            col += span;
        }
        ncols = @max(ncols, @max(col, @as(u16, @intCast(held.items.len))));
        for (held.items) |*h| {
            if (h.* > 0) h.* -= 1;
        }
        try grid.append(ctx.a, try cells.toOwnedSlice(ctx.a));
    }
    if (ncols == 0) return layoutContainer(ctx, node, x, avail_w, start_y, null, out);

    var y = try layoutTableCaptions(ctx, node, x, avail_w, start_y, out);

    const col_min = try ctx.a.alloc(u16, ncols);
    const col_max = try ctx.a.alloc(u16, ncols);
    @memset(col_min, 0);
    @memset(col_max, 0);

    for (grid.items) |cells| {
        for (cells) |*cell| {
            cell.min = try measureCell(ctx, cell.node, 1);
            cell.max = try measureCell(ctx, cell.node, max_content_width);
            if (cell.span == 1) {
                col_min[cell.col] = @max(col_min[cell.col], cell.min);
                col_max[cell.col] = @max(col_max[cell.col], cell.max);
            }
        }
    }
    for (grid.items) |cells| {
        for (cells) |cell| {
            if (cell.span == 1) continue;
            spread(col_min, cell.col, cell.span, cell.min);
            spread(col_max, cell.col, cell.span, cell.max);
        }
    }

    const widths = try ctx.a.alloc(u16, ncols);
    distribute(col_min, col_max, avail_w, widths);

    for (rows.items, grid.items) |tr, cells| {
        var row_kids: std.ArrayList(Box) = .empty;
        var row_end = y;
        for (cells) |cell| {
            const cx = x + colOffset(widths, cell.col);
            const cw = spanWidth(widths, cell.col, cell.span);
            var kids: std.ArrayList(Box) = .empty;
            const cell_end = try layoutContainer(ctx, cell.node, cx, cw, y, null, &kids);
            try row_kids.append(ctx.a, .{
                .kind = .block,
                .rect = .{ .x = cx, .y = y, .w = cw, .h = cell_end - y },
                .node = cell.node,
                .style = cell.node.computed,
                .children = try kids.toOwnedSlice(ctx.a),
            });
            row_end = @max(row_end, cell_end);
        }
        try out.append(ctx.a, .{
            .kind = .block,
            .rect = .{ .x = x, .y = y, .w = avail_w, .h = row_end - y },
            .node = tr,
            .style = tr.computed,
            .children = try row_kids.toOwnedSlice(ctx.a),
        });
        y = row_end;
    }
    return y;
}

fn layoutTableCaptions(ctx: *Ctx, node: *dom.Node, x: u16, avail_w: u16, start_y: u16, out: *std.ArrayList(Box)) std.mem.Allocator.Error!u16 {
    var y = start_y;
    var child = node.first_child;
    while (child) |c| : (child = c.next_sibling) {
        const cs = c.computed orelse continue;
        switch (cs.display) {
            .block, .list_item, .table => {
                const blk = try layoutBlock(ctx, c, x, avail_w, y, null);
                try out.append(ctx.a, blk);
                y = blk.rect.y + blk.rect.h;
            },
            else => {},
        }
    }
    return y;
}

fn collectRows(a: std.mem.Allocator, node: *dom.Node, out: *std.ArrayList(*dom.Node)) std.mem.Allocator.Error!void {
    var child = node.first_child;
    while (child) |c| : (child = c.next_sibling) {
        const cs = c.computed orelse continue;
        switch (cs.display) {
            .table_row => try out.append(a, c),
            .table_row_group => try collectRows(a, c, out),
            else => {},
        }
    }
}

fn spanOf(cell: *dom.Node, attr: []const u8) u16 {
    const raw = cell.attr(attr) orelse return 1;
    const n = std.fmt.parseInt(u16, std.mem.trim(u8, raw, " \t"), 10) catch return 1;
    return std.math.clamp(n, 1, 64);
}

fn growTo(a: std.mem.Allocator, list: *std.ArrayList(u16), len: u16) !void {
    while (list.items.len < len) try list.append(a, 0);
}

fn spread(cols: []u16, col: u16, span: u16, want: u16) void {
    const end = @min(@as(usize, col) + span, cols.len);
    if (col >= cols.len) return;
    var have: u32 = @as(u32, @intCast(end - col - 1)) * gutter;
    for (cols[col..end]) |w| have += w;
    if (have >= want) return;
    const deficit: u32 = want - have;
    const n: u32 = @intCast(end - col);
    const each: u32 = deficit / n;
    var rem: u32 = deficit % n;
    for (cols[col..end]) |*w| {
        var add = each;
        if (rem > 0) {
            add += 1;
            rem -= 1;
        }
        w.* = @intCast(@min(@as(u32, w.*) + add, std.math.maxInt(u16)));
    }
}

fn distribute(mins: []const u16, maxs: []const u16, avail_w: u16, out: []u16) void {
    const n: u32 = @intCast(out.len);
    const gut: u32 = (n - 1) * gutter;
    const content: u32 = if (avail_w > gut + n) avail_w - gut else n;

    var sum_min: u32 = 0;
    var sum_max: u32 = 0;
    for (mins, maxs) |lo, hi| {
        sum_min += @max(lo, 1);
        sum_max += @max(hi, 1);
    }

    if (sum_max <= content) {
        for (out, maxs) |*w, hi| w.* = @max(hi, 1);
        return;
    }
    if (sum_min >= content) {
        for (out, mins) |*w, lo| w.* = @max(lo, 1);
        return;
    }
    const extra: u32 = content - sum_min;
    const range: u32 = sum_max - sum_min;
    for (out, mins, maxs) |*w, lo, hi| {
        const base: u32 = @max(lo, 1);
        const span: u32 = @max(hi, 1) - base;
        w.* = @intCast(base + extra * span / range);
    }
}

fn colOffset(widths: []const u16, col: u16) u16 {
    var off: u32 = @as(u32, col) * gutter;
    for (widths[0..@min(col, widths.len)]) |w| off += w;
    return @intCast(@min(off, std.math.maxInt(u16)));
}

fn spanWidth(widths: []const u16, col: u16, span: u16) u16 {
    const end = @min(@as(usize, col) + span, widths.len);
    if (col >= widths.len) return 1;
    var total: u32 = @as(u32, @intCast(end - col - 1)) * gutter;
    for (widths[col..end]) |w| total += w;
    return @intCast(@max(@min(total, std.math.maxInt(u16)), 1));
}

fn measureCell(ctx: *Ctx, node: *dom.Node, w: u16) std.mem.Allocator.Error!u16 {
    if (ctx.budget.* == 0) return estimateWidth(ctx.a, node, w);
    ctx.budget.* -= 1;

    var links: std.ArrayList([]const u8) = .empty;
    defer links.deinit(ctx.a);
    try links.appendSlice(ctx.a, ctx.links.items);
    var fields: std.ArrayList(Field) = .empty;
    defer fields.deinit(ctx.a);
    try fields.appendSlice(ctx.a, ctx.fields.items);

    var sub = Ctx{ .a = ctx.a, .width = w, .links = &links, .fields = &fields, .budget = ctx.budget };
    var kids: std.ArrayList(Box) = .empty;
    defer kids.deinit(ctx.a);
    _ = try layoutContainer(&sub, node, 0, w, 0, null, &kids);

    var widest: u16 = 0;
    for (kids.items) |k| widest = @max(widest, extent(k));
    return widest;
}

fn extent(box: Box) u16 {
    var widest: u16 = if (box.kind == .text) box.rect.x + box.rect.w else 0;
    for (box.children) |c| widest = @max(widest, extent(c));
    return widest;
}

fn estimateWidth(a: std.mem.Allocator, node: *dom.Node, w: u16) u16 {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    node.appendText(a, &text) catch return 1;
    if (w > 1) return @intCast(@min(boxmod.cellWidth(text.items), max_content_width));
    var widest: usize = 1;
    var it = std.mem.tokenizeAny(u8, text.items, " \t\r\n");
    while (it.next()) |word| widest = @max(widest, boxmod.cellWidth(word));
    return @intCast(widest);
}

fn layoutPre(ctx: *Ctx, node: *dom.Node, x: u16, avail_w: u16, start_y: u16, out: *std.ArrayList(Box)) !u16 {
    var text: std.ArrayList(u8) = .empty;
    node.appendText(ctx.a, &text) catch {};
    const cs = node.computed;

    var y = start_y;
    var it = std.mem.splitScalar(u8, text.items, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        var kids: std.ArrayList(Box) = .empty;
        const w: u16 = @intCast(@min(boxmod.cellWidth(line), avail_w));
        try kids.append(ctx.a, .{
            .kind = .text,
            .rect = .{ .x = x, .y = y, .w = w, .h = 1 },
            .style = cs,
            .text = line,
        });
        try out.append(ctx.a, .{
            .kind = .line,
            .rect = .{ .x = x, .y = y, .w = w, .h = 1 },
            .node = node,
            .children = try kids.toOwnedSlice(ctx.a),
        });
        y += 1;
    }
    return y;
}

fn collectInline(ctx: *Ctx, node: *dom.Node, link: u16, out: *std.ArrayList(Word)) !void {
    switch (node.kind) {
        .text => {
            const cs = node.computed orelse return;
            var it = std.mem.tokenizeAny(u8, node.text, " \t\r\n\x0c");
            while (it.next()) |word| try out.append(ctx.a, .{ .text = word, .cs = cs, .link = link });
        },
        .element => {
            const cs = node.computed;
            if (cs != null and cs.?.display == .none) return;
            if (std.mem.eql(u8, node.tag, "br")) {
                try out.append(ctx.a, .{ .cs = cs orelse return, .forced_break = true });
                return;
            }
            if (isControl(node.tag)) {
                try emitField(ctx, node, cs orelse return, out);
                return;
            }
            if (std.mem.eql(u8, node.tag, "img")) {
                try emitImage(ctx, node, cs orelse return, link, out);
                return;
            }
            var cur = link;
            if (std.mem.eql(u8, node.tag, "a")) {
                if (node.attr("href")) |href| {
                    try ctx.links.append(ctx.a, href);
                    cur = @intCast(ctx.links.items.len);
                    if (cs) |s| {
                        const hint = try std.fmt.allocPrint(ctx.a, "[{d}]", .{cur});
                        try out.append(ctx.a, .{ .text = hint, .cs = s, .link = cur });
                    }
                }
            }
            var child = node.first_child;
            while (child) |c| : (child = c.next_sibling) try collectInline(ctx, c, cur, out);
        },
        else => {},
    }
}

const px_per_cell = 8;
const max_spacer_cells = 20;

fn emitImage(ctx: *Ctx, node: *dom.Node, cs: *const ComputedStyle, link: u16, out: *std.ArrayList(Word)) !void {
    if (node.attr("alt")) |raw| {
        const alt = std.mem.trim(u8, raw, " \t\r\n");
        if (alt.len > 0) {
            var it = std.mem.tokenizeAny(u8, alt, " \t\r\n");
            while (it.next()) |word| try out.append(ctx.a, .{ .text = word, .cs = cs, .link = link });
            return;
        }
    } else if (node.attr("width") == null) {
        try out.append(ctx.a, .{ .text = "[img]", .cs = cs, .link = link });
        return;
    }

    const cells = spacerCells(node);
    if (cells == 0) return;
    const pad = try ctx.a.alloc(u8, cells);
    @memset(pad, ' ');
    try out.append(ctx.a, .{ .text = pad, .cs = cs, .link = link });
}

fn spacerCells(node: *dom.Node) usize {
    const raw = node.attr("width") orelse return 0;
    var end: usize = 0;
    while (end < raw.len and std.ascii.isDigit(raw[end])) end += 1;
    if (end == 0) return 0;
    const px = std.fmt.parseInt(u32, raw[0..end], 10) catch return 0;
    return @min(px / px_per_cell, max_spacer_cells);
}

fn isControl(tag: []const u8) bool {
    return std.mem.eql(u8, tag, "input") or std.mem.eql(u8, tag, "textarea") or
        std.mem.eql(u8, tag, "button");
}

fn emitField(ctx: *Ctx, node: *dom.Node, cs: *const ComputedStyle, out: *std.ArrayList(Word)) !void {
    const k = forms.kind(node);
    if (k == .hidden) return;
    try ctx.fields.append(ctx.a, .{ .node = node, .kind = k });
    const n = ctx.fields.items.len;
    const val = node.value orelse "";

    const text = switch (k) {
        .submit => blk: {
            const label = if (val.len > 0) val else "Submit";
            break :blk try std.fmt.allocPrint(ctx.a, "{{{d}}}[ {s} ]", .{ n, label });
        },
        .checkbox, .radio => try std.fmt.allocPrint(ctx.a, "{{{d}}}[{s}]", .{ n, if (forms.isChecked(node)) "x" else " " }),
        .password => blk: {
            var stars: std.ArrayList(u8) = .empty;
            try stars.appendNTimes(ctx.a, '*', boxmod.cellWidth(val));
            break :blk try fieldBox(ctx.a, n, stars.items, node);
        },
        else => try fieldBox(ctx.a, n, val, node),
    };
    try out.append(ctx.a, .{ .text = text, .cs = cs });
}

fn fieldBox(a: std.mem.Allocator, n: usize, val: []const u8, node: *dom.Node) ![]const u8 {
    const size: usize = if (node.attr("size")) |s| (std.fmt.parseInt(usize, s, 10) catch 20) else 20;
    const shown = @max(size, boxmod.cellWidth(val));
    var inner: std.ArrayList(u8) = .empty;
    try inner.appendSlice(a, val);
    try inner.appendNTimes(a, ' ', shown - boxmod.cellWidth(val));
    return std.fmt.allocPrint(a, "{{{d}}}[{s}]", .{ n, inner.items });
}

fn wrapWords(ctx: *Ctx, words: []const Word, x: u16, avail_w: u16, start_y: u16, out: *std.ArrayList(Box)) !u16 {
    var y = start_y;
    var line: std.ArrayList(Box) = .empty;
    defer line.deinit(ctx.a);
    var cur_x = x;

    for (words) |w| {
        if (w.forced_break) {
            if (line.items.len > 0) {
                try emitLine(ctx, &line, x, cur_x, y, out);
                y += 1;
                cur_x = x;
            } else {
                y += 1;
            }
            continue;
        }
        const ww: u16 = @intCast(boxmod.cellWidth(w.text));
        const space: u16 = if (line.items.len > 0) 1 else 0;
        if (line.items.len > 0 and (cur_x - x) + space + ww > avail_w) {
            try emitLine(ctx, &line, x, cur_x, y, out);
            y += 1;
            cur_x = x;
        }
        if (line.items.len > 0) cur_x += 1;
        try line.append(ctx.a, .{
            .kind = .text,
            .rect = .{ .x = cur_x, .y = y, .w = ww, .h = 1 },
            .style = w.cs,
            .text = w.text,
            .link = w.link,
        });
        cur_x += ww;
    }
    if (line.items.len > 0) {
        try emitLine(ctx, &line, x, cur_x, y, out);
        y += 1;
    }
    return y;
}

fn emitLine(ctx: *Ctx, line: *std.ArrayList(Box), x: u16, cur_x: u16, y: u16, out: *std.ArrayList(Box)) !void {
    try out.append(ctx.a, .{
        .kind = .line,
        .rect = .{ .x = x, .y = y, .w = cur_x - x, .h = 1 },
        .children = try line.toOwnedSlice(ctx.a),
    });
}

const testing = std.testing;
const html = @import("../html/parser.zig");
const cascade = @import("../css/cascade.zig");

fn styledDoc(src: []const u8) !dom.Document {
    var doc = try html.parse(testing.allocator, src);
    errdefer doc.deinit();
    try cascade.apply(doc.alloc(), &doc, "", null, &.{});
    return doc;
}

fn collectText(box: Box, out: *std.ArrayList(Box)) !void {
    if (box.kind == .text) try out.append(testing.allocator, box);
    for (box.children) |c| try collectText(c, out);
}

test "inline text wraps at width" {
    var doc = try styledDoc("<body><p>aaa bbb ccc ddd</p></body>");
    defer doc.deinit();
    const root = (try layout(doc.alloc(), &doc, 7)).root;
    var runs: std.ArrayList(Box) = .empty;
    defer runs.deinit(testing.allocator);
    try collectText(root, &runs);
    try testing.expectEqual(@as(usize, 4), runs.items.len);
    try testing.expectEqual(@as(u16, 0), runs.items[0].rect.y);
    try testing.expectEqual(@as(u16, 0), runs.items[1].rect.y);
    try testing.expectEqual(@as(u16, 1), runs.items[2].rect.y);
    try testing.expectEqualStrings("ccc", runs.items[2].text);
    try testing.expectEqual(@as(u16, 0), runs.items[2].rect.x);
}

test "blocks stack with collapsing margins" {
    var doc = try styledDoc("<body><p>one</p><p>two</p></body>");
    defer doc.deinit();
    const root = (try layout(doc.alloc(), &doc, 80)).root;
    var runs: std.ArrayList(Box) = .empty;
    defer runs.deinit(testing.allocator);
    try collectText(root, &runs);
    try testing.expectEqual(@as(usize, 2), runs.items.len);
    try testing.expectEqualStrings("one", runs.items[0].text);
    try testing.expectEqual(@as(u16, 0), runs.items[0].rect.y);
    try testing.expectEqual(@as(u16, 2), runs.items[1].rect.y);
}

test "list items get a bullet" {
    var doc = try styledDoc("<body><ul><li>x</li><li>y</li></ul></body>");
    defer doc.deinit();
    const root = (try layout(doc.alloc(), &doc, 80)).root;
    var runs: std.ArrayList(Box) = .empty;
    defer runs.deinit(testing.allocator);
    try collectText(root, &runs);
    try testing.expectEqualStrings("\u{2022}", runs.items[0].text);
    try testing.expectEqualStrings("x", runs.items[1].text);
    try testing.expectEqualStrings("\u{2022}", runs.items[2].text);
    try testing.expectEqualStrings("y", runs.items[3].text);
}

test "ordered lists number their items and honor start" {
    var doc = try styledDoc("<body><ol start=3><li>x</li><li>y</li></ol></body>");
    defer doc.deinit();
    const root = (try layout(doc.alloc(), &doc, 80)).root;
    var runs: std.ArrayList(Box) = .empty;
    defer runs.deinit(testing.allocator);
    try collectText(root, &runs);
    try testing.expectEqualStrings("3.", runs.items[0].text);
    try testing.expectEqualStrings("x", runs.items[1].text);
    try testing.expectEqualStrings("4.", runs.items[2].text);
    try testing.expectEqualStrings("y", runs.items[3].text);
}

test "nested lists indent one level per depth" {
    var doc = try styledDoc("<body><ul><li>a<ul><li>b</li></ul></li></ul></body>");
    defer doc.deinit();
    const root = (try layout(doc.alloc(), &doc, 80)).root;
    var runs: std.ArrayList(Box) = .empty;
    defer runs.deinit(testing.allocator);
    try collectText(root, &runs);

    var outer: u16 = 0;
    var inner: u16 = 0;
    for (runs.items) |r| {
        if (std.mem.eql(u8, r.text, "a")) outer = r.rect.x;
        if (std.mem.eql(u8, r.text, "b")) inner = r.rect.x;
    }
    try testing.expect(inner > outer);
}

test "blockquote is indented, hr draws a full-width rule" {
    var doc = try styledDoc("<body><p>flush</p><blockquote>quoted</blockquote><hr></body>");
    defer doc.deinit();
    const root = (try layout(doc.alloc(), &doc, 20)).root;
    var runs: std.ArrayList(Box) = .empty;
    defer runs.deinit(testing.allocator);
    try collectText(root, &runs);

    try testing.expectEqualStrings("flush", runs.items[0].text);
    try testing.expectEqual(@as(u16, 0), runs.items[0].rect.x);
    try testing.expectEqualStrings("quoted", runs.items[1].text);
    try testing.expectEqual(@as(u16, 4), runs.items[1].rect.x);

    const rule = runs.items[runs.items.len - 1];
    try testing.expectEqual(@as(u16, 20), rule.rect.w);
    try testing.expectEqual(@as(usize, 20), boxmod.cellWidth(rule.text));
}

test "display:none produces no boxes" {
    var doc = try styledDoc("<body><p>seen</p><script>hidden()</script><style>x{}</style></body>");
    defer doc.deinit();
    const root = (try layout(doc.alloc(), &doc, 80)).root;
    var runs: std.ArrayList(Box) = .empty;
    defer runs.deinit(testing.allocator);
    try collectText(root, &runs);
    try testing.expectEqual(@as(usize, 1), runs.items.len);
    try testing.expectEqualStrings("seen", runs.items[0].text);
}

test "table cells sit side by side in aligned columns" {
    var doc = try styledDoc("<body><table><tr><td>a</td><td>bb</td></tr><tr><td>ccc</td><td>d</td></tr></table></body>");
    defer doc.deinit();
    const root = (try layout(doc.alloc(), &doc, 80)).root;
    var runs: std.ArrayList(Box) = .empty;
    defer runs.deinit(testing.allocator);
    try collectText(root, &runs);

    try testing.expectEqual(@as(usize, 4), runs.items.len);
    try testing.expectEqualStrings("a", runs.items[0].text);
    try testing.expectEqual(@as(u16, 0), runs.items[0].rect.x);
    try testing.expectEqual(@as(u16, 0), runs.items[0].rect.y);
    try testing.expectEqualStrings("bb", runs.items[1].text);
    try testing.expectEqual(@as(u16, 4), runs.items[1].rect.x);
    try testing.expectEqual(@as(u16, 0), runs.items[1].rect.y);

    try testing.expectEqualStrings("ccc", runs.items[2].text);
    try testing.expectEqual(@as(u16, 0), runs.items[2].rect.x);
    try testing.expectEqual(@as(u16, 1), runs.items[2].rect.y);
    try testing.expectEqualStrings("d", runs.items[3].text);
    try testing.expectEqual(@as(u16, 4), runs.items[3].rect.x);
    try testing.expectEqual(@as(u16, 1), runs.items[3].rect.y);
}

test "row height is the tallest cell, next row clears it" {
    var doc = try styledDoc("<body><table><tr><td>aa bb cc</td><td>x</td></tr><tr><td>y</td></tr></table></body>");
    defer doc.deinit();
    const root = (try layout(doc.alloc(), &doc, 12)).root;
    var runs: std.ArrayList(Box) = .empty;
    defer runs.deinit(testing.allocator);
    try collectText(root, &runs);

    const last = runs.items[runs.items.len - 1];
    try testing.expectEqualStrings("y", last.text);
    var tall: u16 = 0;
    for (runs.items[0 .. runs.items.len - 1]) |r| tall = @max(tall, r.rect.y);
    try testing.expect(last.rect.y > tall);
}

test "colspan cell spans its columns" {
    var doc = try styledDoc("<body><table><tr><td colspan=2>wide header</td></tr><tr><td>a</td><td>b</td></tr></table></body>");
    defer doc.deinit();
    const root = (try layout(doc.alloc(), &doc, 80)).root;
    var runs: std.ArrayList(Box) = .empty;
    defer runs.deinit(testing.allocator);
    try collectText(root, &runs);

    try testing.expectEqualStrings("wide", runs.items[0].text);
    try testing.expectEqualStrings("header", runs.items[1].text);
    try testing.expectEqual(@as(u16, 0), runs.items[0].rect.y);
    try testing.expectEqual(@as(u16, 0), runs.items[1].rect.y);
    try testing.expectEqualStrings("a", runs.items[2].text);
    try testing.expectEqual(@as(u16, 0), runs.items[2].rect.x);
    try testing.expect(runs.items[3].rect.x > 0);
}

test "block element inside an inline one is promoted, not swallowed" {
    var doc = try styledDoc("<body><center><table><tr><td>in</td></tr></table></center></body>");
    defer doc.deinit();
    const root = (try layout(doc.alloc(), &doc, 80)).root;
    var runs: std.ArrayList(Box) = .empty;
    defer runs.deinit(testing.allocator);
    try collectText(root, &runs);
    try testing.expectEqual(@as(usize, 1), runs.items.len);
    try testing.expectEqualStrings("in", runs.items[0].text);
}

test "img alt text renders as words, missing alt gives a placeholder" {
    var doc = try styledDoc("<body><p><img src=a.png alt=\"a cat\"><img src=b.png></p></body>");
    defer doc.deinit();
    const root = (try layout(doc.alloc(), &doc, 80)).root;
    var runs: std.ArrayList(Box) = .empty;
    defer runs.deinit(testing.allocator);
    try collectText(root, &runs);
    try testing.expectEqual(@as(usize, 3), runs.items.len);
    try testing.expectEqualStrings("a", runs.items[0].text);
    try testing.expectEqualStrings("cat", runs.items[1].text);
    try testing.expectEqualStrings("[img]", runs.items[2].text);
}

test "spacer img becomes indent cells, decorative img stays silent" {
    var doc = try styledDoc("<body><p><img src=s.gif width=40 alt=\"\">x</p><p><img src=s.gif alt=\"\">y</p></body>");
    defer doc.deinit();
    const root = (try layout(doc.alloc(), &doc, 80)).root;
    var runs: std.ArrayList(Box) = .empty;
    defer runs.deinit(testing.allocator);
    try collectText(root, &runs);
    try testing.expectEqual(@as(usize, 3), runs.items.len);
    try testing.expectEqualStrings("     ", runs.items[0].text);
    try testing.expectEqualStrings("x", runs.items[1].text);
    try testing.expectEqualStrings("y", runs.items[2].text);
    try testing.expectEqual(@as(u16, 0), runs.items[2].rect.x);
}

test "rowspan holds its columns so later rows stay aligned" {
    const src = "<body><table>" ++
        "<tr><td rowspan=2>span</td><td>b1</td></tr>" ++
        "<tr><td>b2</td></tr>" ++
        "<tr><td>a3</td><td>b3</td></tr>" ++
        "</table></body>";
    var doc = try styledDoc(src);
    defer doc.deinit();
    const root = (try layout(doc.alloc(), &doc, 80)).root;
    var runs: std.ArrayList(Box) = .empty;
    defer runs.deinit(testing.allocator);
    try collectText(root, &runs);

    var b1: Box = undefined;
    var b2: Box = undefined;
    var b3: Box = undefined;
    var a3: Box = undefined;
    for (runs.items) |r| {
        if (std.mem.eql(u8, r.text, "b1")) b1 = r;
        if (std.mem.eql(u8, r.text, "b2")) b2 = r;
        if (std.mem.eql(u8, r.text, "b3")) b3 = r;
        if (std.mem.eql(u8, r.text, "a3")) a3 = r;
    }
    try testing.expectEqual(b1.rect.x, b2.rect.x);
    try testing.expectEqual(b1.rect.x, b3.rect.x);
    try testing.expectEqual(@as(u16, 0), a3.rect.x);
    try testing.expect(b2.rect.y > b1.rect.y);
}

test "links collected with hint numbers and hrefs" {
    var doc = try styledDoc("<body><p><a href=\"/a\">one</a> <a href=\"http://x/b\">two</a></p></body>");
    defer doc.deinit();
    const pg = try layout(doc.alloc(), &doc, 80);
    try testing.expectEqual(@as(usize, 2), pg.links.len);
    try testing.expectEqualStrings("/a", pg.links[0]);
    try testing.expectEqualStrings("http://x/b", pg.links[1]);

    var runs: std.ArrayList(Box) = .empty;
    defer runs.deinit(testing.allocator);
    try collectText(pg.root, &runs);
    try testing.expectEqualStrings("[1]", runs.items[0].text);
    try testing.expectEqual(@as(u16, 1), runs.items[0].link);
    try testing.expectEqual(@as(u16, 1), runs.items[1].link);
}
