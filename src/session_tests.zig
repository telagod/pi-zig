//! session_tests.zig —— session.zig 的单测主体(持久化/列表/fork/web 会话/图片)。
//! 拆自 session.zig(原净尾 483 行);session.zig 尾部 test 钩子引回,收集不变。
const std = @import("std");
const util = @import("util.zig");
const ai = @import("ai.zig");
const sess = @import("session.zig");

const Session = sess.Session;
const MAX_TITLE_BYTES = sess.MAX_TITLE_BYTES;
const deriveTitle = sess.deriveTitle;
const formatAge = sess.formatAge;
const saveWeb = sess.saveWeb;
const loadWeb = sess.loadWeb;
const webDirPublic = sess.webDirPublic;
const archiveWeb = sess.archiveWeb;
const restoreWeb = sess.restoreWeb;
const persistImageFile = sess.persistImageFile;
const loadImageFile = sess.loadImageFile;

test "session compaction audit sidecar(借 dsh compaction/* 仅日志之意)" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);
    defer util.environ_map.?.put("PIZ_DIR", "/nonexistent-piz-dir") catch {};

    Session.logCompaction(a, "/work/x", 12, 5, 1, 262144, 40000, "折叠摘要甲");
    Session.logCompaction(a, "/work/x", 3, 20, 2, 262144, 9000, "摘要乙");
    const path = try std.fmt.allocPrint(a, "{s}/sessions/compactions.jsonl", .{tmp_path});
    const content = try std.Io.Dir.cwd().readFileAlloc(util.io, path, a, .limited(1 << 20));
    var lines = std.mem.splitScalar(u8, content, '\n');
    const l1 = lines.next().?;
    const l2 = lines.next().?;
    const rest = lines.next() orelse "";
    try t.expect(rest.len == 0);
    try t.expect(lines.next() == null);
    const v1 = try std.json.parseFromSliceLeaky(std.json.Value, a, l1, .{});
    try t.expectEqual(@as(i64, 12), v1.object.get("cut").?.integer);
    try t.expectEqual(@as(i64, 5), v1.object.get("kept").?.integer);
    try t.expectEqualStrings("/work/x", v1.object.get("cwd").?.string);
    try t.expectEqualStrings("折叠摘要甲", v1.object.get("summary").?.string);
    const v2 = try std.json.parseFromSliceLeaky(std.json.Value, a, l2, .{});
    try t.expectEqual(@as(i64, 2), v2.object.get("compacts").?.integer);
    try t.expectEqual(@as(i64, 9000), v2.object.get("est_after").?.integer);
    // 回放不染:行无 role 字段,loadMessages 天然跳过
    try t.expect(v1.object.get("role") == null);
}

test "session roundtrip" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 隔离 env:否则会受其他测试污染并写真实会话目录
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    var sess1 = try Session.fresh(a, "/tmp");
    defer {
        std.Io.Dir.cwd().deleteFile(util.io, sess1.path) catch {};
        if (std.fmt.allocPrint(a, "{s}/sessions/--tmp--", .{tmp_path})) |sd1| {
            std.Io.Dir.cwd().deleteDir(util.io, sd1) catch {};
        } else |_| {}
        if (std.fmt.allocPrint(a, "{s}/sessions", .{tmp_path})) |sd2| {
            std.Io.Dir.cwd().deleteDir(util.io, sd2) catch {};
        } else |_| {}
    }
    try sess1.saveMessage(&.{ .role = "user", .content = "hi" });
    try sess1.saveMessage(&.{ .role = "assistant", .content = "hello", .tool_calls = &.{.{ .id = "c1", .name = "bash", .args = "{}" }}, .reasoning = "cot", .thinking_signature = "sig1" });
    try sess1.saveMessage(&.{ .role = "tool", .content = "out", .tool_call_id = "c1" });

    const msgs = try sess1.loadMessages();
    try t.expectEqual(@as(usize, 3), msgs.len);
    try t.expectEqualStrings("hi", msgs[0].content);
    try t.expectEqualStrings("bash", msgs[1].tool_calls.?[0].name);
    try t.expectEqualStrings("cot", msgs[1].reasoning.?);
    try t.expectEqualStrings("sig1", msgs[1].thinking_signature.?);
    try t.expectEqualStrings("c1", msgs[2].tool_call_id.?);
}

