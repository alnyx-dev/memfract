const std = @import("std");
const win = @import("win.zig");

pub const Kind = enum {
    int32,
    int64,
    float32,
    float64,
    int8,
    int16,
    uint8,
    uint16,
    uint32,
    uint64,
    string,
    bytes,

    pub fn size(k: Kind) usize {
        return switch (k) {
            .int8, .uint8 => 1,
            .int16, .uint16 => 2,
            .int32, .float32, .uint32 => 4,
            .int64, .float64, .uint64 => 8,
            .string, .bytes => 0,
        };
    }

    pub fn isFloat(k: Kind) bool {
        return k == .float32 or k == .float64;
    }

    /// Types whose value length comes from the pattern, not from the type.
    pub fn isVariable(k: Kind) bool {
        return k == .string or k == .bytes;
    }

    pub fn parse(name: []const u8) ?Kind {
        return std.meta.stringToEnum(Kind, name);
    }
};

pub const Encoding = enum { utf8, utf16le };

pub const max_value_len = 256;

pub const Value = struct {
    bytes: [8]u8 = std.mem.zeroes([8]u8),
};

pub fn encode(kind: Kind, text: []const u8) !Value {
    var v: Value = .{};
    switch (kind) {
        .int8 => std.mem.writeInt(i8, v.bytes[0..1], try std.fmt.parseInt(i8, text, 0), .little),
        .int16 => std.mem.writeInt(i16, v.bytes[0..2], try std.fmt.parseInt(i16, text, 0), .little),
        .int32 => std.mem.writeInt(i32, v.bytes[0..4], try std.fmt.parseInt(i32, text, 0), .little),
        .int64 => std.mem.writeInt(i64, v.bytes[0..8], try std.fmt.parseInt(i64, text, 0), .little),
        .uint8 => std.mem.writeInt(u8, v.bytes[0..1], try std.fmt.parseInt(u8, text, 0), .little),
        .uint16 => std.mem.writeInt(u16, v.bytes[0..2], try std.fmt.parseInt(u16, text, 0), .little),
        .uint32 => std.mem.writeInt(u32, v.bytes[0..4], try std.fmt.parseInt(u32, text, 0), .little),
        .uint64 => std.mem.writeInt(u64, v.bytes[0..8], try std.fmt.parseInt(u64, text, 0), .little),
        .float32 => {
            const f = try std.fmt.parseFloat(f32, text);
            std.mem.writeInt(u32, v.bytes[0..4], @bitCast(f), .little);
        },
        .float64 => {
            const f = try std.fmt.parseFloat(f64, text);
            std.mem.writeInt(u64, v.bytes[0..8], @bitCast(f), .little);
        },
        .string, .bytes => return error.UnsupportedType,
    }
    return v;
}

pub fn show(kind: Kind, b: []const u8) void {
    var buf: [48]u8 = undefined;
    std.debug.print("{s}", .{fmtValue(kind, b, &buf)});
}

pub fn fmtValue(kind: Kind, b: []const u8, buf: []u8) []const u8 {
    const r = switch (kind) {
        .int8 => std.fmt.bufPrint(buf, "{d}", .{std.mem.readInt(i8, b[0..1], .little)}),
        .int16 => std.fmt.bufPrint(buf, "{d}", .{std.mem.readInt(i16, b[0..2], .little)}),
        .int32 => std.fmt.bufPrint(buf, "{d}", .{std.mem.readInt(i32, b[0..4], .little)}),
        .int64 => std.fmt.bufPrint(buf, "{d}", .{std.mem.readInt(i64, b[0..8], .little)}),
        .uint8 => std.fmt.bufPrint(buf, "{d}", .{std.mem.readInt(u8, b[0..1], .little)}),
        .uint16 => std.fmt.bufPrint(buf, "{d}", .{std.mem.readInt(u16, b[0..2], .little)}),
        .uint32 => std.fmt.bufPrint(buf, "{d}", .{std.mem.readInt(u32, b[0..4], .little)}),
        .uint64 => std.fmt.bufPrint(buf, "{d}", .{std.mem.readInt(u64, b[0..8], .little)}),
        .float32 => std.fmt.bufPrint(buf, "{d}", .{@as(f32, @bitCast(std.mem.readInt(u32, b[0..4], .little)))}),
        .float64 => std.fmt.bufPrint(buf, "{d}", .{@as(f64, @bitCast(std.mem.readInt(u64, b[0..8], .little)))}),
        .string, .bytes => "?",
    };
    return r catch "?";
}

/// Display a match of any type in a short, single-line form.
pub fn fmtValueAny(kind: Kind, encoding: Encoding, b: []const u8, buf: []u8) []const u8 {
    return switch (kind) {
        .string => decodeText(encoding, b, buf) orelse asciiPreview(b, buf),
        .bytes => hexPreview(b, buf),
        else => fmtValue(kind, b, buf),
    };
}

