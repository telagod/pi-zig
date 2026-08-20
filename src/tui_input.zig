// tui_input.zig — 键盘/鼠标输入、剪贴板、斜杠与 @文件 补全。拆自 tui.zig。
const std = @import("std");
const tui = @import("tui.zig");
const util = @import("core").util;
const slash = @import("tui_slash.zig");
const keys = @import("tui_keys.zig");
const filesmod = @import("core").tools_files;
const emit = @import("tui_emit.zig");
const wrapRowCount = emit.wrapRowCount;
const wrapCursor = emit.wrapCursor;
const wrapMoveVertical = emit.wrapMoveVertical;

const Tui = tui.Tui;
pub const Action = union(enum) { none, quit, abort, detach, submit: []const u8, think, copy, sandbox, jobs, usage, redo, doctor, diff, log };
const WheelDir = keys.WheelDir;
const SlashRank = slash.SlashRank;
const slashName = slash.slashName;
const slashQuery = slash.slashQuery;
const rankSlash = slash.rankSlash;
const consumeSameCsi = keys.consumeSameCsi;
const sgrWheel = keys.sgrWheel;
const classifyCsi = keys.classifyCsi;
const deleteUtf8Before = keys.deleteUtf8Before;
const deleteUtf8At = keys.deleteUtf8At;
const utf8PrevLen = keys.utf8PrevLen;
const utf8LenAt = keys.utf8LenAt;

pub fn armOrQuit(self: *Tui, key: u8) Action {
    const now = tui.nowNs();
    if (self.quit_arm_key == key and self.quit_arm_ns != 0 and now - self.quit_arm_ns < std.time.ns_per_s) {
        self.disarmQuit();
        return .quit;
    }
    self.quit_arm_key = key;
    self.quit_arm_ns = now;
    self.dirty.store(true, .release);
    return .none;
}

pub fn pasteClipboard(self: *Tui) void {
    if (util.clipboardImage(self.alloc)) |img| {
        if (self.pending_image) |old| self.alloc.free(old);
        self.pending_image = img;
        self.pending_mime = if (img.len >= 3 and img[0] == 0xff) "image/jpeg" else "image/png";
        self.dirty.store(true, .release);
        return;
    }
    const text = util.clipboardText(self.alloc) orelse return;
    defer self.alloc.free(text);
    for (text) |c| {
        if (c == '\n' or c == '\r') continue;
        if (self.cursor >= self.input.items.len) {
            self.input.append(c) catch break;
        } else {
            self.input.insert(self.cursor, c) catch break;
        }
        self.cursor += 1;
    }
    self.dirty.store(true, .release);
}

pub fn hasPendingImage(self: *const Tui) bool {
    return self.pending_image != null;
}

pub const PendingImage = struct { data: []u8, mime: []const u8 };

pub fn takePendingImage(self: *Tui) ?PendingImage {
    const img = self.pending_image orelse return null;
    const mime = self.pending_mime;
    self.pending_image = null;
    self.pending_mime = "";
    self.dirty.store(true, .release);
    return .{ .data = img, .mime = mime };
}

pub fn takeSubmit(self: *Tui) !Action {
    if (self.input.items.len == 0 and self.pending_image == null) return .none;
    const line = if (slashSubmitLine(self)) |picked|
        picked
    else
        try self.alloc.dupe(u8, self.input.items);
    self.input.clearRetainingCapacity();
    self.cursor = 0;
    self.hist_idx = null;
    self.slash_sel = 0;
    self.disarmQuit();
    self.esc_armed = false;
    self.shortcuts_open = false;
    return .{ .submit = line };
}

pub fn slashSubmitLine(self: *Tui) ?[]u8 {
    const q = slashQuery(self.input.items) orelse return null;
    var ranks: [64]SlashRank = undefined;
    const n = rankSlash(self.slash_items, q, &ranks);
    if (n == 0) return null;
    const sel = @min(self.slash_sel, n - 1);
    const name = slashName(self.slash_items[ranks[sel].item].cmd);
    return std.fmt.allocPrint(self.alloc, "/{s}", .{name}) catch null;
}

pub fn completeSlash(self: *Tui) !void {
    const q = slashQuery(self.input.items) orelse return;
    var ranks: [64]SlashRank = undefined;
    const n = rankSlash(self.slash_items, q, &ranks);
    if (n == 0) return;
    const sel = @min(self.slash_sel, n - 1);
    const name = slashName(self.slash_items[ranks[sel].item].cmd);
    self.input.clearRetainingCapacity();
    try self.input.append('/');
    try self.input.appendSlice(name);
    self.cursor = self.input.items.len;
    self.dirty.store(true, .release);
}

