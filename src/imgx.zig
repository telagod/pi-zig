// imgx.zig — 图像压缩管线。
//
// 借鉴 oh-my-pi 的 image-resize 机制(预算/长边/最小边/阶梯/降级),
// 超越其三处:
//   1. 内容自适应:线稿(颜色数少)PNG 直出保真,照片走 JPEG —— 不必每次
//      全格式竞标,省编码 CPU;竞标只在都不达标时兜底。
//   2. token 预算驱动:目标长边由 provider 上下文窗口反推 —— 大窗 128K 用
//      满 API 上限(anthropic 1568),小窗(8K/16K 廉价模型)自动把图压小,
//      给文本让出空间。omp 固定 1568,小窗下每张图照样吃掉 3K+ token。
//   3. 达标优先保真 + 质量二分:PNG 达标就出 PNG(无失真),不达标才走
//      JPEG 质量二分(对数收敛,比固定阶梯 [70,60,50,40] 少一半编码)。
//
// 编解码由 vendored stb 完成(无 libc:内存/拷贝全走本文件 export 的
// piz_* 函数,stb_impl.c 编译单元直接调用)。
const std = @import("std");
const config = @import("config.zig");

// ---------------------------------------------------------------------------
// stb 外部声明(stb_impl.c 实现)与内存供给
// ---------------------------------------------------------------------------