fn asciiPreview(b: []const u8, buf: []u8) []const u8 {
    const n = @min(b.len, buf.len);
    for (b[0..n], 0..) |c, i| buf[i] = if (c >= 0x20 and c < 0x7F) c else '.';
    return buf[0..n];
}

fn hexPreview(b: []const u8, buf: []u8) []const u8 {
    if (buf.len < 3) return "";
    const digits = "0123456789abcdef";
    var n: usize = 0;
    for (b) |c| {
        if (n + 3 > buf.len) {
            buf[n] = '.';
            buf[n + 1] = '.';
            return buf[0 .. n + 2];
        }
        buf[n] = digits[c >> 4];
        buf[n + 1] = digits[c & 15];
        n += 2;
    }
    return buf[0..n];
}

fn asF64(kind: Kind, b: []const u8) f64 {
    switch (kind) {
        .float32 => {
            const f: f32 = @bitCast(std.mem.readInt(u32, b[0..4], .little));
            return f;
        },
        .float64 => {
            const f: f64 = @bitCast(std.mem.readInt(u64, b[0..8], .little));
            return f;
        },
        else => return 0,
    }
}

pub fn cmpVal(kind: Kind, x: []const u8, y: []const u8) ?std.math.Order {
    switch (kind) {
        .int8 => return std.math.order(std.mem.readInt(i8, x[0..1], .little), std.mem.readInt(i8, y[0..1], .little)),
        .int16 => return std.math.order(std.mem.readInt(i16, x[0..2], .little), std.mem.readInt(i16, y[0..2], .little)),
        .int32 => return std.math.order(std.mem.readInt(i32, x[0..4], .little), std.mem.readInt(i32, y[0..4], .little)),
        .int64 => return std.math.order(std.mem.readInt(i64, x[0..8], .little), std.mem.readInt(i64, y[0..8], .little)),
        .uint8 => return std.math.order(std.mem.readInt(u8, x[0..1], .little), std.mem.readInt(u8, y[0..1], .little)),
        .uint16 => return std.math.order(std.mem.readInt(u16, x[0..2], .little), std.mem.readInt(u16, y[0..2], .little)),
        .uint32 => return std.math.order(std.mem.readInt(u32, x[0..4], .little), std.mem.readInt(u32, y[0..4], .little)),
        .uint64 => return std.math.order(std.mem.readInt(u64, x[0..8], .little), std.mem.readInt(u64, y[0..8], .little)),
        .float32, .float64 => {
            const a = asF64(kind, x);
            const b = asF64(kind, y);
            if (std.math.isNan(a) or std.math.isNan(b)) return null;
            return std.math.order(a, b);
        },
        .string, .bytes => return null,
    }
}

pub const Mode = enum {
    exact,
    greater,
    less,
    between,
    unknown,
    changed,
    unchanged,
    increased,
    decreased,
};

pub const Cond = struct {
    mode: Mode,
    a: Value = .{},
    b: Value = .{},
    tol: f64 = 0,
    pattern: [max_value_len]u8 = undefined,
    pattern_len: usize = 0,
    /// 1 = byte must match, 0 = wildcard. An empty mask matches every byte.
    mask: [max_value_len]u8 = undefined,
    mask_len: usize = 0,
    encoding: Encoding = .utf8,

    pub fn patternSlice(c: *const Cond) []const u8 {
        return c.pattern[0..c.pattern_len];
    }

    pub fn maskSlice(c: *const Cond) []const u8 {
        return c.mask[0..c.mask_len];
    }

    pub fn setText(c: *Cond, text: []const u8) !void {
        const out = try encodeText(c.encoding, text, &c.pattern);
        c.pattern_len = out.len;
        c.mask_len = 0;
    }

    pub fn setBytePattern(c: *Cond, text: []const u8) !void {
        const p = try parseBytePattern(text, &c.pattern, &c.mask);
        c.pattern_len = p.bytes.len;
        c.mask_len = p.mask.len;
    }
};

fn patternEqual(cur: []const u8, pat: []const u8, mask: []const u8) bool {
    if (cur.len != pat.len) return false;
    for (cur, pat, 0..) |c, p, i| {
        if (mask.len == 0 or mask[i] != 0) {
            if (c != p) return false;
        }
    }
    return true;
}

