const std = @import("std");

pub const HANDLE = *anyopaque;

const PROCESS_VM_OPERATION = 0x0008;
const PROCESS_VM_READ = 0x0010;
const PROCESS_VM_WRITE = 0x0020;
const PROCESS_QUERY_INFORMATION = 0x0400;
const MEM_COMMIT = 0x1000;
const MEM_MAPPED = 0x40000;
const PAGE_NOACCESS = 0x01;
const PAGE_GUARD = 0x100;
const TH32CS_SNAPPROCESS = 0x2;
const TH32CS_SNAPMODULE = 0x8;
const TH32CS_SNAPMODULE32 = 0x10;
const INVALID_HANDLE: usize = std.math.maxInt(usize);

const MBI = extern struct {
    BaseAddress: usize,
    AllocationBase: usize,
    AllocationProtect: u32,
    PartitionId: u16,
    RegionSize: usize,
    State: u32,
    Protect: u32,
    Type: u32,
};

const PROCESSENTRY32W = extern struct {
    dwSize: u32,
    cntUsage: u32,
    th32ProcessID: u32,
    th32DefaultHeapID: usize,
    th32ModuleID: u32,
    cntThreads: u32,
    th32ParentProcessID: u32,
    pcPriClassBase: i32,
    dwFlags: u32,
    szExeFile: [260]u16,
};

const MODULEENTRY32W = extern struct {
    dwSize: u32,
    th32ModuleID: u32,
    th32ProcessID: u32,
    GlblcntUsage: u32,
    ProccntUsage: u32,
    modBaseAddr: usize,
    modBaseSize: u32,
    hModule: usize,
    szModule: [256]u16,
    szExePath: [260]u16,
};

const FILETIME = extern struct {
    dwLowDateTime: u32,
    dwHighDateTime: u32,
};

extern "kernel32" fn OpenProcess(access: u32, inherit: i32, pid: u32) callconv(.winapi) ?HANDLE;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn VirtualQueryEx(h: HANDLE, addr: usize, out: *MBI, len: usize) callconv(.winapi) usize;
extern "kernel32" fn ReadProcessMemory(h: HANDLE, addr: usize, buf: [*]u8, n: usize, read: ?*usize) callconv(.winapi) i32;
extern "kernel32" fn WriteProcessMemory(h: HANDLE, addr: usize, buf: [*]const u8, n: usize, written: ?*usize) callconv(.winapi) i32;
extern "kernel32" fn CreateToolhelp32Snapshot(flags: u32, pid: u32) callconv(.winapi) usize;
extern "kernel32" fn Process32FirstW(snap: HANDLE, e: *PROCESSENTRY32W) callconv(.winapi) i32;
extern "kernel32" fn Process32NextW(snap: HANDLE, e: *PROCESSENTRY32W) callconv(.winapi) i32;
extern "kernel32" fn Module32FirstW(snap: HANDLE, e: *MODULEENTRY32W) callconv(.winapi) i32;
extern "kernel32" fn Module32NextW(snap: HANDLE, e: *MODULEENTRY32W) callconv(.winapi) i32;
extern "kernel32" fn GetStdHandle(which: u32) callconv(.winapi) ?HANDLE;
extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetProcessTimes(h: HANDLE, creation: *FILETIME, exit: *FILETIME, kernel: *FILETIME, user: *FILETIME) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceCounter(out: *i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(out: *i64) callconv(.winapi) i32;
extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const u16;
extern "shell32" fn CommandLineToArgvW(cmd: [*:0]const u16, argc: *i32) callconv(.winapi) ?[*][*:0]u16;
extern "kernel32" fn LocalFree(h: usize) callconv(.winapi) usize;
pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

fn lowerAscii(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and lowerAscii(haystack[i + j]) == lowerAscii(needle[j])) : (j += 1) {}
        if (j == needle.len) return true;
    }
    return false;
}

pub const Region = struct {
    base: usize,
    size: usize,
    protect: u32,
    mem_type: u32,
};