test "model-visible reconstruct drops system and keeps user/assistant/tool" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    var sess1 = try Session.fresh(a, "/tmp");
    defer {
        std.Io.Dir.cwd().deleteFile(util.io, sess1.path) catch {};
        if (std.fmt.allocPrint(a, "{s}/sessions/--tmp--", .{tmp_path})) |sd1| {
            std.Io.Dir.cwd().deleteDir(util.io, sd1) catch {};
        } else |_| {}
        if (std.fmt.allocPrint(a, "{s}/sessions", .{tmp_path})) |sd2| {
            std.Io.Dir.cwd().deleteDir(util.io, sd2) catch {};
        } else |_| {}
    }
    try sess1.saveMessage(&.{ .role = "system", .content = "you are piz" });
    try sess1.saveMessage(&.{ .role = "user", .content = "hi" });
    try sess1.saveMessage(&.{ .role = "assistant", .content = "ok" });
    try sess1.saveMessage(&.{ .role = "tool", .content = "out", .tool_call_id = "c1" });

    const vis = try sess1.reconstructModelVisible();
    try t.expectEqual(@as(usize, 3), vis.len);
    try t.expectEqualStrings("user", vis[0].role);
    try t.expectEqualStrings("assistant", vis[1].role);
    try t.expectEqualStrings("tool", vis[2].role);
    try t.expect(Session.isModelVisibleRole("user"));
    try t.expect(!Session.isModelVisibleRole("system"));
}

test "session title + list + setTitle" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 注:Environ.Map.put 覆盖时 free 旧值,恢复旧值会 UAF——测试内只覆盖不恢复
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    var s0 = try Session.fresh(a, "/tmp");
    var s1 = try Session.freshTitle(a, "/tmp", "my title");
    try t.expect(!std.mem.eql(u8, s0.sessionId(), s1.sessionId()));
    std.Io.Dir.cwd().deleteFile(util.io, s0.path) catch {};
    defer {
        std.Io.Dir.cwd().deleteFile(util.io, s1.path) catch {};
        if (std.fmt.allocPrint(a, "{s}/sessions/--tmp--", .{tmp_path})) |sd1| {
            std.Io.Dir.cwd().deleteDir(util.io, sd1) catch |e| std.debug.print("[sess-test] deleteDir1 {s}\n", .{@errorName(e)});
        } else |_| {}
        if (std.fmt.allocPrint(a, "{s}/sessions", .{tmp_path})) |sd2| {
            std.Io.Dir.cwd().deleteDir(util.io, sd2) catch |e| std.debug.print("[sess-test] deleteDir2 {s}\n", .{@errorName(e)});
        } else |_| {}
    }
    try s1.saveMessage(&.{ .role = "user", .content = "hi" });
    _ = std.Io.sleep(util.io, .{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake) catch {};
    var s2 = try Session.fresh(a, "/tmp");
    defer {
        std.Io.Dir.cwd().deleteFile(util.io, s2.path) catch {};
    }

    // open 读回 title
    const opened = try Session.open(a, s1.path);
    try t.expectEqualStrings("my title", opened.title.?);
    // 惰性写盘:s2 未言,档无 meta——findLatest/list 皆不见
    try t.expectEqual(@as(usize, 1), (try Session.list(a, "/tmp")).len);
    try t.expectEqualStrings(s1.path, (try Session.findLatest(a, "/tmp")).?.path);
    // s2 发言后入场,为最新
    try s2.saveMessage(&.{ .role = "user", .content = "s2 hi" });
    // findLatest 返回最新
    const latest = (try Session.findLatest(a, "/tmp")).?;
    try t.expectEqualStrings(s2.path, latest.path);
    // list 降序
    const all = try Session.list(a, "/tmp");
    try t.expectEqual(@as(usize, 2), all.len);
    try t.expectEqualStrings(s2.path, all[0].path);
    try t.expectEqualStrings(s1.path, all[1].path);
    // setTitle 重写元信息
    try s1.setTitle("renamed");
    const opened2 = try Session.open(a, s1.path);
    try t.expectEqualStrings("renamed", opened2.title.?);

    // 落盘的标题裁到 MAX_TITLE_BYTES:无界标题会一路带进内存和每个响应
    try s1.setTitle("L" ** 2000);
    try t.expectEqual(@as(usize, MAX_TITLE_BYTES), (try Session.open(a, s1.path)).title.?.len);

    // 中文不能切在多字节序列中间 —— 那样读回来是非法 UTF-8,JSON 也就坏了
    try s1.setTitle("标题" ** 500);
    const zh = (try Session.open(a, s1.path)).title.?;
    try t.expect(zh.len <= MAX_TITLE_BYTES);    try t.expect(std.unicode.utf8ValidateSlice(zh));

    // 上限内原样保留
    try s1.setTitle("正常标题");
    try t.expectEqualStrings("正常标题", (try Session.open(a, s1.path)).title.?);
}