fn check(kind: Kind, cur: []const u8, old: []const u8, c: *const Cond) bool {
    if (kind.isVariable()) {
        return switch (c.mode) {
            .exact => patternEqual(cur, c.patternSlice(), c.maskSlice()),
            .changed => !std.mem.eql(u8, cur, old),
            .unchanged => std.mem.eql(u8, cur, old),
            else => false,
        };
    }
    const sz = cur.len;
    switch (c.mode) {
        .unknown => return true,
        .changed => return !std.mem.eql(u8, cur, old),
        .unchanged => return std.mem.eql(u8, cur, old),
        .increased => {
            const o = cmpVal(kind, cur, old) orelse return false;
            return o == .gt;
        },
        .decreased => {
            const o = cmpVal(kind, cur, old) orelse return false;
            return o == .lt;
        },
        .exact => {
            if (kind.isFloat() and c.tol > 0) {
                const x = asF64(kind, cur);
                const y = asF64(kind, c.a.bytes[0..sz]);
                if (std.math.isNan(x)) return false;
                return @abs(x - y) <= c.tol;
            }
            return std.mem.eql(u8, cur, c.a.bytes[0..sz]);
        },
        .greater => {
            const o = cmpVal(kind, cur, c.a.bytes[0..sz]) orelse return false;
            return o == .gt;
        },
        .less => {
            const o = cmpVal(kind, cur, c.a.bytes[0..sz]) orelse return false;
            return o == .lt;
        },
        .between => {
            const lo = cmpVal(kind, cur, c.a.bytes[0..sz]) orelse return false;
            const hi = cmpVal(kind, cur, c.b.bytes[0..sz]) orelse return false;
            return lo != .lt and hi != .gt;
        },
    }
}

pub const Match = struct {
    addr: usize,
};

pub const Pattern = struct {
    bytes: []const u8,
    mask: []const u8,
};

pub fn parseBytePattern(text: []const u8, bytes_out: []u8, mask_out: []u8) !Pattern {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, " \t");
    while (it.next()) |tok| {
        if (n >= bytes_out.len or n >= mask_out.len) return error.PatternTooLong;
        var t = tok;
        if (std.mem.eql(u8, t, "?") or std.mem.eql(u8, t, "??")) {
            bytes_out[n] = 0;
            mask_out[n] = 0;
            n += 1;
            continue;
        }
        if (t.len > 2 and (std.mem.startsWith(u8, t, "0x") or std.mem.startsWith(u8, t, "0X"))) t = t[2..];
        if (t.len == 0 or t.len > 2) return error.InvalidPattern;
        var b: u16 = 0;
        for (t) |ch| {
            const d = std.fmt.charToDigit(ch, 16) catch return error.InvalidPattern;
            b = b * 16 + d;
        }
        bytes_out[n] = @intCast(b);
        mask_out[n] = 1;
        n += 1;
    }
    if (n == 0) return error.InvalidPattern;
    return .{ .bytes = bytes_out[0..n], .mask = mask_out[0..n] };
}

pub fn encodeText(encoding: Encoding, text: []const u8, out: []u8) ![]const u8 {
    switch (encoding) {
        .utf8 => {
            if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidPattern;
            if (text.len > out.len) return error.PatternTooLong;
            @memcpy(out[0..text.len], text);
            return out[0..text.len];
        },
        .utf16le => {
            if (text.len > max_value_len) return error.PatternTooLong;
            var tmp: [max_value_len / 2]u16 = undefined;
            const n = std.unicode.utf8ToUtf16Le(&tmp, text) catch return error.InvalidPattern;
            if (n * 2 > out.len) return error.PatternTooLong;
            @memcpy(out[0 .. n * 2], std.mem.sliceAsBytes(tmp[0..n]));
            return out[0 .. n * 2];
        },
    }
}

pub fn decodeText(encoding: Encoding, bytes: []const u8, out: []u8) ?[]const u8 {
    switch (encoding) {
        .utf8 => return if (std.unicode.utf8ValidateSlice(bytes)) bytes else null,
        .utf16le => {
            if (bytes.len % 2 != 0 or bytes.len / 2 > max_value_len / 2) return null;
            var tmp: [max_value_len / 2]u16 = undefined;
            var i: usize = 0;
            while (i < bytes.len) : (i += 2) tmp[i / 2] = std.mem.readInt(u16, bytes[i..][0..2], .little);
            const n = std.unicode.utf16LeToUtf8(out, tmp[0 .. bytes.len / 2]) catch return null;
            return out[0..n];
        },
    }
}

pub var progress = std.atomic.Value(u32).init(0);
pub var cancel_flag = std.atomic.Value(bool).init(false);

pub const Range = struct {
    start: usize = 0,
    end: usize = std.math.maxInt(usize),
};

const Span = struct { off: usize, len: usize };

fn regionSpan(range: Range, base: usize, size: usize, alignment: usize, step: usize) ?Span {
    const end, const overflow = @addWithOverflow(base, size);
    if (overflow != 0) return null;
    if (end <= range.start or base >= range.end) return null;
    const lo = @max(base, range.start);
    const hi = @min(end, range.end);
    const off = std.mem.alignForward(usize, lo - base, alignment);
    const stop = hi - base;
    if (off >= stop) return null;
    return .{ .off = off, .len = @min(size - off, stop - off + step - 1) };
}

