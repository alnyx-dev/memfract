const std = @import("std");
const win = @import("win.zig");
const scan = @import("scan.zig");

pub const max_depth = 32;
pub const default_max_depth = 3;
pub const default_max_offset: u64 = 0x1000;
pub const default_max_results: usize = 1000;
pub const max_results_limit: usize = 10_000;
pub const max_slots: usize = 8_000_000;
pub const max_steps: usize = 2_000_000;

const chunk_size = 1 << 20;
const page_size = 4096;
const ptr_size = 8;

/// A chain in the form `--addr` and `--offsets` accept: the first pointer lives at
/// `base`, every offset is added after one dereference, and the last one lands on the
/// scanned address.
pub const Chain = struct {
    base: usize,
    len: u8 = 0,
    offsets: [max_depth]i64 = @splat(0),

    pub fn offsetsSlice(self: *const Chain) []const i64 {
        return self.offsets[0..self.len];
    }
};

/// Sorted by `base`: `search` binary-searches it for every candidate slot.
pub const StaticRange = struct {
    base: usize,
    size: usize,
};

pub const Options = struct {
    target: usize,
    max_depth: usize = default_max_depth,
    max_offset: u64 = default_max_offset,
    max_results: usize = default_max_results,
};

pub const Result = struct {
    target: usize = 0,
    chains: std.ArrayList(Chain) = .empty,
    slots: usize = 0,
    bytes_read: u64 = 0,
    truncated: bool = false,
    canceled: bool = false,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        self.chains.deinit(gpa);
    }
};

const Slot = struct {
    value: u64,
    addr: usize,
};

const Range = struct {
    base: usize,
    end: usize,
};

const Index = struct {
    slots: std.ArrayList(Slot) = .empty,
    ranges: std.ArrayList(Range) = .empty,
    bytes_read: u64 = 0,
    truncated: bool = false,
    canceled: bool = false,

    fn deinit(self: *Index, gpa: std.mem.Allocator) void {
        self.slots.deinit(gpa);
        self.ranges.deinit(gpa);
    }

    fn inRanges(self: *const Index, value: u64) bool {
        const v: usize = @intCast(value);
        var lo: usize = 0;
        var hi: usize = self.ranges.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const r = self.ranges.items[mid];
            if (v < r.base) {
                hi = mid;
            } else if (v - r.base < r.end - r.base) {
                return true;
            } else {
                lo = mid + 1;
            }
        }
        return false;
    }

    fn addSlot(self: *Index, gpa: std.mem.Allocator, value: u64, addr: usize) !void {
        if (value == 0 or !self.inRanges(value)) return;
        if (self.slots.items.len >= max_slots) {
            self.truncated = true;
            return;
        }
        try self.slots.append(gpa, .{ .value = value, .addr = addr });
    }

    fn collect(self: *Index, gpa: std.mem.Allocator, bytes: []const u8, base: usize) !void {
        var i: usize = 0;
        while (i + ptr_size <= bytes.len) : (i += ptr_size) {
            const v = std.mem.readInt(u64, bytes[i..][0..ptr_size], .little);
            try self.addSlot(gpa, v, base + i);
            if (self.truncated) return;
        }
    }

    fn scanRegion(
        self: *Index,
        gpa: std.mem.Allocator,
        source: scan.Source,
        base: usize,
        size: usize,
        buf: []u8,
    ) !void {
        const end, const overflow = @addWithOverflow(base, size);
        if (overflow != 0) return;
        const aligned = std.mem.alignForward(usize, base, ptr_size);
        if (aligned >= end) return;

        var off = aligned - base;
        while (off < size) {
            if (self.truncated or self.canceled) return;
            if (scan.cancel_flag.load(.acquire)) {
                self.canceled = true;
                return;
            }

            const n = @min(chunk_size, size - off);
            const addr = base + off;
            if (source.read(addr, buf[0..n])) |_| {
                self.bytes_read += n;
                try self.collect(gpa, buf[0..n], addr);
            } else |_| {
                var po: usize = 0;
                while (po < n) : (po += page_size) {
                    if (self.truncated or self.canceled) return;
                    const pn = @min(page_size, n - po);
                    if (source.read(addr + po, buf[po..][0..pn])) |_| {
                        self.bytes_read += pn;
                        try self.collect(gpa, buf[po..][0..pn], addr + po);
                    } else |_| {}
                }
            }
            off += n;
        }
    }
};