test "session describe prefers title then first user preview" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    var titled = try Session.freshTitle(a, "/tmp", "my title");
    defer {
        std.Io.Dir.cwd().deleteFile(util.io, titled.path) catch {};
        titled.deinit();
    }
    try titled.saveMessage(&.{ .role = "user", .content = "ignored because titled" });
    const now = std.Io.Clock.now(.real, util.io).nanoseconds;
    const d0 = try titled.describe(a, now);
    defer d0.deinit(a);
    try t.expectEqualStrings("my title", d0.headline);
    try t.expect(std.mem.indexOf(u8, d0.hint, "1t") != null);

    var untitled = try Session.fresh(a, "/tmp");
    defer {
        std.Io.Dir.cwd().deleteFile(util.io, untitled.path) catch {};
        untitled.deinit();
    }
    try untitled.saveMessage(&.{ .role = "user", .content = "fix footer mojibake\nand more" });
    const d1 = try untitled.describe(a, now);
    defer d1.deinit(a);
    try t.expectEqualStrings("fix footer mojibake and more", d1.headline);
    try t.expect(std.mem.indexOf(u8, d1.hint, "1t") != null);

    var age_buf: [16]u8 = undefined;
    try t.expectEqualStrings("now", formatAge(&age_buf, 100, 100));
    try t.expectEqualStrings("5m", formatAge(&age_buf, 6 * 60 * std.time.ns_per_s, 1 * 60 * std.time.ns_per_s));
    try t.expectEqualStrings("3h", formatAge(&age_buf, 4 * 3600 * std.time.ns_per_s, 1 * 3600 * std.time.ns_per_s));
}

test "session truncate" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    var sess1 = try Session.fresh(a, "/tmp");
    defer {
        std.Io.Dir.cwd().deleteFile(util.io, sess1.path) catch {};
        // deleteTree 对空目录链静默失败,手动清 sessions 目录
        if (std.fmt.allocPrint(a, "{s}/sessions/--tmp--", .{tmp_path})) |sd1| {
            std.Io.Dir.cwd().deleteDir(util.io, sd1) catch |e| std.debug.print("[sess-test] deleteDir1 {s}\n", .{@errorName(e)});
        } else |_| {}
        if (std.fmt.allocPrint(a, "{s}/sessions", .{tmp_path})) |sd2| {
            std.Io.Dir.cwd().deleteDir(util.io, sd2) catch |e| std.debug.print("[sess-test] deleteDir2 {s}\n", .{@errorName(e)});
        } else |_| {}
    }
    try sess1.saveMessage(&.{ .role = "user", .content = "q1" });
    try sess1.saveMessage(&.{ .role = "assistant", .content = "a1" });
    try sess1.saveMessage(&.{ .role = "user", .content = "q2" });
    try sess1.saveMessage(&.{ .role = "assistant", .content = "a2" });

    try sess1.truncate(2); // 保留元信息 + 前 2 条
    const msgs = try sess1.loadMessages();
    try t.expectEqual(@as(usize, 2), msgs.len);
    try t.expectEqualStrings("q1", msgs[0].content);
    try t.expectEqualStrings("a1", msgs[1].content);
    // 截断后追加仍正常
    try sess1.saveMessage(&.{ .role = "user", .content = "q3" });
    const msgs2 = try sess1.loadMessages();
    try t.expectEqual(@as(usize, 3), msgs2.len);
    try t.expectEqualStrings("q3", msgs2[2].content);
}