pub const Scanner = struct {
    kind: Kind = .int32,
    matches: std.ArrayList(Match) = .empty,
    values: std.ArrayList(u8) = .empty,
    value_len: usize = 0,
    encoding: Encoding = .utf8,
    truncated: bool = false,

    const chunk_size = 1 << 20;
    const page_size = 4096;
    const max_matches = 16_000_000;

    pub fn deinit(self: *Scanner, gpa: std.mem.Allocator) void {
        self.matches.deinit(gpa);
        self.values.deinit(gpa);
    }

    pub fn valueLen(self: *const Scanner) usize {
        return if (self.kind.isVariable()) self.value_len else self.kind.size();
    }

    pub fn valueAt(self: *const Scanner, i: usize) []const u8 {
        const len = self.valueLen();
        return self.values.items[i * len ..][0..len];
    }

    pub fn reset(self: *Scanner) void {
        self.matches.clearRetainingCapacity();
        self.values.clearRetainingCapacity();
        self.truncated = false;
    }

    pub fn first(
        self: *Scanner,
        gpa: std.mem.Allocator,
        proc: win.Process,
        kind: Kind,
        cond: Cond,
        writable_only: bool,
        range: Range,
        alignment: usize,
    ) !void {
        if (kind.isVariable()) {
            if (cond.mode != .exact or cond.pattern_len == 0) return error.MissingPattern;
            if (cond.pattern_len > max_value_len) return error.PatternTooLong;
        }
        self.kind = kind;
        self.encoding = cond.encoding;
        self.value_len = if (kind.isVariable()) cond.pattern_len else kind.size();
        self.reset();
        progress.store(0, .release);

        const step = self.valueLen();
        const stride = @max(alignment, 1);

        var regs = try proc.regions(gpa, writable_only);
        defer regs.deinit(gpa);

        var total: u64 = 1;
        for (regs.items) |r| {
            if (regionSpan(range, r.base, r.size, stride, step)) |s| total += s.len;
        }
        var done: u64 = 0;

        const buf = try gpa.alloc(u8, chunk_size + step - 1);
        defer gpa.free(buf);

        outer: for (regs.items) |r| {
            const span = regionSpan(range, r.base, r.size, stride, step) orelse continue;
            var off = span.off;
            const stop = span.off + span.len;
            while (off < stop) : (off += chunk_size) {
                if (cancel_flag.load(.acquire)) {
                    self.reset();
                    return error.Canceled;
                }
                const avail = stop - off;
                // Each chunk owns `starts` start offsets; the read reaches step-1 bytes
                // further so unaligned values that cross the boundary are still seen.
                const starts = @min(chunk_size, avail);
                const n = @min(chunk_size + step - 1, avail);
                done += starts;
                progress.store(@intCast(done * 1000 / total), .release);

                if (proc.read(r.base + off, buf[0..n])) |_| {
                    if (try self.scanBlock(gpa, kind, cond, buf[0..n], r.base + off, stride, starts)) break :outer;
                } else |_| {
                    var po: usize = 0;
                    while (po < starts) : (po += page_size) {
                        const pn = @min(page_size, starts - po);
                        const take = @min(pn + step - 1, avail - po);
                        if (proc.read(r.base + off + po, buf[po..][0..take])) |_| {
                            if (try self.scanBlock(gpa, kind, cond, buf[po..][0..take], r.base + off + po, stride, pn)) break :outer;
                        } else |_| {
                            proc.read(r.base + off + po, buf[po..][0..pn]) catch continue;
                            if (try self.scanBlock(gpa, kind, cond, buf[po..][0..pn], r.base + off + po, stride, pn)) break :outer;
                        }
                    }
                }
            }
        }
        progress.store(1000, .release);
    }

    fn scanBlock(
        self: *Scanner,
        gpa: std.mem.Allocator,
        kind: Kind,
        cond: Cond,
        buf: []const u8,
        base: usize,
        stride: usize,
        starts: usize,
    ) !bool {
        self.kind = kind;
        const step = if (kind.isVariable()) cond.pattern_len else kind.size();
        self.value_len = step;

        if (cond.mode == .exact and !kind.isFloat() and !kind.isVariable()) {
            return switch (kind) {
                .int8 => self.scanExact(gpa, i8, buf, base, std.mem.readInt(i8, cond.a.bytes[0..1], .little), stride, starts),
                .int16 => self.scanExact(gpa, i16, buf, base, std.mem.readInt(i16, cond.a.bytes[0..2], .little), stride, starts),
                .int32 => self.scanExact(gpa, i32, buf, base, std.mem.readInt(i32, cond.a.bytes[0..4], .little), stride, starts),
                .int64 => self.scanExact(gpa, i64, buf, base, std.mem.readInt(i64, cond.a.bytes[0..8], .little), stride, starts),
                .uint8 => self.scanExact(gpa, u8, buf, base, std.mem.readInt(u8, cond.a.bytes[0..1], .little), stride, starts),
                .uint16 => self.scanExact(gpa, u16, buf, base, std.mem.readInt(u16, cond.a.bytes[0..2], .little), stride, starts),
                .uint32 => self.scanExact(gpa, u32, buf, base, std.mem.readInt(u32, cond.a.bytes[0..4], .little), stride, starts),
                .uint64 => self.scanExact(gpa, u64, buf, base, std.mem.readInt(u64, cond.a.bytes[0..8], .little), stride, starts),
                else => unreachable,
            };
        }
        var i: usize = 0;
        while (i < starts and i + step <= buf.len) : (i += stride) {
            const cur = buf[i..][0..step];
            if (!check(kind, cur, cur, &cond)) continue;
            if (self.matches.items.len >= max_matches) {
                self.truncated = true;
                return true;
            }
            try self.matches.append(gpa, .{ .addr = base + i });
            try self.values.appendSlice(gpa, cur);
        }
        return false;
    }

    /// Exact match for integer types with a comptime-known width.
    fn scanExact(
        self: *Scanner,
        gpa: std.mem.Allocator,
        comptime T: type,
        buf: []const u8,
        base: usize,
        needle: T,
        stride: usize,
        starts: usize,
    ) !bool {
        const step = @sizeOf(T);
        var i: usize = 0;
        while (i < starts and i + step <= buf.len) : (i += stride) {
            if (std.mem.readInt(T, buf[i..][0..step], .little) != needle) continue;
            if (self.matches.items.len >= max_matches) {
                self.truncated = true;
                return true;
            }
            try self.matches.append(gpa, .{ .addr = base + i });
            try self.values.appendSlice(gpa, buf[i..][0..step]);
        }
        return false;
    }

    fn moveDown(self: *Scanner, w: usize, i: usize) void {
        const step = self.valueLen();
        self.matches.items[w] = self.matches.items[i];
        std.mem.copyForwards(u8, self.values.items[w * step ..][0..step], self.values.items[i * step ..][0..step]);
    }

    pub fn next(self: *Scanner, proc: win.Process, cond: Cond) bool {
        const step = self.valueLen();
        const total = self.matches.items.len;
        var w: usize = 0;
        var i: usize = 0;
        var canceled = false;
        var page: [page_size]u8 = undefined;
        var cur: [max_value_len]u8 = undefined;
        var next_check: usize = 0;
        progress.store(0, .release);

        // Matches are stored in ascending address order, so every 4 KB page can be
        // read once and reused for all matches that fall inside it.
        while (i < total) {
            if (i >= next_check) {
                next_check = i + 1024;
                progress.store(@intCast(i * 1000 / total), .release);
                if (cancel_flag.load(.acquire)) {
                    canceled = true;
                    const keep = total - i;
                    var k: usize = 0;
                    while (k < keep) : (k += 1) self.moveDown(w + k, i + k);
                    w += keep;
                    break;
                }
            }

            const base = self.matches.items[i].addr & ~@as(usize, page_size - 1);
            const limit = page_size - step;
            var j = i;
            while (j < total) {
                const a = self.matches.items[j].addr;
                if (a < base or a - base > limit) break;
                j += 1;
            }

            if (j == i) {
                // The value straddles a page boundary (not produced by aligned scans).
                const m = self.matches.items[i];
                i += 1;
                if (proc.read(m.addr, cur[0..step])) {
                    if (check(self.kind, cur[0..step], self.valueAt(i - 1), &cond)) {
                        self.matches.items[w] = m;
                        @memcpy(self.values.items[w * step ..][0..step], cur[0..step]);
                        w += 1;
                    }
                } else |_| {}
                continue;
            }

            if (proc.read(base, page[0..])) |_| {
                var k = i;
                while (k < j) : (k += 1) {
                    const m = self.matches.items[k];
                    const off = m.addr - base;
                    if (check(self.kind, page[off..][0..step], self.valueAt(k), &cond)) {
                        self.matches.items[w] = m;
                        @memcpy(self.values.items[w * step ..][0..step], page[off..][0..step]);
                        w += 1;
                    }
                }
            } else |_| {}
            i = j;
        }
        self.matches.shrinkRetainingCapacity(w);
        self.values.shrinkRetainingCapacity(w * step);
        progress.store(1000, .release);
        return canceled;
    }
};