pub const Process = struct {
    h: HANDLE,

    pub fn open(pid: u32) !Process {
        const h = OpenProcess(
            PROCESS_VM_READ | PROCESS_VM_WRITE | PROCESS_VM_OPERATION | PROCESS_QUERY_INFORMATION,
            0,
            pid,
        ) orelse return error.OpenProcessFailed;
        return .{ .h = h };
    }

    pub fn close(self: Process) void {
        _ = CloseHandle(self.h);
    }

    pub fn creationTime(self: Process) u64 {
        var creation: FILETIME = undefined;
        var exit_time: FILETIME = undefined;
        var kernel_time: FILETIME = undefined;
        var user_time: FILETIME = undefined;
        if (GetProcessTimes(self.h, &creation, &exit_time, &kernel_time, &user_time) == 0) return 0;
        return (@as(u64, creation.dwHighDateTime) << 32) | creation.dwLowDateTime;
    }

    pub fn read(self: Process, addr: usize, dst: []u8) !void {
        var n: usize = 0;
        if (ReadProcessMemory(self.h, addr, dst.ptr, dst.len, &n) == 0 or n != dst.len)
            return error.ReadFailed;
    }

    pub fn write(self: Process, addr: usize, src: []const u8) !void {
        var n: usize = 0;
        if (WriteProcessMemory(self.h, addr, src.ptr, src.len, &n) == 0 or n != src.len)
            return error.WriteFailed;
    }

    pub fn regions(self: Process, gpa: std.mem.Allocator, writable_only: bool) !std.ArrayList(Region) {
        var list: std.ArrayList(Region) = .empty;
        errdefer list.deinit(gpa);

        var addr: usize = 0;
        var mbi: MBI = undefined;
        while (VirtualQueryEx(self.h, addr, &mbi, @sizeOf(MBI)) != 0) {
            const readable = mbi.State == MEM_COMMIT and (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) == 0;
            const writable = (mbi.Protect & 0xCC) != 0;
            // Writable-only scans skip MEM_MAPPED (shared sections, can be GBs); --all includes it.
            if (readable and (!writable_only or (writable and mbi.Type != MEM_MAPPED))) {
                try list.append(gpa, .{
                    .base = mbi.BaseAddress,
                    .size = mbi.RegionSize,
                    .protect = mbi.Protect,
                    .mem_type = mbi.Type,
                });
            }
            const next, const overflow = @addWithOverflow(mbi.BaseAddress, mbi.RegionSize);
            if (overflow != 0) break;
            addr = next;
        }
        return list;
    }
};

/// Monotonic counter for measuring short intervals: pair with `perfFrequency`.
pub fn perfCounter() i64 {
    var v: i64 = 0;
    _ = QueryPerformanceCounter(&v);
    return v;
}

pub fn perfFrequency() i64 {
    var v: i64 = 0;
    _ = QueryPerformanceFrequency(&v);
    if (v == 0) return 1;
    return v;
}

pub fn listProcesses(filter: []const u8) void {
    const snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE) {
        std.debug.print("failed to enumerate processes\n", .{});
        return;
    }
    const snap_h: HANDLE = @ptrFromInt(snap);
    defer _ = CloseHandle(snap_h);

    var e: PROCESSENTRY32W = undefined;
    e.dwSize = @sizeOf(PROCESSENTRY32W);
    var ok = Process32FirstW(snap_h, &e) != 0;
    while (ok) : (ok = Process32NextW(snap_h, &e) != 0) {
        const wlen = std.mem.indexOfScalar(u16, &e.szExeFile, 0) orelse e.szExeFile.len;
        var name_buf: [1040]u8 = undefined;
        const n = std.unicode.utf16LeToUtf8(&name_buf, e.szExeFile[0..wlen]) catch continue;
        const name = name_buf[0..n];
        if (filter.len > 0 and !containsIgnoreCase(name, filter)) continue;
        std.debug.print("{d:>7}  {s}\n", .{ e.th32ProcessID, name });
    }
}

