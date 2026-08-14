// runopts.zig — CLI 运行选项(交互/print 共用,避免循环 import)。
pub const OutputFormat = enum { text, json, jsonl };

pub const RunOptions = struct {
    provider_name: ?[]const u8 = null,
    model_name: ?[]const u8 = null,
    read_only: bool = false,
    /// -x:工具自动执行,不询问
    execute: bool = false,
    new_session: bool = false,
    title: ?[]const u8 = null,
    output_format: OutputFormat = .text,
    /// -s:恢复指定会话(id 为文件名去 .jsonl)
    session_id: ?[]const u8 = null,
    /// -a:异步后台运行(仅 print 模式)
    async_run: bool = false,
    /// --system:自定义系统提示
    system_override: ?[]const u8 = null,
};
