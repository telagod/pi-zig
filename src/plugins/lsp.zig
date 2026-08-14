// LSP 桥:按扩展起语言服务器,转发 hover/def/refs。
const std = @import("std");
const agentmod = @import("../agent.zig");
const activity = @import("../activity.zig");
const toolsmod = @import("../tools.zig");

/// LSP 请求超时。语言服务器首次索引大仓库可能慢,但绝不能永久阻塞 agent 循环。
const LSP_TIMEOUT_MS: i64 = 15_000;

/// 按文件扩展名选语言服务器。argv[0] 不存在时由调用方给安装提示。
fn lspServerFor(path: []const u8) ?[]const []const u8 {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".zig")) return &.{"zls"};
    if (std.mem.eql(u8, ext, ".rs")) return &.{"rust-analyzer"};
    if (std.mem.eql(u8, ext, ".py")) return &.{ "pyright-langserver", "--stdio" };
    if (std.mem.eql(u8, ext, ".go")) return &.{"gopls"};
    if (std.mem.eql(u8, ext, ".c") or std.mem.eql(u8, ext, ".h") or
        std.mem.eql(u8, ext, ".cc") or std.mem.eql(u8, ext, ".cpp") or
        std.mem.eql(u8, ext, ".hpp")) return &.{"clangd"};
    if (std.mem.eql(u8, ext, ".ts") or std.mem.eql(u8, ext, ".tsx") or
        std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".jsx") or
        std.mem.eql(u8, ext, ".mjs")) return &.{ "typescript-language-server", "--stdio" };
    return null;
}

/// LSP 的 languageId(initialize 与 didOpen 都要)。
fn lspLanguageId(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".zig")) return "zig";
    if (std.mem.eql(u8, ext, ".rs")) return "rust";
    if (std.mem.eql(u8, ext, ".py")) return "python";
    if (std.mem.eql(u8, ext, ".go")) return "go";
    if (std.mem.eql(u8, ext, ".ts")) return "typescript";
    if (std.mem.eql(u8, ext, ".tsx")) return "typescriptreact";
    if (std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".mjs")) return "javascript";
    if (std.mem.eql(u8, ext, ".jsx")) return "javascriptreact";
    if (std.mem.eql(u8, ext, ".c") or std.mem.eql(u8, ext, ".h")) return "c";
    return "plaintext";
}

/// 编码一条 JSON-RPC 消息:`Content-Length: N\r\n\r\n<body>`。
fn lspEncodeFrame(alloc: std.mem.Allocator, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}

/// 从缓冲区头部解出一帧。返回 body 与该帧总长(供调用方推进游标)。
/// 帧不完整返回 null —— 调用方继续读。
const LspFrame = struct { body: []const u8, consumed: usize };

fn lspDecodeFrame(buf: []const u8) ?LspFrame {
    // 头部以空行结束(\r\n\r\n,容忍 \n\n)
    const sep_crlf = std.mem.indexOf(u8, buf, "\r\n\r\n");
    const sep_lf = std.mem.indexOf(u8, buf, "\n\n");
    var head_end: usize = undefined;
    var body_start: usize = undefined;
    if (sep_crlf) |i| {
        // 若 \n\n 更早出现则以它为界(某些服务器不严格用 CRLF)
        if (sep_lf != null and sep_lf.? < i) {
            head_end = sep_lf.?;
            body_start = sep_lf.? + 2;
        } else {
            head_end = i;
            body_start = i + 4;
        }
    } else if (sep_lf) |i| {
        head_end = i;
        body_start = i + 2;
    } else return null; // 头部还没读完

    // 找 Content-Length
    var len: ?usize = null;
    var it = std.mem.splitAny(u8, buf[0..head_end], "\r\n");
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "content-length")) continue;
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
        len = std.fmt.parseInt(usize, val, 10) catch null;
    }
    const body_len = len orelse return null; // 无 Content-Length:等更多数据或视为坏帧
    if (buf.len < body_start + body_len) return null; // body 还没读全
    return .{ .body = buf[body_start .. body_start + body_len], .consumed = body_start + body_len };
}

const LspPos = struct { line: u32, character: u32 };