test "encode roundtrip" {
    const v = try encode(.int32, "1337");
    try std.testing.expectEqual(@as(i32, 1337), std.mem.readInt(i32, v.bytes[0..4], .little));
}

test "check greater/between" {
    var c: Cond = .{ .mode = .greater };
    c.a = try encode(.int32, "10");
    const x = try encode(.int32, "11");
    try std.testing.expect(check(.int32, x.bytes[0..4], x.bytes[0..4], &c));
    c.mode = .between;
    c.b = try encode(.int32, "20");
    try std.testing.expect(check(.int32, x.bytes[0..4], x.bytes[0..4], &c));
}

test "Kind metadata and parsing" {
    try std.testing.expectEqual(@as(usize, 4), Kind.int32.size());
    try std.testing.expectEqual(@as(usize, 8), Kind.float64.size());
    try std.testing.expect(Kind.float32.isFloat());
    try std.testing.expect(!Kind.int64.isFloat());
    try std.testing.expectEqual(Kind.int32, Kind.parse("int32").?);
    try std.testing.expectEqual(@as(?Kind, null), Kind.parse("u32"));
}

test "encode all types" {
    const i64v = try encode(.int64, "-9223372036854775808");
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), std.mem.readInt(i64, i64v.bytes[0..8], .little));

    const f32v = try encode(.float32, "1.5");
    const f32bits = std.mem.readInt(u32, f32v.bytes[0..4], .little);
    try std.testing.expectEqual(@as(f32, 1.5), @as(f32, @bitCast(f32bits)));

    const f64v = try encode(.float64, "-2.25");
    const f64bits = std.mem.readInt(u64, f64v.bytes[0..8], .little);
    try std.testing.expectEqual(@as(f64, -2.25), @as(f64, @bitCast(f64bits)));
}

