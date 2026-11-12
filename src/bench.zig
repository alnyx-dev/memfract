const std = @import("std");
const scan = @import("scan.zig");
const win = @import("win.zig");

const gpa = std.heap.page_allocator;
const needle: u32 = 0xDEADBEEF;

const Backing = struct {
    base: usize,
    mem: []u8,
};

const Synthetic = struct {
    backings: []Backing,

    fn readFn(ctx: *anyopaque, addr: usize, dst: []u8) bool {
        const self: *Synthetic = @ptrCast(@alignCast(ctx));
        for (self.backings) |b| {
            if (addr >= b.base and addr - b.base <= b.mem.len and dst.len <= b.mem.len - (addr - b.base)) {
                @memcpy(dst, b.mem[addr - b.base ..][0..dst.len]);
                return true;
            }
        }
        return false;
    }

    fn regionsFn(ctx: *anyopaque, alloc: std.mem.Allocator, writable_only: bool) anyerror!std.ArrayList(win.Region) {
        _ = writable_only;
        const self: *Synthetic = @ptrCast(@alignCast(ctx));
        var list: std.ArrayList(win.Region) = .empty;
        errdefer list.deinit(alloc);
        for (self.backings) |b| {
            try list.append(alloc, .{ .base = b.base, .size = b.mem.len, .protect = 0x04, .mem_type = 0x20000 });
        }
        return list;
    }

    fn source(self: *Synthetic) scan.Source {
        return .{ .ctx = self, .readFn = readFn, .regionsFn = regionsFn };
    }
};

const Sample = struct {
    ticks: i64,
    stats: scan.Stats,
    count: usize,
};

const Config = struct {
    mb: usize = 128,
    rounds: usize = 3,
    threads: usize = 0,
    regions: usize = 16,
    density: usize = 4096,
};

pub fn main() !void {
    const argv = try win.argsAlloc(gpa);
    const cfg = parseConfig(argv) catch |e| {
        if (e == error.HelpRequested) return;
        std.debug.print("bad arguments; run with --help\n", .{});
        return e;
    };
    const total_bytes = cfg.mb * 1024 * 1024;
    const per = (total_bytes / cfg.regions) & ~@as(usize, 4095);
    if (per < 4096) {
        std.debug.print("too little memory per region; lower --regions or raise --mb\n", .{});
        return error.BadArgs;
    }

    var synth = Synthetic{ .backings = try gpa.alloc(Backing, cfg.regions) };
    defer gpa.free(synth.backings);
    defer for (synth.backings) |b| gpa.free(b.mem);

    var planted: usize = 0;
    for (synth.backings, 0..) |*b, i| {
        const mem = try gpa.alloc(u8, per);
        b.* = .{ .base = 0x1000_0000 + i * (per + 0x10_0000), .mem = mem };
        planted += fillRegion(mem, @intCast(i + 1), cfg.density);
    }
    const cond: scan.Cond = .{ .mode = .exact, .a = encodeNeedle() };
    const bytes: u64 = @intCast(per * cfg.regions);

    std.debug.print(
        "synthetic: {d} MiB over {d} regions, {d} int32 values planted every {d} bytes\n",
        .{ bytes / (1024 * 1024), cfg.regions, planted, cfg.density },
    );

    const baseline = measureBaseline(synth.backings);
    if (baseline.count != planted) {
        std.debug.print("baseline counted {d} matches, expected {d}\n", .{ baseline.count, planted });
        return error.Mismatch;
    }
    std.debug.print(
        "reference: scalar read pass, {d} matches, {d:.1} ms ({d:.0} MiB/s)\n",
        .{ baseline.count, millis(baseline.ticks), mibPerSec(bytes, baseline.ticks) },
    );

    var sc: scan.Scanner = .{};
    defer sc.deinit(gpa);

    var best_aligned: f64 = 0;
    var round: usize = 1;
    while (round <= cfg.rounds) : (round += 1) {
        planted = refill(synth.backings, cfg.density);

        const aligned = try timeScan(&sc, synth.source(), cond, 4, cfg.threads);
        if (aligned.count != planted) {
            std.debug.print("aligned scan found {d} matches, expected {d}\n", .{ aligned.count, planted });
            return error.Mismatch;
        }

        const changed = mutateHalf(synth.backings, cfg.density);
        const t0 = win.perfCounter();
        const canceled = sc.nextSource(synth.source(), .{ .mode = .changed });
        const next = Sample{ .ticks = win.perfCounter() - t0, .stats = sc.stats, .count = sc.matches.items.len };
        if (canceled or next.count != changed) {
            std.debug.print("next kept {d} matches, expected {d}\n", .{ next.count, changed });
            return error.Mismatch;
        }

        _ = refill(synth.backings, cfg.density);
        const unaligned = try timeScan(&sc, synth.source(), cond, 1, cfg.threads);

        const rate = mibPerSec(bytes, aligned.ticks);
        if (rate > best_aligned) best_aligned = rate;
        std.debug.print(
            "round {d}: aligned {d:.1} ms ({d:.0} MiB/s, {d} threads, {d} matches), next {d:.1} ms ({d} matches, {d:.0} KiB read), unaligned {d:.1} ms ({d:.0} MiB/s, {d} matches)\n",
            .{
                round,
                millis(aligned.ticks),
                rate,
                aligned.stats.threads,
                aligned.count,
                millis(next.ticks),
                next.count,
                @as(f64, @floatFromInt(next.stats.bytes_read)) / 1024.0,
                millis(unaligned.ticks),
                mibPerSec(bytes, unaligned.ticks),
                unaligned.count,
            },
        );
    }

    if (cfg.threads == 0) {
        std.debug.print("best aligned: {d:.0} MiB/s with auto threads\n", .{best_aligned});
    } else {
        std.debug.print("best aligned: {d:.0} MiB/s with {d} threads\n", .{ best_aligned, cfg.threads });
    }
}

