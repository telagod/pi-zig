// core.zig — piz 核心库聚合入口(对齐 pi 子包结构:core = 引擎 + 工具 + 会话 + 配置 + 包管理)。
pub const util = @import("util.zig");
pub const activity = @import("activity.zig");
pub const config = @import("config.zig");
pub const httpc = @import("httpc.zig");
pub const ai = @import("ai.zig");
pub const imgx = @import("imgx.zig");
pub const mcp = @import("mcp.zig");
pub const tools = @import("tools.zig");
pub const session = @import("session.zig");
pub const agent = @import("agent.zig");
pub const agents = @import("agents.zig");
pub const pkgs = @import("pkgs.zig");
pub const events = @import("events.zig");
pub const webplugins = @import("webplugins.zig");
pub const plugins = @import("plugins.zig");
pub const compress = @import("compress.zig");

comptime {
    // stb C 对象引用的 piz_* 导出:zig 惰性编译下 export fn 若不被 zig 侧
    // 引用就不生成符号(实测:单独 build-obj core.zig 里 piz_malloc 不存在),
    // 而 C 侧的外部引用编译器看不见 —— 链接时报 undefined symbol。
    // 取函数地址强制生成;core 容器被 root 引用时本块执行,不增运行时开销。
    _ = &imgx.piz_malloc;
    _ = &imgx.piz_realloc;
    _ = &imgx.piz_free;
    _ = &imgx.piz_memcpy;
    _ = &imgx.piz_memmove;
    _ = &imgx.piz_memset;
    _ = &imgx.piz_memcmp;
    _ = &imgx.piz_abs;
}

test {
    _ = @import("util.zig");
    _ = @import("activity.zig");
    _ = @import("config.zig");
    _ = @import("httpc.zig");
    _ = @import("ai.zig");
    _ = @import("imgx.zig");
    // 注意:mcp.zig 的测试**不**在此收集 —— 收集它会让 zig 0.16 的
    // sema 在全量 test 引用闭包下挂死(实测;独立编译无碍,故测试移居 e2e.zig)。
    _ = @import("tools.zig");
    _ = @import("session.zig");
    _ = @import("agent.zig");
    _ = @import("agents.zig");
    _ = @import("pkgs.zig");
    _ = @import("events.zig");
    _ = @import("webplugins.zig");
    _ = @import("plugins.zig");
    _ = @import("compress.zig");
}