pub fn moveSlash(self: *Tui, delta: isize) void {
    const q = slashQuery(self.input.items) orelse return;
    var ranks: [64]SlashRank = undefined;
    const n = rankSlash(self.slash_items, q, &ranks);
    if (n == 0) return;
    if (delta < 0) {
        const d: usize = @intCast(-delta);
        self.slash_sel = if (self.slash_sel >= d) self.slash_sel - d else 0;
    } else {
        const d: usize = @intCast(delta);
        self.slash_sel = @min(n - 1, self.slash_sel + d);
    }
    self.dirty.store(true, .release);
}

pub fn slashOpen(self: *const Tui) bool {
    return self.picker == null and slashQuery(self.input.items) != null and self.slash_items.len > 0;
}

pub fn fileOpen(self: *const Tui) bool {
    return self.picker == null and filesmod.atQuery(self.input.items) != null and self.file_items.len > 0;
}

pub fn ensureAtFiles(self: *Tui) void {
    const q = filesmod.atQuery(self.input.items) orelse {
        self.file_items = &.{};
        self.file_q_hash = 0;
        return;
    };
    const root = if (self.footer_cwd.items.len > 0) self.footer_cwd.items else ".";
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(root);
    hasher.update(q);
    const h = hasher.final();
    if (h == self.file_q_hash) return;
    self.file_q_hash = h;
    _ = self.file_arena.reset(.retain_capacity);
    const a = self.file_arena.allocator();
    self.file_items = filesmod.listWorkspaceFiles(a, root, q) catch &.{};
    if (self.file_sel >= self.file_items.len) self.file_sel = 0;
}

pub fn completeAtFile(self: *Tui) !void {
    ensureAtFiles(self);
    if (self.file_items.len == 0) return;
    const start = filesmod.atTokenStart(self.input.items) orelse return;
    const sel = @min(self.file_sel, self.file_items.len - 1);
    const it = self.file_items[sel];
    const filled = if (it.dir)
        try std.fmt.allocPrint(self.alloc, "@./{s}/", .{it.path})
    else
        try std.fmt.allocPrint(self.alloc, "@./{s} ", .{it.path});
    defer self.alloc.free(filled);
    self.input.shrinkRetainingCapacity(start);
    try self.input.appendSlice(filled);
    self.cursor = self.input.items.len;
    self.file_q_hash = 0;
    ensureAtFiles(self);
    self.dirty.store(true, .release);
}

pub fn moveFile(self: *Tui, delta: isize) void {
    ensureAtFiles(self);
    if (self.file_items.len == 0) return;
    if (delta < 0) {
        const d: usize = @intCast(-delta);
        self.file_sel = if (self.file_sel >= d) self.file_sel - d else 0;
    } else {
        const d: usize = @intCast(delta);
        self.file_sel = @min(self.file_items.len - 1, self.file_sel + d);
    }
    self.dirty.store(true, .release);
}

pub fn insertByte(self: *Tui, b: u8) !void {
    if (self.cursor >= self.input.items.len) {
        try self.input.append(b);
    } else {
        try self.input.insert(self.cursor, b);
    }
    self.cursor += 1;
    self.dirty.store(true, .release);
}