fn parseConfig(argv: []const []const u8) !Config {
    var cfg: Config = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                "usage: memfract-bench [--mb N] [--rounds N] [--threads N] [--regions N] [--density BYTES]\n",
                .{},
            );
            return error.HelpRequested;
        }
        if (i + 1 >= argv.len) return error.BadArgs;
        const value = argv[i + 1];
        i += 1;
        if (std.mem.eql(u8, arg, "--mb")) {
            cfg.mb = try number(value, 1, 8192);
        } else if (std.mem.eql(u8, arg, "--rounds")) {
            cfg.rounds = try number(value, 1, 50);
        } else if (std.mem.eql(u8, arg, "--threads")) {
            cfg.threads = try number(value, 0, scan.max_threads);
        } else if (std.mem.eql(u8, arg, "--regions")) {
            cfg.regions = try number(value, 1, 64);
        } else if (std.mem.eql(u8, arg, "--density")) {
            const n = try number(value, 4, 1 << 20);
            cfg.density = n & ~@as(usize, 3);
        } else {
            return error.BadArgs;
        }
    }
    return cfg;
}

fn number(text: []const u8, lo: usize, hi: usize) !usize {
    const n = std.fmt.parseInt(usize, text, 0) catch return error.BadArgs;
    if (n < lo or n > hi) return error.BadArgs;
    return n;
}

fn encodeNeedle() scan.Value {
    var v: scan.Value = .{};
    std.mem.writeInt(u32, v.bytes[0..4], needle, .little);
    return v;
}

fn fillRegion(mem: []u8, seed: u32, density: usize) usize {
    var state = seed | 1;
    var off: usize = 0;
    while (off + 4 <= mem.len) : (off += 4) {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        const v = if (state == needle) state ^ 1 else state;
        std.mem.writeInt(u32, mem[off..][0..4], v, .little);
    }
    var planted: usize = 0;
    off = 0;
    while (off + 4 <= mem.len) : (off += density) {
        std.mem.writeInt(u32, mem[off..][0..4], needle, .little);
        planted += 1;
    }
    return planted;
}

fn refill(backings: []const Backing, density: usize) usize {
    var planted: usize = 0;
    for (backings, 0..) |b, i| planted += fillRegion(b.mem, @intCast(i + 1), density);
    return planted;
}

fn mutateHalf(backings: []const Backing, density: usize) usize {
    var changed: usize = 0;
    for (backings) |b| {
        var off: usize = 0;
        var idx: usize = 0;
        while (off + 4 <= b.mem.len) : (off += density) {
            if (idx % 2 == 0) {
                std.mem.writeInt(u32, b.mem[off..][0..4], needle ^ 1, .little);
                changed += 1;
            }
            idx += 1;
        }
    }
    return changed;
}

fn timeScan(sc: *scan.Scanner, source: scan.Source, cond: scan.Cond, alignment: usize, threads: usize) !Sample {
    const t0 = win.perfCounter();
    try sc.firstSource(gpa, source, .uint32, cond, true, .{}, alignment, threads);
    return .{ .ticks = win.perfCounter() - t0, .stats = sc.stats, .count = sc.matches.items.len };
}

fn measureBaseline(backings: []const Backing) Sample {
    const t0 = win.perfCounter();
    var count: usize = 0;
    for (backings) |b| {
        var off: usize = 0;
        while (off + 4 <= b.mem.len) : (off += 4) {
            if (std.mem.readInt(u32, b.mem[off..][0..4], .little) == needle) count += 1;
        }
    }
    return .{ .ticks = win.perfCounter() - t0, .stats = .{}, .count = count };
}

fn millis(ticks: i64) f64 {
    return @as(f64, @floatFromInt(ticks)) * 1000.0 / @as(f64, @floatFromInt(win.perfFrequency()));
}

fn mibPerSec(bytes: u64, ticks: i64) f64 {
    const seconds = @as(f64, @floatFromInt(ticks)) / @as(f64, @floatFromInt(win.perfFrequency()));
    if (seconds <= 0) return 0;
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0) / seconds;
}
