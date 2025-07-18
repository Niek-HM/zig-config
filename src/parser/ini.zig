const std = @import("std");
const utils = @import("../utils.zig");

const parseLine = @import("shared.zig").parseLine;
const parseString = @import("shared.zig").parseString;
const resolveVariables = @import("shared.zig").resolveVariables;

const Config = @import("../config.zig").Config;
const ConfigError = @import("../errors.zig").ConfigError;
const Value = @import("../value.zig").Value;

/// Parses raw `.ini`-style text content into a `Config` structure.
///
/// Supports:
/// - `[section]` headers: keys inside are namespaced as `section.key`
/// - `key=value` lines (standard INI format)
/// - Quoted values: `"abc"` or `'abc'`
/// - Variable substitution via `${VAR}` if present
/// - Comments: lines starting with `#` or `;` are ignored
///
/// Rules:
/// - Keys outside of any section are stored as-is
/// - Duplicated keys overwrite earlier ones
/// - Values are resolved using the config being built
///
/// Errors:
/// - `ParseUnterminatedSection` if a section header is malformed
/// - `ParseInvalidLine` or `InvalidKey` if the line is invalid
/// - `InvalidPlaceholder` or `CircularReference` from substitutions
///
/// Returns:
/// - `Config` with fully parsed key-value pairs (caller owns and must call `deinit`)
pub fn parseIni(text: []const u8, allocator: std.mem.Allocator) !Config {
    var config: Config = Config.init(allocator);
    errdefer config.deinit();

    var current_section: ?[]const u8 = null; // active section (e.g. "db")
    var lines = std.mem.splitSequence(u8, text, "\n");

    while (lines.next()) |line| {
        const trimmed: []const u8 = std.mem.trim(u8, line, "\t\r\n");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') continue;

        if (trimmed.len < 3 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']')
            return ConfigError.ParseUnterminatedSection;

        // Handle section headers
        if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            const name: []const u8 = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
            if (name.len == 0) return ConfigError.ParseUnterminatedSection;
            current_section = name;
            continue;
        }

        // Parse key=value from the line
        const kv = try parseLine(trimmed);

        // Create full key as "section.key" or just "key"
        const full_key: []u8 = blk: {
            if (current_section) |sec| {
                break :blk try std.fmt.allocPrint(allocator, "{s}.{s}", .{ sec, kv.key });
            } else {
                break :blk try allocator.dupe(u8, kv.key);
            }
        };
        defer allocator.free(full_key);

        var dummy_lines = std.mem.splitSequence(u8, "", "\n");
        var dummy_buf = std.ArrayList(u8).init(allocator);
        defer dummy_buf.deinit();

        // Parse strings
        const parsed = try parseString(kv.value, &dummy_lines, &dummy_buf, allocator);
        defer allocator.free(parsed);

        const needs_resolve = std.mem.indexOfScalar(u8, parsed, '$') != null;

        const resolved = if (needs_resolve)
            try resolveVariables(parsed, &config, allocator, null, full_key, null)
        else
            try allocator.dupe(u8, parsed);
        errdefer allocator.free(resolved);

        const key_copy = try allocator.dupe(u8, full_key);
        errdefer allocator.free(key_copy);

        if (config.map.getEntry(key_copy)) |entry| {
            defer allocator.free(key_copy);
            entry.value_ptr.deinit(allocator);
            try config.map.put(entry.key_ptr.*, .{ .string = resolved });
        } else {
            try config.map.put(key_copy, .{ .string = resolved });
        }
    }

    return config;
}