pub fn handleInput(self: *Tui, bytes: []const u8) !Action {
    if (self.picker != null) return handlePickerInput(self, bytes);
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        const streaming = self.streaming.load(.acquire);

        // bracketed paste 进行中:原样收录到 ESC[201~;\r\n/\r 归一 \n。
        if (self.paste_mode) {
            if (b == 0x1b and i + 5 < bytes.len and bytes[i + 1] == '[' and bytes[i + 2] == '2' and bytes[i + 3] == '0' and bytes[i + 4] == '1' and bytes[i + 5] == '~') {
                self.paste_mode = false;
                i += 6;
                continue;
            }
            if (b == '\r') { // \r\n 一并吞
                try insertByte(self, '\n');
                i += if (i + 1 < bytes.len and bytes[i + 1] == '\n') 2 else 1;
                continue;
            }
            try insertByte(self, b);
            i += 1;
            continue;
        }

        if (b == 0x1b) {
            if (i + 1 < bytes.len and (bytes[i + 1] == '\r' or bytes[i + 1] == '\n')) {
                // Alt+Enter:插入换行(多行草稿)。
                self.disarmQuit();
                self.esc_armed = false;
                try insertByte(self, '\n');
                i += 2;
                continue;
            }
            if (i + 1 < bytes.len and bytes[i + 1] == '[') {
                i += 2;
                var k = i;
                while (k < bytes.len and (bytes[k] < '@' or bytes[k] > '~')) k += 1;
                if (k >= bytes.len) break;
                self.disarmQuit();
                self.esc_armed = false;
                const params = bytes[i..k];
                const final = bytes[k];
                i = k + 1;
                // bracketed paste 起止标记
                if (final == '~' and std.mem.eql(u8, params, "200")) {
                    self.paste_mode = true;
                    continue;
                }
                if (final == '~' and std.mem.eql(u8, params, "201")) continue; // 狐尾止符
                if (applyMouseScroll(self, params, final, bytes, &i)) continue;
                switch (classifyCsi(params, final)) {
                    .up => arrowOrWheel(self, .up, bytes, &i, params, final),
                    .down => arrowOrWheel(self, .down, bytes, &i, params, final),
                    .page_up => self.scrollBy(@intCast(pageRows(self))),
                    .page_down => self.scrollBy(-@as(isize, @intCast(pageRows(self)))),
                    .ctrl_up => self.scrollBy(3),
                    .ctrl_down => self.scrollBy(-3),
                    .shift_up => {
                        self.cycleThink(true);
                        return .think;
                    },
                    .shift_down => {
                        self.cycleThink(false);
                        return .think;
                    },
                    .right => {
                        if (self.cursor < self.input.items.len) {
                            self.cursor += utf8LenAt(self.input.items, self.cursor);
                        }
                        self.dirty.store(true, .release);
                    },
                    .left => {
                        if (self.cursor > 0) self.cursor -= utf8PrevLen(self.input.items, self.cursor);
                        self.dirty.store(true, .release);
                    },
                    .home => {
                        self.cursor = 0;
                        self.dirty.store(true, .release);
                    },
                    .end => {
                        self.cursor = self.input.items.len;
                        self.dirty.store(true, .release);
                    },
                    .delete => {
                        deleteUtf8At(&self.input, self.cursor);
                        self.dirty.store(true, .release);
                    },
                    .other => {},
                }
                continue;
            }
            if (i + 1 < bytes.len and bytes[i + 1] == ',') {
                self.disarmQuit();
                self.esc_armed = false;
                self.cycleThink(false);
                return .think;
            }
            if (i + 1 < bytes.len and bytes[i + 1] == '.') {
                self.disarmQuit();
                self.esc_armed = false;
                self.cycleThink(true);
                return .think;
            }
            if (streaming) return .abort;
            if (self.input.items.len == 0) {
                if (self.esc_armed) {
                    self.esc_armed = false;
                    self.historyPrev();
                } else {
                    self.esc_armed = true;
                    self.dirty.store(true, .release);
                }
            }
            i += 1;
            continue;
        }

        if (b == 0x03) {
            if (self.input.items.len > 0) {
                self.input.clearRetainingCapacity();
                self.cursor = 0;
                self.disarmQuit();
                self.esc_armed = false;
                self.dirty.store(true, .release);
            } else {
                return armOrQuit(self, 0x03);
            }
            i += 1;
            continue;
        }
        if (b == 0x04) {
            if (self.input.items.len == 0) return armOrQuit(self, 0x04);
            i += 1;
            continue;
        }
        if (streaming and b == 0x02) return .detach;
        if (b == 0x14) {
            self.toggleThink();
            i += 1;
            continue;
        }
        if (b == 0x0f) {
            self.toggleTools();
            i += 1;
            continue;
        }
        if (b == 0x09) {
            if (streaming) {
                const act = try takeSubmit(self);
                if (act != .none) return act;
            } else if (fileOpen(self)) {
                try completeAtFile(self);
            } else if (slashOpen(self)) {
                try completeSlash(self);
            }
            i += 1;
            continue;
        }

        self.disarmQuit();
        self.esc_armed = false;
        if (b != '?') self.shortcuts_open = false;

        switch (b) {
            '\n', '\r' => {
                if (!streaming and fileOpen(self)) {
                    try completeAtFile(self);
                } else {
                    const act = try takeSubmit(self);
                    if (act != .none) return act;
                }
            },
            0x02 => {
                if (self.cursor > 0) self.cursor -= utf8PrevLen(self.input.items, self.cursor);
                self.dirty.store(true, .release);
            },
            0x06 => {
                if (self.cursor < self.input.items.len) {
                    self.cursor += utf8LenAt(self.input.items, self.cursor);
                }
                self.dirty.store(true, .release);
            },
            0x10 => if (fileOpen(self)) moveFile(self, -1) else if (slashOpen(self)) moveSlash(self, -1) else self.historyPrev(),
            0x0e => if (fileOpen(self)) moveFile(self, 1) else if (slashOpen(self)) moveSlash(self, 1) else self.historyNext(),
            0x08, 0x7f => {
                deleteUtf8Before(&self.input, &self.cursor);
                self.dirty.store(true, .release);
            },
            0x01 => {
                self.cursor = 0;
                self.dirty.store(true, .release);
            },
            0x05 => {
                self.cursor = self.input.items.len;
                self.dirty.store(true, .release);
            },
            0x0b => {
                self.input.shrinkRetainingCapacity(self.cursor);
                self.dirty.store(true, .release);
            },
            0x15 => {
                self.input.clearRetainingCapacity();
                self.cursor = 0;
                self.dirty.store(true, .release);
            },
            0x17 => {
                while (self.cursor > 0 and self.input.items[self.cursor - 1] == ' ') {
                    deleteUtf8Before(&self.input, &self.cursor);
                }
                while (self.cursor > 0 and self.input.items[self.cursor - 1] != ' ') {
                    deleteUtf8Before(&self.input, &self.cursor);
                }
                self.dirty.store(true, .release);
            },
            0x16 => {
                pasteClipboard(self);
            },
            0x0c => {
                self.clearScroll();
            },
            'n' => {
                if (self.input.items.len == 0 and self.search_q.len > 0 and !streaming) {
                    _ = self.findNext(self.search_q, false) catch false;
                } else {
                    try insertByte(self, 'n');
                }
            },
            'N' => {
                if (self.input.items.len == 0 and self.search_q.len > 0 and !streaming) {
                    _ = self.findNext(self.search_q, true) catch false;
                } else {
                    try insertByte(self, 'N');
                }
            },
            'g', 'G' => {
                if (self.input.items.len == 0 and !streaming) {
                    return .diff;
                } else {
                    try insertByte(self, b);
                }
            },
            'l', 'L' => {
                if (self.input.items.len == 0 and !streaming) {
                    return .log;
                } else {
                    try insertByte(self, b);
                }
            },
            'd', 'D' => {
                if (self.input.items.len == 0 and !streaming) {
                    return .doctor;
                } else {
                    try insertByte(self, b);
                }
            },
            'r', 'R' => {
                if (self.input.items.len == 0 and !streaming) {
                    return .redo;
                } else {
                    try insertByte(self, b);
                }
            },
            'u', 'U' => {
                if (self.input.items.len == 0 and !streaming) {
                    return .usage;
                } else {
                    try insertByte(self, b);
                }
            },
            'j', 'J' => {
                if (self.input.items.len == 0 and !streaming) {
                    return .jobs;
                } else {
                    try insertByte(self, b);
                }
            },
            's', 'S' => {
                if (self.input.items.len == 0 and !streaming) {
                    return .sandbox;
                } else {
                    try insertByte(self, b);
                }
            },
            'c', 'C' => {
                if (self.input.items.len == 0 and !streaming) {
                    return .copy;
                } else {
                    try insertByte(self, b);
                }
            },
            '?' => {
                if (self.input.items.len == 0 and !streaming) {
                    self.shortcuts_open = !self.shortcuts_open;
                    self.dirty.store(true, .release);
                } else {
                    try insertByte(self, '?');
                    self.shortcuts_open = false;
                }
            },
            else => {
                if (b >= 0x20) {
                    const word = std.unicode.utf8ByteSequenceLength(b) catch 1;
                    const avail = @min(word, bytes.len - i);
                    if (self.cursor >= self.input.items.len) {
                        try self.input.appendSlice(bytes[i .. i + avail]);
                    } else {
                        var j: usize = 0;
                        while (j < avail) : (j += 1) {
                            try self.input.insert(self.cursor + j, bytes[i + j]);
                        }
                    }
                    self.cursor += avail;
                    i += avail;
                    self.dirty.store(true, .release);
                    continue;
                }
            },
        }
        i += 1;
    }
    return .none;
}

