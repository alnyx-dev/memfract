const std = @import("std");
const win = @import("win.zig");

pub fn main() void {
    var hp: i32 = 100;
    const p: *volatile i32 = &hp;

    std.debug.print("PID: {d}\nhp address: 0x{x}\n", .{ win.GetCurrentProcessId(), @intFromPtr(p) });

    var buf: [64]u8 = undefined;
    while (true) {
        std.debug.print("hp = {d}   (Enter: hp -= 7, q: quit)\n", .{p.*});
        const line = win.readLine(&buf) orelse return;
        if (line.len > 0 and line[0] == 'q') return;
        p.* -= 7;
    }
}
