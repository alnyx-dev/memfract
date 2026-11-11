const std = @import("std");
const win = @import("win.zig");
const scan = @import("scan.zig");
const json = @import("json.zig");
const util = @import("util.zig");

const gpa = std.heap.page_allocator;
const version = @import("version.zig").string;

extern "kernel32" fn ExitProcess(code: u32) callconv(.winapi) noreturn;
extern "kernel32" fn SetConsoleOutputCP(cp: u32) callconv(.winapi) i32;
const CtrlHandler = *const fn (ctrl_type: u32) callconv(.winapi) i32;
extern "kernel32" fn SetConsoleCtrlHandler(handler: ?CtrlHandler, add: i32) callconv(.winapi) i32;
extern "kernel32" fn GetTempPathW(n: u32, buf: [*]u16) callconv(.winapi) u32;
extern "kernel32" fn CreateDirectoryW(path: [*:0]const u16, sec: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CreateThread(attr: ?*anyopaque, stack: usize, start: *const fn (?*anyopaque) callconv(.winapi) u32, param: ?*anyopaque, flags: u32, id: ?*u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn CloseHandle(h: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

var err_buf: [320]u8 = undefined;
var err_len: usize = 0;
var interrupted = std.atomic.Value(bool).init(false);

fn ctrlHandler(ctrl_type: u32) callconv(.winapi) i32 {
    // Ctrl+C / Ctrl+Break: ask every cooperative loop to stop, but keep the
    // process alive long enough to print a well-formed JSON response.
    if (ctrl_type == 0 or ctrl_type == 1) {
        interrupted.store(true, .release);
        scan.cancel_flag.store(true, .release);
        return 1;
    }
    return 0;
}

fn installCtrlHandler() void {
    interrupted.store(false, .release);
    _ = SetConsoleCtrlHandler(ctrlHandler, 1);
}

fn fail(e: anyerror, comptime fmt: []const u8, args: anytype) anyerror {
    const s = std.fmt.bufPrint(&err_buf, fmt, args) catch err_buf[0..0];
    err_len = s.len;
    return e;
}

fn exitCodeFor(e: anyerror) u8 {
    if (e == error.BadArgs or e == error.UnknownCommand) return 2;
    return 1;
}

const value_opts = [_][]const u8{
    "--pid",       "--process", "--type",   "--cond",    "--value",   "--value2",   "--addr",
    "--size",      "--limit",   "--offset", "--session", "--filter",  "--for",      "--interval",
    "--count",     "--desc",    "--index",  "--file",    "--timeout", "--offsets",  "--tol",
    "--from-scan", "--module",  "--start",  "--end",     "--align",   "--encoding",
};

fn takesValue(t: []const u8) bool {
    for (value_opts) |o| {
        if (std.mem.eql(u8, o, t)) return true;
    }
    return false;
}

const Args = struct {
    v: []const []const u8,

    fn opt(self: Args, name: []const u8) ?[]const u8 {
        var i: usize = 0;
        while (i < self.v.len) : (i += 1) {
            const t = self.v[i];
            if (std.mem.eql(u8, t, name)) {
                if (i + 1 < self.v.len) return self.v[i + 1];
                return null;
            }
            if (t.len > name.len and std.mem.startsWith(u8, t, name) and t[name.len] == '=') {
                return t[name.len + 1 ..];
            }
        }
        return null;
    }

    fn flag(self: Args, name: []const u8) bool {
        for (self.v) |t| {
            if (std.mem.eql(u8, t, name)) return true;
        }
        return false;
    }

    fn pos(self: Args, n: usize) ?[]const u8 {
        var i: usize = 0;
        var k: usize = 0;
        while (i < self.v.len) : (i += 1) {
            const t = self.v[i];
            if (t.len >= 2 and t[0] == '-' and t[1] == '-') {
                if (std.mem.indexOfScalar(u8, t, '=') == null and takesValue(t)) i += 1;
                continue;
            }
            if (k == n) return t;
            k += 1;
        }
        return null;
    }
};

fn parseU64(s: []const u8) !u64 {
    return std.fmt.parseInt(u64, std.mem.trim(u8, s, " "), 0) catch
        return fail(error.BadArgs, "not a number: '{s}'", .{s});
}

fn parseU32(s: []const u8) !u32 {
    const v = try parseU64(s);
    if (v > std.math.maxInt(u32)) return fail(error.BadArgs, "number too large: '{s}'", .{s});
    return @intCast(v);
}

fn parseI64(s: []const u8) !i64 {
    return std.fmt.parseInt(i64, std.mem.trim(u8, s, " "), 0) catch
        return fail(error.BadArgs, "not a number: '{s}'", .{s});
}

fn lowerAscii(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn eqlIC(x: []const u8, y: []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| {
        if (lowerAscii(p) != lowerAscii(q)) return false;
    }
    return true;
}

const Row = struct {
    addr: u64,
    kind: scan.Kind,
    desc: []u8,
};

const Session = struct {
    name: []const u8,
    pid: u32 = 0,
    ctime: u64 = 0,
    proc: ?win.Process = null,
    sc: scan.Scanner = .{},
    scanned: bool = false,
    table: std.ArrayList(Row) = .empty,
    dirty: bool = false,
    notice: []const u8 = "",
};

fn W(comptime s: []const u8) []const u16 {
    const lit = std.unicode.utf8ToUtf16LeStringLiteral(s);
    return lit;
}

fn validSessionName(name: []const u8) bool {
    if (name.len == 0 or name.len > 40) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn sessionPathSuffix(a: std.mem.Allocator, name: []const u8, suffix: []const u8) ![:0]u16 {
    var tmp: [520]u16 = undefined;
    const n = GetTempPathW(520, &tmp);
    if (n == 0 or n > tmp.len) return error.NoTempDir;

    var list: std.ArrayList(u16) = .empty;
    try list.appendSlice(a, tmp[0..n]);
    try list.appendSlice(a, W("memfract"));
    try list.append(a, 0);
    const dirz = list.items[0 .. list.items.len - 1 :0];
    _ = CreateDirectoryW(dirz.ptr, null);
    _ = list.pop();

    try list.append(a, '\\');
    for (name) |c| try list.append(a, c);
    try list.appendSlice(a, W(".session"));
    for (suffix) |c| try list.append(a, c);
    try list.append(a, 0);
    return list.items[0 .. list.items.len - 1 :0];
}

fn sessionPath(a: std.mem.Allocator, name: []const u8) ![:0]u16 {
    return sessionPathSuffix(a, name, "");
}

const Cur = struct {
    d: []const u8,
    p: usize = 0,

    fn take(self: *Cur, n: usize) ![]const u8 {
        if (self.p + n > self.d.len) return error.CorruptSession;
        const r = self.d[self.p..][0..n];
        self.p += n;
        return r;
    }
    fn u8_(self: *Cur) !u8 {
        return (try self.take(1))[0];
    }
    fn u16_(self: *Cur) !u16 {
        return std.mem.readInt(u16, (try self.take(2))[0..2], .little);
    }
    fn u32_(self: *Cur) !u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }
    fn u64_(self: *Cur) !u64 {
        return std.mem.readInt(u64, (try self.take(8))[0..8], .little);
    }
};

fn putInt(a: std.mem.Allocator, list: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try list.appendSlice(a, &b);
}

const session_magic_v2 = "ZCS2";
const session_magic_v3 = "ZCS3";
const session_magic = "ZCS4";

fn decodeSession(data: []const u8, s: *Session) !void {
    var c: Cur = .{ .d = data };
    const magic = try c.take(4);
    const v4 = std.mem.eql(u8, magic, session_magic);
    const v3 = std.mem.eql(u8, magic, session_magic_v3);
    const v2 = std.mem.eql(u8, magic, session_magic_v2);
    if (!v4 and !v3 and !v2) return error.CorruptSession;

    s.pid = try c.u32_();
    s.ctime = try c.u64_();
    const kind_i = try c.u8_();
    s.scanned = (try c.u8_()) != 0;
    s.sc.truncated = (try c.u8_()) != 0;
    const enc_i = try c.u8_();
    s.sc.kind = std.enums.fromInt(scan.Kind, kind_i) orelse return error.CorruptSession;

    var value_len: usize = 0;
    if (v4) {
        const vlen = try c.u64_();
        if (s.sc.kind.isVariable()) {
            if (vlen == 0 or vlen > scan.max_value_len) return error.CorruptSession;
        } else if (vlen != s.sc.kind.size()) return error.CorruptSession;
        value_len = @intCast(vlen);
        s.sc.encoding = std.enums.fromInt(scan.Encoding, enc_i) orelse return error.CorruptSession;
    } else {
        // Older formats only ever stored fixed-width types.
        if (s.sc.kind.isVariable()) return error.CorruptSession;
        value_len = s.sc.kind.size();
        s.sc.encoding = .utf8;
    }
    s.sc.value_len = value_len;

    const stored = if (v2) 8 else value_len;
    const record = 8 + stored;

    const count = try c.u64_();
    if (count > (data.len - c.p) / record) return error.CorruptSession;
    try s.sc.matches.ensureTotalCapacity(gpa, @intCast(count));
    try s.sc.values.ensureTotalCapacity(gpa, @as(usize, @intCast(count)) * value_len);

    var prev: u64 = 0;
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        const addr = try c.u64_();
        // Matches must be strictly ascending: next() relies on it to batch page reads,
        // and the writer never produces duplicates.
        if (i > 0 and addr <= prev) return error.CorruptSession;
        prev = addr;
        const raw = try c.take(stored);
        s.sc.matches.appendAssumeCapacity(.{ .addr = @intCast(addr) });
        try s.sc.values.appendSlice(gpa, raw[0..value_len]);
    }

    const rows = try c.u32_();
    var r: u32 = 0;
    while (r < rows) : (r += 1) {
        const addr = try c.u64_();
        const k = std.enums.fromInt(scan.Kind, try c.u8_()) orelse return error.CorruptSession;
        if (k.isVariable()) return error.CorruptSession;
        const dl = try c.u16_();
        const raw_desc = try c.take(dl);
        const d = try gpa.dupe(u8, util.cleanUtf8(raw_desc));
        try s.table.append(gpa, .{ .addr = addr, .kind = k, .desc = d });
    }
}

fn freeSession(s: *Session) void {
    s.sc.deinit(gpa);
    for (s.table.items) |row| gpa.free(row.desc);
    s.table.deinit(gpa);
}

fn encodeSession(a: std.mem.Allocator, s: *Session) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    const value_len = s.sc.valueLen();
    if (value_len != 0 and s.sc.values.items.len != s.sc.matches.items.len * value_len)
        return error.CorruptSession;

    try out.appendSlice(a, session_magic);
    try putInt(a, &out, u32, s.pid);
    try putInt(a, &out, u64, s.ctime);
    try out.append(a, @backingInt(s.sc.kind));
    try out.append(a, @intFromBool(s.scanned));
    try out.append(a, @intFromBool(s.sc.truncated));
    try out.append(a, @backingInt(s.sc.encoding));
    try putInt(a, &out, u64, value_len);

    try putInt(a, &out, u64, s.sc.matches.items.len);
    for (s.sc.matches.items, 0..) |m, i| {
        try putInt(a, &out, u64, m.addr);
        try out.appendSlice(a, s.sc.valueAt(i));
    }

    if (s.table.items.len > std.math.maxInt(u32)) return error.TooManyRows;
    try putInt(a, &out, u32, @intCast(s.table.items.len));
    for (s.table.items) |row| {
        try putInt(a, &out, u64, row.addr);
        try out.append(a, @backingInt(row.kind));
        try putInt(a, &out, u16, @as(u16, @intCast(row.desc.len)));
        try out.appendSlice(a, row.desc);
    }
    return out.toOwnedSlice(a);
}

const corrupt_notice = "the saved session file was corrupt; it was moved to <name>.session.corrupt and a fresh session was started";

fn quarantineSession(a: std.mem.Allocator, name: []const u8) void {
    const src = sessionPath(a, name) catch return;
    const dst = sessionPathSuffix(a, name, ".corrupt") catch return;
    win.moveFileReplace(src.ptr, dst.ptr) catch {};
}

fn loadSession(a: std.mem.Allocator, s: *Session) void {
    const path = sessionPath(a, s.name) catch return;
    const data = win.readFileMax(a, path.ptr, 1 << 30) catch |e| {
        // FileOpenFailed means "no session file" (or no access); anything else means
        // the file exists but could not be read as a session.
        if (e != error.FileOpenFailed) {
            s.notice = corrupt_notice;
            s.dirty = true;
            quarantineSession(a, s.name);
        }
        return;
    };

    var tmp: Session = .{ .name = s.name };
    decodeSession(data, &tmp) catch |e| {
        freeSession(&tmp);
        if (e != error.OutOfMemory) {
            s.notice = corrupt_notice;
            s.dirty = true;
            quarantineSession(a, s.name);
        }
        return;
    };
    s.* = tmp;
}

fn saveSession(a: std.mem.Allocator, s: *Session) !void {
    const data = try encodeSession(a, s);
    defer a.free(data);
    const path = try sessionPath(a, s.name);
    try win.writeFileAtomic(path.ptr, data);
}

fn findPid(a: std.mem.Allocator, name: []const u8) !u32 {
    var list: std.ArrayList(win.ProcEntry) = .empty;
    try win.enumProcesses(a, &list, name);
    var exact: u32 = 0;
    var exact_n: usize = 0;
    for (list.items) |e| {
        if (eqlIC(e.name[0..e.name_len], name)) {
            exact = e.pid;
            exact_n += 1;
        }
    }
    if (exact_n == 1) return exact;
    if (exact_n > 1) return fail(error.Ambiguous, "{d} processes are named '{s}'; use --pid", .{ exact_n, name });
    if (list.items.len == 1) return list.items[0].pid;
    if (list.items.len == 0) return fail(error.NotFound, "no process matches '{s}'", .{name});
    return fail(error.Ambiguous, "{d} processes match '{s}'; use --pid or the exact name", .{ list.items.len, name });
}

fn attachPid(s: *Session, pid: u32) !void {
    const p = win.Process.open(pid) catch
        return fail(error.OpenFailed, "cannot open PID {d} (run as Administrator, or the PID does not exist)", .{pid});
    const ct = p.creationTime();
    if (s.pid == pid and s.ctime != 0 and ct != s.ctime) {
        p.close();
        return fail(error.StaleSession, "PID {d} was restarted since the saved session; run 'detach' or 'scan reset'", .{pid});
    }
    if (s.proc) |old| old.close();
    const changed = s.pid != pid or s.ctime != ct;
    if (s.pid != pid) {
        s.sc.deinit(gpa);
        s.sc = .{};
        s.scanned = false;
    }
    s.proc = p;
    s.pid = pid;
    s.ctime = ct;
    // Re-opening the same process (same PID and creation time) is not a state change:
    // do not rewrite a potentially huge session file after read-only commands.
    if (changed) s.dirty = true;
}

fn getProc(a: std.mem.Allocator, s: *Session, args: Args) !win.Process {
    var want: ?u32 = null;
    if (args.opt("--pid")) |t| {
        want = try parseU32(t);
    } else if (args.opt("--process")) |n| {
        want = try findPid(a, n);
    }
    if (want) |pid| {
        if (s.proc == null or s.pid != pid) try attachPid(s, pid);
        return s.proc.?;
    }
    if (s.proc) |p| return p;
    if (s.pid != 0) {
        try attachPid(s, s.pid);
        return s.proc.?;
    }
    return fail(error.NoProcess, "no process selected: pass --pid/--process or run 'attach' first", .{});
}

fn parseAddrText(a: std.mem.Allocator, s: *Session, text: []const u8) !usize {
    const t = std.mem.trim(u8, text, " ");
    if (std.mem.indexOfScalar(u8, t, '+')) |plus| {
        const left = std.mem.trim(u8, t[0..plus], " ");
        const off = try parseU64(t[plus + 1 ..]);
        if (std.fmt.parseInt(u64, left, 0)) |base| {
            return @intCast(base +% off);
        } else |_| {}
        var mods: std.ArrayList(win.ModEntry) = .empty;
        try win.enumModules(a, s.pid, &mods);
        for (mods.items) |m| {
            if (eqlIC(m.name[0..m.name_len], left)) return @intCast(@as(u64, m.base) +% off);
        }
        return fail(error.NotFound, "module '{s}' not found in the process", .{left});
    }
    return @intCast(try parseU64(t));
}

fn resolveAddr(a: std.mem.Allocator, s: *Session, p: win.Process, args: Args) !usize {
    const txt = args.opt("--addr") orelse return fail(error.BadArgs, "missing --addr", .{});
    var addr = try parseAddrText(a, s, txt);
    if (args.opt("--offsets")) |offs| {
        var it = std.mem.splitScalar(u8, offs, ',');
        while (it.next()) |o| {
            const t = std.mem.trim(u8, o, " ");
            if (t.len == 0) continue;
            const off = try parseI64(t);
            var pb: [8]u8 = undefined;
            p.read(addr, &pb) catch return fail(error.ReadFailed, "cannot read pointer at 0x{X}", .{addr});
            const ptr = std.mem.readInt(u64, &pb, .little);
            addr = @intCast(ptr +% @as(u64, @bitCast(off)));
        }
    }
    return addr;
}

fn kindArg(args: Args) !scan.Kind {
    const t = args.opt("--type") orelse return .int32;
    return scan.Kind.parse(t) orelse
        return fail(error.BadArgs, "unknown --type '{s}' (int8, int16, int32, int64, uint8, uint16, uint32, uint64, float32, float64, string, bytes)", .{t});
}

fn fixedKindArg(args: Args) !scan.Kind {
    const kind = try kindArg(args);
    if (kind.isVariable())
        return fail(error.BadArgs, "--type {s} is only supported by 'scan first' and 'scan next'", .{@tagName(kind)});
    return kind;
}

fn encodingArg(args: Args, default: scan.Encoding) !scan.Encoding {
    const t = args.opt("--encoding") orelse return default;
    return std.meta.stringToEnum(scan.Encoding, t) orelse
        return fail(error.BadArgs, "unknown --encoding '{s}' (utf8, utf16le)", .{t});
}

fn alignmentArg(args: Args, kind: scan.Kind) !usize {
    const t = args.opt("--align") orelse return kind.size();
    const n = try parseU64(t);
    if (n == 0 or n > 64 or n & (n - 1) != 0)
        return fail(error.BadArgs, "--align must be a power of two between 1 and 64", .{});
    return @intCast(n);
}

fn scanRange(a: std.mem.Allocator, s: *Session, args: Args) !scan.Range {
    var range: scan.Range = .{};
    if (args.opt("--start")) |t| range.start = try parseAddrText(a, s, t);
    if (args.opt("--end")) |t| {
        const end = try parseAddrText(a, s, t);
        range.end = if (end == std.math.maxInt(usize)) end else end + 1;
    }
    if (args.opt("--module")) |name| {
        var mods: std.ArrayList(win.ModEntry) = .empty;
        defer mods.deinit(a);
        try win.enumModules(a, s.pid, &mods);
        for (mods.items) |m| {
            if (!eqlIC(m.name[0..m.name_len], name)) continue;
            const end, const overflow = @addWithOverflow(m.base, m.size);
            range.start = @max(range.start, m.base);
            range.end = @min(range.end, if (overflow != 0) std.math.maxInt(usize) else end);
            break;
        } else return fail(error.NotFound, "module '{s}' not found in the process", .{name});
    }
    if (range.start >= range.end) return fail(error.BadArgs, "empty scan range", .{});
    return range;
}

fn modeArg(args: Args, default: scan.Mode) !scan.Mode {
    const t = args.opt("--cond") orelse return default;
    return std.meta.stringToEnum(scan.Mode, t) orelse
        return fail(error.BadArgs, "unknown --cond '{s}' (exact, greater, less, between, unknown, changed, unchanged, increased, decreased)", .{t});
}

fn encodeArg(kind: scan.Kind, text: []const u8, what: []const u8) !scan.Value {
    var nb: [128]u8 = undefined;
    const t = util.normNum(text, &nb);
    return scan.encode(kind, t) catch
        return fail(error.BadArgs, "bad {s} '{s}' for type {s}", .{ what, text, @tagName(kind) });
}

fn buildCond(kind: scan.Kind, mode: scan.Mode, default_encoding: scan.Encoding, args: Args) !scan.Cond {
    var cond: scan.Cond = .{ .mode = mode, .encoding = try encodingArg(args, default_encoding) };

    if (kind.isVariable()) {
        switch (mode) {
            .exact => {},
            .changed, .unchanged => return cond,
            else => return fail(error.BadArgs, "cond '{s}' is not supported for type {s}", .{ @tagName(mode), @tagName(kind) }),
        }
        const text = args.opt("--value") orelse return fail(error.BadArgs, "cond 'exact' needs --value", .{});
        const res = if (kind == .bytes) cond.setBytePattern(text) else cond.setText(text);
        res catch |e| switch (e) {
            error.PatternTooLong => return fail(error.BadArgs, "--value is longer than {d} bytes", .{scan.max_value_len}),
            error.InvalidPattern => return fail(error.BadArgs, "bad {s} pattern '{s}'", .{ @tagName(kind), text }),
        };
        return cond;
    }

    const needs = switch (mode) {
        .exact, .greater, .less, .between => true,
        else => false,
    };
    if (!needs) return cond;

    const t1 = args.opt("--value") orelse return fail(error.BadArgs, "cond '{s}' needs --value", .{@tagName(mode)});
    var nb: [128]u8 = undefined;
    const nt = util.normNum(t1, &nb);
    cond.a = try encodeArg(kind, t1, "--value");
    cond.tol = if (args.opt("--tol")) |tt|
        (std.fmt.parseFloat(f64, tt) catch return fail(error.BadArgs, "bad --tol '{s}'", .{tt}))
    else
        util.tolFromText(kind, nt);

    if (mode == .between) {
        const t2 = args.opt("--value2") orelse return fail(error.BadArgs, "cond 'between' needs --value2", .{});
        cond.b = try encodeArg(kind, t2, "--value2");
        const sz = kind.size();
        if (scan.cmpVal(kind, cond.a.bytes[0..sz], cond.b.bytes[0..sz])) |o| {
            if (o == .gt) {
                const tmp = cond.a;
                cond.a = cond.b;
                cond.b = tmp;
            }
        }
    }
    return cond;
}

fn hexAddr(buf: *[24]u8, addr: u64) []const u8 {
    return std.fmt.bufPrint(buf, "0x{X:0>16}", .{addr}) catch buf[0..0];
}

fn emitValue(w: *json.Writer, kind: scan.Kind, b: []const u8) !void {
    switch (kind) {
        .int8 => try w.int(std.mem.readInt(i8, b[0..1], .little)),
        .int16 => try w.int(std.mem.readInt(i16, b[0..2], .little)),
        .int32 => try w.int(std.mem.readInt(i32, b[0..4], .little)),
        .int64 => try w.int(std.mem.readInt(i64, b[0..8], .little)),
        .uint8 => try w.int(std.mem.readInt(u8, b[0..1], .little)),
        .uint16 => try w.int(std.mem.readInt(u16, b[0..2], .little)),
        .uint32 => try w.int(std.mem.readInt(u32, b[0..4], .little)),
        .uint64 => try w.int(std.mem.readInt(u64, b[0..8], .little)),
        .float32 => try w.float32(@bitCast(std.mem.readInt(u32, b[0..4], .little))),
        .float64 => try w.float(@bitCast(std.mem.readInt(u64, b[0..8], .little))),
        .string, .bytes => try w.nullv(),
    }
}

fn emitValueAny(w: *json.Writer, kind: scan.Kind, encoding: scan.Encoding, b: []const u8) !void {
    switch (kind) {
        .string, .bytes => {
            var buf: [scan.max_value_len * 3]u8 = undefined;
            const s = if (kind == .string)
                scan.fmtValueAny(kind, encoding, b, &buf)
            else
                hexSpaced(b, &buf);
            try w.string(s);
        },
        else => try emitValue(w, kind, b),
    }
}

fn hexSpaced(b: []const u8, buf: []u8) []const u8 {
    const digits = "0123456789abcdef";
    var n: usize = 0;
    for (b, 0..) |c, i| {
        if (i > 0) {
            if (n == buf.len) break;
            buf[n] = ' ';
            n += 1;
        }
        if (n + 2 > buf.len) break;
        buf[n] = digits[c >> 4];
        buf[n + 1] = digits[c & 15];
        n += 2;
    }
    return buf[0..n];
}

fn hexString(a: std.mem.Allocator, b: []const u8) ![]u8 {
    const digits = "0123456789abcdef";
    const out = try a.alloc(u8, b.len * 2);
    for (b, 0..) |c, i| {
        out[i * 2] = digits[c >> 4];
        out[i * 2 + 1] = digits[c & 15];
    }
    return out;
}

fn asciiString(a: std.mem.Allocator, b: []const u8) ![]u8 {
    const out = try a.alloc(u8, b.len);
    for (b, 0..) |c, i| out[i] = if (c >= 0x20 and c < 0x7F) c else '.';
    return out;
}

fn protectString(p: u32) []const u8 {
    return switch (p & 0xFF) {
        0x02 => "r",
        0x04 => "rw",
        0x08 => "rw-copy",
        0x10 => "x",
        0x20 => "rx",
        0x40 => "rwx",
        0x80 => "rwx-copy",
        else => "other",
    };
}

fn memTypeString(t: u32) []const u8 {
    return switch (t) {
        0x1000000 => "image",
        0x40000 => "mapped",
        0x20000 => "private",
        else => "unknown",
    };
}

var wd_gen = std.atomic.Value(u32).init(0);
var wd_ms: u32 = 0;

fn watchdogThread(param: ?*anyopaque) callconv(.winapi) u32 {
    const gen: u32 = @intCast(@intFromPtr(param.?));
    var waited: u32 = 0;
    while (waited < wd_ms) {
        Sleep(20);
        waited += 20;
        if (wd_gen.load(.acquire) != gen) return 0;
    }
    if (wd_gen.load(.acquire) == gen) scan.cancel_flag.store(true, .release);
    return 0;
}

fn startWatchdog(ms: u32) void {
    scan.cancel_flag.store(false, .release);
    const gen = wd_gen.fetchAdd(1, .acq_rel) + 1;
    if (ms == 0) return;
    wd_ms = ms;
    const th = CreateThread(null, 0, &watchdogThread, @ptrFromInt(@as(usize, gen)), 0, null);
    if (th) |t| _ = CloseHandle(t);
}

fn stopWatchdog() void {
    _ = wd_gen.fetchAdd(1, .acq_rel);
}

fn timeoutArg(args: Args) !u32 {
    return if (args.opt("--timeout")) |t| try parseU32(t) else 0;
}

const HelpEntry = struct { name: []const u8, usage: []const u8, desc: []const u8 };

const help_entries = [_]HelpEntry{
    .{ .name = "help", .usage = "help", .desc = "Machine-readable list of commands and conventions." },
    .{ .name = "version", .usage = "version", .desc = "Program version." },
    .{ .name = "ps", .usage = "ps [--filter NAME]", .desc = "List processes (pid, name)." },
    .{ .name = "modules", .usage = "modules [--pid N | --process NAME]", .desc = "List loaded modules with base addresses." },
    .{ .name = "regions", .usage = "regions [--pid N | --process NAME] [--writable]", .desc = "List readable memory regions (base, size, protection, type)." },
    .{ .name = "attach", .usage = "attach --pid N | --process NAME", .desc = "Select the target process for following commands (saved in the session)." },
    .{ .name = "detach", .usage = "detach", .desc = "Forget the selected process and clear scan results." },
    .{ .name = "read", .usage = "read --addr A [--offsets o1,o2] (--type T | --size N)", .desc = "Read a typed value or a hex dump. A is 0x... or module+offset. --offsets follows a pointer chain." },
    .{ .name = "write", .usage = "write --addr A --value V [--type T] [--offsets o1,o2]", .desc = "Write a value and read it back." },
    .{ .name = "scan first", .usage = "scan first [--type T] [--cond C] [--value V] [--value2 V] [--encoding E] [--module NAME] [--start A] [--end A] [--align N] [--all] [--tol X] [--timeout MS]", .desc = "First scan. Conds: exact, greater, less, between, unknown. Scans writable memory unless --all; --module/--start/--end limit the address range. --align N (a power of two, default the type size) sets the address alignment; use --align 1 for unaligned values. string and bytes scans need --cond exact with --value as the pattern." },
    .{ .name = "scan next", .usage = "scan next --cond C [--value V] [--value2 V] [--encoding E] [--tol X] [--timeout MS]", .desc = "Filter previous results. Conds: exact, greater, less, between, changed, unchanged, increased, decreased. For string and bytes only exact, changed and unchanged are supported." },
    .{ .name = "scan list", .usage = "scan list [--offset N] [--limit N]", .desc = "Show results with current and previous values (limit <= 10000, default 50). String values are JSON strings; bytes values are hex strings." },
    .{ .name = "scan status", .usage = "scan status", .desc = "Scan state: count, type, truncated flag." },
    .{ .name = "scan reset", .usage = "scan reset", .desc = "Discard scan results." },
    .{ .name = "freeze", .usage = "freeze --addr A --value V [--type T] [--offsets ...] [--for MS] [--interval MS] [--timeout MS]", .desc = "Keep writing a value for the given time (blocking). Ctrl+C stops early; --timeout MS caps the duration." },
    .{ .name = "watch", .usage = "watch --addr A [--type T] [--offsets ...] [--interval MS] [--count N] [--timeout MS] [--changes-only]", .desc = "Sample a value repeatedly. Ctrl+C stops early; --timeout MS caps the total time." },
    .{ .name = "table add", .usage = "table add (--addr A [--type T] [--offsets ...] | --from-scan INDEX) [--desc TEXT]", .desc = "Save an address in the session table." },
    .{ .name = "table list", .usage = "table list", .desc = "Show saved addresses with live values." },
    .{ .name = "table write", .usage = "table write --index N --value V", .desc = "Write a value to a saved address." },
    .{ .name = "table remove", .usage = "table remove --index N", .desc = "Remove a saved address." },
    .{ .name = "table clear", .usage = "table clear", .desc = "Remove all saved addresses." },
    .{ .name = "table save", .usage = "table save --file PATH", .desc = "Export the table (GUI-compatible text format)." },
    .{ .name = "table load", .usage = "table load --file PATH", .desc = "Import a table file." },
    .{ .name = "serve", .usage = "serve", .desc = "Long-lived mode: read one command per line from stdin, answer one JSON line per command. State stays in memory. Send 'exit' to quit." },
};

const help_notes = [_][]const u8{
    "Every response is a single JSON object on one line: {\"ok\":true,...} or {\"ok\":false,\"error\":{\"code\":...,\"message\":...}}.",
    "Exit codes: 0 success, 1 runtime error, 2 usage error.",
    "Addresses are strings like \"0x00007FF6A1B2C3D4\". Input accepts hex (0x..), decimal, or module+offset (game.exe+0x1A2B3C).",
    "Types: int8, int16, int32, int64, uint8, uint16, uint32, uint64, float32, float64, string, bytes. Float 'exact' matches with rounding tolerance derived from the typed digits (use --tol 0 for bit-exact).",
    "Integer values accept decimal, hex (0x..), octal (0o..), and binary (0b..) literals; --addr accepts 0x.., decimal, or module+offset.",
    "String scans match the bytes of --value, encoded as --encoding utf8 (default) or utf16le. Bytes scans take a hex pattern such as \"48 8B ?? ?? 89\", where ?? matches any byte. Patterns are limited to 256 bytes and scanned on every byte offset.",
    "One-shot mode keeps scan state in %TEMP%\\memfract\\<session>.session (--session NAME, default 'default'; --no-session disables). Use 'serve' for many commands without disk I/O.",
    "Typical flow: ps -> attach -> scan first -> (change value in target) -> scan next -> scan list -> table add -> write/freeze.",
    "Run as Administrator to open most processes. Not for use against online games or protected processes.",
    "Session files are written atomically. If a saved session is corrupt it is moved to <name>.session.corrupt, a fresh session is started, and the response includes a 'notice' field.",
    "Long-running commands (scan, freeze, watch) stop on Ctrl+C and return a normal JSON response; freeze and watch also accept --timeout MS as an upper bound.",
};

fn cmdHelp(w: *json.Writer) !void {
    try w.kvStr("version", version);
    try w.key("commands");
    try w.arrayBegin();
    for (help_entries) |e| {
        try w.objectBegin();
        try w.kvStr("name", e.name);
        try w.kvStr("usage", e.usage);
        try w.kvStr("description", e.desc);
        try w.objectEnd();
    }
    try w.arrayEnd();
    try w.key("notes");
    try w.arrayBegin();
    for (help_notes) |n| try w.string(n);
    try w.arrayEnd();
}

fn cmdPs(a: std.mem.Allocator, args: Args, w: *json.Writer) !void {
    var list: std.ArrayList(win.ProcEntry) = .empty;
    try win.enumProcesses(a, &list, args.opt("--filter") orelse "");
    try w.kvInt("count", list.items.len);
    try w.key("processes");
    try w.arrayBegin();
    for (list.items) |e| {
        try w.objectBegin();
        try w.kvInt("pid", e.pid);
        try w.kvStr("name", e.name[0..e.name_len]);
        try w.objectEnd();
    }
    try w.arrayEnd();
}

fn cmdModules(a: std.mem.Allocator, s: *Session, args: Args, w: *json.Writer) !void {
    _ = try getProc(a, s, args);
    var mods: std.ArrayList(win.ModEntry) = .empty;
    win.enumModules(a, s.pid, &mods) catch return fail(error.SnapshotFailed, "cannot enumerate modules of PID {d}", .{s.pid});
    try w.kvInt("pid", s.pid);
    try w.kvInt("count", mods.items.len);
    try w.key("modules");
    try w.arrayBegin();
    var ab: [24]u8 = undefined;
    for (mods.items) |m| {
        try w.objectBegin();
        try w.kvStr("name", m.name[0..m.name_len]);
        try w.kvStr("base", hexAddr(&ab, m.base));
        try w.kvInt("size", m.size);
        try w.kvStr("path", m.path[0..m.path_len]);
        try w.objectEnd();
    }
    try w.arrayEnd();
}

fn cmdRegions(a: std.mem.Allocator, s: *Session, args: Args, w: *json.Writer) !void {
    const p = try getProc(a, s, args);
    const regs = try p.regions(a, args.flag("--writable"));
    try w.kvInt("count", regs.items.len);
    try w.key("regions");
    try w.arrayBegin();
    var ab: [24]u8 = undefined;
    for (regs.items) |r| {
        try w.objectBegin();
        try w.kvStr("base", hexAddr(&ab, r.base));
        try w.kvInt("size", r.size);
        try w.kvStr("protect", protectString(r.protect));
        try w.kvStr("type", memTypeString(r.mem_type));
        try w.objectEnd();
    }
    try w.arrayEnd();
}

fn cmdAttach(a: std.mem.Allocator, s: *Session, args: Args, w: *json.Writer) !void {
    if (args.opt("--pid") == null and args.opt("--process") == null)
        return fail(error.BadArgs, "attach needs --pid or --process", .{});
    _ = try getProc(a, s, args);
    try w.kvInt("pid", s.pid);
    try w.kvBool("attached", true);
}

fn cmdDetach(s: *Session, w: *json.Writer) !void {
    if (s.proc) |p| p.close();
    s.proc = null;
    s.pid = 0;
    s.ctime = 0;
    s.sc.deinit(gpa);
    s.sc = .{};
    s.scanned = false;
    s.dirty = true;
    try w.kvBool("detached", true);
}

fn cmdRead(a: std.mem.Allocator, s: *Session, args: Args, w: *json.Writer) !void {
    const p = try getProc(a, s, args);
    const addr = try resolveAddr(a, s, p, args);
    var ab: [24]u8 = undefined;
    try w.kvStr("address", hexAddr(&ab, addr));

    if (args.opt("--size")) |st| {
        const n = try parseU64(st);
        if (n == 0 or n > 65536) return fail(error.BadArgs, "--size must be 1..65536", .{});
        const buf = try a.alloc(u8, @intCast(n));
        p.read(addr, buf) catch return fail(error.ReadFailed, "cannot read {d} bytes at 0x{X}", .{ n, addr });
        try w.kvInt("size", n);
        try w.kvStr("hex", try hexString(a, buf));
        try w.kvStr("ascii", try asciiString(a, buf));
        return;
    }

    const kind = try fixedKindArg(args);
    const sz = kind.size();
    var raw: [8]u8 = undefined;
    p.read(addr, raw[0..sz]) catch return fail(error.ReadFailed, "cannot read memory at 0x{X}", .{addr});
    try w.kvStr("type", @tagName(kind));
    try w.key("value");
    try emitValue(w, kind, raw[0..sz]);
    try w.kvStr("raw", try hexString(a, raw[0..sz]));
}

fn cmdWrite(a: std.mem.Allocator, s: *Session, args: Args, w: *json.Writer) !void {
    const p = try getProc(a, s, args);
    const addr = try resolveAddr(a, s, p, args);
    const kind = try fixedKindArg(args);
    const vt = args.opt("--value") orelse return fail(error.BadArgs, "missing --value", .{});
    const val = try encodeArg(kind, vt, "--value");
    const sz = kind.size();
    p.write(addr, val.bytes[0..sz]) catch
        return fail(error.WriteFailed, "cannot write memory at 0x{X} (protected or invalid address)", .{addr});

    var ab: [24]u8 = undefined;
    try w.kvStr("address", hexAddr(&ab, addr));
    try w.kvStr("type", @tagName(kind));
    var back: [8]u8 = undefined;
    try w.key("value");
    if (p.read(addr, back[0..sz])) |_| {
        try emitValue(w, kind, back[0..sz]);
    } else |_| {
        try w.nullv();
    }
}

fn scanSummary(s: *Session, w: *json.Writer, elapsed_ms: u64) !void {
    try w.kvInt("pid", s.pid);
    try w.kvStr("type", @tagName(s.sc.kind));
    try w.kvInt("count", s.sc.matches.items.len);
    try w.kvBool("truncated", s.sc.truncated);
    try w.kvInt("elapsed_ms", elapsed_ms);
}

fn cmdScan(a: std.mem.Allocator, s: *Session, args: Args, w: *json.Writer) !void {
    const sub = args.pos(1) orelse return fail(error.BadArgs, "scan needs a subcommand: first | next | list | status | reset", .{});

    if (std.mem.eql(u8, sub, "first")) {
        const p = try getProc(a, s, args);
        const kind = try kindArg(args);
        const mode = try modeArg(args, .exact);
        switch (mode) {
            .exact, .greater, .less, .between, .unknown => {},
            else => return fail(error.BadArgs, "cond '{s}' is only valid for 'scan next'", .{@tagName(mode)}),
        }
        const cond = try buildCond(kind, mode, .utf8, args);
        const range = try scanRange(a, s, args);
        const alignment = try alignmentArg(args, kind);
        const timeout = try timeoutArg(args);

        startWatchdog(timeout);
        const t0 = GetTickCount64();
        const res = s.sc.first(gpa, p, kind, cond, !args.flag("--all"), range, alignment);
        stopWatchdog();
        res catch |e| {
            if (e == error.Canceled) {
                if (interrupted.load(.acquire)) return fail(error.Canceled, "scan canceled by Ctrl+C", .{});
                return fail(error.Timeout, "scan stopped by --timeout {d} ms; narrow the scan or raise the timeout", .{timeout});
            }
            if (e == error.MissingPattern) return fail(error.BadArgs, "type {s} needs --value as the pattern", .{@tagName(kind)});
            if (e == error.PatternTooLong) return fail(error.BadArgs, "--value is longer than {d} bytes", .{scan.max_value_len});
            return e;
        };
        s.scanned = true;
        s.dirty = true;
        try scanSummary(s, w, GetTickCount64() - t0);
    } else if (std.mem.eql(u8, sub, "next")) {
        const p = try getProc(a, s, args);
        if (!s.scanned) return fail(error.NoScan, "no previous scan: run 'scan first' first", .{});
        const mode = try modeArg(args, .exact);
        if (mode == .unknown) return fail(error.BadArgs, "cond 'unknown' is only valid for 'scan first'", .{});
        const cond = try buildCond(s.sc.kind, mode, s.sc.encoding, args);
        const timeout = try timeoutArg(args);

        startWatchdog(timeout);
        const t0 = GetTickCount64();
        const canceled = s.sc.next(p, cond);
        stopWatchdog();
        s.dirty = true;
        try scanSummary(s, w, GetTickCount64() - t0);
        try w.kvBool("canceled", canceled);
    } else if (std.mem.eql(u8, sub, "list")) {
        if (!s.scanned) return fail(error.NoScan, "no scan results: run 'scan first' first", .{});
        const p: ?win.Process = getProc(a, s, args) catch null;
        const offset: usize = if (args.opt("--offset")) |t| @intCast(try parseU64(t)) else 0;
        var limit: usize = if (args.opt("--limit")) |t| @intCast(try parseU64(t)) else 50;
        if (limit > 10000) limit = 10000;

        const items = s.sc.matches.items;
        const end = @min(items.len, offset +| limit);
        const kind = s.sc.kind;
        const step = s.sc.valueLen();

        try w.kvInt("count", items.len);
        try w.kvInt("offset", offset);
        try w.kvStr("type", @tagName(kind));
        if (kind == .string) try w.kvStr("encoding", @tagName(s.sc.encoding));
        try w.key("results");
        try w.arrayBegin();
        var ab: [24]u8 = undefined;
        var i: usize = @min(offset, items.len);
        while (i < end) : (i += 1) {
            const m = items[i];
            try w.objectBegin();
            try w.kvInt("index", i);
            try w.kvStr("address", hexAddr(&ab, m.addr));
            try w.key("value");
            var cur: [scan.max_value_len]u8 = undefined;
            if (p != null and (p.?.read(m.addr, cur[0..step]) catch null) != null) {
                try emitValueAny(w, kind, s.sc.encoding, cur[0..step]);
            } else {
                try w.nullv();
            }
            try w.key("previous");
            try emitValueAny(w, kind, s.sc.encoding, s.sc.valueAt(i));
            try w.objectEnd();
        }
        try w.arrayEnd();
    } else if (std.mem.eql(u8, sub, "status")) {
        try w.kvBool("scanned", s.scanned);
        try w.kvInt("pid", s.pid);
        try w.kvStr("type", @tagName(s.sc.kind));
        try w.kvInt("count", s.sc.matches.items.len);
        try w.kvBool("truncated", s.sc.truncated);
    } else if (std.mem.eql(u8, sub, "reset")) {
        s.sc.deinit(gpa);
        s.sc = .{};
        s.scanned = false;
        s.dirty = true;
        try w.kvBool("reset", true);
    } else {
        return fail(error.BadArgs, "unknown scan subcommand '{s}'", .{sub});
    }
}

fn cmdFreeze(a: std.mem.Allocator, s: *Session, args: Args, w: *json.Writer) !void {
    const p = try getProc(a, s, args);
    const addr = try resolveAddr(a, s, p, args);
    const kind = try fixedKindArg(args);
    const vt = args.opt("--value") orelse return fail(error.BadArgs, "missing --value", .{});
    const val = try encodeArg(kind, vt, "--value");
    const dur: u64 = if (args.opt("--for")) |t| try parseU64(t) else 1000;
    if (dur > 3_600_000) return fail(error.BadArgs, "--for must be <= 3600000 ms", .{});
    const interval: u32 = if (args.opt("--interval")) |t| try parseU32(t) else 20;
    const timeout = try timeoutArg(args);

    const t0 = GetTickCount64();
    var writes: u64 = 0;
    var failures: u64 = 0;
    var canceled = false;
    while (GetTickCount64() - t0 < dur) {
        const elapsed = GetTickCount64() - t0;
        if (interrupted.load(.acquire) or (timeout != 0 and elapsed >= timeout)) {
            canceled = true;
            break;
        }
        if (p.write(addr, val.bytes[0..kind.size()])) |_| {
            writes += 1;
        } else |_| {
            failures += 1;
        }
        Sleep(@max(interval, 1));
    }
    var ab: [24]u8 = undefined;
    try w.kvStr("address", hexAddr(&ab, addr));
    try w.kvInt("writes", writes);
    try w.kvInt("failures", failures);
    try w.kvBool("canceled", canceled);
}

fn cmdWatch(a: std.mem.Allocator, s: *Session, args: Args, w: *json.Writer) !void {
    const p = try getProc(a, s, args);
    const addr = try resolveAddr(a, s, p, args);
    const kind = try fixedKindArg(args);
    const sz = kind.size();
    const interval: u32 = if (args.opt("--interval")) |t| try parseU32(t) else 100;
    const count: u64 = if (args.opt("--count")) |t| try parseU64(t) else 20;
    if (count == 0 or count > 100000) return fail(error.BadArgs, "--count must be 1..100000", .{});
    const only_changes = args.flag("--changes-only");
    const timeout = try timeoutArg(args);

    var ab: [24]u8 = undefined;
    try w.kvStr("address", hexAddr(&ab, addr));
    try w.kvStr("type", @tagName(kind));
    try w.key("samples");
    try w.arrayBegin();

    const t0 = GetTickCount64();
    var prev: [8]u8 = std.mem.zeroes([8]u8);
    var have_prev = false;
    var canceled = false;
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        if (interrupted.load(.acquire) or (timeout != 0 and GetTickCount64() - t0 >= timeout)) {
            canceled = true;
            break;
        }
        var cur: [8]u8 = undefined;
        const ok = if (p.read(addr, cur[0..sz])) |_| true else |_| false;
        const changed = !have_prev or !ok or !std.mem.eql(u8, cur[0..sz], prev[0..sz]);
        if (!only_changes or changed) {
            try w.objectBegin();
            try w.kvInt("t_ms", GetTickCount64() - t0);
            try w.key("value");
            if (ok) try emitValue(w, kind, cur[0..sz]) else try w.nullv();
            try w.objectEnd();
        }
        if (ok) {
            prev = cur;
            have_prev = true;
        }
        if (i + 1 < count) Sleep(@max(interval, 1));
    }
    try w.arrayEnd();
    try w.kvBool("canceled", canceled);
}

fn rowIndex(s: *Session, args: Args) !usize {
    const t = args.opt("--index") orelse return fail(error.BadArgs, "missing --index", .{});
    const i: usize = @intCast(try parseU64(t));
    if (i >= s.table.items.len) return fail(error.NotFound, "no table row with index {d}", .{i});
    return i;
}

fn cmdTable(a: std.mem.Allocator, s: *Session, args: Args, w: *json.Writer) !void {
    const sub = args.pos(1) orelse return fail(error.BadArgs, "table needs a subcommand: add | list | write | remove | clear | save | load", .{});

    if (std.mem.eql(u8, sub, "add")) {
        var addr: u64 = 0;
        var kind: scan.Kind = .int32;
        if (args.opt("--from-scan")) |t| {
            const idx: usize = @intCast(try parseU64(t));
            if (!s.scanned or idx >= s.sc.matches.items.len) return fail(error.NotFound, "no scan result with index {d}", .{idx});
            addr = s.sc.matches.items[idx].addr;
            kind = s.sc.kind;
            if (kind.isVariable())
                return fail(error.BadArgs, "the table does not support type {s}; use 'scan list' instead", .{@tagName(kind)});
        } else {
            const p = try getProc(a, s, args);
            addr = try resolveAddr(a, s, p, args);
            kind = try fixedKindArg(args);
        }
        const raw_desc = util.clipUtf8(args.opt("--desc") orelse "", 120);
        const d = try gpa.dupe(u8, util.cleanUtf8(raw_desc));
        try s.table.append(gpa, .{ .addr = addr, .kind = kind, .desc = d });
        s.dirty = true;
        var ab: [24]u8 = undefined;
        try w.kvInt("index", s.table.items.len - 1);
        try w.kvStr("address", hexAddr(&ab, addr));
    } else if (std.mem.eql(u8, sub, "list")) {
        const p: ?win.Process = getProc(a, s, args) catch null;
        try w.kvInt("count", s.table.items.len);
        try w.key("rows");
        try w.arrayBegin();
        var ab: [24]u8 = undefined;
        for (s.table.items, 0..) |row, i| {
            try w.objectBegin();
            try w.kvInt("index", i);
            try w.kvStr("address", hexAddr(&ab, row.addr));
            try w.kvStr("type", @tagName(row.kind));
            try w.kvStr("description", row.desc);
            try w.key("value");
            var cur: [8]u8 = undefined;
            const sz = row.kind.size();
            if (p != null and (p.?.read(@intCast(row.addr), cur[0..sz]) catch null) != null) {
                try emitValue(w, row.kind, cur[0..sz]);
            } else {
                try w.nullv();
            }
            try w.objectEnd();
        }
        try w.arrayEnd();
    } else if (std.mem.eql(u8, sub, "write")) {
        const p = try getProc(a, s, args);
        const i = try rowIndex(s, args);
        const row = s.table.items[i];
        const vt = args.opt("--value") orelse return fail(error.BadArgs, "missing --value", .{});
        const val = try encodeArg(row.kind, vt, "--value");
        p.write(@intCast(row.addr), val.bytes[0..row.kind.size()]) catch
            return fail(error.WriteFailed, "cannot write memory at 0x{X}", .{row.addr});
        try w.kvInt("index", i);
        try w.kvBool("written", true);
        var back: [8]u8 = undefined;
        try w.key("value");
        if (p.read(@intCast(row.addr), back[0..row.kind.size()])) |_| {
            try emitValue(w, row.kind, back[0..row.kind.size()]);
        } else |_| {
            try w.nullv();
        }
    } else if (std.mem.eql(u8, sub, "remove")) {
        const i = try rowIndex(s, args);
        const row = s.table.orderedRemove(i);
        gpa.free(row.desc);
        s.dirty = true;
        try w.kvInt("count", s.table.items.len);
    } else if (std.mem.eql(u8, sub, "clear")) {
        for (s.table.items) |row| gpa.free(row.desc);
        s.table.clearRetainingCapacity();
        s.dirty = true;
        try w.kvInt("count", 0);
    } else if (std.mem.eql(u8, sub, "save")) {
        const path = args.opt("--file") orelse return fail(error.BadArgs, "missing --file", .{});
        var out: std.ArrayList(u8) = .empty;
        for (s.table.items) |row| {
            var line: [320]u8 = undefined;
            const ls = util.writeTableLine(&line, row.addr, row.kind, row.desc) orelse continue;
            try out.appendSlice(a, ls);
        }
        const wp = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
        win.writeFileAtomic(wp.ptr, out.items) catch return fail(error.FileFailed, "cannot write file '{s}'", .{path});
        try w.kvInt("rows", s.table.items.len);
    } else if (std.mem.eql(u8, sub, "load")) {
        const path = args.opt("--file") orelse return fail(error.BadArgs, "missing --file", .{});
        const wp = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
        const data = win.readFileAlloc(a, wp.ptr) catch return fail(error.FileFailed, "cannot read file '{s}'", .{path});
        for (s.table.items) |row| gpa.free(row.desc);
        s.table.clearRetainingCapacity();
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw| {
            const parsed = util.parseTableLine(raw) orelse continue;
            if (parsed.kind.isVariable()) continue;
            const d = try gpa.dupe(u8, util.clipUtf8(util.cleanUtf8(parsed.desc), 120));
            try s.table.append(gpa, .{ .addr = parsed.addr, .kind = parsed.kind, .desc = d });
        }
        s.dirty = true;
        try w.kvInt("rows", s.table.items.len);
    } else {
        return fail(error.BadArgs, "unknown table subcommand '{s}'", .{sub});
    }
}

fn dispatch(a: std.mem.Allocator, s: *Session, argv: []const []const u8, w: *json.Writer) !void {
    if (argv.len == 0) return fail(error.BadArgs, "no command; run 'help'", .{});
    const args = Args{ .v = argv };
    const cmd = argv[0];
    const eq = std.mem.eql;

    if (eq(u8, cmd, "help") or eq(u8, cmd, "--help") or eq(u8, cmd, "-h")) return cmdHelp(w);
    if (eq(u8, cmd, "version") or eq(u8, cmd, "--version") or eq(u8, cmd, "-V")) return w.kvStr("version", version);
    if (eq(u8, cmd, "ps")) return cmdPs(a, args, w);
    if (eq(u8, cmd, "modules")) return cmdModules(a, s, args, w);
    if (eq(u8, cmd, "regions")) return cmdRegions(a, s, args, w);
    if (eq(u8, cmd, "attach")) return cmdAttach(a, s, args, w);
    if (eq(u8, cmd, "detach")) return cmdDetach(s, w);
    if (eq(u8, cmd, "read")) return cmdRead(a, s, args, w);
    if (eq(u8, cmd, "write")) return cmdWrite(a, s, args, w);
    if (eq(u8, cmd, "scan")) return cmdScan(a, s, args, w);
    if (eq(u8, cmd, "freeze")) return cmdFreeze(a, s, args, w);
    if (eq(u8, cmd, "watch")) return cmdWatch(a, s, args, w);
    if (eq(u8, cmd, "table")) return cmdTable(a, s, args, w);
    return fail(error.UnknownCommand, "unknown command '{s}'; run 'help'", .{cmd});
}

fn runInner(a: std.mem.Allocator, s: *Session, argv: []const []const u8, w: *json.Writer) !void {
    w.reset();
    try w.objectBegin();
    try w.kvBool("ok", true);
    try dispatch(a, s, argv, w);
    if (s.notice.len > 0) try w.kvStr("notice", s.notice);
    try w.objectEnd();
}

fn writeError(w: *json.Writer, e: anyerror, notice: []const u8) !void {
    w.reset();
    try w.objectBegin();
    try w.kvBool("ok", false);
    try w.key("error");
    try w.objectBegin();
    try w.kvStr("code", @errorName(e));
    try w.kvStr("message", if (err_len > 0) err_buf[0..err_len] else @errorName(e));
    try w.objectEnd();
    if (notice.len > 0) try w.kvStr("notice", notice);
    try w.objectEnd();
}

fn run(a: std.mem.Allocator, s: *Session, argv: []const []const u8, w: *json.Writer) u8 {
    err_len = 0;
    runInner(a, s, argv, w) catch |e| {
        writeError(w, e, s.notice) catch {};
        return exitCodeFor(e);
    };
    return 0;
}

fn tokenize(a: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var in_q = false;
    var have = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (in_q) {
            if (c == '\\' and i + 1 < line.len and (line[i + 1] == '"' or line[i + 1] == '\\')) {
                i += 1;
                try cur.append(a, line[i]);
            } else if (c == '"') {
                in_q = false;
            } else {
                try cur.append(a, c);
            }
        } else if (c == '"') {
            in_q = true;
            have = true;
        } else if (c == ' ' or c == '\t') {
            if (have) {
                try out.append(a, try cur.toOwnedSlice(a));
                have = false;
            }
        } else {
            try cur.append(a, c);
            have = true;
        }
    }
    if (have) try out.append(a, try cur.toOwnedSlice(a));
    return out.items;
}