/// 在文件内容里找符号首次出现的位置,返回 0-based (line, character)。
/// 模型给符号名而非行列时用这个 —— 降低调用门槛。
///
/// 必须跳过注释里的出现:带文档注释的符号(`// Foo does ...` 紧挨 `fn Foo`)
/// 首个文本匹配落在注释上,language server 在那个位置没有符号,references
/// 直接返回空。实测 gopls 就是这样失败的。
/// 同理跳过字符串字面量内部,并要求匹配是完整标识符而非更长名字的子串。
fn lspFindSymbol(content: []const u8, symbol: []const u8) ?LspPos {
    if (symbol.len == 0) return null;
    var fallback: ?LspPos = null;
    var line_no: u32 = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| : (line_no += 1) {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, line, from, symbol)) |col| {
            from = col + 1;
            // 完整标识符:两侧不能再是标识符字符,否则 `Total` 会命中 `ComputeTotal`
            const before_ok = col == 0 or !isIdentChar(line[col - 1]);
            const after = col + symbol.len;
            const after_ok = after >= line.len or !isIdentChar(line[after]);
            if (!before_ok or !after_ok) continue;
            const hit: LspPos = .{ .line = line_no, .character = @intCast(col) };
            // 注释/字符串里的出现只作兜底 —— 真实定义几乎总在后面
            if (inCommentOrString(line, col)) {
                if (fallback == null) fallback = hit;
                continue;
            }
            return hit;
        }
    }
    return fallback;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// 判断 `col` 是否落在行注释或字符串字面量内。按行判断,足够覆盖
/// 文档注释这个实际场景;跨行块注释不处理(代价远大于收益)。
fn inCommentOrString(line: []const u8, col: usize) bool {
    var i: usize = 0;
    var quote: ?u8 = null;
    while (i < col) : (i += 1) {
        const c = line[i];
        if (quote) |q| {
            if (c == '\\') {
                i += 1; // 跳过被转义的字符
            } else if (c == q) {
                quote = null;
            }
            continue;
        }
        switch (c) {
            '"', '\'', '`' => quote = c,
            '/' => if (i + 1 < line.len and (line[i + 1] == '/')) return true,
            '#' => return true, // python/shell 行注释
            ';' => {},
            else => {},
        }
    }
    return quote != null;
}

/// 把绝对路径转成 file:// URI(百分号编码空格等)。
fn lspPathToUri(alloc: std.mem.Allocator, abs_path: []const u8) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    try aw.writer.writeAll("file://");
    for (abs_path) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '/', '-', '_', '.', '~' => try aw.writer.writeByte(c),
            else => try aw.writer.print("%{X:0>2}", .{c}),
        }
    }
    return aw.toOwnedSlice();
}

/// file:// URI 转回路径(解百分号编码)。非 file:// 原样返回。
fn lspUriToPath(alloc: std.mem.Allocator, uri: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return alloc.dupe(u8, uri);
    const raw = uri["file://".len..];
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '%' and i + 2 < raw.len) {
            const hi = std.fmt.charToDigit(raw[i + 1], 16) catch {
                try aw.writer.writeByte(raw[i]);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(raw[i + 2], 16) catch {
                try aw.writer.writeByte(raw[i]);
                i += 1;
                continue;
            };
            try aw.writer.writeByte(hi * 16 + lo);
            i += 3;
            continue;
        }
        try aw.writer.writeByte(raw[i]);
        i += 1;
    }
    return aw.toOwnedSlice();
}