test "fmtValue prints integers" {
    var buf: [48]u8 = undefined;
    const v = try encode(.int32, "42");
    try std.testing.expectEqualStrings("42", fmtValue(.int32, v.bytes[0..4], &buf));
    const big = try encode(.int64, "-1234567890123");
    try std.testing.expectEqualStrings("-1234567890123", fmtValue(.int64, big.bytes[0..8], &buf));
}

test "cmpVal orders values and rejects NaN" {
    const one = try encode(.int32, "1");
    const two = try encode(.int32, "2");
    try std.testing.expectEqual(std.math.Order.lt, cmpVal(.int32, one.bytes[0..4], two.bytes[0..4]).?);
    try std.testing.expectEqual(std.math.Order.gt, cmpVal(.int32, two.bytes[0..4], one.bytes[0..4]).?);
    try std.testing.expectEqual(std.math.Order.eq, cmpVal(.int32, one.bytes[0..4], one.bytes[0..4]).?);

    var nan: Value = .{};
    std.mem.writeInt(u32, nan.bytes[0..4], 0x7FC00000, .little);
    const onef = try encode(.float32, "1");
    try std.testing.expectEqual(@as(?std.math.Order, null), cmpVal(.float32, nan.bytes[0..4], onef.bytes[0..4]));
}

test "all scan conditions" {
    const cur = try encode(.int32, "15");
    const old = try encode(.int32, "10");
    const v10 = try encode(.int32, "10");
    const v20 = try encode(.int32, "20");
    const cs = cur.bytes[0..4];
    const os = old.bytes[0..4];

    var c: Cond = .{ .mode = .unknown };
    try std.testing.expect(check(.int32, cs, os, &c));
    c = .{ .mode = .changed };
    try std.testing.expect(check(.int32, cs, os, &c));
    c = .{ .mode = .unchanged };
    try std.testing.expect(!check(.int32, cs, os, &c));
    c = .{ .mode = .increased };
    try std.testing.expect(check(.int32, cs, os, &c));
    c = .{ .mode = .decreased };
    try std.testing.expect(!check(.int32, cs, os, &c));
    c = .{ .mode = .exact, .a = v10 };
    try std.testing.expect(!check(.int32, cs, os, &c));
    c = .{ .mode = .greater, .a = v10 };
    try std.testing.expect(check(.int32, cs, os, &c));
    c = .{ .mode = .less, .a = v20 };
    try std.testing.expect(check(.int32, cs, os, &c));
    c = .{ .mode = .between, .a = v10, .b = v20 };
    try std.testing.expect(check(.int32, cs, os, &c));
    c = .{ .mode = .between, .a = v20, .b = v10 };
    try std.testing.expect(!check(.int32, cs, os, &c));
}

test "int8 and int16 roundtrip, format, and compare" {
    const small = try encode(.int8, "-128");
    try std.testing.expectEqual(@as(i8, -128), std.mem.readInt(i8, small.bytes[0..1], .little));
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("-128", fmtValue(.int8, small.bytes[0..1], &buf));

    const wide = try encode(.int16, "32767");
    try std.testing.expectEqualStrings("32767", fmtValue(.int16, wide.bytes[0..2], &buf));

    const lo = try encode(.int16, "-2");
    const hi = try encode(.int16, "3");
    try std.testing.expectEqual(std.math.Order.lt, cmpVal(.int16, lo.bytes[0..2], hi.bytes[0..2]).?);

    var c: Cond = .{ .mode = .exact, .a = small };
    try std.testing.expect(check(.int8, small.bytes[0..1], small.bytes[0..1], &c));
    try std.testing.expectEqual(@as(usize, 1), Kind.int8.size());
    try std.testing.expectEqual(Kind.int16, Kind.parse("int16").?);
}

