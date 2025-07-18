const std = @import("std");
const utils = @import("../utils.zig");

const Config = @import("../config.zig").Config;
const ConfigError = @import("../errors.zig").ConfigError;
const Value = @import("../value.zig").Value;
const Table = @import("../value.zig").Table;

const parseList = @import("shared.zig").parseList;
const parseString = @import("shared.zig").parseString;
const parseTable = @import("shared.zig").parseTable;
const resolveVariables = @import("shared.zig").resolveVariables;

/// Parses TOML configuration files into a flat key-value map.
///
/// Supported TOML features:
/// - Sections and sub-sections via `[section]`, `[section.sub]`
/// - Array-of-tables via `[[table]]` → flattened to `table.0.key`, `table.1.key`, etc.
/// - Inline tables `{ k = v }` and arrays `[1, 2, 3]`
/// - Strings: single-line, multi-line, literal, and escape sequences
/// - Variable substitution using `${VAR}` with fallback support
/// - Comments (`#`) are stripped
///
/// All values are stored in `Config.map` using flattened keys (`a.b.c = v`)
pub fn parseToml(text: []const u8, allocator: std.mem.Allocator) ConfigError!Config {
    var config: Config = Config.init(allocator);
    errdefer config.deinit();

    var current_prefix: []const u8 = "";
    var multiline_buf = std.ArrayList(u8).init(allocator);
    defer multiline_buf.deinit();

    var table_arrays = std.StringHashMap(usize).init(allocator);
    defer table_arrays.deinit();

    var lines = std.mem.splitSequence(u8, text, "\n");
    while (lines.next()) |line| {
        const trimmed: []const u8 = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        const comment_pos: ?usize = std.mem.indexOfScalar(u8, trimmed, '#');
        const line_clean = if (comment_pos) |i|
            std.mem.trim(u8, trimmed[0..i], " \t\r\n")
        else
            trimmed;
        if (line_clean.len == 0) continue;

        // Handle [[table]] array-of-tables
        // Each [[table]] appends a new Table to the corresponding array key
        if (std.mem.startsWith(u8, line_clean, "[[") and std.mem.endsWith(u8, line_clean, "]]")) {
            const array_key = std.mem.trim(u8, line_clean[2 .. line_clean.len - 2], " ");

            var list_val: Value = blk: {
                if (config.map.getEntry(array_key)) |entry_ptr| {
                    if (entry_ptr.value_ptr.* != .list) return ConfigError.ParseError;
                    const deep_clone = try utils.deepCloneValue(&entry_ptr.value_ptr.*, allocator);
                    break :blk deep_clone;
                } else {
                    const new_list = try allocator.alloc(Value, 0);
                    break :blk .{ .list = new_list };
                }
            };
            errdefer list_val.deinit(allocator);

            var copy_ptr: ?[]const u8 = null;

            if (config.map.getEntry(array_key)) |entry| {
                copy_ptr = entry.key_ptr.*;
                entry.value_ptr.*.deinit(allocator);
                _ = config.map.remove(array_key);
            }

            const new_table = try allocator.create(Table);
            new_table.* = Table.init(allocator);

            const old_list = list_val.list;
            const grown = try allocator.realloc(old_list, old_list.len + 1);
            grown[old_list.len] = .{ .table = new_table };
            list_val.list = grown;

            {
                const key_copy = try allocator.dupe(u8, array_key);
                errdefer allocator.free(key_copy);

                try config.map.put(key_copy, list_val);
            }

            if (copy_ptr) |owned_key| {
                allocator.free(owned_key);
            }

            if (current_prefix.len > 0) allocator.free(current_prefix);
            current_prefix = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ array_key, list_val.list.len - 1 });

            continue;
        } else if (line_clean[0] == '[' and line_clean[line_clean.len - 1] == ']') {
            // Handle [section] headers (update current prefix)
            if (current_prefix.len > 0) allocator.free(current_prefix);
            current_prefix = try allocator.dupe(u8, std.mem.trim(u8, line_clean[1 .. line_clean.len - 1], " "));
            errdefer allocator.free(current_prefix);
            continue;
        }

        // Parse key-value line (split on `=` and process value by type)
        const eq_idx: usize = std.mem.indexOfScalar(u8, line_clean, '=') orelse continue;
        const raw_key: []const u8 = std.mem.trim(u8, line_clean[0..eq_idx], " \t\r\n");
        const raw_val: []const u8 = std.mem.trim(u8, line_clean[eq_idx + 1 ..], " \t\r\n");

        const full_key: []u8 = if (current_prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ current_prefix, raw_key })
        else
            try allocator.dupe(u8, raw_key);
        defer allocator.free(full_key);

        // Handle quoted strings (including multiline and substitutions)
        if (raw_val.len >= 1 and (raw_val[0] == '"' or raw_val[0] == '\'' or
            std.mem.startsWith(u8, raw_val, "\"\"\"") or std.mem.startsWith(u8, raw_val, "'''")))
        {
            const parsed: []const u8 = try parseString(raw_val, &lines, &multiline_buf, allocator);
            defer allocator.free(parsed);

            const needs_resolve: bool = std.mem.indexOfScalar(u8, parsed, '$') != null;

            const resolved: []const u8 = if (needs_resolve)
                try resolveVariables(parsed, &config, allocator, null, full_key, null)
            else
                try allocator.dupe(u8, parsed);
            errdefer allocator.free(resolved);

            if (config.map.getEntry(full_key)) |entry_ptr| {
                entry_ptr.value_ptr.*.deinit(allocator);
                _ = config.map.remove(full_key);
            }

            const key_copy = try allocator.dupe(u8, full_key);
            errdefer allocator.free(key_copy);

            try config.map.put(key_copy, .{ .string = resolved });
            continue;
        }

        // Handle booleans (`true`, `false`)
        if (utils.getBool(raw_val)) |bool_val| {
            const key_copy = try allocator.dupe(u8, full_key);
            errdefer allocator.free(key_copy);
            try config.map.put(key_copy, .{ .bool = bool_val });
            continue;
        }

        // Handle integer values
        if (std.fmt.parseInt(i64, raw_val, 10) catch null) |parsed_int| {
            const key_copy = try allocator.dupe(u8, full_key);
            errdefer allocator.free(key_copy);
            try config.map.put(key_copy, .{ .int = parsed_int });
            continue;
        }

        // Handle float values
        if (std.fmt.parseFloat(f64, raw_val) catch null) |parsed_float| {
            const key_copy = try allocator.dupe(u8, full_key);
            errdefer allocator.free(key_copy);
            try config.map.put(key_copy, .{ .float = parsed_float });
            continue;
        }

        // Handle arrays (single or multiline)
        if (raw_val[0] == '[') {
            const parsed_list = try parseList(raw_val, &lines, &multiline_buf, allocator);
            const key_copy = try allocator.dupe(u8, full_key);
            errdefer allocator.free(key_copy);
            try config.map.put(key_copy, .{ .list = parsed_list });
            continue;
        }

        // Handle inline tables
        if (raw_val[0] == '{') {
            const parsed_table = try parseTable(raw_val, &lines, &multiline_buf, allocator);
            const boxed = try allocator.create(Table);
            boxed.* = parsed_table;

            const key_copy = try allocator.dupe(u8, full_key);
            errdefer allocator.free(key_copy);
            try config.map.put(key_copy, .{ .table = boxed });
            continue;
        }

        // Fallback: try parsing as unquoted string (resolve if needed)
        const parsed = try parseString(raw_val, &lines, &multiline_buf, allocator);
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

    if (current_prefix.len > 0) allocator.free(current_prefix);
    return config;
}