/// 一次 LSP 会话:spawn 服务器 → initialize → didOpen → 目标请求 → shutdown。
/// 每次工具调用起一个新进程。不缓存服务器 —— 简单、无状态泄漏,代价是首次索引开销。
const LspSession = struct {
    child: std.process.Child,
    arena: std.mem.Allocator,
    buf: std.array_list.Managed(u8),
    next_id: i64 = 1,
    deadline_ns: i96,

    fn start(arena: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) !LspSession {
        _ = cwd;
        const child = try std.process.spawn(agentmod.util.io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        if (child.stdout) |f| agentmod.util.setNonBlock(f.handle);
        return .{
            .child = child,
            .arena = arena,
            .buf = std.array_list.Managed(u8).init(arena),
            .deadline_ns = std.Io.Clock.now(.awake, agentmod.util.io).nanoseconds +
                @as(i96, LSP_TIMEOUT_MS) * std.time.ns_per_ms,
        };
    }

    /// 结束会话:发 shutdown/exit(尽力),然后杀进程收尸。
    /// 注意:`kill` 自己会关闭并清理 stdin/stdout,这里**不能**再手动 close ——
    /// 否则 double close,std 会在 Debug 下 panic(EBADF use-after-free)。
    fn deinit(self: *LspSession) void {
        self.send("{\"jsonrpc\":\"2.0\",\"id\":9999,\"method\":\"shutdown\"}") catch {};
        self.send("{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}") catch {};
        // 不等自然退出:某些服务器收到 exit 后仍挂着,直接 kill 更可靠。
        // kill 内部做 childCleanupPosix,关掉全部管道并 wait 收尸。
        self.child.kill(agentmod.util.io);
    }

    fn send(self: *LspSession, body: []const u8) !void {
        const frame = try lspEncodeFrame(self.arena, body);
        const stdin = self.child.stdin orelse return error.NoStdin;
        var wbuf: [4096]u8 = undefined;
        var w = stdin.writer(agentmod.util.io, &wbuf);
        try w.interface.writeAll(frame);
        try w.flush();
    }

    /// 读到一条 id 匹配的响应。通知与其他 id 的响应被跳过。
    /// 超时返回 error.LspTimeout —— 绝不无限等。
    fn awaitResponse(self: *LspSession, want_id: i64) ![]const u8 {
        const stdout = self.child.stdout orelse return error.NoStdout;
        const act = activity.begin(.tool, "lsp", "await", LSP_TIMEOUT_MS);
        defer act.release();
        var chunk: [8192]u8 = undefined;
        var cursor: usize = 0;
        while (true) {
            // 先尝试从已有缓冲里解帧
            while (lspDecodeFrame(self.buf.items[cursor..])) |frame| {
                cursor += frame.consumed;
                const root = std.json.parseFromSliceLeaky(std.json.Value, self.arena, frame.body, .{}) catch continue;
                if (root != .object) continue;
                const id = root.object.get("id") orelse continue; // 通知,无 id
                const got: i64 = switch (id) {
                    .integer => |i| i,
                    .float => |f| @intFromFloat(f),
                    else => continue,
                };
                if (got != want_id) continue;
                return frame.body;
            }
            if (std.Io.Clock.now(.awake, agentmod.util.io).nanoseconds > self.deadline_ns) return error.LspTimeout;
            if (act.cancelled()) return error.Canceled;
            // 读更多
            var pfd = [_]std.posix.pollfd{.{ .fd = stdout.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const n = std.posix.poll(&pfd, 100) catch 0;
            if (n == 0) continue;
            const got = std.posix.read(stdout.handle, &chunk) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return error.LspReadFailed,
            };
            if (got == 0) return error.LspClosed; // 服务器退出
            try self.buf.appendSlice(chunk[0..got]);
        }
    }

    /// 发一个请求并等它的响应。返回响应体 JSON。
    fn request(self: *LspSession, method: []const u8, params_json: []const u8) ![]const u8 {
        const id = self.next_id;
        self.next_id += 1;
        const body = try std.fmt.allocPrint(
            self.arena,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}",
            .{ id, method, params_json },
        );
        try self.send(body);
        return self.awaitResponse(id);
    }

    fn notify(self: *LspSession, method: []const u8, params_json: []const u8) !void {
        const body = try std.fmt.allocPrint(
            self.arena,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}",
            .{ method, params_json },
        );
        try self.send(body);
    }
};

/// 把 LSP 的 Location / Location[] / LocationLink[] 渲染成 path:line:col 清单。
fn lspRenderLocations(arena: std.mem.Allocator, result: std.json.Value, writer: *std.Io.Writer) !usize {
    var n: usize = 0;
    const items: []const std.json.Value = switch (result) {
        .array => |a| a.items,
        .object => blk: {
            const one = try arena.alloc(std.json.Value, 1);
            one[0] = result;
            break :blk one;
        },
        else => return 0,
    };
    for (items) |loc| {
        if (loc != .object) continue;
        // Location 用 uri+range;LocationLink 用 targetUri+targetRange
        const uri_v = loc.object.get("uri") orelse loc.object.get("targetUri") orelse continue;
        if (uri_v != .string) continue;
        const range_v = loc.object.get("range") orelse loc.object.get("targetRange") orelse continue;
        if (range_v != .object) continue;
        const start = range_v.object.get("start") orelse continue;
        if (start != .object) continue;
        const line = if (start.object.get("line")) |l| (if (l == .integer) l.integer else 0) else 0;
        const ch = if (start.object.get("character")) |c| (if (c == .integer) c.integer else 0) else 0;
        const path = try lspUriToPath(arena, uri_v.string);
        // LSP 行列是 0-based,展示成 1-based 与编辑器一致
        try writer.print("{s}:{d}:{d}\n", .{ path, line + 1, ch + 1 });
        n += 1;
    }
    return n;
}