test "regionSpan clamps to the range and keeps alignment" {
    const span = regionSpan(.{ .start = 0x1003, .end = 0x1800 }, 0x1000, 0x1000, 4, 4).?;
    try std.testing.expectEqual(@as(usize, 4), span.off);
    try std.testing.expectEqual(@as(usize, 0x7FF), span.len);

    const single = regionSpan(.{ .start = 0x1010, .end = 0x1011 }, 0x1000, 0x1000, 4, 4).?;
    try std.testing.expectEqual(@as(usize, 0x10), single.off);
    try std.testing.expectEqual(@as(usize, 4), single.len);

    try std.testing.expectEqual(@as(?Span, null), regionSpan(.{ .start = 0x3000, .end = 0x4000 }, 0x1000, 0x1000, 4, 4));
    try std.testing.expectEqual(@as(?Span, null), regionSpan(.{ .start = 0x1000, .end = 0x1000 }, 0x1000, 0x1000, 4, 4));
}

test "regionSpan supports byte alignment" {
    const span = regionSpan(.{ .start = 0x1003, .end = 0x1800 }, 0x1000, 0x1000, 1, 8).?;
    try std.testing.expectEqual(@as(usize, 3), span.off);
    try std.testing.expectEqual(@as(usize, 0x804), span.len);
}

test "float exact respects tolerance" {
    var c: Cond = .{ .mode = .exact };
    c.a = try encode(.float32, "76.5");
    c.tol = 0.05;
    const near = try encode(.float32, "76.52");
    const far = try encode(.float32, "76.6");
    try std.testing.expect(check(.float32, near.bytes[0..4], near.bytes[0..4], &c));
    try std.testing.expect(!check(.float32, far.bytes[0..4], far.bytes[0..4], &c));

    c.tol = 0;
    try std.testing.expect(!check(.float32, near.bytes[0..4], near.bytes[0..4], &c));
}

test "unsigned types encode, format, and compare" {
    const v = try encode(.uint32, "0xFFFFFFFE");
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFE), std.mem.readInt(u32, v.bytes[0..4], .little));
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("4294967294", fmtValue(.uint32, v.bytes[0..4], &buf));

    const top = try encode(.uint64, "18446744073709551615");
    try std.testing.expectEqual(std.math.maxInt(u64), std.mem.readInt(u64, top.bytes[0..8], .little));

    const lo = try encode(.uint8, "5");
    const hi = try encode(.uint8, "250");
    try std.testing.expectEqual(std.math.Order.lt, cmpVal(.uint8, lo.bytes[0..1], hi.bytes[0..1]).?);
    try std.testing.expectEqual(std.math.Order.gt, cmpVal(.uint8, hi.bytes[0..1], lo.bytes[0..1]).?);

    try std.testing.expectEqual(Kind.uint16, Kind.parse("uint16").?);
    try std.testing.expectEqual(@as(usize, 8), Kind.uint64.size());
    try std.testing.expectError(error.Overflow, encode(.uint8, "-1"));
}

test "integer values accept hex literals" {
    const signed = try encode(.int32, "-0x10");
    try std.testing.expectEqual(@as(i32, -16), std.mem.readInt(i32, signed.bytes[0..4], .little));

    const wide = try encode(.uint64, "0xFFFF_FFFF_FFFF_FFFF");
    try std.testing.expectEqual(std.math.maxInt(u64), std.mem.readInt(u64, wide.bytes[0..8], .little));

    const small = try encode(.int16, "0x7FFF");
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("32767", fmtValue(.int16, small.bytes[0..2], &buf));
}

test "scanBlock finds values at unaligned offsets" {
    const a = std.testing.allocator;
    var sc: Scanner = .{};
    defer sc.deinit(a);

    const cond: Cond = .{ .mode = .exact, .a = try encode(.uint32, "0x11223344") };
    var buf = std.mem.zeroes([16]u8);
    std.mem.writeInt(u32, buf[1..5], 0x11223344, .little);
    std.mem.writeInt(u32, buf[7..11], 0x11223344, .little);

    const truncated = try sc.scanBlock(a, .uint32, cond, buf[0..12], 0x1000, 1, 12);
    try std.testing.expect(!truncated);
    try std.testing.expectEqual(@as(usize, 2), sc.matches.items.len);
    try std.testing.expectEqual(@as(usize, 0x1001), sc.matches.items[0].addr);
    try std.testing.expectEqual(@as(usize, 0x1007), sc.matches.items[1].addr);
}