var line_buf: [16384]u8 = undefined;

fn serve() void {
    var s: Session = .{ .name = "serve" };
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var w = json.Writer.init(arena.allocator());
        w.objectBegin() catch {};
        w.kvBool("ok", true) catch {};
        w.kvBool("ready", true) catch {};
        w.kvStr("version", version) catch {};
        w.objectEnd() catch {};
        w.buf.append(arena.allocator(), '\n') catch {};
        win.writeStdout(w.buf.items);
    }

    while (win.readLine(&line_buf)) |line| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var w = json.Writer.init(a);

        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) {
            win.writeStdout("{\"ok\":true,\"bye\":true}\n");
            break;
        }

        const argv = tokenize(a, trimmed) catch {
            win.writeStdout("{\"ok\":false,\"error\":{\"code\":\"OutOfMemory\",\"message\":\"cannot parse command\"}}\n");
            continue;
        };
        interrupted.store(false, .release);
        _ = run(a, &s, argv, &w);
        w.buf.append(a, '\n') catch {};
        win.writeStdout(w.buf.items);
    }
    if (s.proc) |p| p.close();
}

fn isStatelessCommand(cmd: []const u8) bool {
    const eq = std.mem.eql;
    return eq(u8, cmd, "help") or eq(u8, cmd, "--help") or eq(u8, cmd, "-h") or
        eq(u8, cmd, "version") or eq(u8, cmd, "--version") or eq(u8, cmd, "-V") or
        eq(u8, cmd, "ps");
}

