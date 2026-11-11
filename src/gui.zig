const std = @import("std");
const win = @import("win.zig");
const scan = @import("scan.zig");
const util = @import("util.zig");
const version = @import("version.zig").string;

const gpa = std.heap.page_allocator;

const HWND = *anyopaque;
const HDC = *anyopaque;
const HINSTANCE = *anyopaque;
const WNDPROC = *const fn (HWND, u32, usize, isize) callconv(.winapi) isize;

const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const POINT = extern struct { x: i32, y: i32 };

const WNDCLASSEXW = extern struct {
    cbSize: u32,
    style: u32,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: ?HINSTANCE,
    hIcon: ?*anyopaque,
    hCursor: ?*anyopaque,
    hbrBackground: usize,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque,
};

const MSG = extern struct {
    hwnd: ?HWND,
    message: u32,
    wParam: usize,
    lParam: isize,
    time: u32,
    pt_x: i32,
    pt_y: i32,
    lPrivate: u32,
};

const PAINTSTRUCT = extern struct {
    hdc: ?HDC,
    fErase: i32,
    rcPaint: RECT,
    fRestore: i32,
    fIncUpdate: i32,
    rgbReserved: [32]u8,
};

const DRAWITEMSTRUCT = extern struct {
    CtlType: u32,
    CtlID: u32,
    itemID: u32,
    itemAction: u32,
    itemState: u32,
    hwndItem: HWND,
    hDC: HDC,
    rcItem: RECT,
    itemData: usize,
};

const MEASUREITEMSTRUCT = extern struct {
    CtlType: u32,
    CtlID: u32,
    itemID: u32,
    itemWidth: u32,
    itemHeight: u32,
    itemData: usize,
};

const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};

const GdiplusStartupInput = extern struct {
    GdiplusVersion: u32,
    DebugEventCallback: ?*anyopaque,
    SuppressBackgroundThread: i32,
    SuppressExternalCodecs: i32,
};

