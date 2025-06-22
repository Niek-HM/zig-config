const std = @import("std");
const config = @import("zig_ini_reader_lib"); // Imports src/root.zig

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var cfg = try config.Config.loadEnvFile(".env", allocator);
    defer cfg.deinit();

    const keys = [_][]const u8{ "API_KEY", "DB_HOST", "PORT", "MISSING" };
    for (keys) |k| {
        if (cfg.get(k)) |v| {
            std.debug.print("{s} = {s}\n", .{ k, v });
        } else {
            std.debug.print("{s} not found\n", .{k});
        }
    }

    if (cfg.getInt("PORT")) |port| {
        std.debug.print("PORT as int: {}\n", .{port});
    }

    if (cfg.getBool("DEBUG")) |debug_mode| {
        std.debug.print("Debug mode: {}\n", .{debug_mode});
    }

    if (cfg.getFloat("THRESHOLD")) |th| {
        std.debug.print("Threshold: {}\n", .{th});
    }

    cfg.debugPrint();

    try cfg.writeEnvFile("output.env");

    const all_keys = try cfg.keys(allocator);
    defer allocator.free(all_keys);

    for (all_keys) |k| {
        std.debug.print("Found key: {s}\n", .{k});
    }

    var cfg2 = try config.Config.loadIniFile("config.ini", allocator);
    defer cfg2.deinit();

    // Print all keys
    cfg2.debugPrint();

    // Extract 'database' section
    var db_section = try cfg2.getSection("database", allocator);
    defer db_section.deinit();

    if (db_section.get("host")) |host| {
        std.debug.print("DB Host: {s}\n", .{host});
    }

    if (db_section.getInt("port")) |port| {
        std.debug.print("DB Port: {d}\n", .{port});
    }

    if (db_section.get("user")) |user| {
        std.debug.print("DB User: {s}\n", .{user});
    }
}