/// lsp 工具主体。
pub fn toolLsp(ctx: ?*anyopaque, arena: std.mem.Allocator, args: []const u8) anyerror!toolsmod.Result {
    const self: *agentmod.Agent = @ptrCast(@alignCast(ctx.?));
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{}) catch
        return .{ .content = "error: invalid JSON arguments", .is_error = true };
    if (v != .object) return .{ .content = "error: arguments must be an object", .is_error = true };

    const action = blk: {
        const a = v.object.get("action") orelse break :blk "";
        break :blk if (a == .string) a.string else "";
    };
    if (action.len == 0) return .{ .content = "error: missing 'action' (definition | references | hover | rename | diagnostics)", .is_error = true };
    const file = blk: {
        const f = v.object.get("file") orelse break :blk "";
        break :blk if (f == .string) f.string else "";
    };
    if (file.len == 0) return .{ .content = "error: missing 'file'", .is_error = true };

    const argv = lspServerFor(file) orelse return .{
        .content = try std.fmt.allocPrint(arena, "error: no language server mapped for '{s}'. Supported: .zig(zls) .rs(rust-analyzer) .py(pyright-langserver) .go(gopls) .ts/.js(typescript-language-server) .c/.cpp(clangd)", .{std.fs.path.extension(file)}),
        .is_error = true,
    };

    // 读文件:既要 didOpen 的内容,也用于 symbol 定位
    const content = std.Io.Dir.cwd().readFileAlloc(agentmod.util.io, file, arena, .limited(8 * 1024 * 1024)) catch |err|
        return .{ .content = try std.fmt.allocPrint(arena, "error reading {s}: {s}", .{ file, @errorName(err) }), .is_error = true };

    // 定位:优先显式 line/character,否则按 symbol 搜首次出现
    var line: u32 = 0;
    var character: u32 = 0;
    const needs_pos = !std.mem.eql(u8, action, "diagnostics");
    if (needs_pos) {
        if (v.object.get("line")) |l| {
            const raw: i64 = switch (l) {
                .integer => |i| i,
                .float => |f| @intFromFloat(f),
                else => 1,
            };
            line = @intCast(@max(0, raw - 1)); // 入参 1-based → LSP 0-based
            if (v.object.get("character")) |c| {
                const rc: i64 = switch (c) {
                    .integer => |i| i,
                    .float => |f| @intFromFloat(f),
                    else => 1,
                };
                character = @intCast(@max(0, rc - 1));
            }
        } else if (v.object.get("symbol")) |s| {
            if (s != .string or s.string.len == 0) return .{ .content = "error: 'symbol' must be a non-empty string", .is_error = true };
            const found = lspFindSymbol(content, s.string) orelse return .{
                .content = try std.fmt.allocPrint(arena, "error: symbol '{s}' not found in {s}", .{ s.string, file }),
                .is_error = true,
            };
            line = found.line;
            character = found.character;
        } else {
            return .{ .content = "error: need 'symbol' or 'line' to locate the position", .is_error = true };
        }
    }

    var session = LspSession.start(arena, argv, self.cwd) catch
        return .{
            .content = try std.fmt.allocPrint(arena, "error: cannot start language server '{s}' — is it installed and on PATH?", .{argv[0]}),
            .is_error = true,
        };
    defer session.deinit();

    const abs_file = if (std.fs.path.isAbsolute(file)) try arena.dupe(u8, file) else try agentmod.util.joinPath(arena, self.cwd, file);
    const file_uri = try lspPathToUri(arena, abs_file);
    const root_uri = try lspPathToUri(arena, self.cwd);

    // initialize:声明最小能力集
    const init_params = try std.fmt.allocPrint(arena,
        \\{{"processId":null,"rootUri":"{s}","capabilities":{{"textDocument":{{"definition":{{"linkSupport":true}},"references":{{}},"hover":{{"contentFormat":["plaintext","markdown"]}},"rename":{{}},"publishDiagnostics":{{}}}}}},"workspaceFolders":null}}
    , .{root_uri});
    _ = session.request("initialize", init_params) catch |err|
        return .{
            .content = try std.fmt.allocPrint(arena, "error: language server '{s}' handshake failed: {s}", .{ argv[0], @errorName(err) }),
            .is_error = true,
        };
    session.notify("initialized", "{}") catch {};

    // didOpen:把文件内容喂进去(服务器不必自己读盘,也支持未保存内容)
    var text_json = std.Io.Writer.Allocating.init(arena);
    defer text_json.deinit();
    try std.json.Stringify.value(content, .{}, &text_json.writer);
    const open_params = try std.fmt.allocPrint(arena,
        \\{{"textDocument":{{"uri":"{s}","languageId":"{s}","version":1,"text":{s}}}}}
    , .{ file_uri, lspLanguageId(file), text_json.written() });
    session.notify("textDocument/didOpen", open_params) catch {};

    var aw = std.Io.Writer.Allocating.init(arena);
    defer aw.deinit();
    const pos_params = try std.fmt.allocPrint(arena,
        \\{{"textDocument":{{"uri":"{s}"}},"position":{{"line":{d},"character":{d}}}}}
    , .{ file_uri, line, character });

    if (std.mem.eql(u8, action, "definition") or std.mem.eql(u8, action, "references") or std.mem.eql(u8, action, "implementation") or std.mem.eql(u8, action, "type_definition")) {
        const method = if (std.mem.eql(u8, action, "definition"))
            "textDocument/definition"
        else if (std.mem.eql(u8, action, "references"))
            "textDocument/references"
        else if (std.mem.eql(u8, action, "implementation"))
            "textDocument/implementation"
        else
            "textDocument/typeDefinition";
        const params = if (std.mem.eql(u8, action, "references"))
            try std.fmt.allocPrint(arena,
                \\{{"textDocument":{{"uri":"{s}"}},"position":{{"line":{d},"character":{d}}},"context":{{"includeDeclaration":true}}}}
            , .{ file_uri, line, character })
        else
            pos_params;
        const resp = session.request(method, params) catch |err|
            return lspError(arena, argv[0], action, err);
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena, resp, .{}) catch
            return .{ .content = "error: language server returned invalid JSON", .is_error = true };
        if (root == .object) {
            if (root.object.get("error")) |e| return lspServerError(arena, e);
        }
        const result = if (root == .object) (root.object.get("result") orelse std.json.Value{ .null = {} }) else std.json.Value{ .null = {} };
        const n = try lspRenderLocations(arena, result, &aw.writer);
        if (n == 0) return .{ .content = try std.fmt.allocPrint(arena, "no {s} found at {s}:{d}:{d}", .{ action, file, line + 1, character + 1 }) };
        return toolsmod.capped(arena, aw.written(), "lsp", aw.written().len);
    }

    if (std.mem.eql(u8, action, "hover")) {
        const resp = session.request("textDocument/hover", pos_params) catch |err|
            return lspError(arena, argv[0], action, err);
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena, resp, .{}) catch
            return .{ .content = "error: language server returned invalid JSON", .is_error = true };
        if (root == .object) {
            if (root.object.get("error")) |e| return lspServerError(arena, e);
        }
        const result = if (root == .object) (root.object.get("result") orelse std.json.Value{ .null = {} }) else std.json.Value{ .null = {} };
        if (result != .object) return .{ .content = try std.fmt.allocPrint(arena, "no hover info at {s}:{d}:{d}", .{ file, line + 1, character + 1 }) };
        const contents = result.object.get("contents") orelse return .{ .content = "no hover info" };
        // contents 可能是 string / {value} / MarkedString[]
        switch (contents) {
            .string => |s| try aw.writer.writeAll(s),
            .object => |o| {
                if (o.get("value")) |val| {
                    if (val == .string) try aw.writer.writeAll(val.string);
                }
            },
            .array => |a| for (a.items) |item| {
                switch (item) {
                    .string => |s| try aw.writer.print("{s}\n", .{s}),
                    .object => |o| if (o.get("value")) |val| {
                        if (val == .string) try aw.writer.print("{s}\n", .{val.string});
                    },
                    else => {},
                }
            },
            else => {},
        }
        if (aw.written().len == 0) return .{ .content = "no hover info" };
        return toolsmod.capped(arena, aw.written(), "lsp", aw.written().len);
    }

    if (std.mem.eql(u8, action, "rename")) {
        const new_name = blk: {
            const nn = v.object.get("new_name") orelse break :blk "";
            break :blk if (nn == .string) nn.string else "";
        };
        if (new_name.len == 0) return .{ .content = "error: rename needs 'new_name'", .is_error = true };
        const params = try std.fmt.allocPrint(arena,
            \\{{"textDocument":{{"uri":"{s}"}},"position":{{"line":{d},"character":{d}}},"newName":"{s}"}}
        , .{ file_uri, line, character, new_name });
        const resp = session.request("textDocument/rename", params) catch |err|
            return lspError(arena, argv[0], action, err);
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena, resp, .{}) catch
            return .{ .content = "error: language server returned invalid JSON", .is_error = true };
        if (root == .object) {
            if (root.object.get("error")) |e| return lspServerError(arena, e);
        }
        const result = if (root == .object) (root.object.get("result") orelse std.json.Value{ .null = {} }) else std.json.Value{ .null = {} };
        if (result != .object) return .{ .content = "rename produced no edits", .is_error = true };
        // 只报告将改动的位置,不落盘 —— 落盘要走 edit 工具以便过权限门与写锁
        try aw.writer.print("rename '{s}' would touch:\n", .{new_name});
        var total: usize = 0;
        if (result.object.get("changes")) |changes| {
            if (changes == .object) {
                var it = changes.object.iterator();
                while (it.next()) |entry| {
                    const path = try lspUriToPath(arena, entry.key_ptr.*);
                    const edits = entry.value_ptr.*;
                    if (edits != .array) continue;
                    try aw.writer.print("  {s}: {d} edits\n", .{ path, edits.array.items.len });
                    total += edits.array.items.len;
                }
            }
        }
        if (result.object.get("documentChanges")) |dc| {
            if (dc == .array) {
                for (dc.array.items) |item| {
                    if (item != .object) continue;
                    const td = item.object.get("textDocument") orelse continue;
                    if (td != .object) continue;
                    const uri_v = td.object.get("uri") orelse continue;
                    if (uri_v != .string) continue;
                    const edits = item.object.get("edits") orelse continue;
                    if (edits != .array) continue;
                    const path = try lspUriToPath(arena, uri_v.string);
                    try aw.writer.print("  {s}: {d} edits\n", .{ path, edits.array.items.len });
                    total += edits.array.items.len;
                }
            }
        }
        if (total == 0) return .{ .content = "rename produced no edits (symbol may not be renameable here)" };
        try aw.writer.writeAll("\nApply them with the edit or multi_edit tool — lsp does not write files.\n");
        return toolsmod.capped(arena, aw.written(), "lsp", aw.written().len);
    }

    if (std.mem.eql(u8, action, "diagnostics")) {
        // 诊断是服务器主动推的通知,没有请求可等。发一个 hover 当同步栅栏,
        // 让服务器有机会完成分析并把 publishDiagnostics 推过来。
        _ = session.request("textDocument/hover", try std.fmt.allocPrint(arena,
            \\{{"textDocument":{{"uri":"{s}"}},"position":{{"line":0,"character":0}}}}
        , .{file_uri})) catch {};
        var count: usize = 0;
        var cursor: usize = 0;
        while (lspDecodeFrame(session.buf.items[cursor..])) |frame| {
            cursor += frame.consumed;
            const root = std.json.parseFromSliceLeaky(std.json.Value, arena, frame.body, .{}) catch continue;
            if (root != .object) continue;
            const m = root.object.get("method") orelse continue;
            if (m != .string or !std.mem.eql(u8, m.string, "textDocument/publishDiagnostics")) continue;
            const params = root.object.get("params") orelse continue;
            if (params != .object) continue;
            const diags = params.object.get("diagnostics") orelse continue;
            if (diags != .array) continue;
            for (diags.array.items) |d| {
                if (d != .object) continue;
                const rng = d.object.get("range") orelse continue;
                if (rng != .object) continue;
                const start = rng.object.get("start") orelse continue;
                if (start != .object) continue;
                const dl = if (start.object.get("line")) |x| (if (x == .integer) x.integer else 0) else 0;
                const dc = if (start.object.get("character")) |x| (if (x == .integer) x.integer else 0) else 0;
                const sev = if (d.object.get("severity")) |x| (if (x == .integer) x.integer else 0) else 0;
                const label = switch (sev) {
                    1 => "error",
                    2 => "warning",
                    3 => "info",
                    4 => "hint",
                    else => "diag",
                };
                const msg = if (d.object.get("message")) |x| (if (x == .string) x.string else "") else "";
                try aw.writer.print("{s}:{d}:{d}: {s}: {s}\n", .{ file, dl + 1, dc + 1, label, msg });
                count += 1;
            }
        }
        if (count == 0) return .{ .content = try std.fmt.allocPrint(arena, "no diagnostics reported for {s}", .{file}) };
        return toolsmod.capped(arena, aw.written(), "lsp", aw.written().len);
    }

    return .{
        .content = try std.fmt.allocPrint(arena, "error: unknown action '{s}'. Use definition | references | hover | rename | diagnostics | implementation | type_definition", .{action}),
        .is_error = true,
    };
}

