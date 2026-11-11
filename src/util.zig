const std = @import("std");
const scan = @import("scan.zig");

/// Replace the decimal comma with a dot and copy at most `out.len` bytes.
pub fn normNum(s: []const u8, out: []u8) []const u8 {
    const n = @min(s.len, out.len);
    for (s[0..n], 0..) |c, i| out[i] = if (c == ',') '.' else c;
    return out[0..n];
}

/// Float "exact" tolerance derived from the number of typed decimal digits.
pub fn tolFromText(kind: scan.Kind, s: []const u8) f64 {
    if (!kind.isFloat()) return 0;
    const dot = std.mem.indexOfScalar(u8, s, '.') orelse return 0.5;
    const dec = s.len - dot - 1;
    var t: f64 = 0.5;
    var k: usize = 0;
    while (k < dec) : (k += 1) t /= 10;
    return t;
}

/// Cut a UTF-8 string to `max` bytes without splitting a code point.
pub fn clipUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

/// Drop strings that are not valid UTF-8.
pub fn cleanUtf8(s: []const u8) []const u8 {
    return if (std.unicode.utf8ValidateSlice(s)) s else "";
}

pub const ParsedLine = struct {
    addr: u64,
    kind: scan.Kind,
    desc: []const u8,
};

/// Parse one `ADDR|type|description` line of the address table file.
/// The returned description points into `line`.
pub fn parseTableLine(line: []const u8) ?ParsedLine {
    const trimmed = std.mem.trim(u8, line, "\r\n ");
    if (trimmed.len == 0) return null;

    var parts = std.mem.splitScalar(u8, trimmed, '|');
    const addr_text = parts.next() orelse return null;
    const kind_text = parts.next() orelse return null;
    const addr = std.fmt.parseInt(u64, std.mem.trim(u8, addr_text, " "), 16) catch return null;
    const kind = scan.Kind.parse(std.mem.trim(u8, kind_text, " ")) orelse return null;
    return .{ .addr = addr, .kind = kind, .desc = parts.rest() };
}

/// Format one address table line, replacing the `|` separator and newlines in
/// the description with spaces so the file stays line-oriented.
pub fn writeTableLine(buf: []u8, addr: u64, kind: scan.Kind, desc: []const u8) ?[]const u8 {
    var clean: [128]u8 = undefined;
    const d = clipUtf8(desc, clean.len);
    for (d, 0..) |c, i| clean[i] = if (c == '|' or c == '\n' or c == '\r') ' ' else c;
    return std.fmt.bufPrint(buf, "{X}|{s}|{s}\n", .{ addr, @tagName(kind), clean[0..d.len] }) catch null;
}

test "normNum and float tolerance" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("1.5", normNum("1,5", &buf));
    try std.testing.expectEqual(@as(f64, 0), tolFromText(.int32, "10"));
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), tolFromText(.float32, "100"), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), tolFromText(.float64, "76.5"), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0005), tolFromText(.float64, "0.125"), 1e-12);
}

test "clipUtf8 does not split code points" {
    const s = "héllo";
    try std.testing.expectEqualStrings("hé", clipUtf8(s, 3));
    try std.testing.expectEqualStrings(s, clipUtf8(s, 12));
}

test "cleanUtf8 rejects invalid bytes" {
    try std.testing.expectEqualStrings("ok", cleanUtf8("ok"));
    try std.testing.expectEqualStrings("", cleanUtf8("\xff"));
}

test "table line roundtrip" {
    var buf: [320]u8 = undefined;
    const line = writeTableLine(&buf, 0x7FF6A1B2C3D4, .float32, "player|health\nbar").?;
    try std.testing.expectEqualStrings("7FF6A1B2C3D4|float32|player health bar\n", line);

    const parsed = parseTableLine(line).?;
    try std.testing.expectEqual(@as(u64, 0x7FF6A1B2C3D4), parsed.addr);
    try std.testing.expectEqual(scan.Kind.float32, parsed.kind);
    try std.testing.expectEqualStrings("player health bar", parsed.desc);
}

test "table line roundtrip keeps unicode descriptions" {
    var buf: [320]u8 = undefined;
    const line = writeTableLine(&buf, 0x1000, .int64, "здоровье игрока").?;
    const parsed = parseTableLine(line).?;
    try std.testing.expectEqualStrings("здоровье игрока", parsed.desc);
}

test "writeTableLine does not split a code point" {
    // "a" followed by 100 two-byte letters: the 128-byte cut lands inside one.
    var desc: [201]u8 = undefined;
    desc[0] = 'a';
    for (0..100) |i| @memcpy(desc[1 + i * 2 ..][0..2], "я");
    var buf: [320]u8 = undefined;
    const line = writeTableLine(&buf, 1, .int32, &desc).?;
    try std.testing.expect(std.unicode.utf8ValidateSlice(line));
}

test "parseTableLine rejects malformed lines" {
    try std.testing.expectEqual(@as(?ParsedLine, null), parseTableLine(""));
    try std.testing.expectEqual(@as(?ParsedLine, null), parseTableLine("   \r"));
    try std.testing.expectEqual(@as(?ParsedLine, null), parseTableLine("nonsense"));
    try std.testing.expectEqual(@as(?ParsedLine, null), parseTableLine("zz|int32|bad addr"));
    try std.testing.expectEqual(@as(?ParsedLine, null), parseTableLine("1000|u32|bad type"));
}