extern fn stbi_load_from_memory(buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, channels_in_file: *c_int, desired_channels: c_int) ?*anyopaque;
extern fn stbi_image_free(retval: ?*anyopaque) void;
extern fn stbi_write_png_to_func(func: *const fn (ctx: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void, context: ?*anyopaque, w: c_int, h: c_int, comp: c_int, data: ?*const anyopaque, stride_bytes_in: c_int) c_int;
extern fn stbi_write_jpg_to_func(func: *const fn (ctx: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void, context: ?*anyopaque, w: c_int, h: c_int, comp: c_int, data: ?*const anyopaque, quality: c_int) c_int;
extern fn stbir_resize_uint8_linear(input_pixels: ?*const anyopaque, input_w: c_int, input_h: c_int, input_stride_in_bytes: c_int, output_pixels: ?*anyopaque, output_w: c_int, output_h: c_int, output_stride_in_bytes: c_int, pixel_layout: c_uint) ?*anyopaque;

/// stb 分配块头:记录实际大小,供 piz_realloc 用。
/// Allocator.realloc 需要旧 slice 的精确长度,而 stb 的 realloc 回调只给指针。
const BlockHeader = extern struct { size: usize, pad: usize };
const BLOCK_ALIGN = 16;

fn baseOf(p: *anyopaque) [*]u8 {
    return @as([*]u8, @ptrCast(p)) - @sizeOf(BlockHeader);
}

pub export fn piz_malloc(sz: usize) ?*anyopaque {
    if (sz == 0) return null;
    const a = std.heap.page_allocator;
    const raw = a.alloc(u8, @sizeOf(BlockHeader) + sz) catch return null;
    const hdr: *BlockHeader = @ptrCast(@alignCast(raw.ptr));
    hdr.* = .{ .size = sz, .pad = 0 };
    return @ptrCast(raw.ptr + @sizeOf(BlockHeader));
}

pub export fn piz_realloc(p: ?*anyopaque, sz: usize) ?*anyopaque {
    if (p == null) return piz_malloc(sz);
    const a = std.heap.page_allocator;
    const hdr: *BlockHeader = @ptrCast(@alignCast(baseOf(p.?)));
    const old_len = @sizeOf(BlockHeader) + hdr.size;
    const raw = a.realloc(baseOf(p.?)[0..old_len], @sizeOf(BlockHeader) + sz) catch return null;
    const nhdr: *BlockHeader = @ptrCast(@alignCast(raw.ptr));
    nhdr.* = .{ .size = sz, .pad = 0 };
    return @ptrCast(raw.ptr + @sizeOf(BlockHeader));
}

pub export fn piz_free(p: ?*anyopaque) void {
    if (p == null) return;
    const a = std.heap.page_allocator;
    const hdr: *BlockHeader = @ptrCast(@alignCast(baseOf(p.?)));
    a.free(baseOf(p.?)[0 .. @sizeOf(BlockHeader) + hdr.size]);
}

pub export fn piz_memcpy(dst: ?*anyopaque, src: ?*const anyopaque, n: usize) callconv(.c) ?*anyopaque {
    if (n > 0 and dst != null and src != null) {
        @memcpy(@as([*]u8, @ptrCast(dst.?))[0..n], @as([*]const u8, @ptrCast(src.?))[0..n]);
    }
    return dst;
}

pub export fn piz_memmove(dst: ?*anyopaque, src: ?*const anyopaque, n: usize) callconv(.c) ?*anyopaque {
    if (n > 0 and dst != null and src != null) {
        std.mem.copyForwards(u8, @as([*]u8, @ptrCast(dst.?))[0..n], @as([*]const u8, @ptrCast(src.?))[0..n]);
    }
    return dst;
}

pub export fn piz_memset(dst: ?*anyopaque, c: c_int, n: usize) callconv(.c) ?*anyopaque {
    if (n > 0 and dst != null) {
        @memset(@as([*]u8, @ptrCast(dst.?))[0..n], @truncate(@as(u32, @bitCast(c))));
    }
    return dst;
}

pub export fn piz_abs(x: c_int) callconv(.c) c_int {
    return if (x < 0) -x else x;
}

pub export fn piz_memcmp(a: ?*const anyopaque, b: ?*const anyopaque, n: usize) callconv(.c) c_int {
    if (a == null or b == null or n == 0) return 0;
    const x = @as([*]const u8, @ptrCast(a.?))[0..n];
    const y = @as([*]const u8, @ptrCast(b.?))[0..n];
    const order = std.mem.order(u8, x, y);
    return switch (order) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

export fn piz_floor(x: f64) callconv(.c) f64 {
    return @floor(x);
}

export fn piz_ceil(x: f64) callconv(.c) f64 {
    return @ceil(x);
}

// ---------------------------------------------------------------------------
// 预算与尺寸
// ---------------------------------------------------------------------------

pub const Options = struct {
    /// 目标体积(压缩后字节)。默认 500KB —— omp 同款,够 1568px 质量图。
    max_bytes: usize = 500 * 1024,
    /// 长边上限。0 = 按 provider 上下文窗口自动推导(maxDimForContext)。
    max_dim: u32 = 0,
    /// 最小边:vision 后端按固定 patch 分块(anthropic 28px),1×1 之类退化图
    /// 会硬 400 毒化整请求 —— 过小的图放大到该尺寸。
    min_dim: u32 = 200,
    jpeg_quality: u8 = 80,
};

pub const Out = struct {
    /// base64 数据(alloc 分配,调用方负责生命周期)
    data: []const u8,
    /// 输出 mime("image/png" / "image/jpeg" / 原格式)
    mime: []const u8,
    w: u32,
    h: u32,
    orig_w: u32,
    orig_h: u32,
    /// 压缩后字节数
    bytes: usize,
    resized: bool,
    /// 解码失败:原样返回输入(尺寸来自手工头解析,0 = 未知)
    passthrough: bool,
};

/// 视觉规格表:按 API 的输入上限与数量上限。
const VisionSpec = struct {
    max_dim: u32, // 该 API 长边像素上限(服务端内缩阈值)
    images: usize, // 单请求图片数量上限
};

fn specFor(api: config.Api) VisionSpec {
    return switch (api) {
        .anthropic_messages => .{ .max_dim = 1568, .images = 100 },
        .openai_completions, .openai_responses => .{ .max_dim = 2048, .images = 20 },
    };
}

/// 按 provider 上下文窗口反推图片长边上限。
///
/// 现实修正:如今主流是 200K/1M 窗口 —— 15% 预算反推的长边恒超 API
/// 上限,窗口驱动只对 ≤16K 小窗有意义。所以规则反过来:
///   - 1M 窗口的 openai 兼容端点基本是 Gemini 3 系,视觉上限 3072 —— 给满;
///   - 其余按 API 规格上限(anthropic 1568 / openai 2048);
///   - 窗口小到图片预算吃紧(<32K)时才下调长边,给文本让 token。
/// 大窗下分辨率由体积预算(500KB)主导,不再伪调像素。
pub fn maxDimForContext(ctx_window: u32, api: config.Api) u32 {
    const spec = specFor(api);
    const api_max: u32 = if (api == .openai_completions and ctx_window >= 1_000_000) 3072 else spec.max_dim;
    // 窗口预算:15% 给图(与压缩硬线 85% 互补);anthropic 近似 tok ≈ w*h/750。
    const budget = ctx_window * 15 / 100;
    const dim_f: f64 = @sqrt(@as(f64, @floatFromInt(budget)) * 750.0);
    var dim: u32 = @intFromFloat(dim_f);
    dim = @max(dim, 512);
    return @min(dim, api_max);
}

fn fitDims(w0: u32, h0: u32, max_dim: u32, min_dim: u32) struct { w: u32, h: u32 } {
    var w: u32 = w0;
    var h: u32 = h0;
    // 长边压制
    if (w > max_dim or h > max_dim) {
        const scale = @min(@as(f64, @floatFromInt(max_dim)) / @as(f64, @floatFromInt(w)), @as(f64, @floatFromInt(max_dim)) / @as(f64, @floatFromInt(h)));
        w = @intFromFloat(@round(@as(f64, @floatFromInt(w)) * scale));
        h = @intFromFloat(@round(@as(f64, @floatFromInt(h)) * scale));
    }
    // 小图放大到最小边(统一比例;极端比例退回拉伸)
    const short = @min(w, h);
    if (short < min_dim and short > 0) {
        const up = @min(
            @as(f64, @floatFromInt(min_dim)) / @as(f64, @floatFromInt(short)),
            @as(f64, @floatFromInt(max_dim)) / @as(f64, @floatFromInt(@max(w, 1))),
        );
        if (up > 1.0) {
            w = @intFromFloat(@round(@as(f64, @floatFromInt(w)) * up));
            h = @intFromFloat(@round(@as(f64, @floatFromInt(h)) * up));
        }
        w = @min(max_dim, @max(min_dim, w));
        h = @min(max_dim, @max(min_dim, h));
    }
    return .{ .w = @max(w, 1), .h = @max(h, 1) };
}

// ---------------------------------------------------------------------------
// 解码 / 编码
// ---------------------------------------------------------------------------

const Decoded = struct {
    rgba: []const u8, // w*h*4,page_allocator,用完 free
    w: u32,
    h: u32,
};

fn decode(input: []const u8) ?Decoded {
    var x: c_int = 0;
    var y: c_int = 0;
    var ch: c_int = 0;
    const px = stbi_load_from_memory(input.ptr, @intCast(input.len), &x, &y, &ch, 4) orelse return null;
    defer stbi_image_free(px);
    const n = @as(usize, @intCast(x)) * @as(usize, @intCast(y)) * 4;
    const copy = std.heap.page_allocator.alloc(u8, n) catch {
        stbi_image_free(px);
        return null;
    };
    @memcpy(copy, @as([*]const u8, @ptrCast(px))[0..n]);
    return .{ .rgba = copy, .w = @intCast(x), .h = @intCast(y) };
}

fn freeDecoded(d: Decoded) void {
    std.heap.page_allocator.free(d.rgba);
}

const EncBuf = struct {
    buf: std.array_list.Managed(u8) = undefined,

    fn write(self: *EncBuf, data: []const u8) !void {
        try self.buf.appendSlice(data);
    }
};

fn encCb(ctx: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
    const self: *EncBuf = @ptrCast(@alignCast(ctx.?));
    self.write(@as([*]const u8, @ptrCast(data.?))[0..@intCast(size)]) catch {};
}

fn encodePng(alloc: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) ![]const u8 {
    var eb = EncBuf{ .buf = std.array_list.Managed(u8).init(alloc) };
    errdefer eb.buf.deinit();
    _ = stbi_write_png_to_func(encCb, &eb, @intCast(w), @intCast(h), 4, rgba.ptr, @intCast(w * 4));
    return eb.buf.toOwnedSlice() catch "";
}

/// 密图快压:RGBA 像素 → base64 PNG(供 compress.snap 挂到消息上)。
pub fn encodeRgbaPngB64(alloc: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) !struct { data: []const u8, bytes: usize } {
    const png = try encodePng(alloc, rgba, w, h);
    defer if (png.len > 0) alloc.free(png);
    if (png.len == 0) return error.EncodeFailed;
    return .{ .data = try b64(alloc, png), .bytes = png.len };
}

fn encodeJpeg(alloc: std.mem.Allocator, rgba: []const u8, w: u32, h: u32, quality: u8) ![]const u8 {
    var eb = EncBuf{ .buf = std.array_list.Managed(u8).init(alloc) };
    errdefer eb.buf.deinit();
    _ = stbi_write_jpg_to_func(encCb, &eb, @intCast(w), @intCast(h), 4, rgba.ptr, @intCast(quality));
    return eb.buf.toOwnedSlice() catch "";
}

/// RGBA 缩放(stb_image_resize2,双线性)。输出 page_allocator,调用方 free。
fn resizeRgba(rgba: []const u8, sw: u32, sh: u32, dw: u32, dh: u32) ![]u8 {
    const out = try std.heap.page_allocator.alloc(u8, @as(usize, dw) * dh * 4);
    errdefer std.heap.page_allocator.free(out);
    _ = stbir_resize_uint8_linear(rgba.ptr, @intCast(sw), @intCast(sh), @intCast(sw * 4), out.ptr, @intCast(dw), @intCast(dh), @intCast(dw * 4), 1); // STBIR_RGBA = 1
    return out;
}

/// 缩放后编码 PNG:尺寸不同则先 resize 到目标(临时缓冲 page_allocator)。
fn encodeResizedPng(alloc: std.mem.Allocator, rgba: []const u8, sw: u32, sh: u32, dw: u32, dh: u32) ![]const u8 {
    if (dw == sw and dh == sh) return encodePng(alloc, rgba, dw, dh);
    const tmp = try resizeRgba(rgba, sw, sh, dw, dh);
    defer std.heap.page_allocator.free(tmp);
    return encodePng(alloc, tmp, dw, dh);
}

fn encodeResizedJpeg(alloc: std.mem.Allocator, rgba: []const u8, sw: u32, sh: u32, dw: u32, dh: u32, quality: u8) ![]const u8 {
    if (dw == sw and dh == sh) return encodeJpeg(alloc, rgba, dw, dh, quality);
    const tmp = try resizeRgba(rgba, sw, sh, dw, dh);
    defer std.heap.page_allocator.free(tmp);
    return encodeJpeg(alloc, tmp, dw, dh, quality);
}

/// 内容分类:抽样(步长 4)统计颜色种类。线稿/图表/截图 UI 颜色数少。
fn isLineArt(rgba: []const u8, w: u32, h: u32) bool {
    var set = std.AutoHashMap(u32, void).init(std.heap.page_allocator);
    defer set.deinit();
    var samples: usize = 0;
    var y: usize = 0;
    const n = @as(usize, w) * @as(usize, h);
    if (n == 0) return false;
    while (y < h) : (y += 4) {
        var x: usize = 0;
        while (x < w) : (x += 4) {
            const i = (y * w + x) * 4;
            const key = (@as(u32, rgba[i]) << 16) | (@as(u32, rgba[i + 1]) << 8) | rgba[i + 2];
            set.put(key, {}) catch {};
            samples += 1;
            if (samples > 4096) break;
        }
        if (samples > 4096) break;
    }
    if (samples == 0) return false;
    // 独特色 ≤ 1024 视为线稿/UI(照片动辄上万)
    return set.count() <= 1024;
}

// ---------------------------------------------------------------------------
// 头解析(解码失败降级用)
// ---------------------------------------------------------------------------

const HeaderInfo = struct { w: u32, h: u32, mime: []const u8 };

fn readBe32(b: []const u8, off: usize) u32 {
    return (@as(u32, b[off]) << 24) | (@as(u32, b[off + 1]) << 16) | (@as(u32, b[off + 2]) << 8) | b[off + 3];
}

fn readLe16(b: []const u8, off: usize) u32 {
    return @as(u32, b[off]) | (@as(u32, b[off + 1]) << 8);
}

fn parseHeader(input: []const u8) ?HeaderInfo {
    // PNG:签名 8B + IHDR(len 4B + "IHDR" 4B + w 4B + h 4B)
    if (input.len >= 24 and std.mem.eql(u8, input[0..8], "\x89PNG\r\n\x1a\n") and readBe32(input, 8) == 13 and std.mem.eql(u8, input[12..16], "IHDR")) {
        return .{ .w = readBe32(input, 16), .h = readBe32(input, 20), .mime = "image/png" };
    }
    // JPEG:SOF0/1/2 段内高宽(大端)
    if (input.len >= 4 and input[0] == 0xff and input[1] == 0xd8) {
        var off: usize = 2;
        while (off + 9 < input.len) {
            if (input[off] != 0xff) {
                off += 1;
                continue;
            }
            while (off < input.len and input[off] == 0xff) off += 1;
            if (off >= input.len) break;
            const marker = input[off];
            off += 1;
            if (marker == 0xd9 or marker == 0xda) break;
            if (marker == 0x01 or (marker >= 0xd0 and marker <= 0xd7)) continue;
            const seg = readBe32(input, off - 2) >> 16; // 段长(2B)
            if (seg < 2) break;
            const is_sof = (marker >= 0xc0 and marker <= 0xc3) or (marker >= 0xc5 and marker <= 0xc7) or (marker >= 0xc9 and marker <= 0xcb) or (marker >= 0xcd and marker <= 0xcf);
            if (is_sof and off + 5 < input.len) {
                return .{ .w = readBe32(input, off + 3) >> 16, .h = readBe32(input, off + 1) >> 16, .mime = "image/jpeg" };
            }
            off += seg;
        }
        return null;
    }
    // GIF:签名 6B + 逻辑屏幕 w/h(小端 2B)
    if (input.len >= 10 and (std.mem.eql(u8, input[0..6], "GIF87a") or std.mem.eql(u8, input[0..6], "GIF89a"))) {
        return .{ .w = readLe16(input, 6), .h = readLe16(input, 8), .mime = "image/gif" };
    }
    return null;
}

fn mimeOf(input: []const u8) []const u8 {
    if (input.len >= 8 and std.mem.eql(u8, input[0..8], "\x89PNG\r\n\x1a\n")) return "image/png";
    if (input.len >= 3 and input[0] == 0xff and input[1] == 0xd8 and input[2] == 0xff) return "image/jpeg";
    if (input.len >= 6 and (std.mem.eql(u8, input[0..6], "GIF87a") or std.mem.eql(u8, input[0..6], "GIF89a"))) return "image/gif";
    if (input.len >= 12 and std.mem.eql(u8, input[0..4], "RIFF") and std.mem.eql(u8, input[8..12], "WEBP")) return "image/webp";
    if (input.len >= 4 and std.mem.eql(u8, input[0..4], "BM")) return "image/bmp";
    return "application/octet-stream";
}

fn b64(alloc: std.mem.Allocator, data: []const u8) ![]const u8 {
    const out = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(data.len));
    _ = std.base64.standard.Encoder.encode(out, data);
    return out;
}

/// 编码竞标辅助:cur 更小(或首份)则替换 best,否则释放 cur。
fn keepBest(b: *[]const u8, m: *[]const u8, al: std.mem.Allocator, cur: []const u8, cm: []const u8) void {
    if (b.len == 0 or cur.len < b.len) {
        if (b.len > 0) al.free(b.*);
        b.* = cur;
        m.* = cm;
    } else {
        al.free(cur);
    }
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

/// 压缩管线。返回的 data 是 base64;mime 为输出格式。
/// 失败(allocator 耗尽)返回 error —— 解码失败不报错,走 passthrough。
/// opts.max_dim == 0 时取默认 1568(调用方应先按 provider 预算推导)。
pub fn process(alloc: std.mem.Allocator, input: []const u8, opts: Options) !Out {
    const max_dim = if (opts.max_dim == 0) 1568 else opts.max_dim;
    const orig_info = parseHeader(input);
    const dec = decode(input);
    // 原始尺寸:解码成功以解码为准(头解析可能认不出 stb 支持的格式,如 BMP);
    // 解码失败才退化到头解析值。
    const orig_w = if (dec) |d| d.w else (if (orig_info) |i| i.w else 0);
    const orig_h = if (dec) |d| d.h else (if (orig_info) |i| i.h else 0);

    if (dec == null) {
        // 解码失败:原样返回(尺寸未知时 0)
        return .{
            .data = try b64(alloc, input),
            .mime = if (orig_info) |i| i.mime else mimeOf(input),
            .w = orig_w,
            .h = orig_h,
            .orig_w = orig_w,
            .orig_h = orig_h,
            .bytes = input.len,
            .resized = false,
            .passthrough = true,
        };
    }
    const d = dec.?;
    defer freeDecoded(d);

    // 快路径:尺寸在界内(留 5% 裕量 —— 服务端会自己缩,微超尺寸的
    // 小图重编反而更差:实测 1600px 线稿重编后 10KB→100KB)、体积 ≤ 预算
    // 1/4、非 webp —— 原样返回。
    // webp 不享受快路径:多数后端(stb/llama.cpp)不解 webp,必须转码。
    const src_mime = mimeOf(input);
    const comfortable = opts.max_bytes / 4;
    const min_dim = @min(opts.min_dim, @max(max_dim, 1));
    const dim_room = max_dim * 105 / 100;
    if (d.w >= min_dim and d.h >= min_dim and d.w <= dim_room and d.h <= dim_room and input.len <= comfortable and !std.mem.eql(u8, src_mime, "image/webp")) {
        return .{
            .data = try b64(alloc, input),
            .mime = src_mime,
            .w = d.w,
            .h = d.h,
            .orig_w = orig_w,
            .orig_h = orig_h,
            .bytes = input.len,
            .resized = false,
            .passthrough = false,
        };
    }

    const dims = fitDims(d.w, d.h, max_dim, min_dim);
    const line_art = isLineArt(d.rgba, d.w, d.h);

    var best: []const u8 = &.{};
    var best_mime: []const u8 = "image/jpeg";
    var best_dims = dims;
    var done = false;

    // 第一轮:目标尺寸上双格式竞标(线稿只试 PNG —— 保真优先)。
    if (line_art) {
        const png = try encodeResizedPng(alloc, d.rgba, d.w, d.h, dims.w, dims.h);
        if (png.len <= opts.max_bytes) {
            best = png;
            best_mime = "image/png";
            done = true;
        } else {
            // 线稿 PNG 超大:退回竞标
            keepBest(&best, &best_mime, alloc, png, "image/png");
            const jpg = try encodeResizedJpeg(alloc, d.rgba, d.w, d.h, dims.w, dims.h, opts.jpeg_quality);
            if (jpg.len <= opts.max_bytes) {
                best = jpg;
                best_mime = "image/jpeg";
                done = true;
            } else {
                keepBest(&best, &best_mime, alloc, jpg, "image/jpeg");
            }
        }
    } else {
        const jpg = try encodeResizedJpeg(alloc, d.rgba, d.w, d.h, dims.w, dims.h, opts.jpeg_quality);
        if (jpg.len <= opts.max_bytes) {
            best = jpg;
            best_mime = "image/jpeg";
            done = true;
        } else {
            keepBest(&best, &best_mime, alloc, jpg, "image/jpeg");
            const png = try encodeResizedPng(alloc, d.rgba, d.w, d.h, dims.w, dims.h);
            if (png.len <= opts.max_bytes) {
                best = png;
                best_mime = "image/png";
                done = true;
            } else {
                keepBest(&best, &best_mime, alloc, png, "image/png");
            }
        }
    }

    // 第二轮:JPEG 质量二分 [30, 当前质量]。JPEG 尺寸对 quality 近似单调,
    // 二分对数收敛(omp 固定 4 档阶梯,这里 ≤5 次且自动贴合预算)。
    if (!done) {
        var lo: u8 = 30;
        var hi: u8 = @min(opts.jpeg_quality, 95);
        var last_ok: ?[]const u8 = null;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const jpg = try encodeResizedJpeg(alloc, d.rgba, d.w, d.h, dims.w, dims.h, mid);
            if (jpg.len <= opts.max_bytes) {
                if (last_ok) |lo_| alloc.free(lo_);
                last_ok = jpg;
                hi = mid; // 更小质量仍可能达标 → 继续压
            } else {
                keepBest(&best, &best_mime, alloc, jpg, "image/jpeg");
                lo = mid + 1;
            }
        }
        if (last_ok) |ok| {
            best = ok;
            best_mime = "image/jpeg";
            done = true;
        }
    }

    // 第三轮:尺寸阶梯 ×0.75/0.5/0.35/0.25(下限 100px),每级 JPEG(q60)+PNG 取小。
    if (!done) {
        const scales = [_]f64{ 0.75, 0.5, 0.35, 0.25 };
        for (scales) |s| {
            const w2: u32 = @max(@as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(dims.w)) * s))), 100);
            const h2: u32 = @max(@as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(dims.h)) * s))), 100);
            const jpg = try encodeResizedJpeg(alloc, d.rgba, d.w, d.h, w2, h2, 60);
            const ok_j = jpg.len <= opts.max_bytes;
            keepBest(&best, &best_mime, alloc, jpg, "image/jpeg");
            const png = try encodeResizedPng(alloc, d.rgba, d.w, d.h, w2, h2);
            if (png.len <= opts.max_bytes) keepBest(&best, &best_mime, alloc, png, "image/png") else alloc.free(png);
            if (ok_j or best.len <= opts.max_bytes) {
                best_dims = .{ .w = w2, .h = h2 };
                break;
            }
            best_dims = .{ .w = w2, .h = h2 };
        }
    }

    // 兜底:best 必非空(第一轮至少编码过一次)
    const out = try b64(alloc, best);
    alloc.free(best);
    return .{
        .data = out,
        .mime = best_mime,
        .w = best_dims.w,
        .h = best_dims.h,
        .orig_w = orig_w,
        .orig_h = orig_h,
        .bytes = out.len * 3 / 4,
        .resized = best_dims.w != d.w or best_dims.h != d.h,
        .passthrough = false,
    };
}

