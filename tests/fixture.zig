const std = @import("std");

extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

var needle = [_]u8{ 'm', 'e', 'm', 'f', 'r', 'a', 'c', 't', '-', 'n', 'e', 'e', 'd', 'l', 'e', 0 };
var signature = [_]u8{ 0x48, 0x8B, 0x90, 0x12, 0x89 };
var hp_ref: *i32 = undefined;

pub fn main() void {
    var hp: i32 = 305419896;
    hp_ref = &hp;
    const p: *volatile i32 = &hp;
    std.debug.print(
        "fixture pid={d} addr=0x{x} ref=0x{x} needle=0x{x} signature=0x{x}\n",
        .{ GetCurrentProcessId(), @intFromPtr(p), @intFromPtr(hp_ref), @intFromPtr(&needle), @intFromPtr(&signature) },
    );
    while (true) Sleep(1000);
}