fn rangeLess(_: void, a: Range, b: Range) bool {
    return a.base < b.base;
}

fn slotLess(_: void, a: Slot, b: Slot) bool {
    return a.value < b.value;
}

fn buildIndex(gpa: std.mem.Allocator, source: scan.Source) !Index {
    var idx: Index = .{};
    errdefer idx.deinit(gpa);

    var regs = try source.regions(gpa, false);
    defer regs.deinit(gpa);

    for (regs.items) |r| {
        if (r.size == 0) continue;
        const end, const overflow = @addWithOverflow(r.base, r.size);
        if (overflow != 0) continue;
        try idx.ranges.append(gpa, .{ .base = r.base, .end = end });
    }
    std.sort.pdq(Range, idx.ranges.items, {}, rangeLess);

    const buf = try gpa.alloc(u8, chunk_size);
    defer gpa.free(buf);

    for (regs.items) |r| {
        if (idx.truncated or idx.canceled) break;
        try idx.scanRegion(gpa, source, r.base, r.size, buf);
    }
    return idx;
}

fn firstAtLeast(slots: []const Slot, value: u64) usize {
    var lo: usize = 0;
    var hi: usize = slots.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (slots[mid].value < value) lo = mid + 1 else hi = mid;
    }
    return lo;
}

fn inStatic(ranges: []const StaticRange, addr: usize) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (addr < r.base) {
            hi = mid;
        } else if (addr - r.base < r.size) {
            return true;
        } else {
            lo = mid + 1;
        }
    }
    return false;
}

const no_parent = std.math.maxInt(usize);

const Step = struct {
    cur: usize,
    parent: usize,
    offset: i64,
    depth: usize,
};

fn inPath(steps: []const Step, from: usize, addr: usize) bool {
    var i = from;
    while (true) {
        if (steps[i].cur == addr) return true;
        if (steps[i].parent == no_parent) return false;
        i = steps[i].parent;
    }
}

fn emitChain(out: *Result, gpa: std.mem.Allocator, steps: []const Step, from: usize, base: usize, offset: i64) !void {
    var chain: Chain = .{ .base = base };
    chain.offsets[chain.len] = offset;
    chain.len += 1;

    var i = from;
    while (i != no_parent) {
        if (steps[i].parent == no_parent) break;
        chain.offsets[chain.len] = steps[i].offset;
        chain.len += 1;
        i = steps[i].parent;
    }
    try out.chains.append(gpa, chain);
}

fn search(
    gpa: std.mem.Allocator,
    slots: []Slot,
    static_ranges: []const StaticRange,
    opts: Options,
    out: *Result,
) !void {
    std.sort.pdq(Slot, slots, {}, slotLess);

    var steps: std.ArrayList(Step) = .empty;
    defer steps.deinit(gpa);
    try steps.append(gpa, .{ .cur = opts.target, .parent = no_parent, .offset = 0, .depth = 0 });

    var head: usize = 0;
    var stop = false;
    while (head < steps.items.len and !stop) : (head += 1) {
        if (out.chains.items.len >= opts.max_results) {
            out.truncated = true;
            break;
        }
        if (scan.cancel_flag.load(.acquire)) {
            out.canceled = true;
            break;
        }

        const rec = steps.items[head];
        if (rec.depth >= opts.max_depth) continue;

        const cur: u64 = @intCast(rec.cur);
        const lo = cur -| opts.max_offset;
        const hi = cur +| opts.max_offset;
        var i = firstAtLeast(slots, lo);
        while (i < slots.len and slots[i].value <= hi) : (i += 1) {
            if (out.chains.items.len >= opts.max_results) {
                out.truncated = true;
                stop = true;
                break;
            }

            const slot = slots[i];
            const offset = @as(i64, @intCast(rec.cur)) - @as(i64, @intCast(slot.value));
            if (inStatic(static_ranges, slot.addr)) {
                try emitChain(out, gpa, steps.items, head, slot.addr, offset);
            } else if (rec.depth + 1 < opts.max_depth and !inPath(steps.items, head, slot.addr)) {
                if (steps.items.len >= max_steps) {
                    out.truncated = true;
                    stop = true;
                    break;
                }
                try steps.append(gpa, .{
                    .cur = slot.addr,
                    .parent = head,
                    .offset = offset,
                    .depth = rec.depth + 1,
                });
            }
        }
    }
}