test "full-file rewrites replace atomically, never truncate in place" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    var sess1 = try Session.fresh(a, "/tmp");
    defer {
        std.Io.Dir.cwd().deleteFile(util.io, sess1.path) catch {};
        if (std.fmt.allocPrint(a, "{s}/sessions/--tmp--", .{tmp_path})) |sd1| {
            std.Io.Dir.cwd().deleteDir(util.io, sd1) catch {};
        } else |_| {}
        if (std.fmt.allocPrint(a, "{s}/sessions", .{tmp_path})) |sd2| {
            std.Io.Dir.cwd().deleteDir(util.io, sd2) catch {};
        } else |_| {}
    }
    try sess1.saveMessage(&.{ .role = "user", .content = "q1" });
    try sess1.saveMessage(&.{ .role = "assistant", .content = "a1" });
    try sess1.saveMessage(&.{ .role = "user", .content = "q2" });

    // 原地覆盖会保持 inode 不变;原子替换必然换掉 inode。
    // 这是「实现真的走了临时文件 + rename」唯一能从外部观测的签名 ——
    // 直写 writeFile 的话磁盘满/被 kill 会留下截断的文件,用户一次 /undo 丢光历史。
    const ino_before = (try std.Io.Dir.cwd().statFile(util.io, sess1.path, .{})).inode;
    try sess1.truncate(2);
    const ino_after = (try std.Io.Dir.cwd().statFile(util.io, sess1.path, .{})).inode;
    try t.expect(ino_before != ino_after);

    // 内容仍然正确,且没有 .tmp 残留
    const msgs = try sess1.loadMessages();
    try t.expectEqual(@as(usize, 2), msgs.len);
    try t.expectEqualStrings("q1", msgs[0].content);
    const leftover = try std.fmt.allocPrint(a, "{s}.tmp", .{sess1.path});
    try t.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(util.io, leftover, .{}));

    // setTitle 走同一条原子路径
    const ino2 = (try std.Io.Dir.cwd().statFile(util.io, sess1.path, .{})).inode;
    try sess1.setTitle("renamed");
    const ino3 = (try std.Io.Dir.cwd().statFile(util.io, sess1.path, .{})).inode;
    try t.expect(ino2 != ino3);
    try t.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(util.io, leftover, .{}));
}

test "session listing, latest and lookup by id" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    // 造一个更早的会话文件(手写,时间戳文件名),验证 list 按 mtime 降序
    const slug_dir = try std.fmt.allocPrint(a, "{s}/sessions/--tmp--", .{tmp_path});
    try std.Io.Dir.cwd().createDirPath(util.io, slug_dir);
    const pi_file = try std.fmt.allocPrint(a, "{s}/1700000000000.jsonl", .{slug_dir});
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = pi_file, .data = "{\"cwd\":\"/tmp\",\"started\":1}\n{\"role\":\"user\",\"content\":\"older\"}\n" });

    var s1 = try Session.fresh(a, "/tmp");
    _ = std.Io.sleep(util.io, .{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake) catch {};
    defer {
        std.Io.Dir.cwd().deleteFile(util.io, s1.path) catch {};
        std.Io.Dir.cwd().deleteFile(util.io, pi_file) catch {};
        if (std.fmt.allocPrint(a, "{s}/sessions/--tmp--", .{tmp_path})) |sd1| {
            std.Io.Dir.cwd().deleteDir(util.io, sd1) catch {};
        } else |_| {}
        if (std.fmt.allocPrint(a, "{s}/sessions", .{tmp_path})) |sd2| {
            std.Io.Dir.cwd().deleteDir(util.io, sd2) catch {};
        } else |_| {}
    }
    try s1.saveMessage(&.{ .role = "user", .content = "piz hello" });

    // list 看到两个会话,按 mtime 降序(最新在前)
    const all = try Session.list(a, "/tmp");
    try t.expectEqual(@as(usize, 2), all.len);
    try t.expectEqualStrings(s1.path, all[0].path); // piz 最新在前
    // findLatest 命中 piz 会话,消息完整
    var latest = (try Session.findLatest(a, "/tmp")).?;
    const msgs = try latest.loadMessages();
    try t.expectEqual(@as(usize, 1), msgs.len);
    try t.expectEqualStrings("piz hello", msgs[0].content);
    // findById:带/不带 .jsonl 均可命中
    const b1 = std.fs.path.basename(s1.path);
    const id1 = b1[0 .. b1.len - ".jsonl".len];
    try t.expectEqualStrings(id1, s1.sessionId());
    try t.expectEqualStrings(s1.path, (try Session.findById(a, "/tmp", id1)).?.path);
    try t.expectEqualStrings(s1.path, (try Session.findById(a, "/tmp", b1)).?.path);
    try t.expect((try Session.findById(a, "/tmp", "nope")) == null);
}