/// 传输层失败的统一提示(超时/服务器崩了)。
fn lspError(arena: std.mem.Allocator, server: []const u8, action: []const u8, err: anyerror) toolsmod.Result {
    const hint = switch (err) {
        error.LspTimeout => "the server may still be indexing a large project; retry, or narrow the request",
        error.LspClosed => "the server exited unexpectedly; check that it runs standalone in this project",
        else => "check that the server works standalone in this project",
    };
    return .{
        .content = std.fmt.allocPrint(arena, "error: {s} {s} failed ({s}) — {s}", .{ server, action, @errorName(err), hint }) catch "error: lsp request failed",
        .is_error = true,
    };
}

/// 服务器返回的 JSON-RPC error 对象。
fn lspServerError(arena: std.mem.Allocator, e: std.json.Value) toolsmod.Result {
    var msg: []const u8 = "unknown error";
    if (e == .object) {
        if (e.object.get("message")) |m| {
            if (m == .string) msg = m.string;
        }
    }
    return .{
        .content = std.fmt.allocPrint(arena, "error: language server reported: {s}", .{msg}) catch "error: language server reported an error",
        .is_error = true,
    };
}

test "lsp frame encode and decode roundtrip" {
    const t = std.testing;
    const a = std.testing.allocator;
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}";
    const frame = try lspEncodeFrame(a, body);
    defer a.free(frame);
    try t.expect(std.mem.startsWith(u8, frame, "Content-Length: 38\r\n\r\n"));

    const decoded = lspDecodeFrame(frame) orelse return error.DecodeFailed;
    try t.expectEqualStrings(body, decoded.body);
    try t.expectEqual(frame.len, decoded.consumed);
}