pub fn main() !void {
    _ = SetConsoleOutputCP(65001);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const all = try win.argsAlloc(a);
    var w = json.Writer.init(a);

    if (all.len < 2) {
        err_len = 0;
        writeError(&w, fail(error.BadArgs, "no command; run 'memfract help'", .{}), "") catch {};
        w.buf.append(a, '\n') catch {};
        win.writeStdout(w.buf.items);
        ExitProcess(2);
    }
    const argv = all[1..];

    if (std.mem.eql(u8, argv[0], "serve")) {
        serve();
        return;
    }

    installCtrlHandler();

    const args = Args{ .v = argv };
    const name = args.opt("--session") orelse "default";
    if (!validSessionName(name)) {
        writeError(&w, fail(error.BadArgs, "invalid --session name (use A-Z a-z 0-9 _ -, up to 40 chars)", .{}), "") catch {};
        w.buf.append(a, '\n') catch {};
        win.writeStdout(w.buf.items);
        ExitProcess(2);
    }

    const stateless = isStatelessCommand(argv[0]) or args.flag("--no-session");

    var s: Session = .{ .name = name };
    if (!stateless) loadSession(a, &s);

    const code = run(a, &s, argv, &w);

    if (!stateless and s.dirty and code == 0) {
        saveSession(a, &s) catch {
            w.reset();
            writeError(&w, fail(error.SessionSaveFailed, "command succeeded but the session could not be saved", .{}), s.notice) catch {};
            w.buf.append(a, '\n') catch {};
            win.writeStdout(w.buf.items);
            ExitProcess(1);
        };
    }
    if (s.proc) |p| p.close();

    w.buf.append(a, '\n') catch {};
    win.writeStdout(w.buf.items);
    if (code != 0) ExitProcess(code);
}