test "session fork tree" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    var sess1 = try Session.fresh(a, "/tmp");
    try sess1.saveMessage(&.{ .role = "user", .content = "q1" });
    try sess1.saveMessage(&.{ .role = "assistant", .content = "a1" });
    try sess1.saveMessage(&.{ .role = "user", .content = "q2" });
    try sess1.saveMessage(&.{ .role = "assistant", .content = "a2" });

    // 落盘带 id/parent_id,链式相接
    const raw_content = try std.Io.Dir.cwd().readFileAlloc(util.io, sess1.path, a, .limited(4096));
    // 首行是元信息,随后每条消息各一行(4 条消息 + meta + 尾随换行)
    try t.expect(std.mem.indexOf(u8, raw_content, "\"role\":\"user\"") != null);
    try t.expect(std.mem.indexOf(u8, raw_content, "\"parent_id\":") != null);
    const msgs = try sess1.loadMessages();
    try t.expect(msgs[0].id != null);
    try t.expect(msgs[1].parent_id != null);
    try t.expectEqualStrings(msgs[0].id.?, msgs[1].parent_id.?);
    try t.expectEqualStrings(msgs[2].parent_id.?, msgs[1].id.?);
    // 续写接续最后一条
    try sess1.saveMessage(&.{ .role = "user", .content = "q3" });
    const msgs2 = try sess1.loadMessages();
    try t.expectEqualStrings(msgs[3].id.?, msgs2[4].parent_id.?);

    // fork:前 2 条拷贝到新会话,续写 parent 接第 2 条
    var branch = try sess1.fork(2);
    defer {
        std.Io.Dir.cwd().deleteFile(util.io, branch.path) catch {};
        std.Io.Dir.cwd().deleteFile(util.io, sess1.path) catch {};
        if (std.fmt.allocPrint(a, "{s}/sessions/--tmp--", .{tmp_path})) |sd1| {
            std.Io.Dir.cwd().deleteDir(util.io, sd1) catch {};
        } else |_| {}
        if (std.fmt.allocPrint(a, "{s}/sessions", .{tmp_path})) |sd2| {
            std.Io.Dir.cwd().deleteDir(util.io, sd2) catch {};
        } else |_| {}
    }
    const bmsgs = try branch.loadMessages();
    try t.expectEqual(@as(usize, 2), bmsgs.len);
    try t.expectEqualStrings("q1", bmsgs[0].content);
    try t.expectEqualStrings("a1", bmsgs[1].content);
    try branch.saveMessage(&.{ .role = "user", .content = "branch-q" });
    const bmsgs2 = try branch.loadMessages();
    try t.expectEqual(@as(usize, 3), bmsgs2.len);
    try t.expectEqualStrings(bmsgs[1].id.?, bmsgs2[2].parent_id.?); // 分支接第 2 条
}