pub fn readLine(buf: []u8) ?[]u8 {
    const h = GetStdHandle(0xFFFFFFF6) orelse return null;
    var len: usize = 0;
    while (true) {
        var c: [1]u8 = undefined;
        var n: u32 = 0;
        if (ReadFile(h, &c, 1, &n, null) == 0 or n == 0) {
            return if (len == 0) null else buf[0..len];
        }
        if (c[0] == '\n') break;
        if (c[0] != '\r' and len < buf.len) {
            buf[len] = c[0];
            len += 1;
        }
    }
    return buf[0..len];
}

pub fn argsAlloc(gpa: std.mem.Allocator) ![]const []const u8 {
    var argc: i32 = 0;
    const wargv = CommandLineToArgvW(GetCommandLineW(), &argc) orelse return error.ArgsFailed;
    defer _ = LocalFree(@intFromPtr(wargv));

    const n: usize = @intCast(@max(argc, 0));
    const out = try gpa.alloc([]const u8, n);
    errdefer gpa.free(out);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        out[i] = try std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.span(wargv[i]));
    }
    return out;
}

pub fn writeStdout(data: []const u8) void {
    const h = GetStdHandle(0xFFFFFFF5) orelse return;
    var off: usize = 0;
    while (off < data.len) {
        const left = data.len - off;
        const chunk: u32 = @intCast(@min(left, @as(usize, std.math.maxInt(u32))));
        var written: u32 = 0;
        if (WriteFile(h, data.ptr + off, chunk, &written, null) == 0 or written == 0) return;
        off += written;
    }
}

pub const ProcEntry = struct {
    pid: u32,
    name: [780]u8,
    name_len: usize,
};

pub fn enumProcesses(gpa: std.mem.Allocator, out: *std.ArrayList(ProcEntry), filter: []const u8) !void {
    out.clearRetainingCapacity();
    const snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE) return error.SnapshotFailed;
    const snap_h: HANDLE = @ptrFromInt(snap);
    defer _ = CloseHandle(snap_h);

    var e: PROCESSENTRY32W = undefined;
    e.dwSize = @sizeOf(PROCESSENTRY32W);
    var ok = Process32FirstW(snap_h, &e) != 0;
    while (ok) : (ok = Process32NextW(snap_h, &e) != 0) {
        const wlen = std.mem.indexOfScalar(u16, &e.szExeFile, 0) orelse e.szExeFile.len;
        var entry: ProcEntry = undefined;
        entry.pid = e.th32ProcessID;
        entry.name_len = std.unicode.utf16LeToUtf8(&entry.name, e.szExeFile[0..wlen]) catch continue;
        if (filter.len > 0 and !containsIgnoreCase(entry.name[0..entry.name_len], filter)) continue;
        try out.append(gpa, entry);
    }
}

pub const ModEntry = struct {
    name: [780]u8,
    name_len: usize,
    path: [780]u8,
    path_len: usize,
    base: usize,
    size: usize,
};

pub fn enumModules(gpa: std.mem.Allocator, pid: u32, out: *std.ArrayList(ModEntry)) !void {
    out.clearRetainingCapacity();
    const snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
    if (snap == INVALID_HANDLE) return error.SnapshotFailed;
    const snap_h: HANDLE = @ptrFromInt(snap);
    defer _ = CloseHandle(snap_h);

    var e: MODULEENTRY32W = undefined;
    e.dwSize = @sizeOf(MODULEENTRY32W);
    var ok = Module32FirstW(snap_h, &e) != 0;
    while (ok) : (ok = Module32NextW(snap_h, &e) != 0) {
        var entry: ModEntry = undefined;
        const nlen = std.mem.indexOfScalar(u16, &e.szModule, 0) orelse e.szModule.len;
        entry.name_len = std.unicode.utf16LeToUtf8(&entry.name, e.szModule[0..nlen]) catch continue;
        const plen = std.mem.indexOfScalar(u16, &e.szExePath, 0) orelse e.szExePath.len;
        entry.path_len = std.unicode.utf16LeToUtf8(&entry.path, e.szExePath[0..plen]) catch continue;
        entry.base = e.modBaseAddr;
        entry.size = e.modBaseSize;
        try out.append(gpa, entry);
    }
}

extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sec: ?*anyopaque, disp: u32, flags: u32, tmpl: ?*anyopaque) callconv(.winapi) usize;
extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: u32, written: *u32, ov: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetFileSize(h: HANDLE, high: ?*u32) callconv(.winapi) u32;
extern "kernel32" fn FlushFileBuffers(h: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: [*:0]const u16, flags: u32) callconv(.winapi) i32;
extern "kernel32" fn DeleteFileW(name: [*:0]const u16) callconv(.winapi) i32;
extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) u32;

const MOVEFILE_REPLACE_EXISTING = 0x1;
const MOVEFILE_WRITE_THROUGH = 0x8;

/// Write a file atomically: the data goes to a process-unique temp file next to `path`,
/// is flushed, and only then replaces the destination. A reader either sees the old
/// file or the complete new one, never a half-written session.
pub fn writeFileAtomic(path: [*:0]const u16, data: []const u8) !void {
    var name_buf: [640]u16 = undefined;
    const n = std.mem.len(path);
    if (n + 32 >= name_buf.len) return error.PathTooLong;
    @memcpy(name_buf[0..n], path[0..n]);

    var num_buf: [24]u8 = undefined;
    const suffix = std.fmt.bufPrint(&num_buf, ".{d}.tmp", .{GetCurrentProcessId()}) catch unreachable;
    const slen = try std.unicode.utf8ToUtf16Le(name_buf[n..], suffix);
    name_buf[n + slen] = 0;
    const tmp: [:0]u16 = name_buf[0 .. n + slen :0];

    const raw = CreateFileW(tmp.ptr, 0x40000000, 0, null, 2, 0x80, null);
    if (raw == INVALID_HANDLE) return error.FileOpenFailed;
    const hh: HANDLE = @ptrFromInt(raw);

    var closed = false;
    var keep = false;
    defer {
        if (!closed) _ = CloseHandle(hh);
        if (!keep) _ = DeleteFileW(tmp.ptr);
    }

    var off: usize = 0;
    while (off < data.len) {
        const left = data.len - off;
        const chunk: u32 = @intCast(@min(left, @as(usize, std.math.maxInt(u32))));
        var written: u32 = 0;
        if (WriteFile(hh, data.ptr + off, chunk, &written, null) == 0 or written == 0)
            return error.FileWriteFailed;
        off += written;
    }
    if (FlushFileBuffers(hh) == 0) return error.FileWriteFailed;

    _ = CloseHandle(hh);
    closed = true;
    if (MoveFileExW(tmp.ptr, path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) == 0)
        return error.FileRenameFailed;
    keep = true;
}

/// Best-effort rename that replaces the destination (used to quarantine corrupt files).
pub fn moveFileReplace(from: [*:0]const u16, to: [*:0]const u16) !void {
    if (MoveFileExW(from, to, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) == 0)
        return error.FileRenameFailed;
}

pub fn deleteFile(path: [*:0]const u16) void {
    _ = DeleteFileW(path);
}

pub fn fileExists(path: [*:0]const u16) bool {
    return GetFileAttributesW(path) != 0xFFFFFFFF;
}

pub fn readFileMax(gpa: std.mem.Allocator, path: [*:0]const u16, max: usize) ![]u8 {
    const h = CreateFileW(path, 0x80000000, 1, null, 3, 0x80, null);
    if (h == INVALID_HANDLE) return error.FileOpenFailed;
    const hh: HANDLE = @ptrFromInt(h);
    defer _ = CloseHandle(hh);
    const size = GetFileSize(hh, null);
    if (size == 0xFFFFFFFF or size > max) return error.FileReadFailed;
    const buf = try gpa.alloc(u8, size);
    errdefer gpa.free(buf);
    var got: u32 = 0;
    if (ReadFile(hh, buf.ptr, size, &got, null) == 0 or got != size) return error.FileReadFailed;
    return buf;
}

pub fn readFileAlloc(gpa: std.mem.Allocator, path: [*:0]const u16) ![]u8 {
    return readFileMax(gpa, path, 16 * 1024 * 1024);
}