test "validSessionName" {
    try std.testing.expect(validSessionName("default"));
    try std.testing.expect(validSessionName("agent-1_X"));
    try std.testing.expect(!validSessionName(""));
    try std.testing.expect(!validSessionName("a b"));
    try std.testing.expect(!validSessionName("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"));
}

test "tokenize handles quotes and escapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const t = try tokenize(a, "table add --desc \"player health\"");
    try std.testing.expectEqual(@as(usize, 4), t.len);
    try std.testing.expectEqualStrings("player health", t[3]);

    const e = try tokenize(a, "write --desc \"a\\\"b\"");
    try std.testing.expectEqualStrings("a\"b", e[2]);
}

test "hexAddr is fixed width" {
    var b: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0x0000000000001234", hexAddr(&b, 0x1234));
}

test "cli version aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Session = .{ .name = "test" };
    var w = json.Writer.init(a);
    const argv = [_][]const u8{"--version"};
    const code = run(a, &s, &argv, &w);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, w.buf.items, "\"version\":\"" ++ version ++ "\"") != null);
}

fn appendZeros(a: std.mem.Allocator, list: *std.ArrayList(u8), n: usize) !void {
    const zeros = std.mem.zeroes([8]u8);
    var left = n;
    while (left > 0) {
        const take = @min(left, zeros.len);
        try list.appendSlice(a, zeros[0..take]);
        left -= take;
    }
}