pub fn find(gpa: std.mem.Allocator, source: scan.Source, static_ranges: []const StaticRange, opts: Options) !Result {
    var out: Result = .{ .target = opts.target };
    errdefer out.deinit(gpa);

    var idx = try buildIndex(gpa, source);
    defer idx.deinit(gpa);

    out.slots = idx.slots.items.len;
    out.bytes_read = idx.bytes_read;
    out.truncated = idx.truncated;
    out.canceled = idx.canceled;
    if (out.canceled) return out;

    try search(gpa, idx.slots.items, static_ranges, opts, &out);
    return out;
}

pub fn resolve(source: scan.Source, chain: Chain) !usize {
    var addr = chain.base;
    for (chain.offsetsSlice()) |off| {
        var raw: [ptr_size]u8 = undefined;
        try source.read(addr, &raw);
        const ptr = std.mem.readInt(u64, &raw, .little);
        addr = @intCast(ptr +% @as(u64, @bitCast(off)));
    }
    return addr;
}

const TestMem = struct {
    bases: [2]usize = .{ 0x1000, 0x10000 },
    mem: [2][]u8,

    fn readFn(ctx: *anyopaque, addr: usize, dst: []u8) bool {
        const self: *TestMem = @ptrCast(@alignCast(ctx));
        for (self.mem, 0..) |m, i| {
            const base = self.bases[i];
            if (addr >= base and addr - base <= m.len and dst.len <= m.len - (addr - base)) {
                @memcpy(dst, m[addr - base ..][0..dst.len]);
                return true;
            }
        }
        return false;
    }

    fn regionsFn(ctx: *anyopaque, gpa: std.mem.Allocator, writable_only: bool) anyerror!std.ArrayList(win.Region) {
        _ = writable_only;
        const self: *TestMem = @ptrCast(@alignCast(ctx));
        var list: std.ArrayList(win.Region) = .empty;
        for (self.mem, 0..) |m, i| {
            try list.append(gpa, .{ .base = self.bases[i], .size = m.len, .protect = 0x04, .mem_type = 0x20000 });
        }
        return list;
    }

    fn source(self: *const TestMem) scan.Source {
        return .{ .ctx = @constCast(self), .readFn = readFn, .regionsFn = regionsFn };
    }
};

fn writePtr(mem: []u8, off: usize, value: usize) void {
    std.mem.writeInt(u64, mem[off..][0..8], @intCast(value), .little);
}

fn testMem(a: std.mem.Allocator) !TestMem {
    var mem: TestMem = .{ .mem = undefined };
    mem.mem[0] = try a.alloc(u8, 0x1000);
    errdefer a.free(mem.mem[0]);
    mem.mem[1] = try a.alloc(u8, 0x2000);
    @memset(mem.mem[0], 0);
    @memset(mem.mem[1], 0);
    return mem;
}

const test_static = [_]StaticRange{.{ .base = 0x1000, .size = 0x1000 }};

fn chainForTest(a: std.mem.Allocator) !TestMem {
    const mem = try testMem(a);
    writePtr(mem.mem[0], 0x10, 0x10F00);
    writePtr(mem.mem[0], 0x20, 0x10400);
    writePtr(mem.mem[1], 0x440, 0x10F80);
    return mem;
}

