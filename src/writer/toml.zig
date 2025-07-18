const std = @import("std");
const utils = @import("../utils.zig");

const Config = @import("../config.zig").Config;
const ConfigError = @import("../errors.zig").ConfigError;
const Value = @import("../value.zig").Value;

/// Writes all config entries to a `.toml`-style file.
///
/// - Keys without a section (no dot `.` in the name) are written first.
/// - Keys in `section.key` format are grouped under `[section]` headers.
/// - All values must be of type `.string`. Other types return `InvalidType`.
///
/// Values are emitted as double-quoted TOML strings, with escaping for:
/// - `"` → `\"`
/// - `\` → `\\`
/// - Control characters (e.g., newline, tab, Unicode) using `\uXXXX`
///
/// Example output:
/// ```toml
/// host = "localhost"
/// port = "8080"
///
/// [db]
/// user = "admin"
/// pass = "p@ss\"w\\rd"
/// ```
///
/// Notes:
/// - The file at `path` is overwritten.
/// - Values are always written as strings, regardless of original type.
/// - Section order is determined by key order; keys are not fully alphabetically sorted.
pub fn writeTomlFile(cfg: *Config, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    const writer = file.writer();

    var sorted_keys = std.ArrayList([]const u8).init(cfg.map.allocator);
    defer sorted_keys.deinit();

    var it = cfg.map.iterator();
    while (it.next()) |entry| {
        try sorted_keys.append(entry.key_ptr.*);
    }

    // * 1. First write all top-level keys (no section)
    for (sorted_keys.items) |key| {
        const sep_index: ?usize = std.mem.lastIndexOfScalar(u8, key, '.');
        if (sep_index != null) continue;

        const entry = cfg.map.get(key) orelse return ConfigError.Missing;
        if (entry != .string)
            return ConfigError.InvalidType;

        const val: []const u8 = entry.string;

        try writer.print("{s} = ", .{key});
        try writeTomlValue(.{ .string = val }, writer, cfg.map.allocator);
        try writer.writeAll("\n");
    }

    // * 2. Then write sectioned keys grouped under [section]
    var current_section: ?[]const u8 = null;
    for (sorted_keys.items) |key| {
        const sep_index = std.mem.lastIndexOfScalar(u8, key, '.');
        if (sep_index == null) continue;

        const section = key[0..sep_index.?];
        const subkey = key[sep_index.? + 1 ..];

        // Print section header if we’ve entered a new section
        if (!std.mem.eql(u8, current_section orelse "", section)) {
            current_section = section;
            try writer.print("\n[{s}]\n", .{section});
        }

        const entry = cfg.map.get(key) orelse return ConfigError.Missing;
        if (entry != .string)
            return ConfigError.InvalidType;

        const val: []const u8 = entry.string;
        try writer.print("{s} = ", .{subkey});
        try writeTomlValue(.{ .string = val }, writer, cfg.map.allocator);
        try writer.writeAll("\n");
    }
}

fn writeTomlValue(
    value: Value,
    writer: anytype,
    allocator: std.mem.Allocator,
) !void {
    switch (value) {
        .string => |s| {
            const escaped = try utils.escapeString(s, allocator);
            try writer.print("\"{s}\"", .{escaped});
            allocator.free(escaped);
        },
        .int => |i| try writer.print("{d}", .{i}),
        .float => |f| try writer.print("{e}", .{f}),
        .bool => |b| try writer.print("{any}", .{b}), // TODO: How to print a bool?
        .list => |items| {
            try writer.writeAll("[");
            for (items, 0..) |item, i| {
                if (i != 0) try writer.writeAll(", ");
                try writeTomlValue(item, writer, allocator);
            }
            try writer.writeAll("]");
        },
        .table => |table| {
            try writer.writeAll("{ ");
            var i: usize = 0;
            var it = table.iterator();
            while (it.next()) |entry| {
                if (i != 0) try writer.writeAll(", ");
                try writer.print("{s} = ", .{entry.key_ptr.*});
                try writeTomlValue(entry.value_ptr.*, writer, allocator);
                i += 1;
            }
            try writer.writeAll(" }");
        },
    }
}