test "session roundtrip keeps matches and table" {
    const a = std.testing.allocator;
    var s: Session = .{ .name = "roundtrip" };
    defer freeSession(&s);
    s.pid = 4242;
    s.ctime = 0x1122334455667788;
    s.sc.kind = .int32;
    s.scanned = true;
    s.sc.truncated = true;

    var v1: [4]u8 = undefined;
    std.mem.writeInt(i32, &v1, 100, .little);
    var v2: [4]u8 = undefined;
    std.mem.writeInt(i32, &v2, -5, .little);
    try s.sc.matches.append(gpa, .{ .addr = 0x1000 });
    try s.sc.matches.append(gpa, .{ .addr = 0x2000 });
    try s.sc.values.appendSlice(gpa, &v1);
    try s.sc.values.appendSlice(gpa, &v2);
    try s.table.append(gpa, .{ .addr = 0x3000, .kind = .float64, .desc = try gpa.dupe(u8, "health") });

    const data = try encodeSession(a, &s);
    defer a.free(data);

    try std.testing.expectEqualStrings("ZCS4", data[0..4]);
    // header 28 + 2 int32 records of 12 bytes + rows count 4 + row 17
    try std.testing.expectEqual(@as(usize, 81), data.len);

    var t: Session = .{ .name = "roundtrip" };
    defer freeSession(&t);
    try decodeSession(data, &t);

    try std.testing.expectEqual(@as(u32, 4242), t.pid);
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), t.ctime);
    try std.testing.expectEqual(scan.Kind.int32, t.sc.kind);
    try std.testing.expect(t.scanned);
    try std.testing.expect(t.sc.truncated);
    try std.testing.expectEqual(@as(usize, 2), t.sc.matches.items.len);
    try std.testing.expectEqual(@as(usize, 0x1000), t.sc.matches.items[0].addr);
    try std.testing.expectEqual(@as(i32, 100), std.mem.readInt(i32, t.sc.valueAt(0)[0..4], .little));
    try std.testing.expectEqual(@as(i32, -5), std.mem.readInt(i32, t.sc.valueAt(1)[0..4], .little));
    try std.testing.expectEqual(@as(usize, 1), t.table.items.len);
    try std.testing.expectEqual(@as(u64, 0x3000), t.table.items[0].addr);
    try std.testing.expectEqual(scan.Kind.float64, t.table.items[0].kind);
    try std.testing.expectEqualStrings("health", t.table.items[0].desc);
}

