// core.zig — piz 核心库聚合入口(对齐 pi 子包结构:core = 引擎 + 工具 + 会话 + 配置 + 包管理)。
pub const util = @import("util.zig");
pub const activity = @import("activity.zig");
pub const config = @import("config.zig");
pub const httpc = @import("httpc.zig");
pub const ai = @import("ai.zig");
pub const tools = @import("tools.zig");
pub const session = @import("session.zig");
pub const agent = @import("agent.zig");
pub const pkgs = @import("pkgs.zig");
pub const events = @import("events.zig");
pub const webplugins = @import("webplugins.zig");
pub const plugins = @import("plugins.zig");

test {
    _ = @import("util.zig");
    _ = @import("activity.zig");
    _ = @import("config.zig");
    _ = @import("httpc.zig");
    _ = @import("ai.zig");
    _ = @import("tools.zig");
    _ = @import("session.zig");
    _ = @import("agent.zig");
    _ = @import("pkgs.zig");
    _ = @import("events.zig");
    _ = @import("webplugins.zig");
    _ = @import("plugins.zig");
}