test "pointer scan finds one- and two-step chains" {
    const a = std.testing.allocator;
    const mem = try chainForTest(a);
    defer a.free(mem.mem[0]);
    defer a.free(mem.mem[1]);

    var res = try find(a, mem.source(), &test_static, .{ .target = 0x11000, .max_depth = 2, .max_offset = 0x100 });
    defer res.deinit(a);

    try std.testing.expectEqual(@as(usize, 2), res.chains.items.len);
    try std.testing.expect(!res.truncated);
    try std.testing.expect(!res.canceled);
    try std.testing.expect(res.slots >= 3);

    const direct = res.chains.items[0];
    try std.testing.expectEqual(@as(usize, 0x1010), direct.base);
    try std.testing.expectEqual(@as(u8, 1), direct.len);
    try std.testing.expectEqual(@as(i64, 0x100), direct.offsets[0]);

    const nested = res.chains.items[1];
    try std.testing.expectEqual(@as(usize, 0x1020), nested.base);
    try std.testing.expectEqual(@as(u8, 2), nested.len);
    try std.testing.expectEqual(@as(i64, 0x40), nested.offsets[0]);
    try std.testing.expectEqual(@as(i64, 0x80), nested.offsets[1]);

    for (res.chains.items) |chain| {
        try std.testing.expectEqual(@as(usize, 0x11000), try resolve(mem.source(), chain));
    }
}

test "pointer scan honors depth, offset, result and module limits" {
    const a = std.testing.allocator;
    const mem = try chainForTest(a);
    defer a.free(mem.mem[0]);
    defer a.free(mem.mem[1]);

    var shallow = try find(a, mem.source(), &test_static, .{ .target = 0x11000, .max_depth = 1, .max_offset = 0x100 });
    defer shallow.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), shallow.chains.items.len);
    try std.testing.expectEqual(@as(usize, 0x1010), shallow.chains.items[0].base);

    var tight = try find(a, mem.source(), &test_static, .{ .target = 0x11000, .max_depth = 2, .max_offset = 0x80 });
    defer tight.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), tight.chains.items.len);
    try std.testing.expectEqual(@as(usize, 0x1020), tight.chains.items[0].base);

    var limited = try find(a, mem.source(), &test_static, .{ .target = 0x11000, .max_depth = 2, .max_offset = 0x100, .max_results = 1 });
    defer limited.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), limited.chains.items.len);
    try std.testing.expect(limited.truncated);

    const other = [_]StaticRange{.{ .base = 0x3000, .size = 0x1000 }};
    var filtered = try find(a, mem.source(), &other, .{ .target = 0x11000, .max_depth = 2, .max_offset = 0x100 });
    defer filtered.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), filtered.chains.items.len);
}

test "pointer scan skips cycles" {
    const a = std.testing.allocator;
    const mem = try testMem(a);
    defer a.free(mem.mem[0]);
    defer a.free(mem.mem[1]);
    writePtr(mem.mem[1], 0x500, 0x10600);
    writePtr(mem.mem[1], 0x600, 0x10500);

    var res = try find(a, mem.source(), &test_static, .{ .target = 0x11000, .max_depth = 4, .max_offset = 0x1000 });
    defer res.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), res.chains.items.len);
}

test "pointer resolve follows the chain in order" {
    const a = std.testing.allocator;
    const mem = try chainForTest(a);
    defer a.free(mem.mem[0]);
    defer a.free(mem.mem[1]);

    var chain: Chain = .{ .base = 0x1020, .len = 2 };
    chain.offsets[0] = 0x40;
    chain.offsets[1] = 0x80;
    try std.testing.expectEqual(@as(usize, 0x11000), try resolve(mem.source(), chain));

    chain.base = 0x1010;
    chain.len = 1;
    chain.offsets[0] = 0x100;
    try std.testing.expectEqual(@as(usize, 0x11000), try resolve(mem.source(), chain));

    chain.base = 0x5000;
    try std.testing.expectError(error.ReadFailed, resolve(mem.source(), chain));
}