test "decodeSession rejects truncated data" {
    const a = std.testing.allocator;
    var s: Session = .{ .name = "truncated" };
    defer freeSession(&s);
    s.sc.kind = .int64;
    try s.sc.matches.append(gpa, .{ .addr = 0x5000 });
    try s.sc.values.appendSlice(gpa, &std.mem.zeroes([8]u8));
    const data = try encodeSession(a, &s);
    defer a.free(data);

    var t: Session = .{ .name = "truncated" };
    defer freeSession(&t);
    try std.testing.expectError(error.CorruptSession, decodeSession(data[0 .. data.len - 1], &t));
}

test "decodeSession rejects unsorted matches" {
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "ZCS3");
    try putInt(a, &buf, u32, 1);
    try putInt(a, &buf, u64, 2);
    try buf.append(a, @backingInt(scan.Kind.int32));
    try buf.append(a, 1);
    try buf.append(a, 0);
    try buf.append(a, 0);
    try putInt(a, &buf, u64, 2);
    try putInt(a, &buf, u64, 0x2000);
    try appendZeros(a, &buf, 4);
    try putInt(a, &buf, u64, 0x1000);
    try appendZeros(a, &buf, 4);
    try putInt(a, &buf, u32, 0);

    var t: Session = .{ .name = "unsorted" };
    defer freeSession(&t);
    try std.testing.expectError(error.CorruptSession, decodeSession(buf.items, &t));
}