pub fn handlePickerInput(self: *Tui, bytes: []const u8) !Action {
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b == 0x1b) {
            if (i + 1 < bytes.len and bytes[i + 1] == '[') {
                i += 2;
                var k = i;
                while (k < bytes.len and (bytes[k] < '@' or bytes[k] > '~')) k += 1;
                if (k >= bytes.len) break;
                const params = bytes[i..k];
                const final = bytes[k];
                i = k + 1;
                if (applyMouseScroll(self, params, final, bytes, &i)) {
                    self.dirty.store(true, .release);
                    continue;
                }
                if (self.picker) |*p| {
                    switch (classifyCsi(params, final)) {
                        .up => {
                            const extra = consumeSameCsi(bytes, &i, params, final);
                            if (extra > 0) {
                                self.scrollBy(3 * @as(isize, @intCast(1 + extra)));
                            } else p.move(-1);
                        },
                        .down => {
                            const extra = consumeSameCsi(bytes, &i, params, final);
                            if (extra > 0) {
                                self.scrollBy(-3 * @as(isize, @intCast(1 + extra)));
                            } else p.move(1);
                        },
                        .page_up => self.scrollBy(@intCast(pageRows(self))),
                        .page_down => self.scrollBy(-@as(isize, @intCast(pageRows(self)))),
                        .ctrl_up => self.scrollBy(3),
                        .ctrl_down => self.scrollBy(-3),
                        else => {},
                    }
                }
                self.dirty.store(true, .release);
                continue;
            }
            self.closePicker();
            return .none;
        }
        if (b == 0x03 or b == 0x04) {
            self.closePicker();
            return .none;
        }
        switch (b) {
            '\n', '\r' => return try confirmPicker(self),
            'k', 'K', 0x10 => if (self.picker) |*p| p.move(-1),
            'j', 'J', 0x0e => if (self.picker) |*p| p.move(1),
            '1'...'9' => {
                const n: usize = b - '1';
                if (self.picker) |*p| {
                    if (n < p.items.len) p.sel = n;
                }
            },
            else => {},
        }
        self.dirty.store(true, .release);
        i += 1;
    }
    return .none;
}