test "web session rewrite is atomic, 0600, and tolerates a corrupt line" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);

    const proj = "/tmp/webproj";
    const msgs = [_]ai.Message{
        .{ .role = "user", .content = "q1" },
        .{ .role = "assistant", .content = "a1" },
    };
    try saveWeb(a, proj, "s1", "m", true, "t1", &msgs);

    const dir = try webDirPublic(a, proj);
    const path = try util.joinPath(a, dir, "s1.jsonl");
    const tmpfile = try std.fmt.allocPrint(a, "{s}.tmp", .{path});
    defer {
        std.Io.Dir.cwd().deleteFile(util.io, path) catch {};
        std.Io.Dir.cwd().deleteFile(util.io, tmpfile) catch {};
    }

    // 会话里是完整对话内容,权限必须是 0600 —— 不能跟目录默认权限走。
    const st = try std.Io.Dir.cwd().statFile(util.io, path, .{});
    try t.expectEqual(@as(u32, 0o600), @as(u32, @intFromEnum(st.permissions)) & 0o777);

    // web 会话每轮都全量重写。原地覆盖会保持 inode;原子替换必然换掉 ——
    // 直写的话写到一半被 kill 就是整份历史被截断。
    const ino1 = st.inode;
    const msgs2 = msgs ++ [_]ai.Message{.{ .role = "user", .content = "q2" }};
    try saveWeb(a, proj, "s1", "m", true, "t1", &msgs2);
    const ino2 = (try std.Io.Dir.cwd().statFile(util.io, path, .{})).inode;
    try t.expect(ino1 != ino2);
    // 临时文件不许残留
    try t.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(util.io, tmpfile, .{}));

    const loaded = (try loadWeb(a, proj, "s1")).?;
    try t.expectEqual(@as(usize, 3), loaded.msgs.len);
    try t.expectEqualStrings("q2", loaded.msgs[2].content);

    // 末行被截断(崩溃留下的形态):跳过坏行,前面的消息仍读得回来,不整体失败
    const raw = try std.Io.Dir.cwd().readFileAlloc(util.io, path, a, .limited(1 << 20));
    const cut = try std.fmt.allocPrint(a, "{s}{{\"role\":\"assistant\",\"cont", .{raw});
    try std.Io.Dir.cwd().writeFile(util.io, .{ .sub_path = path, .data = cut });
    const after = (try loadWeb(a, proj, "s1")).?;
    try t.expectEqual(@as(usize, 3), after.msgs.len);
}

test "archiveWeb restoreWeb propagate missing-file errors" {
    const t = std.testing;
    try util.testInit();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);
    const proj = "/tmp/webproj-arch";
    try t.expectError(error.FileNotFound, archiveWeb(a, proj, "ghost"));
    const msgs = [_]ai.Message{.{ .role = "user", .content = "x" }};
    try saveWeb(a, proj, "s1", "m", true, "t", &msgs);
    try archiveWeb(a, proj, "s1");
    try t.expect((try loadWeb(a, proj, "s1")) == null);
    try restoreWeb(a, proj, "s1");
    const loaded = (try loadWeb(a, proj, "s1")).?;
    try t.expectEqual(@as(usize, 1), loaded.msgs.len);
}

test "session image persist roundtrip" {
    const t = std.testing;
    try util.testInit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd_abs = try std.process.currentPathAlloc(util.io, a);
    const tmp_path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_abs, tmp.sub_path });
    try util.environ_map.?.put("PIZ_DIR", tmp_path);
    const png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
    const name = persistImageFile(a, png_b64, "image/png") orelse return error.PersistFailed;
    const got = loadImageFile(a, name) orelse return error.LoadFailed;
    try t.expect(got.len > 0);
    try t.expect(std.mem.startsWith(u8, name, "img-"));
    try t.expect(loadImageFile(a, "../secret.png") == null);
    try t.expect(loadImageFile(a, "bash-1.txt") == null);
}

test "deriveTitle takes first line and clamps" {
    const t = std.testing;
    var arena = util.Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect(deriveTitle(a, "") == null);
    try t.expect(deriveTitle(a, "  (image)  ") == null);
    const got = deriveTitle(a, "  fix the login bug\nmore") orelse return error.NoTitle;
    try t.expectEqualStrings("fix the login bug", got);
    const long = "x" ** 80;
    const clipped = deriveTitle(a, long) orelse return error.NoTitle;
    try t.expect(clipped.len <= 64);
}