test "decodeSession accepts legacy ZCS2 records" {
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "ZCS2");
    try putInt(a, &buf, u32, 7);
    try putInt(a, &buf, u64, 9);
    try buf.append(a, @backingInt(scan.Kind.int32));
    try buf.append(a, 1);
    try buf.append(a, 0);
    try buf.append(a, 0);
    try putInt(a, &buf, u64, 1);
    try putInt(a, &buf, u64, 0x4000);
    var old: [8]u8 = std.mem.zeroes([8]u8);
    std.mem.writeInt(i32, old[0..4], 77, .little);
    try buf.appendSlice(a, &old);
    try putInt(a, &buf, u32, 0);

    var t: Session = .{ .name = "legacy" };
    defer freeSession(&t);
    try decodeSession(buf.items, &t);
    try std.testing.expectEqual(@as(u32, 7), t.pid);
    try std.testing.expectEqual(@as(usize, 1), t.sc.matches.items.len);
    try std.testing.expectEqual(@as(i32, 77), std.mem.readInt(i32, t.sc.valueAt(0)[0..4], .little));
}

test "decodeSession accepts ZCS3 records" {
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "ZCS3");
    try putInt(a, &buf, u32, 11);
    try putInt(a, &buf, u64, 12);
    try buf.append(a, @backingInt(scan.Kind.int32));
    try buf.append(a, 1);
    try buf.append(a, 0);
    try buf.append(a, 0);
    try putInt(a, &buf, u64, 1);
    try putInt(a, &buf, u64, 0x6000);
    var v: [4]u8 = undefined;
    std.mem.writeInt(i32, &v, 77, .little);
    try buf.appendSlice(a, &v);
    try putInt(a, &buf, u32, 0);

    var t: Session = .{ .name = "v3" };
    defer freeSession(&t);
    try decodeSession(buf.items, &t);
    try std.testing.expectEqual(scan.Kind.int32, t.sc.kind);
    try std.testing.expectEqual(@as(i32, 77), std.mem.readInt(i32, t.sc.valueAt(0)[0..4], .little));
}