test "lsp frame decoder handles partial and stacked frames" {
    const t = std.testing;
    // 头部未读完 → null(等更多数据),不能误判为坏帧
    try t.expect(lspDecodeFrame("Content-Length: 10") == null);
    // body 未读全 → null
    try t.expect(lspDecodeFrame("Content-Length: 10\r\n\r\nshort") == null);
    // 无 Content-Length → null,不 panic
    try t.expect(lspDecodeFrame("X-Foo: bar\r\n\r\n{}") == null);

    // 连续两帧:解出第一帧后按 consumed 推进能拿到第二帧
    const two = "Content-Length: 2\r\n\r\n{}Content-Length: 4\r\n\r\n[1,]";
    const f1 = lspDecodeFrame(two) orelse return error.DecodeFailed;
    try t.expectEqualStrings("{}", f1.body);
    const f2 = lspDecodeFrame(two[f1.consumed..]) orelse return error.DecodeFailed;
    try t.expectEqualStrings("[1,]", f2.body);

    // 容忍 LF-only 分隔(部分服务器不严格用 CRLF)
    const lf = "Content-Length: 2\n\n{}";
    const f3 = lspDecodeFrame(lf) orelse return error.DecodeFailed;
    try t.expectEqualStrings("{}", f3.body);
}

test "lsp server mapping by extension" {
    const t = std.testing;
    try t.expectEqualStrings("zls", lspServerFor("src/main.zig").?[0]);
    try t.expectEqualStrings("rust-analyzer", lspServerFor("src/lib.rs").?[0]);
    try t.expectEqualStrings("gopls", lspServerFor("main.go").?[0]);
    try t.expectEqualStrings("clangd", lspServerFor("a.cpp").?[0]);
    // 带 --stdio 参数的服务器
    const ts = lspServerFor("app.tsx").?;
    try t.expectEqualStrings("typescript-language-server", ts[0]);
    try t.expectEqualStrings("--stdio", ts[1]);
    const py = lspServerFor("main.py").?;
    try t.expectEqualStrings("pyright-langserver", py[0]);
    try t.expectEqualStrings("--stdio", py[1]);
    // 未知扩展名 → null(调用方给可操作提示)
    try t.expect(lspServerFor("notes.txt") == null);
    try t.expect(lspServerFor("Makefile") == null);

    // languageId 映射
    try t.expectEqualStrings("zig", lspLanguageId("a.zig"));
    try t.expectEqualStrings("typescriptreact", lspLanguageId("a.tsx"));
    try t.expectEqualStrings("plaintext", lspLanguageId("a.txt"));
}