/// 缩放说明(仿 omp 的 formatDimensionNote):让模型懂坐标映射。
pub fn dimensionNote(o: Out, alloc: std.mem.Allocator) ?[]const u8 {
    if (!o.resized) return null;
    if (o.orig_w == 0 or o.orig_h == 0 or o.w == 0 or o.h == 0) return null;
    if (o.w == o.orig_w and o.h == o.orig_h) return null;
    const scale = @as(f64, @floatFromInt(o.orig_w)) / @as(f64, @floatFromInt(o.w));
    return std.fmt.allocPrint(alloc, "[Image: original {d}x{d}, sent at {d}x{d}. Multiply coordinates by {d:.2} to map to original image.]", .{ o.orig_w, o.orig_h, o.w, o.h, scale }) catch null;
}

/// 图片消息的 token 估算(存 message 尺寸,序列化前与 estTokens 共用)。
/// ctx_window 参与:1M 窗口的 openai 兼容端点按 Gemini 768px tile 计费。
pub fn estImageTokens(w: u32, h: u32, api: config.Api, ctx_window: u32) usize {
    if (w == 0 or h == 0) return 0;
    return switch (api) {
        // anthropic:长边 1568 内 w*h/750 近似
        .anthropic_messages => @as(usize, w) * @as(usize, h) / 750,
        // 1M 窗口(≈Gemini 3 系):768px tile,每 tile 258 token
        .openai_completions, .openai_responses => if (ctx_window >= 1_000_000)
            258 * ((@as(usize, w) + 767) / 768) * ((@as(usize, h) + 767) / 768)
        else
            // openai:先缩 2048×768,512px tile 每块 170 + base 85
            85 + 170 * ((@as(usize, @max(w, 1)) + 511) / 512) * ((@as(usize, @max(h, 1)) + 511) / 512),
    };
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test "imgx: 1x1 退化图放大 + PNG 头解析" {
    // 手工构造 1×1 红色 PNG(解码用 stb,这里直接喂字节流验证头解析与放大逻辑)
    const png = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 0, 1, 0, 0, 0, 1 };
    const h = parseHeader(&png) orelse return error.Fail;
    try std.testing.expectEqual(@as(u32, 1), h.w);
    try std.testing.expectEqual(@as(u32, 1), h.h);
    try std.testing.expectEqualStrings("image/png", h.mime);
    // fitDims:1×1 → 200×200(min_dim 规则,不超过 max_dim)
    const d = fitDims(1, 1, 1568, 200);
    try std.testing.expectEqual(@as(u32, 200), d.w);
    try std.testing.expectEqual(@as(u32, 200), d.h);
}

