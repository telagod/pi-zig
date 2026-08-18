// tools_skill.zig — skill tool. Search order must match util.loadSkillsIndex.
const std = @import("std");
const util = @import("util.zig");
const tjson = @import("tools_json.zig");
const tpath = @import("tools_path.zig");

const parseArgs = tjson.parseArgs;
const jstr = tjson.jstr;
const diskRead = tpath.diskRead;

pub const Result = struct {
    content: []const u8,
    is_error: bool = false,
};

/// skill: {name} → 读 SKILL.md。搜索顺序与 `util.loadSkillsIndex` 必须一致:
/// <configDir>/skills/,然后各资源包的 skills/。
pub fn toolSkill(arena: std.mem.Allocator, args: []const u8) !Result {
    const v = try parseArgs(arena, args);
    const name = jstr(v, "name") orelse return .{ .content = "error: missing 'name' argument", .is_error = true };
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) {
            return .{ .content = "error: invalid skill name", .is_error = true };
        }
    }
    const cfg_dir = util.configDir(arena) catch return .{ .content = "error: no config dir", .is_error = true };
    const first = try std.fmt.allocPrint(arena, "{s}/skills/{s}/SKILL.md", .{ cfg_dir, name });
    if (diskRead(arena, first, 256 * 1024)) |content| {
        return .{ .content = try std.fmt.allocPrint(arena, "# Skill {s}\n\n{s}", .{ name, content }) };
    } else |_| {}
    if (util.pkgDirsForRuntime(arena)) |pkgs| {
        for (pkgs) |pkg| {
            const p = try std.fmt.allocPrint(arena, "{s}/skills/{s}/SKILL.md", .{ pkg, name });
            if (diskRead(arena, p, 256 * 1024)) |content| {
                return .{ .content = try std.fmt.allocPrint(arena, "# Skill {s}\n\n{s}", .{ name, content }) };
            } else |_| {}
        }
    } else |_| {}
    return .{
        .content = try std.fmt.allocPrint(arena, "error: skill '{s}' not found in {s}/skills/ or any installed package", .{ name, cfg_dir }),
        .is_error = true,
    };
}