test "lsp uri conversion roundtrip" {
    const t = std.testing;
    const a = std.testing.allocator;
    const uri = try lspPathToUri(a, "/home/u/my project/a.zig");
    defer a.free(uri);
    // 空格必须编码,否则服务器解析失败
    try t.expectEqualStrings("file:///home/u/my%20project/a.zig", uri);

    const back = try lspUriToPath(a, uri);
    defer a.free(back);
    try t.expectEqualStrings("/home/u/my project/a.zig", back);

    // 非 file:// 原样返回
    const other = try lspUriToPath(a, "untitled:foo");
    defer a.free(other);
    try t.expectEqualStrings("untitled:foo", other);
}

test "lsp symbol location is zero-based" {
    const t = std.testing;
    const content = "const a = 1;\nfn target() void {}\n";
    const pos = lspFindSymbol(content, "target") orelse return error.NotFound;
    // 第 2 行(0-based=1),列 3(0-based),"fn " 之后
    try t.expectEqual(@as(u32, 1), pos.line);
    try t.expectEqual(@as(u32, 3), pos.character);
    // 找不到 → null
    try t.expect(lspFindSymbol(content, "nonexistent") == null);
    try t.expect(lspFindSymbol(content, "") == null);
}

test "lsp symbol lookup skips comments and partial matches" {
    const t = std.testing;

    // 实测踩过的坑:gopls 对着文档注释里的符号名返回空 references。
    // 首个文本匹配在第 1 行的注释上,真实定义在第 2 行。
    const doc = "// ComputeTotal sums a slice.\nfunc ComputeTotal(xs []int) int {\n";
    const p1 = lspFindSymbol(doc, "ComputeTotal") orelse return error.NotFound;
    try t.expectEqual(@as(u32, 1), p1.line); // 跳过注释,落在定义行
    try t.expectEqual(@as(u32, 5), p1.character); // "func " 之后

    // 完整标识符:Total 不该命中 ComputeTotal 的尾部
    const sub = "func ComputeTotal() {}\nvar Total = 1;\n";
    const p2 = lspFindSymbol(sub, "Total") orelse return error.NotFound;
    try t.expectEqual(@as(u32, 1), p2.line);
    try t.expectEqual(@as(u32, 4), p2.character);

    // 字符串字面量里的出现也跳过
    const str = "print(\"call handleReq now\")\nfn handleReq() void {}\n";
    const p3 = lspFindSymbol(str, "handleReq") orelse return error.NotFound;
    try t.expectEqual(@as(u32, 1), p3.line);

    // 只在注释里出现 → 兜底返回它,而不是假装找不到
    const only = "// TODO: rename oldName later\nconst x = 1;\n";
    const p4 = lspFindSymbol(only, "oldName") orelse return error.NotFound;
    try t.expectEqual(@as(u32, 0), p4.line);

    // python/shell 的 # 注释同样跳过
    const hash = "# helper does things\ndef helper():\n    pass\n";
    const p5 = lspFindSymbol(hash, "helper") orelse return error.NotFound;
    try t.expectEqual(@as(u32, 1), p5.line);
}