test "imgx: maxDimForContext 按 API 规格与窗口" {
    // 常规窗口 = API 规格上限
    try std.testing.expectEqual(@as(u32, 1568), maxDimForContext(128 * 1024, .anthropic_messages));
    try std.testing.expectEqual(@as(u32, 2048), maxDimForContext(128 * 1024, .openai_completions));
    try std.testing.expectEqual(@as(u32, 1568), maxDimForContext(200 * 1024, .anthropic_messages));
    // 1M 窗口 openai 兼容端点(≈Gemini):3072 上限给满
    try std.testing.expectEqual(@as(u32, 3072), maxDimForContext(1_000_000, .openai_completions));
    // 1M 窗口 anthropic:仍是 1568(API 硬上限,窗口再大也放不开)
    try std.testing.expectEqual(@as(u32, 1568), maxDimForContext(1_000_000, .anthropic_messages));
    // 小窗(<32K)才下调:16K 预算 2458 tok → sqrt(2458*750) ≈ 1358
    const d16 = maxDimForContext(16 * 1024, .anthropic_messages);
    try std.testing.expect(d16 < 1568 and d16 >= 512);
    const d8 = maxDimForContext(8 * 1024, .anthropic_messages);
    try std.testing.expect(d8 < d16 and d8 >= 512);
}

