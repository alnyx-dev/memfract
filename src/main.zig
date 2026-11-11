const std = @import("std");
const win = @import("win.zig");
const scan = @import("scan.zig");

const help_text =
    \\Commands:
    \\  ps [filter]              list processes
    \\  attach <pid>             attach to a process
    \\  scan <type> <value>      first scan (types: int8 int16 int32 int64 uint8 uint16 uint32 uint64 float32 float64)
    \\  next <value>             keep addresses with the new exact value
    \\  changed                  keep addresses whose value changed
    \\  unchanged                keep addresses whose value did not change
    \\  list [N]                 show the first N found addresses (default 20)
    \\  set <index> <value>      write a value to an address from the list
    \\  quit                     exit
    \\
;

const State = struct {
    proc: ?win.Process = null,
    sc: scan.Scanner = .{},
};

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    var st: State = .{};
    defer {
        st.sc.deinit(gpa);
        if (st.proc) |p| p.close();
    }

    std.debug.print("memfract - type help\n", .{});

    var buf: [256]u8 = undefined;
    while (true) {
        std.debug.print("> ", .{});
        const line = win.readLine(&buf) orelse break;
        const keep_going = exec(gpa, &st, line) catch |e| {
            std.debug.print("error: {s}\n", .{@errorName(e)});
            continue;
        };
        if (!keep_going) break;
    }
}

fn exec(gpa: std.mem.Allocator, st: *State, line: []const u8) !bool {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const cmd = it.next() orelse return true;
    const eql = std.mem.eql;

    if (eql(u8, cmd, "quit") or eql(u8, cmd, "exit")) {
        return false;
    } else if (eql(u8, cmd, "help")) {
        std.debug.print("{s}", .{help_text});
    } else if (eql(u8, cmd, "ps")) {
        win.listProcesses(it.next() orelse "");
    } else if (eql(u8, cmd, "attach")) {
        const pid = try std.fmt.parseInt(u32, it.next() orelse return error.MissingArgument, 10);
        const p = try win.Process.open(pid);
        if (st.proc) |old| old.close();
        st.proc = p;
        st.sc.matches.clearRetainingCapacity();
        std.debug.print("attached to PID {d}\n", .{pid});
    } else if (eql(u8, cmd, "scan")) {
        const proc = st.proc orelse return error.NotAttached;
        const kind = scan.Kind.parse(it.next() orelse return error.MissingArgument) orelse return error.UnknownType;
        const val = try scan.encode(kind, it.next() orelse return error.MissingArgument);
        try st.sc.first(gpa, proc, kind, .{ .mode = .exact, .a = val }, false, .{});
        std.debug.print("found: {d}\n", .{st.sc.matches.items.len});
    } else if (eql(u8, cmd, "next")) {
        const proc = st.proc orelse return error.NotAttached;
        const val = try scan.encode(st.sc.kind, it.next() orelse return error.MissingArgument);
        _ = st.sc.next(proc, .{ .mode = .exact, .a = val });
        std.debug.print("remaining: {d}\n", .{st.sc.matches.items.len});
    } else if (eql(u8, cmd, "changed") or eql(u8, cmd, "unchanged")) {
        const proc = st.proc orelse return error.NotAttached;
        const mode: scan.Mode = if (eql(u8, cmd, "changed")) .changed else .unchanged;
        _ = st.sc.next(proc, .{ .mode = mode });
        std.debug.print("remaining: {d}\n", .{st.sc.matches.items.len});
    } else if (eql(u8, cmd, "list")) {
        const proc = st.proc orelse return error.NotAttached;
        const limit = if (it.next()) |s| try std.fmt.parseInt(usize, s, 10) else 20;
        const kind = st.sc.kind;
        const sz = kind.size();
        const n = @min(st.sc.matches.items.len, limit);
        for (st.sc.matches.items[0..n], 0..) |m, i| {
            var cur: [8]u8 = undefined;
            std.debug.print("[{d}] 0x{x:0>12}  ", .{ i, m.addr });
            proc.read(m.addr, cur[0..sz]) catch {
                std.debug.print("??\n", .{});
                continue;
            };
            scan.show(kind, cur[0..sz]);
            std.debug.print("\n", .{});
        }
        std.debug.print("total: {d}\n", .{st.sc.matches.items.len});
    } else if (eql(u8, cmd, "set")) {
        const proc = st.proc orelse return error.NotAttached;
        const idx = try std.fmt.parseInt(usize, it.next() orelse return error.MissingArgument, 10);
        if (idx >= st.sc.matches.items.len) return error.IndexOutOfRange;
        const val = try scan.encode(st.sc.kind, it.next() orelse return error.MissingArgument);
        try proc.write(st.sc.matches.items[idx].addr, val.bytes[0..st.sc.kind.size()]);
        std.debug.print("written\n", .{});
    } else {
        std.debug.print("unknown command, see help\n", .{});
    }
    return true;
}
