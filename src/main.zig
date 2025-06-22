const std = @import("std");
const config = @import("zig_ini_reader_lib"); // Imports src/root.zig

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var cfg = try config.Config.loadFromFile(".env", allocator);
    defer cfg.deinit();

    const keys = [_][]const u8{ "API_KEY", "DB_HOST", "PORT", "MISSING" };
    for (keys) |k| {
        if (cfg.get(k)) |v| {
            std.debug.print("{s} = {s}\n", .{ k, v });
        } else {
            std.debug.print("{s} not found\n", .{k});
        }
    }
}
