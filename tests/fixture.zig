const std = @import("std");

extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

pub fn main() void {
    var hp: i32 = 305419896;
    const p: *volatile i32 = &hp;
    std.debug.print("fixture pid={d} addr=0x{x}\n", .{ GetCurrentProcessId(), @intFromPtr(p) });
    while (true) Sleep(1000);
}