test "lsp tool fails gracefully without a server" {
    const t = std.testing;
    try agentmod.util.testInit();
    var arena = agentmod.util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = agentmod.cfgmod.Config{ .arena = &arena };
    var provs = [_]agentmod.cfgmod.Provider{.{ .name = "mock", .api = .openai_completions, .base_url = "http://127.0.0.1:1", .api_key = "k" }};
    cfg.providers = &provs;
    var agent = try agentmod.Agent.init(a, &cfg, "mock", "m", "/tmp");

    // 缺 action / file → 明确错误
    const e1 = try toolLsp(@ptrCast(&agent), a, "{}");
    try t.expect(e1.is_error);
    try t.expect(std.mem.indexOf(u8, e1.content, "action") != null);
    const e2 = try toolLsp(@ptrCast(&agent), a, "{\"action\":\"definition\"}");
    try t.expect(e2.is_error);
    try t.expect(std.mem.indexOf(u8, e2.content, "file") != null);

    // 不支持的扩展名 → 列出支持范围,不 crash
    const e3 = try toolLsp(@ptrCast(&agent), a, "{\"action\":\"definition\",\"file\":\"notes.txt\",\"symbol\":\"x\"}");
    try t.expect(e3.is_error);
    try t.expect(std.mem.indexOf(u8, e3.content, "no language server mapped") != null);

    // 文件不存在 → 读文件错误(在 spawn 之前失败,不留孤儿进程)
    const e4 = try toolLsp(@ptrCast(&agent), a, "{\"action\":\"definition\",\"file\":\"/nonexistent/x.zig\",\"symbol\":\"y\"}");
    try t.expect(e4.is_error);
    try t.expect(std.mem.indexOf(u8, e4.content, "error reading") != null);

    // 未知 action → 列出合法值
    const tmp_dir = std.testing.tmpDir(.{});
    var td = tmp_dir;
    defer td.cleanup();
    try td.dir.writeFile(agentmod.util.io, .{ .sub_path = "x.zig", .data = "const x = 1;\n" });
    const tmppath = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/x.zig", .{td.sub_path[0..]});
    const e5 = try toolLsp(@ptrCast(&agent), a, try std.fmt.allocPrint(a, "{{\"action\":\"bogus\",\"file\":\"{s}\",\"symbol\":\"x\"}}", .{tmppath}));
    try t.expect(e5.is_error);
    // 未知 action 在定位之后才判定,所以要么报 action 非法,要么报服务器不可用(zls 未装)
    try t.expect(std.mem.indexOf(u8, e5.content, "unknown action") != null or
        std.mem.indexOf(u8, e5.content, "cannot start language server") != null);
}