test "scanBlock honors the stride" {
    const a = std.testing.allocator;
    const cond: Cond = .{ .mode = .exact, .a = try encode(.uint32, "7") };

    var aligned = std.mem.zeroes([16]u8);
    std.mem.writeInt(u32, aligned[4..8], 7, .little);
    var sc1: Scanner = .{};
    defer sc1.deinit(a);
    _ = try sc1.scanBlock(a, .uint32, cond, &aligned, 0x2000, 4, aligned.len);
    try std.testing.expectEqual(@as(usize, 1), sc1.matches.items.len);
    try std.testing.expectEqual(@as(usize, 0x2004), sc1.matches.items[0].addr);

    var unaligned = std.mem.zeroes([16]u8);
    std.mem.writeInt(u32, unaligned[5..9], 7, .little);
    var sc2: Scanner = .{};
    defer sc2.deinit(a);
    _ = try sc2.scanBlock(a, .uint32, cond, &unaligned, 0x3000, 4, unaligned.len);
    try std.testing.expectEqual(@as(usize, 0), sc2.matches.items.len);
    _ = try sc2.scanBlock(a, .uint32, cond, &unaligned, 0x3000, 1, unaligned.len);
    try std.testing.expectEqual(@as(usize, 1), sc2.matches.items.len);
    try std.testing.expectEqual(@as(usize, 0x3005), sc2.matches.items[0].addr);
}

test "parseBytePattern accepts wildcards and rejects junk" {
    var pb: [max_value_len]u8 = undefined;
    var mb: [max_value_len]u8 = undefined;
    const p = try parseBytePattern("48 8B ? ?? 0x89", &pb, &mb);
    try std.testing.expectEqual(@as(usize, 5), p.bytes.len);
    try std.testing.expectEqualStrings("\x48\x8b\x00\x00\x89", p.bytes);
    try std.testing.expectEqualStrings("\x01\x01\x00\x00\x01", p.mask);
    try std.testing.expectError(error.InvalidPattern, parseBytePattern("", &pb, &mb));
    try std.testing.expectError(error.InvalidPattern, parseBytePattern("zz", &pb, &mb));
    try std.testing.expectError(error.PatternTooLong, parseBytePattern("00 00 00", &pb, mb[0..2]));
}

test "string encoding roundtrip" {
    var out: [max_value_len]u8 = undefined;
    const utf8 = try encodeText(.utf8, "health", &out);
    try std.testing.expectEqualStrings("health", utf8);
    var back: [max_value_len]u8 = undefined;
    try std.testing.expectEqualStrings("health", decodeText(.utf8, utf8, &back).?);

    const utf16 = try encodeText(.utf16le, "hp", &out);
    try std.testing.expectEqualStrings("h\x00p\x00", utf16);
    try std.testing.expectEqualStrings("hp", decodeText(.utf16le, utf16, &back).?);

    try std.testing.expectError(error.InvalidPattern, encodeText(.utf8, "\xff", &out));
}

test "scanBlock matches string and byte patterns" {
    const a = std.testing.allocator;
    var buf: [32]u8 = undefined;
    @memset(buf[0..], 0);
    @memcpy(buf[3..9], "needle");
    buf[16] = 0x48;
    buf[17] = 0x8B;
    buf[18] = 0x90;
    buf[19] = 0x7F;
    buf[20] = 0x89;

    var string_cond: Cond = .{ .mode = .exact };
    try string_cond.setText("needle");
    var sc: Scanner = .{};
    defer sc.deinit(a);
    _ = try sc.scanBlock(a, .string, string_cond, &buf, 0x1000, 1, buf.len);
    try std.testing.expectEqual(@as(usize, 1), sc.matches.items.len);
    try std.testing.expectEqual(@as(usize, 0x1003), sc.matches.items[0].addr);
    try std.testing.expectEqualStrings("needle", sc.valueAt(0));

    var bytes_cond: Cond = .{ .mode = .exact };
    try bytes_cond.setBytePattern("48 8B ?? ?? 89");
    var sc2: Scanner = .{};
    defer sc2.deinit(a);
    _ = try sc2.scanBlock(a, .bytes, bytes_cond, &buf, 0x2000, 1, buf.len);
    try std.testing.expectEqual(@as(usize, 1), sc2.matches.items.len);
    try std.testing.expectEqual(@as(usize, 0x2010), sc2.matches.items[0].addr);
    try std.testing.expectEqualStrings("\x48\x8b\x90\x7f\x89", sc2.valueAt(0));
}

test "variable conditions compare against the stored value" {
    var c: Cond = .{ .mode = .changed };
    try std.testing.expect(check(.string, "ab", "aa", &c));
    try std.testing.expect(!check(.string, "ab", "ab", &c));
    c.mode = .unchanged;
    try std.testing.expect(check(.string, "ab", "ab", &c));
    c.mode = .greater;
    try std.testing.expect(!check(.string, "ab", "aa", &c));
}

test "fmtValueAny formats strings and bytes" {
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("hi", fmtValueAny(.string, .utf8, "hi", &buf));
    try std.testing.expectEqualStrings("hi", fmtValueAny(.string, .utf16le, "h\x00i\x00", &buf));
    try std.testing.expectEqualStrings("488b9000", fmtValueAny(.bytes, .utf8, "\x48\x8b\x90\x00", &buf));
}