test "imgx: estImageTokens 1M 窗口走 Gemini tile 计费" {
    // 512×512 图:openai tile = 85+170 = 255;Gemini tile = 258
    try std.testing.expectEqual(@as(usize, 255), estImageTokens(512, 512, .openai_completions, 128 * 1024));
    try std.testing.expectEqual(@as(usize, 258), estImageTokens(512, 512, .openai_completions, 1_000_000));
    // anthropic 公式与窗口无关
    try std.testing.expectEqual(@as(usize, 1568 * 1568 / 750), estImageTokens(1568, 1568, .anthropic_messages, 1_000_000));
}

test "imgx: 线稿 PNG 直出、照片 JPEG 达标" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 合成 8×8 纯色 PNG(线稿路径)
    const W = 8;
    const H = 8;
    // 用 stbi 编码?imgx 只有 RGBA→png 编码。构造 8×8 白色 RGBA 编码成 png:
    const rgba = try a.alloc(u8, W * H * 4);
    @memset(rgba, 255);
    const png = try encodePng(a, rgba, W, H);
    // 极小图:走 min_dim 放大(200px)与压缩 —— 白图 PNG 很小,应 PNG 直出
    const out = try process(a, png, .{});
    try t.expectEqualStrings("image/png", out.mime);
    try t.expect(out.w >= 200);
    // base64 可解码且与输出一致
    const raw = try a.alloc(u8, std.base64.standard.Decoder.calcSizeForSlice(out.data) catch return error.Fail);
    _ = std.base64.standard.Decoder.decode(raw, out.data) catch return error.Fail;
}