test "session roundtrip keeps string scans" {
    const a = std.testing.allocator;
    var s: Session = .{ .name = "strings" };
    defer freeSession(&s);
    s.sc.kind = .string;
    s.sc.encoding = .utf16le;
    s.sc.value_len = 6;
    try s.sc.matches.append(gpa, .{ .addr = 0x6000 });
    try s.sc.values.appendSlice(gpa, "h\x00i\x00!\x00");

    const data = try encodeSession(a, &s);
    defer a.free(data);
    try std.testing.expectEqualStrings("ZCS4", data[0..4]);

    var t: Session = .{ .name = "strings" };
    defer freeSession(&t);
    try decodeSession(data, &t);
    try std.testing.expectEqual(scan.Kind.string, t.sc.kind);
    try std.testing.expectEqual(scan.Encoding.utf16le, t.sc.encoding);
    try std.testing.expectEqualStrings("h\x00i\x00!\x00", t.sc.valueAt(0));
}

test "buildCond parses binary patterns" {
    const bytes_argv = [_][]const u8{ "scan", "first", "--type", "bytes", "--value", "48 8b ?? ?? 89" };
    const bc = try buildCond(.bytes, .exact, .utf8, .{ .v = &bytes_argv });
    try std.testing.expectEqual(@as(usize, 5), bc.pattern_len);
    try std.testing.expectEqualStrings("\x48\x8b\x00\x00\x89", bc.patternSlice());
    try std.testing.expectEqualStrings("\x01\x01\x00\x00\x01", bc.maskSlice());

    const str_argv = [_][]const u8{ "scan", "first", "--type", "string", "--value", "hi", "--encoding", "utf16le" };
    const sc_cond = try buildCond(.string, .exact, .utf8, .{ .v = &str_argv });
    try std.testing.expectEqual(scan.Encoding.utf16le, sc_cond.encoding);
    try std.testing.expectEqualStrings("h\x00i\x00", sc_cond.patternSlice());

    const bad_argv = [_][]const u8{ "scan", "first", "--type", "bytes", "--value", "48 zz" };
    try std.testing.expectError(error.BadArgs, buildCond(.bytes, .exact, .utf8, .{ .v = &bad_argv }));

    const mode_argv = [_][]const u8{ "scan", "next", "--cond", "greater", "--value", "1" };
    try std.testing.expectError(error.BadArgs, buildCond(.string, .greater, .utf8, .{ .v = &mode_argv }));
}
