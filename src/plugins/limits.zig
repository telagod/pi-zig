// 委托深度与并行上限。task / agents 共用,勿回引 plugins.zig。
const agentmod = @import("../agent.zig");
const activity = @import("../activity.zig");

/// 顶层并行委托上限。改此值须同步 activity.MAX_SLOTS。
pub const MAX_PARALLEL_TASKS = 32;
pub const MAX_PARALLEL_TASKS_NESTED = 4;
pub const TASK_OUTPUT_LIMIT = 32 * 1024;
pub const TASK_TIMEOUT_MS = 600_000;
pub const MAX_TASK_DEPTH = 2;
pub const DEPTH_ENV = "PIZ_TASK_DEPTH";
pub const SPAWN_ENV = "PIZ_TASK_SPAWN";

pub fn parallelLimitAt(depth: usize) usize {
    return if (depth == 0) MAX_PARALLEL_TASKS else MAX_PARALLEL_TASKS_NESTED;
}

comptime {
    if (activity.MAX_SLOTS < MAX_PARALLEL_TASKS + agentmod.MAX_PARALLEL_TOOLS) {
        @compileError("activity.MAX_SLOTS 必须 >= MAX_PARALLEL_TASKS + MAX_PARALLEL_TOOLS,否则并发活动在界面上不可见");
    }
}
