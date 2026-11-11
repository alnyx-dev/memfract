const std = @import("std");

pub const Writer = struct {
    a: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    has_item: [64]bool = std.mem.zeroes([64]bool),
    depth: usize = 0,
    after_key: bool = false,

    pub fn init(a: std.mem.Allocator) Writer {
        return .{ .a = a };
    }

    pub fn reset(self: *Writer) void {
        self.buf.clearRetainingCapacity();
        self.has_item = std.mem.zeroes([64]bool);
        self.depth = 0;
        self.after_key = false;
    }

    fn raw(self: *Writer, s: []const u8) !void {
        try self.buf.appendSlice(self.a, s);
    }

    fn sep(self: *Writer) !void {
        if (self.after_key) {
            self.after_key = false;
            return;
        }
        if (self.depth > 0) {
            if (self.has_item[self.depth - 1]) try self.raw(",");
            self.has_item[self.depth - 1] = true;
        }
    }

    pub fn objectBegin(self: *Writer) !void {
        if (self.depth >= self.has_item.len) return error.DepthLimit;
        try self.sep();
        try self.raw("{");
        self.depth += 1;
        self.has_item[self.depth - 1] = false;
    }

    pub fn objectEnd(self: *Writer) !void {
        self.depth -= 1;
        try self.raw("}");
    }

    pub fn arrayBegin(self: *Writer) !void {
        if (self.depth >= self.has_item.len) return error.DepthLimit;
        try self.sep();
        try self.raw("[");
        self.depth += 1;
        self.has_item[self.depth - 1] = false;
    }

    pub fn arrayEnd(self: *Writer) !void {
        self.depth -= 1;
        try self.raw("]");
    }

    pub fn key(self: *Writer, k: []const u8) !void {
        try self.sep();
        try self.writeString(k);
        try self.raw(":");
        self.after_key = true;
    }

    fn writeString(self: *Writer, s: []const u8) !void {
        try self.raw("\"");
        for (s) |c| {
            if (c == '"') {
                try self.raw("\\\"");
            } else if (c == '\\') {
                try self.raw("\\\\");
            } else if (c == '\n') {
                try self.raw("\\n");
            } else if (c == '\r') {
                try self.raw("\\r");
            } else if (c == '\t') {
                try self.raw("\\t");
            } else if (c < 0x20) {
                var tmp: [8]u8 = undefined;
                const e = try std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c});
                try self.raw(e);
            } else {
                try self.buf.append(self.a, c);
            }
        }
        try self.raw("\"");
    }

    pub fn string(self: *Writer, s: []const u8) !void {
        try self.sep();
        try self.writeString(s);
    }

    pub fn int(self: *Writer, v: anytype) !void {
        try self.sep();
        var b: [48]u8 = undefined;
        const s = try std.fmt.bufPrint(&b, "{d}", .{v});
        try self.raw(s);
    }

    pub fn boolean(self: *Writer, v: bool) !void {
        try self.sep();
        try self.raw(if (v) "true" else "false");
    }

    pub fn nullv(self: *Writer) !void {
        try self.sep();
        try self.raw("null");
    }

    pub fn float(self: *Writer, v: f64) !void {
        if (!std.math.isFinite(v)) return self.nullv();
        try self.sep();
        var b: [400]u8 = undefined;
        const s = try std.fmt.bufPrint(&b, "{d}", .{v});
        try self.raw(s);
    }

    pub fn float32(self: *Writer, v: f32) !void {
        if (!std.math.isFinite(v)) return self.nullv();
        try self.sep();
        var b: [96]u8 = undefined;
        const s = try std.fmt.bufPrint(&b, "{d}", .{v});
        try self.raw(s);
    }

    pub fn kvStr(self: *Writer, k: []const u8, v: []const u8) !void {
        try self.key(k);
        try self.string(v);
    }

    pub fn kvInt(self: *Writer, k: []const u8, v: anytype) !void {
        try self.key(k);
        try self.int(v);
    }

    pub fn kvBool(self: *Writer, k: []const u8, v: bool) !void {
        try self.key(k);
        try self.boolean(v);
    }
};

test "writer basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w = Writer.init(arena.allocator());
    try w.objectBegin();
    try w.kvBool("ok", true);
    try w.key("list");
    try w.arrayBegin();
    try w.int(1);
    try w.string("a\"b");
    try w.arrayEnd();
    try w.objectEnd();
    try std.testing.expectEqualStrings("{\"ok\":true,\"list\":[1,\"a\\\"b\"]}", w.buf.items);
}

test "writer nested values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w = Writer.init(arena.allocator());
    try w.objectBegin();
    try w.kvStr("name", "z");
    try w.key("items");
    try w.arrayBegin();
    try w.int(-1);
    try w.float(1.5);
    try w.boolean(false);
    try w.nullv();
    try w.arrayEnd();
    try w.objectEnd();
    try std.testing.expectEqualStrings("{\"name\":\"z\",\"items\":[-1,1.5,false,null]}", w.buf.items);
}

test "non-finite floats become null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w = Writer.init(arena.allocator());
    try w.arrayBegin();
    try w.float(std.math.nan(f64));
    try w.float(std.math.inf(f64));
    try w.float32(-std.math.inf(f32));
    try w.arrayEnd();
    try std.testing.expectEqualStrings("[null,null,null]", w.buf.items);
}

test "string escaping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w = Writer.init(arena.allocator());
    try w.string("a\"b\\c\n\t\x01");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\\t\\u0001\"", w.buf.items);
}

test "depth limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w = Writer.init(arena.allocator());
    var i: usize = 0;
    while (i < 64) : (i += 1) try w.arrayBegin();
    try std.testing.expectError(error.DepthLimit, w.arrayBegin());
}