extern "user32" fn RegisterClassExW(wc: *const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(ex: u32, class: [*:0]const u16, name: [*:0]const u16, style: u32, x: i32, y: i32, w: i32, h: i32, parent: ?HWND, menu: usize, inst: ?HINSTANCE, param: ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn DefWindowProcW(h: HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) isize;
extern "user32" fn GetMessageW(msg: *MSG, h: ?HWND, min: u32, max: u32) callconv(.winapi) i32;
extern "user32" fn TranslateMessage(msg: *const MSG) callconv(.winapi) i32;
extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) isize;
extern "user32" fn PostQuitMessage(code: i32) callconv(.winapi) void;
extern "user32" fn SendMessageW(h: HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) isize;
extern "user32" fn PostMessageW(h: HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) i32;
extern "user32" fn SetWindowTextW(h: HWND, text: [*:0]const u16) callconv(.winapi) i32;
extern "user32" fn GetWindowTextW(h: HWND, buf: [*]u16, max: i32) callconv(.winapi) i32;
extern "user32" fn LoadCursorW(inst: ?HINSTANCE, name: usize) callconv(.winapi) ?*anyopaque;
extern "user32" fn UpdateWindow(h: HWND) callconv(.winapi) i32;
extern "user32" fn ShowWindow(h: HWND, cmd: i32) callconv(.winapi) i32;
extern "user32" fn SetTimer(h: ?HWND, id: usize, ms: u32, f: ?*anyopaque) callconv(.winapi) usize;
extern "user32" fn KillTimer(h: ?HWND, id: usize) callconv(.winapi) i32;
extern "user32" fn BeginPaint(h: HWND, ps: *PAINTSTRUCT) callconv(.winapi) ?HDC;
extern "user32" fn EndPaint(h: HWND, ps: *const PAINTSTRUCT) callconv(.winapi) i32;
extern "user32" fn GetClientRect(h: HWND, rc: *RECT) callconv(.winapi) i32;
extern "user32" fn InvalidateRect(h: ?HWND, rc: ?*const RECT, erase: i32) callconv(.winapi) i32;
extern "user32" fn FillRect(dc: HDC, rc: *const RECT, br: *anyopaque) callconv(.winapi) i32;
extern "user32" fn DrawTextW(dc: HDC, s: [*]const u16, n: i32, rc: *RECT, flags: u32) callconv(.winapi) i32;
extern "user32" fn GetCursorPos(pt: *POINT) callconv(.winapi) i32;
extern "user32" fn WindowFromPoint(pt: POINT) callconv(.winapi) ?HWND;
extern "user32" fn AdjustWindowRect(rc: *RECT, style: u32, menu: i32) callconv(.winapi) i32;
extern "user32" fn GetDpiForSystem() callconv(.winapi) u32;
extern "user32" fn GetSystemMetrics(i: i32) callconv(.winapi) i32;
extern "user32" fn SetProcessDPIAware() callconv(.winapi) i32;
extern "user32" fn MoveWindow(h: HWND, x: i32, y: i32, w: i32, hh: i32, repaint: i32) callconv(.winapi) i32;
extern "user32" fn SetFocus(h: HWND) callconv(.winapi) ?HWND;
extern "user32" fn BringWindowToTop(h: HWND) callconv(.winapi) i32;
extern "user32" fn ScreenToClient(h: HWND, pt: *POINT) callconv(.winapi) i32;
extern "user32" fn RedrawWindow(h: HWND, rc: ?*const RECT, rgn: ?*anyopaque, flags: u32) callconv(.winapi) i32;
extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?HINSTANCE;
extern "kernel32" fn CreateThread(attr: ?*anyopaque, stack: usize, start: *const fn (?*anyopaque) callconv(.winapi) u32, param: ?*anyopaque, flags: u32, id: ?*u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn CloseHandle(h: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "gdi32" fn CreateSolidBrush(c: u32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteObject(o: *anyopaque) callconv(.winapi) i32;
extern "gdi32" fn SelectObject(dc: HDC, o: *anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn SetBkMode(dc: HDC, m: i32) callconv(.winapi) i32;
extern "gdi32" fn SetTextColor(dc: HDC, c: u32) callconv(.winapi) u32;
extern "gdi32" fn SetBkColor(dc: HDC, c: u32) callconv(.winapi) u32;
extern "gdi32" fn CreateCompatibleDC(dc: ?HDC) callconv(.winapi) ?HDC;
extern "gdi32" fn CreateCompatibleBitmap(dc: HDC, w: i32, h: i32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn BitBlt(dst: HDC, x: i32, y: i32, w: i32, h: i32, src: HDC, sx: i32, sy: i32, rop: u32) callconv(.winapi) i32;
extern "gdi32" fn DeleteDC(dc: HDC) callconv(.winapi) i32;
extern "gdi32" fn CreateFontW(h: i32, w: i32, esc: i32, ori: i32, weight: i32, it: u32, ul: u32, so: u32, cs: u32, op: u32, cp: u32, q: u32, pf: u32, face: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "gdiplus" fn GdiplusStartup(token: *usize, input: *const GdiplusStartupInput, output: ?*anyopaque) callconv(.winapi) i32;
extern "gdiplus" fn GdiplusShutdown(token: usize) callconv(.winapi) void;
extern "gdiplus" fn GdipCreateFromHDC(dc: HDC, g: *?*anyopaque) callconv(.winapi) i32;
extern "gdiplus" fn GdipDeleteGraphics(g: ?*anyopaque) callconv(.winapi) i32;
extern "gdiplus" fn GdipSetSmoothingMode(g: ?*anyopaque, mode: i32) callconv(.winapi) i32;
extern "gdiplus" fn GdipCreatePath(fill_mode: i32, p: *?*anyopaque) callconv(.winapi) i32;
extern "gdiplus" fn GdipDeletePath(p: ?*anyopaque) callconv(.winapi) i32;
extern "gdiplus" fn GdipAddPathArcI(p: ?*anyopaque, x: i32, y: i32, w: i32, h: i32, start: f32, sweep: f32) callconv(.winapi) i32;
extern "gdiplus" fn GdipAddPathRectangleI(p: ?*anyopaque, x: i32, y: i32, w: i32, h: i32) callconv(.winapi) i32;
extern "gdiplus" fn GdipClosePathFigure(p: ?*anyopaque) callconv(.winapi) i32;
extern "gdiplus" fn GdipCreateSolidFill(argb: u32, b: *?*anyopaque) callconv(.winapi) i32;
extern "gdiplus" fn GdipDeleteBrush(b: ?*anyopaque) callconv(.winapi) i32;
extern "gdiplus" fn GdipFillPath(g: ?*anyopaque, b: ?*anyopaque, p: ?*anyopaque) callconv(.winapi) i32;
extern "gdiplus" fn GdipCreatePen1(argb: u32, width: f32, unit: i32, pen: *?*anyopaque) callconv(.winapi) i32;
extern "gdiplus" fn GdipDeletePen(pen: ?*anyopaque) callconv(.winapi) i32;
extern "gdiplus" fn GdipDrawPath(g: ?*anyopaque, pen: ?*anyopaque, p: ?*anyopaque) callconv(.winapi) i32;
extern "dwmapi" fn DwmSetWindowAttribute(h: HWND, attr: u32, val: *const anyopaque, size: u32) callconv(.winapi) i32;
extern "uxtheme" fn SetWindowTheme(h: HWND, app: ?[*:0]const u16, list: ?[*:0]const u16) callconv(.winapi) i32;
extern "advapi32" fn RegGetValueW(key: usize, sub: [*:0]const u16, value: [*:0]const u16, flags: u32, ty: ?*u32, data: ?*anyopaque, size: ?*u32) callconv(.winapi) i32;

const WM_CREATE = 0x0001;
const WM_DESTROY = 0x0002;
const WM_SIZE = 0x0005;
const WM_PAINT = 0x000F;
const WM_ERASEBKGND = 0x0014;
const WM_GETMINMAXINFO = 0x0024;
const WM_SETFONT = 0x0030;
const WM_DRAWITEM = 0x002B;
const WM_MEASUREITEM = 0x002C;
const WM_COMMAND = 0x0111;
const WM_TIMER = 0x0113;
const WM_CTLCOLOREDIT = 0x0133;
const WM_CTLCOLORLISTBOX = 0x0134;
const WM_SCAN_DONE = 0x8001;

const WS_CHILD = 0x40000000;
const WS_VISIBLE = 0x10000000;
const WS_TABSTOP = 0x00010000;
const WS_VSCROLL = 0x00200000;
const WS_CLIPCHILDREN = 0x02000000;
const WS_CLIPSIBLINGS = 0x04000000;
const WS_CAPTION = 0x00C00000;
const WS_SYSMENU = 0x00080000;
const WS_MINIMIZEBOX = 0x00020000;
const WS_MAXIMIZEBOX = 0x00010000;
const WS_THICKFRAME = 0x00040000;

const main_style: u32 = WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_THICKFRAME | WS_CLIPCHILDREN;

const ES_AUTOHSCROLL = 0x80;
const EM_LIMITTEXT = 0xC5;
const BS_OWNERDRAW = 0xB;
const LBS_NOTIFY = 0x1;
const LBS_OWNERDRAWFIXED = 0x10;
const LBS_NOINTEGRALHEIGHT = 0x100;
const LBS_NODATA = 0x2000;

const LB_SETCURSEL = 0x186;
const LB_GETCURSEL = 0x188;
const LB_GETTOPINDEX = 0x18E;
const LB_SETCOUNT = 0x1A7;
const LB_ITEMFROMPOINT = 0x1A9;
const LBN_SELCHANGE = 1;
const LBN_DBLCLK = 2;
const LBN_KILLFOCUS = 5;
const EN_SETFOCUS = 0x100;
const EN_KILLFOCUS = 0x200;
const EN_CHANGE = 0x300;

const DT_RIGHT = 0x2;
const DT_CENTER = 0x1;
const DT_V = 0x4 | 0x20 | 0x800 | 0x8000;

const Palette = struct {
    bg: u32,
    card: u32,
    card_border: u32,
    field: u32,
    field_border: u32,
    text: u32,
    text2: u32,
    accent: u32,
    on_accent: u32,
    btn: u32,
    btn_border: u32,
    sel: u32,
    good: u32,
};

const dark_pal: Palette = .{
    .bg = 0x202020,
    .card = 0x2B2B2B,
    .card_border = 0x383838,
    .field = 0x333333,
    .field_border = 0x454545,
    .text = 0xFFFFFF,
    .text2 = 0xA8A8A8,
    .accent = 0x60CDFF,
    .on_accent = 0x000000,
    .btn = 0x373737,
    .btn_border = 0x474747,
    .sel = 0x3A3A3A,
    .good = 0x6CCB5F,
};

const light_pal: Palette = .{
    .bg = 0xF3F3F3,
    .card = 0xFFFFFF,
    .card_border = 0xE5E5E5,
    .field = 0xFBFBFB,
    .field_border = 0xD6D6D6,
    .text = 0x1B1B1B,
    .text2 = 0x606060,
    .accent = 0x0067C0,
    .on_accent = 0xFFFFFF,
    .btn = 0xFDFDFD,
    .btn_border = 0xE0E0E0,
    .sel = 0xECECEC,
    .good = 0x0F7B0F,
};

var pal: Palette = dark_pal;
var dark_mode: bool = true;
var br_bg: ?*anyopaque = null;
var br_card: ?*anyopaque = null;
var br_field: ?*anyopaque = null;

var f_body: *anyopaque = undefined;
var f_semi: *anyopaque = undefined;
var f_title: *anyopaque = undefined;
var f_small: *anyopaque = undefined;
var f_mono: *anyopaque = undefined;

var scale: f32 = 1.0;

fn S(v: i32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(v)) * scale));
}

fn cr(rgb: u32) u32 {
    return ((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF);
}

fn argb(rgb: u32) u32 {
    return 0xFF000000 | rgb;
}

fn mix(a: u32, b: u32, t: u32) u32 {
    var out: u32 = 0;
    inline for (.{ 16, 8, 0 }) |sh| {
        const ca: u32 = (a >> sh) & 0xFF;
        const cb: u32 = (b >> sh) & 0xFF;
        const c: u32 = (ca * (100 - t) + cb * t) / 100;
        out |= c << sh;
    }
    return out;
}

const Box = struct { x: i32, y: i32, w: i32, h: i32 };

fn bx(x: i32, y: i32, w: i32, h: i32) Box {
    return .{ .x = x, .y = y, .w = w, .h = h };
}

fn sbox(b: Box) Box {
    return .{ .x = S(b.x), .y = S(b.y), .w = S(b.w), .h = S(b.h) };
}

const client_w = 960;
const client_h = 700;
const min_client_w = 760;
const min_client_h = 620;

var lw: i32 = client_w;
var lh: i32 = client_h;

var b_pill: Box = bx(150, 12, 300, 32);
var b_more: Box = bx(900, 12, 44, 32);

var b_card_pick: Box = bx(16, 60, 928, 600);
var b_filter: Box = bx(32, 76, 896, 36);
var b_procs: Box = bx(32, 120, 896, 480);
var b_pick_close: Box = bx(828, 616, 100, 32);

var b_card_res: Box = bx(16, 60, 440, 320);
var b_results: Box = bx(32, 118, 408, 246);

var b_card_scan: Box = bx(472, 60, 472, 320);
var b_first: Box = bx(488, 76, 140, 40);
var b_next: Box = bx(636, 76, 140, 40);
var b_reset: Box = bx(784, 76, 144, 40);
var b_value_full: Box = bx(488, 130, 440, 36);
var b_value_half: Box = bx(488, 130, 214, 36);
var b_value2: Box = bx(714, 130, 214, 36);
var b_dd_cond: Box = bx(488, 198, 214, 36);
var b_dd_type: Box = bx(714, 198, 214, 36);
var b_writable: Box = bx(488, 248, 440, 28);

var b_card_tbl: Box = bx(16, 388, 928, 272);
var b_table: Box = bx(32, 420, 896, 178);
var b_desc: Box = bx(32, 608, 300, 36);
var b_newval: Box = bx(340, 608, 200, 36);
var b_write: Box = bx(548, 608, 100, 36);
var b_freeze: Box = bx(656, 608, 130, 36);
var b_delete: Box = bx(794, 608, 134, 36);

var b_footer: Box = bx(0, 664, 960, 36);
var b_cancel: Box = bx(836, 668, 108, 28);

fn layout() void {
    var rc: RECT = undefined;
    if (GetClientRect(main_wnd, &rc) == 0) return;
    lw = @max(min_client_w, @as(i32, @intFromFloat(@as(f32, @floatFromInt(rc.right)) / scale + 0.5)));
    lh = @max(min_client_h, @as(i32, @intFromFloat(@as(f32, @floatFromInt(rc.bottom)) / scale + 0.5)));

    const margin: i32 = 16;
    const gap: i32 = 16;
    const header_y: i32 = 60;
    const top_h: i32 = 320;
    const footer_h: i32 = 36;
    const footer_y = lh - footer_h;
    const content_bottom = footer_y - 4;
    const inner_w = lw - margin * 2;

    b_pill = bx(150, 12, 300, 32);
    b_more = bx(lw - 60, 12, 44, 32);

    const res_w = @divTrunc((inner_w - gap) * 440, 912);
    const scan_x = margin + res_w + gap;
    const scan_w = inner_w - res_w - gap;

    b_card_res = bx(margin, header_y, res_w, top_h);
    b_card_scan = bx(scan_x, header_y, scan_w, top_h);
    b_card_tbl = bx(margin, header_y + top_h + 8, inner_w, content_bottom - (header_y + top_h + 8));

    b_results = bx(b_card_res.x + 16, b_card_res.y + 58, b_card_res.w - 32, b_card_res.h - 74);

    const sx = b_card_scan.x + 16;
    const sw = b_card_scan.w - 32;
    const btn_w = @divTrunc((sw - 16) * 140, 424);
    b_first = bx(sx, b_card_scan.y + 16, btn_w, 40);
    b_next = bx(b_first.x + btn_w + 8, b_card_scan.y + 16, btn_w, 40);
    b_reset = bx(b_next.x + btn_w + 8, b_card_scan.y + 16, sw - btn_w * 2 - 16, 40);

    const value_y = b_card_scan.y + 70;
    const half = @divTrunc(sw - 12, 2);
    b_value_full = bx(sx, value_y, sw, 36);
    b_value_half = bx(sx, value_y, half, 36);
    b_value2 = bx(sx + half + 12, value_y, sw - half - 12, 36);
    b_dd_cond = bx(sx, b_card_scan.y + 138, half, 36);
    b_dd_type = bx(sx + half + 12, b_card_scan.y + 138, sw - half - 12, 36);
    b_writable = bx(sx, b_card_scan.y + 188, sw, 28);

    const form_y = b_card_tbl.y + b_card_tbl.h - 52;
    b_delete = bx(b_card_tbl.x + b_card_tbl.w - 16 - 134, form_y, 134, 36);
    b_freeze = bx(b_delete.x - 8 - 130, form_y, 130, 36);
    b_write = bx(b_freeze.x - 8 - 100, form_y, 100, 36);
    b_newval = bx(b_write.x - 8 - 200, form_y, 200, 36);
    b_desc = bx(b_card_tbl.x + 16, form_y, b_newval.x - 8 - (b_card_tbl.x + 16), 36);
    b_table = bx(b_card_tbl.x + 16, b_card_tbl.y + 32, b_card_tbl.w - 32, form_y - 10 - (b_card_tbl.y + 32));

    b_card_pick = bx(margin, header_y, inner_w, content_bottom - header_y);
    b_filter = bx(b_card_pick.x + 16, b_card_pick.y + 16, b_card_pick.w - 32, 36);
    b_procs = bx(b_card_pick.x + 16, b_card_pick.y + 60, b_card_pick.w - 32, b_card_pick.h - 120);
    b_pick_close = bx(b_card_pick.x + b_card_pick.w - 16 - 100, b_card_pick.y + b_card_pick.h - 44, 100, 32);

    b_footer = bx(0, footer_y, lw, footer_h);
    b_cancel = bx(lw - 16 - 108, footer_y + 4, 108, 28);
}

const ID_FILTER: usize = 1;
const ID_PROCS: usize = 2;
const ID_DD_TYPE: usize = 3;
const ID_DD_COND: usize = 4;
const ID_VALUE: usize = 5;
const ID_VALUE2: usize = 6;
const ID_FIRST: usize = 7;
const ID_NEXT: usize = 8;
const ID_RESET: usize = 9;
const ID_WRITABLE: usize = 10;
const ID_RESULTS: usize = 11;
const ID_TABLE: usize = 12;
const ID_DESC: usize = 13;
const ID_NEWVAL: usize = 14;
const ID_WRITE: usize = 15;
const ID_FREEZE: usize = 16;
const ID_DELETE: usize = 17;
const ID_PILL: usize = 18;
const ID_MORE: usize = 19;
const ID_CANCEL: usize = 20;
const ID_POPUP: usize = 21;
const ID_PICK_CLOSE: usize = 22;

const TIMER_FREEZE: usize = 1;
const TIMER_HOVER: usize = 2;
const TIMER_LIVE: usize = 3;
const TIMER_PROGRESS: usize = 4;
const TIMER_ANIM: usize = 5;

const PopupKind = enum { none, type, cond, menu };

const first_modes = [_]scan.Mode{ .exact, .greater, .less, .between, .unknown };
const next_modes = [_]scan.Mode{ .exact, .greater, .less, .between, .changed, .unchanged, .increased, .decreased };
const type_kinds = [_]scan.Kind{ .int8, .uint8, .int16, .uint16, .int32, .uint32, .int64, .uint64, .float32, .float64 };
const type_names = [_][]const u8{ "int8", "uint8", "int16", "uint16", "int32", "uint32", "int64", "uint64", "float32", "float64" };

fn kindIndex(kind: scan.Kind) usize {
    return std.mem.indexOfScalar(scan.Kind, &type_kinds, kind) orelse 0;
}

const Ui = struct {
    pill: HWND,
    more: HWND,
    filter: HWND,
    procs: HWND,
    pick_close: HWND,
    dd_type: HWND,
    dd_cond: HWND,
    value: HWND,
    value2: HWND,
    btn_first: HWND,
    btn_next: HWND,
    btn_reset: HWND,
    writable: HWND,
    results: HWND,
    table: HWND,
    desc: HWND,
    newval: HWND,
    btn_write: HWND,
    btn_freeze: HWND,
    btn_delete: HWND,
    cancel: HWND,
    popup: HWND,
};

const Row = struct {
    addr: usize,
    kind: scan.Kind,
    desc: [128]u8,
    desc_len: usize,
    frozen: bool,
    fval: [8]u8,
    // Last value sampled by liveTick, so painting never reads process memory.
    shown: [48]u8,
    shown_len: usize,
    shown_ok: bool,
};

const Job = struct {
    first: bool,
    kind: scan.Kind,
    cond: scan.Cond,
    writable: bool,
    p: win.Process,
    err: ?[]const u8,
    canceled: bool,
};

var ui: Ui = undefined;
var main_wnd: HWND = undefined;
var hinst: HINSTANCE = undefined;
var focused_id: usize = 0;
var picker: bool = false;
var kind_sel: usize = 4;
var cond_mode: scan.Mode = .exact;
var writable_only: bool = true;
var scan_active: bool = false;
var loading_edit: bool = false;

var popup_kind: PopupKind = .none;
var popup_items: [10][]const u8 = undefined;
var popup_n: usize = 0;
var popup_cur: usize = std.math.maxInt(usize);
var popup_hot: usize = std.math.maxInt(usize);
var popup_rc: Box = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
var popup_cond_list: [8]scan.Mode = undefined;
var popup_closed_kind: PopupKind = .none;
var popup_closed_at: u64 = 0;

var ui_ready = false;
var anim_on = false;

var anim_btns: [24]HWND = undefined;
var anim_hot: [24]i32 = undefined;
var anim_n: usize = 0;

var prog_shown: i32 = 0;

var theme_from: Palette = dark_pal;
var theme_to: Palette = dark_pal;
var theme_t0: u64 = 0;
var theme_anim = false;

var popup_anim = false;
var popup_anim_t0: u64 = 0;
var popup_final_y: i32 = 0;

var proc: ?win.Process = null;
var proc_label: [96]u8 = undefined;
var proc_label_len: usize = 0;
var sc: scan.Scanner = .{};
var procs: std.ArrayList(win.ProcEntry) = .empty;
var table: std.ArrayList(Row) = .empty;

var busy = std.atomic.Value(bool).init(false);
var job: Job = undefined;
var job_start: u64 = 0;

// Visible-window cache for the results list: the previous value comes from the
// match record, but the current value is sampled by liveTick instead of WM_DRAWITEM.
const cache_cap = 64;
var res_cache_idx: [cache_cap]usize = std.mem.zeroes([cache_cap]usize);
var res_cache_len: [cache_cap]usize = std.mem.zeroes([cache_cap]usize);
var res_cache_text: [cache_cap][48]u8 = std.mem.zeroes([cache_cap][48]u8);
var res_cache_filled: [cache_cap]bool = std.mem.zeroes([cache_cap]bool);
var res_cache_top: usize = std.math.maxInt(usize);

var status_buf: [256]u8 = undefined;
var status_len: usize = 0;

const max_shown = 100000;

fn L(comptime s: []const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

fn toWide(s: []const u8, buf: []u16) [:0]u16 {
    const src = s[0..@min(s.len, buf.len - 1)];
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], src) catch 0;
    buf[n] = 0;
    return buf[0..n :0];
}

fn setText(h: HWND, s: []const u8) void {
    var w: [512]u16 = undefined;
    const z = toWide(s, &w);
    _ = SetWindowTextW(h, z.ptr);
}

fn show(h: HWND, visible: bool) void {
    _ = ShowWindow(h, if (visible) 5 else 0);
}

fn fillRgb(hdc: HDC, rc: RECT, rgb: u32) void {
    const b = CreateSolidBrush(cr(rgb)) orelse return;
    _ = FillRect(hdc, &rc, b);
    _ = DeleteObject(b);
}

fn text(hdc: HDC, font: *anyopaque, rgb: u32, s: []const u8, x: i32, y: i32, w: i32, h: i32, flags: u32) void {
    var wbuf: [512]u16 = undefined;
    const z = toWide(s, &wbuf);
    _ = SelectObject(hdc, font);
    _ = SetBkMode(hdc, 1);
    _ = SetTextColor(hdc, cr(rgb));
    var rc: RECT = .{ .left = x, .top = y, .right = x + w, .bottom = y + h };
    _ = DrawTextW(hdc, z.ptr, @intCast(z.len), &rc, flags);
}

fn rrect(hdc: HDC, x: i32, y: i32, w: i32, h: i32, r: i32, fill: ?u32, border: ?u32) void {
    if (w < 3 or h < 3) return;
    var g: ?*anyopaque = null;
    if (GdipCreateFromHDC(hdc, &g) != 0) return;
    defer _ = GdipDeleteGraphics(g);
    _ = GdipSetSmoothingMode(g, 4);

    var path: ?*anyopaque = null;
    if (GdipCreatePath(0, &path) != 0) return;
    defer _ = GdipDeletePath(path);

    const ww = w - 1;
    const hh = h - 1;
    const rr = @min(r, @divTrunc(@min(ww, hh), 2));
    const d = rr * 2;
    if (d < 2) {
        _ = GdipAddPathRectangleI(path, x, y, ww, hh);
    } else {
        _ = GdipAddPathArcI(path, x, y, d, d, 180, 90);
        _ = GdipAddPathArcI(path, x + ww - d, y, d, d, 270, 90);
        _ = GdipAddPathArcI(path, x + ww - d, y + hh - d, d, d, 0, 90);
        _ = GdipAddPathArcI(path, x, y + hh - d, d, d, 90, 90);
        _ = GdipClosePathFigure(path);
    }

    if (fill) |f| {
        var b: ?*anyopaque = null;
        if (GdipCreateSolidFill(argb(f), &b) == 0) {
            _ = GdipFillPath(g, b, path);
            _ = GdipDeleteBrush(b);
        }
    }
    if (border) |bc| {
        var pen: ?*anyopaque = null;
        if (GdipCreatePen1(argb(bc), 1.0, 2, &pen) == 0) {
            _ = GdipDrawPath(g, pen, path);
            _ = GdipDeletePen(pen);
        }
    }
}

fn drawCard(hdc: HDC, b: Box) void {
    const s = sbox(b);
    rrect(hdc, s.x, s.y, s.w, s.h, S(8), pal.card, pal.card_border);
}

fn drawField(hdc: HDC, b: Box, id: usize, caption: []const u8) void {
    const s = sbox(b);
    rrect(hdc, s.x, s.y, s.w, s.h, S(5), pal.field, pal.field_border);
    text(hdc, f_small, pal.text2, caption, s.x + S(10), s.y, S(80), s.h, DT_V);
    if (focused_id == id) {
        rrect(hdc, s.x + S(3), s.y + s.h - S(3), s.w - S(6), S(2), 1, pal.accent, null);
    }
}

fn note(hdc: HDC, s: []const u8, x: i32, y: i32, w: i32) void {
    text(hdc, f_small, pal.text2, s, S(x), S(y), S(w), S(18), DT_V);
}

fn condLabel(m: scan.Mode) []const u8 {
    return switch (m) {
        .exact => "Exact",
        .greater => "Greater",
        .less => "Less",
        .between => "Between",
        .unknown => "Unknown",
        .changed => "Changed",
        .unchanged => "Unchanged",
        .increased => "Increased",
        .decreased => "Decreased",
    };
}

fn valueBox() Box {
    return if (cond_mode == .between) b_value_half else b_value_full;
}

fn paintMain(hwnd: HWND) void {
    var ps: PAINTSTRUCT = undefined;
    const hdc = BeginPaint(hwnd, &ps) orelse return;
    defer _ = EndPaint(hwnd, &ps);

    var rc: RECT = undefined;
    _ = GetClientRect(hwnd, &rc);
    const w = rc.right;
    const h = rc.bottom;
    if (w < 2 or h < 2) return;

    const mdc = CreateCompatibleDC(hdc) orelse return;
    defer _ = DeleteDC(mdc);
    const bmp = CreateCompatibleBitmap(hdc, w, h) orelse return;
    defer _ = DeleteObject(bmp);
    const old = SelectObject(mdc, bmp);
    defer if (old) |o| {
        _ = SelectObject(mdc, o);
    };

    if (br_bg) |b| _ = FillRect(mdc, &rc, b);

    const busy_now = busy.load(.acquire);

    text(mdc, f_title, pal.text, "Memfract", S(20), S(10), S(130), S(36), DT_V);

    if (picker) {
        drawCard(mdc, b_card_pick);
        drawField(mdc, b_filter, ID_FILTER, "Search");
        note(mdc, "Double-click a process to attach", b_card_pick.x + 16, b_card_pick.y + b_card_pick.h - 38, b_card_pick.w - 32);
    } else {
        drawCard(mdc, b_card_res);
        drawCard(mdc, b_card_scan);
        drawCard(mdc, b_card_tbl);

        var cb: [64]u8 = undefined;
        // The scan thread owns the match list: only read it after observing
        // busy == false (the release store synchronizes with this acquire load).
        const found_s: []const u8 = if (busy_now)
            "Scanning..."
        else
            std.fmt.bufPrint(&cb, "Found: {d}{s}", .{ sc.matches.items.len, if (sc.truncated) " (truncated)" else "" }) catch "";
        text(mdc, f_semi, pal.text, found_s, S(b_card_res.x + 16), S(b_card_res.y + 8), S(b_card_res.w - 32), S(24), DT_V);
        const rw = b_results.w;
        note(mdc, "Address", b_results.x + @divTrunc(rw * 12, 408), b_card_res.y + 36, 150);
        note(mdc, "Value", b_results.x + @divTrunc(rw * 190, 408), b_card_res.y + 36, 100);
        note(mdc, "Previous", b_results.x + @divTrunc(rw * 300, 408), b_card_res.y + 36, 100);

        drawField(mdc, valueBox(), ID_VALUE, "Value");
        if (cond_mode == .between) drawField(mdc, b_value2, ID_VALUE2, "To");
        note(mdc, "Condition", b_card_scan.x + 16, b_card_scan.y + 118, 200);
        note(mdc, "Value type", b_dd_type.x, b_card_scan.y + 118, b_dd_type.w);
        note(mdc, "Double-click an address on the left to add it to the table.", b_card_scan.x + 16, b_card_scan.y + 232, b_card_scan.w - 32);
        note(mdc, "Double-click a table row to freeze / unfreeze it.", b_card_scan.x + 16, b_card_scan.y + 252, b_card_scan.w - 32);

        const tw = b_table.w;
        note(mdc, "On", b_table.x + @divTrunc(tw * 20, 896), b_card_tbl.y + 10, 50);
        note(mdc, "Description", b_table.x + @divTrunc(tw * 64, 896), b_card_tbl.y + 10, 200);
        note(mdc, "Address", b_table.x + @divTrunc(tw * 364, 896), b_card_tbl.y + 10, 150);
        note(mdc, "Type", b_table.x + @divTrunc(tw * 564, 896), b_card_tbl.y + 10, 80);
        note(mdc, "Value", b_table.x + @divTrunc(tw * 664, 896), b_card_tbl.y + 10, 150);
        drawField(mdc, b_desc, ID_DESC, "Description");
        drawField(mdc, b_newval, ID_NEWVAL, "Value");
    }

    if (popup_kind != .none) {
        rrect(mdc, popup_rc.x - 1, popup_rc.y - 1, popup_rc.w + 2, popup_rc.h + 2, S(6), null, pal.field_border);
    }

    const fy = S(b_footer.y);
    rrect(mdc, S(20), fy + S(14), S(8), S(8), S(4), if (busy_now) pal.accent else pal.good, null);
    const status_w = if (busy_now) S(@max(220, lw - 440)) else S(lw - 180);
    text(mdc, f_body, pal.text2, status_buf[0..status_len], S(36), fy + S(4), status_w, S(28), DT_V);
    if (busy_now) {
        const pr: i32 = prog_shown;
        const bw = S(200);
        const bxx = S(lw - 400);
        const byy = fy + S(15);
        rrect(mdc, bxx, byy, bw, S(6), S(3), pal.field_border, null);
        const fw = @divTrunc(bw * pr, 1000);
        if (fw > S(6)) rrect(mdc, bxx, byy, fw, S(6), S(3), pal.accent, null);
        var pb: [16]u8 = undefined;
        const pct = std.fmt.bufPrint(&pb, "{d}%", .{@divTrunc(pr, 10)}) catch "";
        text(mdc, f_small, pal.text2, pct, S(lw - 192), fy + S(4), S(50), S(28), DT_V);
    }

    _ = BitBlt(hdc, 0, 0, w, h, mdc, 0, 0, 0x00CC0020);
}

const BtnStyle = enum { accent, normal, dropdown, pill, check };

fn styleOf(id: usize) BtnStyle {
    return switch (id) {
        ID_FIRST, ID_WRITE => .accent,
        ID_DD_TYPE, ID_DD_COND, ID_MORE => .dropdown,
        ID_PILL => .pill,
        ID_WRITABLE => .check,
        else => .normal,
    };
}

fn onBackground(id: usize) bool {
    return switch (id) {
        ID_PILL, ID_MORE, ID_CANCEL => true,
        else => false,
    };
}

fn hoverAmount(h: HWND) i32 {
    for (anim_btns[0..anim_n], 0..) |bh, i| {
        if (bh == h) return anim_hot[i];
    }
    return 0;
}

fn drawButton(di: *const DRAWITEMSTRUCT) void {
    const id: usize = di.CtlID;
    const rc = di.rcItem;
    const w = rc.right - rc.left;
    const h = rc.bottom - rc.top;
    const hdc = di.hDC;
    const disabled = (id == ID_NEXT or id == ID_RESET) and !scan_active;
    const pressed = (di.itemState & 1) != 0 and !disabled;
    const hv: i32 = if (disabled) 0 else hoverAmount(di.hwndItem);
    const hot = hv > 50;
    const st = styleOf(id);

    fillRgb(hdc, rc, if (onBackground(id)) pal.bg else pal.card);

    var tb: [384]u8 = undefined;
    const label_s = getText(di.hwndItem, &tb);

    if (st == .check) {
        const bsz = S(18);
        const by = rc.top + @divTrunc(h - bsz, 2);
        rrect(hdc, rc.left + S(2), by, bsz, bsz, S(4), if (writable_only) pal.accent else pal.field, if (writable_only) null else pal.field_border);
        if (writable_only) text(hdc, f_semi, pal.on_accent, "✓", rc.left + S(2), by, bsz, bsz, DT_V | DT_CENTER);
        text(hdc, f_body, if (hot) pal.text else pal.text2, label_s, rc.left + S(30), rc.top, w - S(30), h, DT_V);
        return;
    }

    var fill: u32 = pal.btn;
    var border: ?u32 = pal.btn_border;
    var fg: u32 = pal.text;
    var radius: i32 = S(5);
    switch (st) {
        .accent => {
            fill = pal.accent;
            border = null;
            fg = pal.on_accent;
        },
        .pill => radius = @divTrunc(h, 2),
        .dropdown => {
            if (id == ID_MORE) {
                fill = pal.bg;
                border = null;
            }
        },
        else => {},
    }
    if (id == ID_CANCEL) {
        fill = pal.bg;
    }
    if (disabled) {
        fg = pal.text2;
        fill = pal.card;
    } else if (pressed) {
        fill = mix(fill, pal.bg, 30);
    } else if (hv > 0) {
        fill = mix(fill, pal.text, @intCast(@divTrunc(9 * hv, 100)));
    }

    rrect(hdc, rc.left, rc.top, w, h, radius, fill, border);

    if (st == .pill) {
        const dot = if (proc != null) pal.good else pal.text2;
        rrect(hdc, rc.left + S(14), rc.top + @divTrunc(h - S(8), 2), S(8), S(8), S(4), dot, null);
        text(hdc, f_body, fg, label_s, rc.left + S(30), rc.top, w - S(40), h, DT_V);
    } else if (st == .dropdown and id != ID_MORE) {
        text(hdc, f_body, fg, label_s, rc.left + S(12), rc.top, w - S(16), h, DT_V);
    } else {
        text(hdc, f_semi, fg, label_s, rc.left, rc.top, w, h, DT_V | DT_CENTER);
    }
}

fn rowValueText(row: Row, vb: []u8) []const u8 {
    const p = proc orelse return "??";
    var cur: [8]u8 = undefined;
    const sz = row.kind.size();
    p.read(row.addr, cur[0..sz]) catch return "??";
    return scan.fmtValue(row.kind, cur[0..sz], vb);
}

fn drawListItem(di: *const DRAWITEMSTRUCT) void {
    if (di.itemID == 0xFFFFFFFF) return;
    const idx: usize = di.itemID;
    const id: usize = di.CtlID;
    const hdc = di.hDC;
    const rc = di.rcItem;
    const w = rc.right - rc.left;
    const h = rc.bottom - rc.top;

    fillRgb(hdc, rc, pal.card);
    if (id != ID_POPUP and (di.itemState & 1) != 0) {
        rrect(hdc, rc.left + S(2), rc.top + S(2), w - S(4), h - S(4), S(5), pal.sel, null);
        rrect(hdc, rc.left + S(4), rc.top + @divTrunc(h - S(16), 2), S(3), S(16), 1, pal.accent, null);
    }

    if (id == ID_PROCS) {
        if (idx >= procs.items.len) return;
        const e = procs.items[idx];
        text(hdc, f_body, pal.text, e.name[0..e.name_len], rc.left + S(16), rc.top, w - S(116), h, DT_V);
        var pb: [32]u8 = undefined;
        const pid_s = std.fmt.bufPrint(&pb, "PID {d}", .{e.pid}) catch "";
        text(hdc, f_small, pal.text2, pid_s, rc.right - S(100), rc.top, S(90), h, DT_V | DT_RIGHT);
    } else if (id == ID_RESULTS) {
        if (busy.load(.acquire) or idx >= sc.matches.items.len) return;
        const m = sc.matches.items[idx];
        const addr_x = rc.left + @divTrunc(w * 12, 408);
        const val_x = rc.left + @divTrunc(w * 190, 408);
        const prev_x = rc.left + @divTrunc(w * 300, 408);
        const addr_w = @divTrunc(w * 176, 408);
        const val_w = @divTrunc(w * 106, 408);

        var ab: [32]u8 = undefined;
        const addr_s = std.fmt.bufPrint(&ab, "0x{X:0>16}", .{m.addr}) catch "";
        text(hdc, f_mono, pal.text2, addr_s, addr_x, rc.top, addr_w, h, DT_V);

        var pv: [48]u8 = undefined;
        const slot = idx % cache_cap;
        const cur_s: []const u8 = if (res_cache_filled[slot] and res_cache_idx[slot] == idx)
            res_cache_text[slot][0..res_cache_len[slot]]
        else
            "...";
        const prev_s = scan.fmtValue(sc.kind, m.old[0..sc.kind.size()], &pv);
        const changed = !std.mem.eql(u8, cur_s, prev_s);
        text(hdc, f_semi, if (changed) pal.accent else pal.text, cur_s, val_x, rc.top, val_w, h, DT_V);
        text(hdc, f_body, pal.text2, prev_s, prev_x, rc.top, rc.right - S(4) - prev_x, h, DT_V);
    } else if (id == ID_TABLE) {
        if (idx >= table.items.len) return;
        const row = table.items[idx];
        const desc_x = rc.left + @divTrunc(w * 64, 896);
        const addr_x = rc.left + @divTrunc(w * 364, 896);
        const type_x = rc.left + @divTrunc(w * 564, 896);
        const val_x = rc.left + @divTrunc(w * 664, 896);

        const bsz = S(16);
        const cx = rc.left + S(20);
        const cy = rc.top + @divTrunc(h - bsz, 2);
        rrect(hdc, cx, cy, bsz, bsz, S(4), if (row.frozen) pal.accent else pal.field, if (row.frozen) null else pal.field_border);
        if (row.frozen) text(hdc, f_semi, pal.on_accent, "✓", cx, cy, bsz, bsz, DT_V | DT_CENTER);

        const desc: []const u8 = if (row.desc_len == 0) "No description" else row.desc[0..row.desc_len];
        text(hdc, f_body, if (row.desc_len == 0) pal.text2 else pal.text, desc, desc_x, rc.top, addr_x - desc_x - S(8), h, DT_V);

        var ab: [32]u8 = undefined;
        const addr_s = std.fmt.bufPrint(&ab, "0x{X:0>16}", .{row.addr}) catch "";
        text(hdc, f_mono, pal.text2, addr_s, addr_x, rc.top, type_x - addr_x - S(8), h, DT_V);
        text(hdc, f_body, pal.text2, @tagName(row.kind), type_x, rc.top, val_x - type_x - S(8), h, DT_V);

        const val_s: []const u8 = if (row.shown_ok) row.shown[0..row.shown_len] else "??";
        text(hdc, f_semi, pal.text, val_s, val_x, rc.top, rc.right - S(4) - val_x, h, DT_V);
    } else if (id == ID_POPUP) {
        if (idx >= popup_n) return;
        if (idx == popup_hot or (di.itemState & 1) != 0) {
            rrect(hdc, rc.left + S(4), rc.top + S(2), w - S(8), h - S(4), S(5), pal.sel, null);
        }
        const current = idx == popup_cur;
        if (current) rrect(hdc, rc.left + S(6), rc.top + @divTrunc(h - S(16), 2), S(3), S(16), 1, pal.accent, null);
        text(hdc, if (current) f_semi else f_body, pal.text, popup_items[idx], rc.left + S(18), rc.top, w - S(28), h, DT_V);
    }
}

fn getText(h: HWND, out: []u8) []const u8 {
    var w: [128]u16 = undefined;
    const got = GetWindowTextW(h, &w, 128);
    const n: usize = if (got > 0) @intCast(got) else 0;
    const m = std.unicode.utf16LeToUtf8(out, w[0..n]) catch return out[0..0];
    return std.mem.trim(u8, out[0..m], " ");
}

fn setStatus(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&status_buf, fmt, args) catch status_buf[0..0];
    status_len = s.len;
    const fr = sbox(b_footer);
    const rc: RECT = .{ .left = fr.x, .top = fr.y, .right = fr.x + fr.w, .bottom = fr.y + fr.h };
    _ = InvalidateRect(main_wnd, &rc, 0);
    _ = UpdateWindow(main_wnd);
}

fn child(parent: HWND, class: [*:0]const u16, caption_w: [*:0]const u16, style: u32, b: Box, id: usize) !HWND {
    const s = sbox(b);
    const hw = CreateWindowExW(0, class, caption_w, WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | style, s.x, s.y, s.w, s.h, parent, id, hinst, null) orelse return error.CreateControlFailed;
    _ = SendMessageW(hw, WM_SETFONT, @intFromPtr(f_body), 1);
    return hw;
}

fn editRect(field: Box, capw: i32) Box {
    return bx(field.x + 10 + capw, field.y + 8, field.w - 20 - capw, field.h - 16);
}

fn edit(parent: HWND, field: Box, id: usize, capw: i32) !HWND {
    return child(parent, L("EDIT"), L(""), WS_TABSTOP | ES_AUTOHSCROLL, editRect(field, capw), id);
}

fn button(parent: HWND, caption_w: [*:0]const u16, b: Box, id: usize) !HWND {
    const h = try child(parent, L("BUTTON"), caption_w, BS_OWNERDRAW | WS_TABSTOP, b, id);
    if (anim_n < anim_btns.len) {
        anim_btns[anim_n] = h;
        anim_hot[anim_n] = 0;
        anim_n += 1;
    }
    return h;
}

fn mkFont(height: i32, weight: i32, face: [*:0]const u16) !*anyopaque {
    return CreateFontW(-S(height), 0, 0, 0, weight, 0, 0, 0, 1, 0, 0, 5, 0, face) orelse error.FontFailed;
}

fn mixPalette(a: Palette, b: Palette, t: u32) Palette {
    return .{
        .bg = mix(a.bg, b.bg, t),
        .card = mix(a.card, b.card, t),
        .card_border = mix(a.card_border, b.card_border, t),
        .field = mix(a.field, b.field, t),
        .field_border = mix(a.field_border, b.field_border, t),
        .text = mix(a.text, b.text, t),
        .text2 = mix(a.text2, b.text2, t),
        .accent = mix(a.accent, b.accent, t),
        .on_accent = mix(a.on_accent, b.on_accent, t),
        .btn = mix(a.btn, b.btn, t),
        .btn_border = mix(a.btn_border, b.btn_border, t),
        .sel = mix(a.sel, b.sel, t),
        .good = mix(a.good, b.good, t),
    };
}

fn smooth(t: f32) f32 {
    return t * t * (3.0 - 2.0 * t);
}

fn rebuildBrushes() void {
    if (br_bg) |b| _ = DeleteObject(b);
    if (br_card) |b| _ = DeleteObject(b);
    if (br_field) |b| _ = DeleteObject(b);
    br_bg = CreateSolidBrush(cr(pal.bg));
    br_card = CreateSolidBrush(cr(pal.card));
    br_field = CreateSolidBrush(cr(pal.field));
}

fn applyThemeChrome() void {
    const d: i32 = if (dark_mode) 1 else 0;
    _ = DwmSetWindowAttribute(main_wnd, 20, &d, 4);
    const cap: u32 = cr(theme_to.bg);
    _ = DwmSetWindowAttribute(main_wnd, 35, &cap, 4);
    const txt: u32 = cr(theme_to.text);
    _ = DwmSetWindowAttribute(main_wnd, 36, &txt, 4);

    const theme = if (dark_mode) L("DarkMode_Explorer") else L("Explorer");
    _ = SetWindowTheme(ui.procs, theme, null);
    _ = SetWindowTheme(ui.results, theme, null);
    _ = SetWindowTheme(ui.table, theme, null);
}

fn applyTheme() void {
    theme_from = pal;
    theme_to = if (dark_mode) dark_pal else light_pal;
    theme_t0 = GetTickCount64();
    theme_anim = true;
    syncAnimTimer();
    applyThemeChrome();
}

fn syncAnimTimer() void {
    if (theme_anim or popup_anim) {
        if (!anim_on) {
            _ = SetTimer(main_wnd, TIMER_ANIM, 16, null);
            anim_on = true;
        }
    } else if (anim_on) {
        _ = KillTimer(main_wnd, TIMER_ANIM);
        anim_on = false;
    }
}

fn animTick() void {
    const now = GetTickCount64();

    if (theme_anim) {
        const t: f32 = @min(1.0, @as(f32, @floatFromInt(now - theme_t0)) / 220.0);
        const e = smooth(t);
        pal = mixPalette(theme_from, theme_to, @intFromFloat(e * 100.0));
        rebuildBrushes();
        _ = RedrawWindow(main_wnd, null, null, 0x85);
        if (t >= 1.0) theme_anim = false;
    }

    if (popup_anim) {
        const t = @min(1.0, @as(f32, @floatFromInt(now - popup_anim_t0)) / 140.0);
        const off: i32 = @intFromFloat((1.0 - smooth(t)) * 8.0);
        popup_rc.y = popup_final_y + off;
        _ = MoveWindow(ui.popup, popup_rc.x, popup_rc.y, popup_rc.w, popup_rc.h, 1);
        _ = InvalidateRect(main_wnd, null, 0);
        if (t >= 1.0) {
            popup_rc.y = popup_final_y;
            popup_anim = false;
        }
    }

    syncAnimTimer();
}

fn systemUsesLightTheme() bool {
    var data: u32 = 1;
    var size: u32 = 4;
    const rc = RegGetValueW(
        0x80000001,
        L("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
        L("AppsUseLightTheme"),
        0x10,
        null,
        &data,
        &size,
    );
    return rc != 0 or data != 0;
}

fn normalizeCond() void {
    const valid = if (scan_active) cond_mode != .unknown else switch (cond_mode) {
        .exact, .greater, .less, .between, .unknown => true,
        else => false,
    };
    if (!valid) cond_mode = .exact;
}

fn layoutValue() void {
    const s = sbox(editRect(valueBox(), 62));
    _ = MoveWindow(ui.value, s.x, s.y, s.w, s.h, 1);
    show(ui.value2, !picker and cond_mode == .between);
}

fn moveBox(h: HWND, b: Box) void {
    const s = sbox(b);
    _ = MoveWindow(h, s.x, s.y, s.w, s.h, 1);
}

fn relayout() void {
    if (!ui_ready) return;
    closePopup();
    layout();
    moveBox(ui.pill, b_pill);
    moveBox(ui.more, b_more);
    moveBox(ui.filter, b_filter);
    moveBox(ui.procs, b_procs);
    moveBox(ui.pick_close, b_pick_close);
    moveBox(ui.results, b_results);
    moveBox(ui.btn_first, b_first);
    moveBox(ui.btn_next, b_next);
    moveBox(ui.btn_reset, b_reset);
    layoutValue();
    moveBox(ui.value2, b_value2);
    moveBox(ui.dd_cond, b_dd_cond);
    moveBox(ui.dd_type, b_dd_type);
    moveBox(ui.writable, b_writable);
    moveBox(ui.table, b_table);
    moveBox(ui.desc, b_desc);
    moveBox(ui.newval, b_newval);
    moveBox(ui.btn_write, b_write);
    moveBox(ui.btn_freeze, b_freeze);
    moveBox(ui.btn_delete, b_delete);
    moveBox(ui.cancel, b_cancel);
    _ = InvalidateRect(main_wnd, null, 0);
}

fn refreshLabels() void {
    normalizeCond();
    const kind: scan.Kind = if (scan_active) sc.kind else type_kinds[kind_sel];
    var b: [64]u8 = undefined;
    setText(ui.dd_type, std.fmt.bufPrint(&b, "{s}  ▾", .{@tagName(kind)}) catch "");
    setText(ui.dd_cond, std.fmt.bufPrint(&b, "{s}  ▾", .{condLabel(cond_mode)}) catch "");
    layoutValue();
    _ = InvalidateRect(ui.btn_next, null, 0);
    _ = InvalidateRect(ui.btn_reset, null, 0);
    _ = InvalidateRect(main_wnd, null, 0);
}

fn setPicker(on: bool) void {
    closePopup();
    picker = on;
    show(ui.filter, on);
    show(ui.procs, on);
    show(ui.pick_close, on);

    const main_ctrls = [_]HWND{
        ui.results,    ui.dd_type,    ui.dd_cond,   ui.value,
        ui.btn_first,  ui.btn_next,   ui.btn_reset, ui.writable,
        ui.table,      ui.desc,       ui.newval,    ui.btn_write,
        ui.btn_freeze, ui.btn_delete,
    };
    for (main_ctrls) |h| show(h, !on);
    show(ui.value2, !on and cond_mode == .between);
    _ = InvalidateRect(main_wnd, null, 0);
}

fn closePopup() void {
    if (popup_kind == .none) return;
    popup_closed_kind = popup_kind;
    popup_closed_at = GetTickCount64();
    popup_kind = .none;
    popup_hot = std.math.maxInt(usize);
    popup_anim = false;
    syncAnimTimer();
    show(ui.popup, false);
    _ = InvalidateRect(main_wnd, null, 0);
}

fn openPopup(kind: PopupKind) void {
    if (kind == popup_closed_kind and GetTickCount64() - popup_closed_at < 250) return;

    var anchor: Box = b_dd_type;
    var width: i32 = 214;
    var right = false;
    popup_cur = std.math.maxInt(usize);

    switch (kind) {
        .none => return,
        .type => {
            anchor = b_dd_type;
            const cur: usize = if (scan_active) kindIndex(sc.kind) else kind_sel;
            for (type_names, 0..) |nm, i| popup_items[i] = nm;
            popup_n = type_names.len;
            popup_cur = cur;
        },
        .cond => {
            anchor = b_dd_cond;
            const modes: []const scan.Mode = if (scan_active) &next_modes else &first_modes;
            for (modes, 0..) |m, i| {
                popup_cond_list[i] = m;
                popup_items[i] = condLabel(m);
                if (m == cond_mode) popup_cur = i;
            }
            popup_n = modes.len;
        },
        .menu => {
            anchor = b_more;
            width = 250;
            right = true;
            popup_items[0] = if (dark_mode) "Light theme" else "Dark theme";
            popup_items[1] = "Save address table";
            popup_items[2] = "Load address table";
            popup_n = 3;
        },
    }

    popup_kind = kind;
    popup_hot = std.math.maxInt(usize);
    const n: i32 = @intCast(popup_n);
    const w = S(width);
    const h = S(34) * n;
    const x = if (right) S(anchor.x + anchor.w) - w else S(anchor.x);
    const y = S(anchor.y + anchor.h + 4);
    popup_rc = .{ .x = x, .y = y, .w = w, .h = h };
    popup_final_y = y;
    popup_anim_t0 = GetTickCount64();
    popup_anim = true;
    syncAnimTimer();

    _ = MoveWindow(ui.popup, x, y + S(8), w, h, 1);
    _ = SendMessageW(ui.popup, LB_SETCOUNT, popup_n, 0);
    _ = SendMessageW(ui.popup, LB_SETCURSEL, std.math.maxInt(usize), 0);
    show(ui.popup, true);
    _ = BringWindowToTop(ui.popup);
    _ = SetFocus(ui.popup);
    _ = InvalidateRect(ui.popup, null, 0);
    _ = InvalidateRect(main_wnd, null, 0);
}

fn onPopupPick(idx: usize) void {
    const kind = popup_kind;
    if (idx >= popup_n) return;
    closePopup();
    switch (kind) {
        .none => {},
        .type => {
            if (scan_active) {
                setStatus("Cannot change type during a scan — press Reset", .{});
            } else {
                kind_sel = idx;
                refreshLabels();
            }
        },
        .cond => {
            cond_mode = popup_cond_list[idx];
            refreshLabels();
        },
        .menu => switch (idx) {
            0 => {
                dark_mode = !dark_mode;
                applyTheme();
            },
            1 => saveTable(),
            2 => loadTable(),
            else => {},
        },
    }
}

fn popupHoverTick() void {
    if (popup_kind == .none) return;
    var pt: POINT = undefined;
    if (GetCursorPos(&pt) == 0) return;
    _ = ScreenToClient(ui.popup, &pt);
    const lp: isize = (@as(isize, pt.y) << 16) | (@as(isize, pt.x) & 0xFFFF);
    const res: usize = @bitCast(SendMessageW(ui.popup, LB_ITEMFROMPOINT, 0, lp));
    const idx = res & 0xFFFF;
    const outside = (res >> 16) & 0xFFFF;
    const new_hot: usize = if (outside != 0 or idx >= popup_n) std.math.maxInt(usize) else idx;
    if (new_hot != popup_hot) {
        popup_hot = new_hot;
        _ = InvalidateRect(ui.popup, null, 0);
    }
}

fn requireProc() ?win.Process {
    if (proc) |p| return p;
    setStatus("Select a process first — click the process name at the top", .{});
    return null;
}

fn refreshProcs() void {
    var tb: [384]u8 = undefined;
    const filter = getText(ui.filter, &tb);
    win.enumProcesses(gpa, &procs, filter) catch {
        setStatus("Failed to enumerate processes", .{});
        return;
    };
    _ = SendMessageW(ui.procs, LB_SETCOUNT, procs.items.len, 0);
    _ = InvalidateRect(ui.procs, null, 0);
}

fn updateResults() void {
    const n = @min(sc.matches.items.len, max_shown);
    _ = SendMessageW(ui.results, LB_SETCOUNT, n, 0);
    _ = InvalidateRect(ui.results, null, 0);
    refreshLabels();
}

fn clearResultsCache() void {
    @memset(res_cache_filled[0..], false);
    res_cache_top = std.math.maxInt(usize);
}

/// Sample the values of the rows currently visible in the results list. Called
/// from timer ticks, never from WM_DRAWITEM, so painting does no memory I/O.
fn refreshResultsValues() void {
    const p = proc orelse return;
    if (busy.load(.acquire)) return;
    const total = sc.matches.items.len;
    if (total == 0) return;

    var rc: RECT = undefined;
    if (GetClientRect(ui.results, &rc) == 0) return;
    const item_h = @max(1, S(30));
    var visible: usize = @intCast(@divTrunc(@max(rc.bottom - rc.top, item_h), item_h) + 1);
    if (visible > cache_cap) visible = cache_cap;

    const top_raw = SendMessageW(ui.results, LB_GETTOPINDEX, 0, 0);
    var top: usize = if (top_raw > 0) @intCast(top_raw) else 0;
    if (top >= total) top = total - 1;
    res_cache_top = top;
    if (visible > total - top) visible = total - top;

    const kind = sc.kind;
    const sz = kind.size();
    var i: usize = 0;
    while (i < visible) : (i += 1) {
        const idx = top + i;
        const slot = idx % cache_cap;
        var cur: [8]u8 = undefined;
        var vb: [48]u8 = undefined;
        res_cache_idx[slot] = idx;
        const value_text: []const u8 = if (p.read(sc.matches.items[idx].addr, cur[0..sz])) |_| scan.fmtValue(kind, cur[0..sz], &vb) else |_| "??";
        @memcpy(res_cache_text[slot][0..value_text.len], value_text);
        res_cache_len[slot] = value_text.len;
        res_cache_filled[slot] = true;
    }
}

/// Refresh table values in one batch, used by timer ticks and after edits.
fn refreshTableValues() void {
    const p = proc orelse return;
    for (table.items) |*row| {
        var cur: [8]u8 = undefined;
        const sz = row.kind.size();
        if (p.read(row.addr, cur[0..sz])) |_| {
            const value_text = scan.fmtValue(row.kind, cur[0..sz], &row.shown);
            row.shown_len = value_text.len;
            row.shown_ok = true;
        } else |_| {
            row.shown_len = 0;
            row.shown_ok = false;
        }
    }
}

fn attach() void {
    const sel = SendMessageW(ui.procs, LB_GETCURSEL, 0, 0);
    if (sel < 0) {
        setStatus("Select a process from the list", .{});
        return;
    }
    const i: usize = @intCast(sel);
    if (i >= procs.items.len) return;
    const e = procs.items[i];
    const p = win.Process.open(e.pid) catch {
        setStatus("Failed to open PID {d}. Run the program as administrator", .{e.pid});
        return;
    };
    if (proc) |old| old.close();
    proc = p;
    scan_active = false;
    for (table.items) |*row| row.frozen = false;
    syncFreezeTimer();
    sc.matches.clearAndFree(gpa);
    sc.truncated = false;
    clearResultsCache();

    const lbl = std.fmt.bufPrint(&proc_label, "{s} · {d}", .{ util.clipUtf8(e.name[0..e.name_len], 40), e.pid }) catch proc_label[0..0];
    proc_label_len = lbl.len;
    setText(ui.pill, proc_label[0..proc_label_len]);

    updateResults();
    refreshTableValues();
    updateFreezeLabel();
    _ = InvalidateRect(ui.table, null, 0);
    setPicker(false);
    setStatus("Attached to {s}. Enter a value and press First Scan", .{e.name[0..e.name_len]});
}

fn scanThread(_: ?*anyopaque) callconv(.winapi) u32 {
    if (job.first) {
        sc.first(gpa, job.p, job.kind, job.cond, job.writable, .{}, job.kind.size()) catch |e| {
            job.err = @errorName(e);
        };
    } else {
        job.canceled = sc.next(job.p, job.cond);
    }
    busy.store(false, .release);
    _ = PostMessageW(main_wnd, WM_SCAN_DONE, 0, 0);
    return 0;
}

fn startJob() void {
    job.err = null;
    job.canceled = false;
    job_start = GetTickCount64();
    scan.cancel_flag.store(false, .release);
    scan.progress.store(0, .release);
    prog_shown = 0;
    clearResultsCache();
    busy.store(true, .release);
    _ = SendMessageW(ui.results, LB_SETCOUNT, 0, 0);
    setStatus("Scanning...", .{});
    show(ui.cancel, true);
    _ = SetTimer(main_wnd, TIMER_PROGRESS, 100, null);
    const th = CreateThread(null, 0, &scanThread, null, 0, null);
    if (th) |t| {
        _ = CloseHandle(t);
    } else {
        busy.store(false, .release);
        show(ui.cancel, false);
        _ = KillTimer(main_wnd, TIMER_PROGRESS);
        setStatus("Failed to start the scan thread", .{});
    }
}

fn doScan(first: bool) void {
    const p = requireProc() orelse return;
    const mode = cond_mode;

    if (first) {
        switch (mode) {
            .exact, .greater, .less, .between, .unknown => {},
            else => {
                setStatus("For the first scan choose: Exact, Greater, Less, Between or Unknown", .{});
                return;
            },
        }
    } else if (!scan_active) {
        setStatus("Run the first scan first", .{});
        return;
    }

    const kind: scan.Kind = if (first) type_kinds[kind_sel] else sc.kind;
    const sz = kind.size();
    var cond: scan.Cond = .{ .mode = mode };

    const needs_value = switch (mode) {
        .exact, .greater, .less, .between => true,
        else => false,
    };
    if (needs_value) {
        var tb: [384]u8 = undefined;
        var nb: [384]u8 = undefined;
        const t1 = util.normNum(getText(ui.value, &tb), &nb);
        cond.a = scan.encode(kind, t1) catch {
            setStatus("Enter a value (type {s})", .{@tagName(kind)});
            return;
        };
        cond.tol = util.tolFromText(kind, t1);

        if (mode == .between) {
            var tb2: [384]u8 = undefined;
            var nb2: [384]u8 = undefined;
            const t2 = util.normNum(getText(ui.value2, &tb2), &nb2);
            cond.b = scan.encode(kind, t2) catch {
                setStatus("Enter the upper bound in the To field", .{});
                return;
            };
            if (scan.cmpVal(kind, cond.a.bytes[0..sz], cond.b.bytes[0..sz])) |o| {
                if (o == .gt) {
                    const tmp = cond.a;
                    cond.a = cond.b;
                    cond.b = tmp;
                }
            }
        }
    }

    job = .{
        .first = first,
        .kind = kind,
        .cond = cond,
        .writable = writable_only,
        .p = p,
        .err = null,
        .canceled = false,
    };
    startJob();
}

fn onScanDone() void {
    // Pair with the scan thread's release store before reading its results.
    _ = busy.load(.acquire);
    _ = KillTimer(main_wnd, TIMER_PROGRESS);
    show(ui.cancel, false);
    if (job.err == null and job.first) scan_active = true;
    updateResults();
    if (job.err == null) {
        refreshResultsValues();
        refreshTableValues();
    }
    const ms = GetTickCount64() - job_start;
    if (job.err) |e| {
        if (std.mem.eql(u8, e, "Canceled")) {
            setStatus("Scan canceled", .{});
        } else {
            setStatus("Scan error: {s}", .{e});
        }
    } else if (job.canceled) {
        setStatus("Filtering canceled, addresses left: {d}", .{sc.matches.items.len});
    } else if (sc.truncated) {
        setStatus("Found {d} (truncated by memory limit) — enable Writable memory only", .{sc.matches.items.len});
    } else {
        setStatus("Addresses found: {d} · {d} ms", .{ sc.matches.items.len, ms });
    }
}

fn doReset() void {
    scan_active = false;
    sc.matches.clearAndFree(gpa);
    sc.truncated = false;
    clearResultsCache();
    updateResults();
    setStatus("Results cleared — you can start a new scan", .{});
}

fn selectedMatch() ?usize {
    const sel = SendMessageW(ui.results, LB_GETCURSEL, 0, 0);
    if (sel < 0) return null;
    const i: usize = @intCast(sel);
    if (i >= sc.matches.items.len) return null;
    return i;
}

fn selectedRow() ?usize {
    const sel = SendMessageW(ui.table, LB_GETCURSEL, 0, 0);
    if (sel < 0) return null;
    const i: usize = @intCast(sel);
    if (i >= table.items.len) return null;
    return i;
}

fn updateTableCount() void {
    _ = SendMessageW(ui.table, LB_SETCOUNT, table.items.len, 0);
    _ = InvalidateRect(ui.table, null, 0);
}

fn syncFreezeTimer() void {
    for (table.items) |row| {
        if (row.frozen) {
            _ = SetTimer(main_wnd, TIMER_FREEZE, 100, null);
            return;
        }
    }
    _ = KillTimer(main_wnd, TIMER_FREEZE);
}

fn updateFreezeLabel() void {
    const frozen = if (selectedRow()) |i| table.items[i].frozen else false;
    setText(ui.btn_freeze, if (frozen) "Unfreeze" else "Freeze");
}

fn loadRowToEdits() void {
    const i = selectedRow() orelse return;
    const row = table.items[i];
    loading_edit = true;
    setText(ui.desc, row.desc[0..row.desc_len]);
    loading_edit = false;
    var vb: [48]u8 = undefined;
    const value_text = if (row.shown_ok) row.shown[0..row.shown_len] else rowValueText(row, &vb);
    setText(ui.newval, value_text);
    updateFreezeLabel();
}

fn applyDesc() void {
    if (loading_edit) return;
    const i = selectedRow() orelse return;
    var tb: [384]u8 = undefined;
    const s = util.clipUtf8(getText(ui.desc, &tb), 120);
    const row = &table.items[i];
    @memcpy(row.desc[0..s.len], s);
    row.desc_len = s.len;
    _ = InvalidateRect(ui.table, null, 0);
}

fn addToTable() void {
    const idx = selectedMatch() orelse return;
    const row: Row = .{
        .addr = sc.matches.items[idx].addr,
        .kind = sc.kind,
        .desc = std.mem.zeroes([128]u8),
        .desc_len = 0,
        .frozen = false,
        .fval = std.mem.zeroes([8]u8),
        .shown = std.mem.zeroes([48]u8),
        .shown_len = 0,
        .shown_ok = false,
    };
    table.append(gpa, row) catch return;
    refreshTableValues();
    updateTableCount();
    _ = SendMessageW(ui.table, LB_SETCURSEL, table.items.len - 1, 0);
    loadRowToEdits();
    setStatus("Address added to the table — set a description below", .{});
}

fn encodeNewValue(kind: scan.Kind) ?scan.Value {
    var tb: [384]u8 = undefined;
    var nb: [384]u8 = undefined;
    const t = util.normNum(getText(ui.newval, &tb), &nb);
    return scan.encode(kind, t) catch {
        setStatus("Invalid value for type {s}", .{@tagName(kind)});
        return null;
    };
}

fn doWrite() void {
    const p = requireProc() orelse return;
    const i = selectedRow() orelse {
        setStatus("Select a row in the table", .{});
        return;
    };
    const row = &table.items[i];
    const val = encodeNewValue(row.kind) orelse return;
    p.write(row.addr, val.bytes[0..row.kind.size()]) catch {
        setStatus("Failed to write the value (process closed or address unavailable)", .{});
        return;
    };
    if (row.frozen) row.fval = val.bytes;
    refreshTableValues();
    _ = InvalidateRect(ui.table, null, 0);
    setStatus("Value written", .{});
}

fn doFreeze() void {
    const p = requireProc() orelse return;
    const i = selectedRow() orelse {
        setStatus("Select a row in the table", .{});
        return;
    };
    const row = &table.items[i];
    if (row.frozen) {
        row.frozen = false;
        setStatus("Unfrozen", .{});
    } else {
        var val: scan.Value = .{};
        var tb: [384]u8 = undefined;
        if (getText(ui.newval, &tb).len > 0) {
            val = encodeNewValue(row.kind) orelse return;
        } else {
            p.read(row.addr, val.bytes[0..row.kind.size()]) catch {
                setStatus("Failed to read the current value", .{});
                return;
            };
        }
        row.frozen = true;
        row.fval = val.bytes;
        setStatus("Value frozen", .{});
    }
    syncFreezeTimer();
    refreshTableValues();
    updateFreezeLabel();
    _ = InvalidateRect(ui.table, null, 0);
}

fn doDelete() void {
    const i = selectedRow() orelse {
        setStatus("Select a row in the table", .{});
        return;
    };
    _ = table.orderedRemove(i);
    syncFreezeTimer();
    updateTableCount();
    if (table.items.len > 0) {
        _ = SendMessageW(ui.table, LB_SETCURSEL, @min(i, table.items.len - 1), 0);
        loadRowToEdits();
    } else {
        updateFreezeLabel();
    }
}

fn saveTable() void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (table.items) |row| {
        var line: [320]u8 = undefined;
        const s = util.writeTableLine(&line, @intCast(row.addr), row.kind, row.desc[0..row.desc_len]) orelse continue;
        out.appendSlice(gpa, s) catch return;
    }
    win.writeFileAtomic(L("memfract_table.txt"), out.items) catch {
        setStatus("Failed to save memfract_table.txt", .{});
        return;
    };
    setStatus("Table saved: memfract_table.txt ({d} rows)", .{table.items.len});
}

fn loadTable() void {
    const data = win.readFileAlloc(gpa, L("memfract_table.txt")) catch {
        setStatus("memfract_table.txt not found or unreadable", .{});
        return;
    };
    defer gpa.free(data);

    table.clearRetainingCapacity();
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const parsed = util.parseTableLine(raw) orelse continue;
        const d = util.clipUtf8(util.cleanUtf8(parsed.desc), 120);
        var row: Row = .{
            .addr = @intCast(parsed.addr),
            .kind = parsed.kind,
            .desc = std.mem.zeroes([128]u8),
            .desc_len = d.len,
            .frozen = false,
            .fval = std.mem.zeroes([8]u8),
            .shown = std.mem.zeroes([48]u8),
            .shown_len = 0,
            .shown_ok = false,
        };
        @memcpy(row.desc[0..d.len], d);
        table.append(gpa, row) catch break;
    }
    syncFreezeTimer();
    refreshTableValues();
    updateTableCount();
    updateFreezeLabel();
    setStatus("Rows loaded: {d}", .{table.items.len});
}

fn freezeTick() void {
    const p = proc orelse return;
    for (table.items) |row| {
        if (row.frozen) p.write(row.addr, row.fval[0..row.kind.size()]) catch {};
    }
}

fn hoverTick() void {
    popupHoverTick();
    refreshResultsOnScroll();
    var pt: POINT = undefined;
    if (GetCursorPos(&pt) == 0) return;
    const w = WindowFromPoint(pt);
    for (anim_btns[0..anim_n], 0..) |bh, i| {
        const target: i32 = if (w != null and w.? == bh) 100 else 0;
        const cur = anim_hot[i];
        if (cur == target) continue;
        const step: i32 = 34;
        anim_hot[i] = if (cur < target) @min(target, cur + step) else @max(target, cur - step);
        _ = InvalidateRect(bh, null, 0);
    }
}

fn refreshResultsOnScroll() void {
    if (picker or busy.load(.acquire)) return;
    if (sc.matches.items.len == 0) return;
    const top_raw = SendMessageW(ui.results, LB_GETTOPINDEX, 0, 0);
    const top: usize = if (top_raw > 0) @intCast(top_raw) else 0;
    if (top != res_cache_top) refreshResultsValues();
}

fn liveTick() void {
    if (proc == null or picker) return;
    if (table.items.len > 0) {
        refreshTableValues();
        _ = InvalidateRect(ui.table, null, 0);
    }
    if (!busy.load(.acquire) and sc.matches.items.len > 0) {
        refreshResultsValues();
        _ = InvalidateRect(ui.results, null, 0);
    }
}

fn progressTick() void {
    const target: i32 = @intCast(scan.progress.load(.acquire));
    const diff = target - prog_shown;
    if (diff != 0) {
        const ad = if (diff < 0) -diff else diff;
        prog_shown += if (ad < 8) diff else @divTrunc(diff, 3);
    }
    const fr = sbox(b_footer);
    const rc: RECT = .{ .left = fr.x, .top = fr.y, .right = fr.x + fr.w, .bottom = fr.y + fr.h };
    _ = InvalidateRect(main_wnd, &rc, 0);
}

fn createControls(p: HWND) !void {
    const list_style = LBS_NOTIFY | LBS_NOINTEGRALHEIGHT | LBS_OWNERDRAWFIXED | LBS_NODATA | WS_VSCROLL | WS_TABSTOP;
    const popup_style = LBS_NOTIFY | LBS_NOINTEGRALHEIGHT | LBS_OWNERDRAWFIXED | LBS_NODATA;

    ui.pill = try button(p, L("Select process"), b_pill, ID_PILL);
    ui.more = try button(p, L("···"), b_more, ID_MORE);

    ui.filter = try edit(p, b_filter, ID_FILTER, 44);
    ui.procs = try child(p, L("LISTBOX"), L(""), list_style, b_procs, ID_PROCS);
    ui.pick_close = try button(p, L("Close"), b_pick_close, ID_PICK_CLOSE);

    ui.results = try child(p, L("LISTBOX"), L(""), list_style, b_results, ID_RESULTS);

    ui.btn_first = try button(p, L("First Scan"), b_first, ID_FIRST);
    ui.btn_next = try button(p, L("Next Scan"), b_next, ID_NEXT);
    ui.btn_reset = try button(p, L("Reset"), b_reset, ID_RESET);
    ui.value = try edit(p, b_value_full, ID_VALUE, 62);
    ui.value2 = try edit(p, b_value2, ID_VALUE2, 26);
    ui.dd_cond = try button(p, L("Exact  ▾"), b_dd_cond, ID_DD_COND);
    ui.dd_type = try button(p, L("int32  ▾"), b_dd_type, ID_DD_TYPE);
    ui.writable = try button(p, L("Writable memory only (faster)"), b_writable, ID_WRITABLE);

    ui.table = try child(p, L("LISTBOX"), L(""), list_style, b_table, ID_TABLE);
    ui.desc = try edit(p, b_desc, ID_DESC, 64);
    ui.newval = try edit(p, b_newval, ID_NEWVAL, 62);
    _ = SendMessageW(ui.desc, EM_LIMITTEXT, 120, 0);
    ui.btn_write = try button(p, L("Write"), b_write, ID_WRITE);
    ui.btn_freeze = try button(p, L("Freeze"), b_freeze, ID_FREEZE);
    ui.btn_delete = try button(p, L("Delete"), b_delete, ID_DELETE);

    ui.cancel = try button(p, L("Cancel"), b_cancel, ID_CANCEL);

    ui.popup = try child(p, L("LISTBOX"), L(""), popup_style, bx(0, 0, 10, 10), ID_POPUP);
}

fn isEditId(id: usize) bool {
    return id == ID_FILTER or id == ID_VALUE or id == ID_VALUE2 or id == ID_DESC or id == ID_NEWVAL;
}

fn onCommand(id: usize, code: usize) void {
    if (isEditId(id)) {
        if (code == EN_SETFOCUS) {
            focused_id = id;
            _ = InvalidateRect(main_wnd, null, 0);
        } else if (code == EN_KILLFOCUS) {
            focused_id = 0;
            _ = InvalidateRect(main_wnd, null, 0);
        } else if (code == EN_CHANGE) {
            if (id == ID_FILTER) refreshProcs();
            if (id == ID_DESC) applyDesc();
        }
        return;
    }

    if (id == ID_POPUP) {
        if (code == LBN_SELCHANGE) {
            const sel = SendMessageW(ui.popup, LB_GETCURSEL, 0, 0);
            if (sel >= 0) onPopupPick(@intCast(sel));
        } else if (code == LBN_KILLFOCUS) {
            closePopup();
        }
        return;
    }

    if (id == ID_PROCS and code != LBN_DBLCLK) return;
    if (id == ID_RESULTS and code != LBN_DBLCLK) return;
    if (id == ID_TABLE) {
        if (code == LBN_SELCHANGE) loadRowToEdits();
        if (code == LBN_DBLCLK) doFreeze();
        return;
    }

    if (id == ID_CANCEL) {
        scan.cancel_flag.store(true, .release);
        setStatus("Canceling...", .{});
        return;
    }

    const heavy = switch (id) {
        ID_PROCS, ID_FIRST, ID_NEXT, ID_RESET, ID_RESULTS => true,
        else => false,
    };
    if (heavy and busy.load(.acquire)) {
        setStatus("Scan in progress — wait or press Cancel", .{});
        return;
    }

    switch (id) {
        ID_PILL => setPicker(!picker),
        ID_PICK_CLOSE => setPicker(false),
        ID_PROCS => attach(),
        ID_DD_TYPE => openPopup(.type),
        ID_DD_COND => openPopup(.cond),
        ID_MORE => openPopup(.menu),
        ID_FIRST => doScan(true),
        ID_NEXT => doScan(false),
        ID_RESET => {
            if (scan_active) doReset();
        },
        ID_WRITABLE => {
            writable_only = !writable_only;
            _ = InvalidateRect(ui.writable, null, 0);
        },
        ID_RESULTS => addToTable(),
        ID_WRITE => doWrite(),
        ID_FREEZE => doFreeze(),
        ID_DELETE => doDelete(),
        else => {},
    }
}

fn wndProc(hwnd: HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) isize {
    switch (msg) {
        WM_CREATE => {
            main_wnd = hwnd;
            layout();
            createControls(hwnd) catch return -1;
            ui_ready = true;
            dark_mode = !systemUsesLightTheme();
            pal = if (dark_mode) dark_pal else light_pal;
            theme_from = pal;
            theme_to = pal;
            rebuildBrushes();
            applyThemeChrome();
            refreshProcs();
            setPicker(false);
            show(ui.pick_close, false);
            show(ui.cancel, false);
            show(ui.popup, false);
            refreshLabels();
            setStatus("Click Select process at the top to attach to a program", .{});
            _ = SetTimer(hwnd, TIMER_HOVER, 50, null);
            _ = SetTimer(hwnd, TIMER_LIVE, 500, null);
            return 0;
        },
        WM_ERASEBKGND => return 1,
        WM_SIZE => {
            if (ui_ready) relayout();
            return 0;
        },
        WM_GETMINMAXINFO => {
            const r = DefWindowProcW(hwnd, msg, wp, lp);
            const mmi: *MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lp)));
            var rc: RECT = .{ .left = 0, .top = 0, .right = S(min_client_w), .bottom = S(min_client_h) };
            _ = AdjustWindowRect(&rc, main_style, 0);
            mmi.ptMinTrackSize = .{ .x = rc.right - rc.left, .y = rc.bottom - rc.top };
            return r;
        },
        WM_PAINT => {
            paintMain(hwnd);
            return 0;
        },
        WM_MEASUREITEM => {
            const mi: *MEASUREITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lp)));
            const hgt: i32 = switch (mi.CtlID) {
                ID_PROCS => S(38),
                ID_TABLE => S(30),
                ID_RESULTS => S(30),
                else => S(34),
            };
            mi.itemHeight = @intCast(hgt);
            return 1;
        },
        WM_DRAWITEM => {
            const di: *const DRAWITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lp)));
            switch (di.CtlType) {
                4 => drawButton(di),
                2 => drawListItem(di),
                else => {},
            }
            return 1;
        },
        WM_CTLCOLOREDIT => {
            if (br_field) |b| {
                const hdc: HDC = @ptrFromInt(wp);
                _ = SetTextColor(hdc, cr(pal.text));
                _ = SetBkColor(hdc, cr(pal.field));
                return @as(isize, @bitCast(@intFromPtr(b)));
            }
        },
        WM_CTLCOLORLISTBOX => {
            if (br_card) |b| return @as(isize, @bitCast(@intFromPtr(b)));
        },
        WM_COMMAND => {
            onCommand(wp & 0xFFFF, (wp >> 16) & 0xFFFF);
            return 0;
        },
        WM_TIMER => {
            switch (wp) {
                TIMER_FREEZE => freezeTick(),
                TIMER_HOVER => hoverTick(),
                TIMER_LIVE => liveTick(),
                TIMER_PROGRESS => progressTick(),
                TIMER_ANIM => animTick(),
                else => {},
            }
            return 0;
        },
        WM_SCAN_DONE => {
            onScanDone();
            return 0;
        },
        WM_DESTROY => {
            PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

pub fn main() !void {
    _ = SetProcessDPIAware();
    const dpi_scale = @as(f32, @floatFromInt(GetDpiForSystem())) / 96.0;
    const fit_w = @as(f32, @floatFromInt(GetSystemMetrics(0) - 40)) / @as(f32, client_w);
    const fit_h = @as(f32, @floatFromInt(GetSystemMetrics(1) - 120)) / @as(f32, client_h);
    scale = @min(dpi_scale, @min(fit_w, fit_h));

    var gdip_token: usize = 0;
    const gin: GdiplusStartupInput = .{
        .GdiplusVersion = 1,
        .DebugEventCallback = null,
        .SuppressBackgroundThread = 0,
        .SuppressExternalCodecs = 0,
    };
    if (GdiplusStartup(&gdip_token, &gin, null) != 0) return error.GdiplusFailed;
    defer GdiplusShutdown(gdip_token);

    f_body = try mkFont(14, 400, L("Segoe UI"));
    f_semi = try mkFont(14, 600, L("Segoe UI"));
    f_title = try mkFont(22, 600, L("Segoe UI"));
    f_small = try mkFont(12, 400, L("Segoe UI"));
    f_mono = try mkFont(13, 400, L("Consolas"));

    hinst = GetModuleHandleW(null) orelse return error.NoModuleHandle;
    const class = L("MemfractWindow");

    const wc: WNDCLASSEXW = .{
        .cbSize = @sizeOf(WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinst,
        .hIcon = null,
        .hCursor = LoadCursorW(null, 32512),
        .hbrBackground = 0,
        .lpszMenuName = null,
        .lpszClassName = class,
        .hIconSm = null,
    };
    if (RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;

    const style: u32 = main_style;
    var rc: RECT = .{ .left = 0, .top = 0, .right = S(client_w), .bottom = S(client_h) };
    _ = AdjustWindowRect(&rc, style, 0);

    const cw_use_default = std.math.minInt(i32);
    const hwnd = CreateWindowExW(
        0,
        class,
        L("Memfract " ++ version),
        style | WS_VISIBLE,
        cw_use_default,
        cw_use_default,
        rc.right - rc.left,
        rc.bottom - rc.top,
        null,
        0,
        hinst,
        null,
    ) orelse return error.CreateWindowFailed;
    _ = hwnd;

    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) > 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}
