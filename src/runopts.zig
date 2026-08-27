// runopts.zig — CLI 运行选项(交互/print 共用,避免循环 import)。
pub const OutputFormat = enum { text, json, jsonl };

pub const RunOptions = struct {
    provider_name: ?[]const u8 = null,
    model_name: ?[]const u8 = null,
    read_only: bool = false,
    /// -x:全权(默认已是 yolo,显式再写一次)
    execute: bool = false,
    /// --ask:危险工具先问
    ask: bool = false,
    /// --sandbox off|workspace|strict。null = 用 settings.json。
    sandbox: ?[]const u8 = null,
    /// -c/--continue:续载最近会话。默认false —— 每次启动都是新会话。
    continue_session: bool = false,
    title: ?[]const u8 = null,
    output_format: OutputFormat = .text,
    /// -s:恢复指定会话(id 为文件名去 .jsonl,或 sessions 清单 1-based 序号)
    session_id: ?[]const u8 = null,
    /// -a:异步后台运行(仅 print 模式)
    async_run: bool = false,
    /// --system:自定义系统提示
    system_override: ?[]const u8 = null,
};