pub fn confirmPicker(self: *Tui) !Action {
    const line = if (self.picker) |*p|
        try p.confirmLine(self.alloc)
    else
        return .none;
    self.closePicker();
    return .{ .submit = line };
}

pub fn pageRows(self: *const Tui) usize {
    return @max(1, self.height / 2);
}

/// 1007 alternate-scroll turns the wheel into CSI arrows. A burst in one
/// read is a wheel; a single arrow is input history (or picker move).
pub fn arrowOrWheel(self: *Tui, dir: WheelDir, bytes: []const u8, i: *usize, params: []const u8, final: u8) void {
    const extra = consumeSameCsi(bytes, i, params, final);
    if (extra > 0) {
        const n: isize = @intCast(1 + extra);
        self.scrollBy(if (dir == .up) 3 * n else -3 * n);
        return;
    }
    if (fileOpen(self)) {
        moveFile(self, if (dir == .up) -1 else 1);
        return;
    }
    if (slashOpen(self)) {
        moveSlash(self, if (dir == .up) -1 else 1);
        return;
    }
    // 多行草稿:先在同列行间移动,顶/底行再落历史。
    const inner = tui.composerInnerWidth(self.width >= 8, self.width);
    const rows = wrapRowCount(self.input.items, inner);
    if (rows > 1) {
        const cur = wrapCursor(self.input.items, self.cursor, inner);
        if (dir == .up and cur.row > 0) {
            self.cursor = wrapMoveVertical(self.input.items, self.cursor, inner, -1);
            self.dirty.store(true, .release);
            return;
        }
        if (dir == .down and cur.row + 1 < rows) {
            self.cursor = wrapMoveVertical(self.input.items, self.cursor, inner, 1);
            self.dirty.store(true, .release);
            return;
        }
    }
    if (dir == .up) self.historyPrev() else self.historyNext();
}

pub fn applyMouseScroll(self: *Tui, params: []const u8, final: u8, bytes: []const u8, i: *usize) bool {
    if (sgrWheel(params)) |dir| {
        self.scrollBy(if (dir == .up) 3 else -3);
        return true;
    }
    if (params.len == 0 and final == 'M' and i.* + 3 <= bytes.len) {
        const btn: u16 = bytes[i.*];
        i.* += 3;
        const base = (btn -% 32) & ~@as(u16, 0x1C);
        if (base == 64) self.scrollBy(3);
        if (base == 65) self.scrollBy(-3);
        return true;
    }
    return false;
}
