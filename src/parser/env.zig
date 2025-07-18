const std = @import("std");
const utils = @import("../utils.zig");

const parseLine = @import("shared.zig").parseLine;
const parseString = @import("shared.zig").parseString;
const resolveVariables = @import("shared.zig").resolveVariables;

const Config = @import("../config.zig").Config;
const ConfigError = @import("../errors.zig").ConfigError;
const Value = @import("../value.zig").Value;

/// Parses raw `.env` text into a `Config`, supporting variable substitution and comments.
///
/// Supports:
/// - Lines in `KEY=VALUE` format
/// - Quoted values: `"abc"` or `'abc'`
/// - Comments: lines starting with `#` or `;` are ignored
/// - Variable substitution:
///     - `${VAR}` → replaced with VAR
///     - `${VAR:-fallback}` → use fallback if VAR is missing/empty
///     - `${VAR:+alt}` → use alt if VAR is set
/// - Circular reference detection
///
/// Returns:
/// - `Config` with all keys and resolved values (caller must call `deinit`)
/// - Fails with `ConfigError` on invalid lines or unresolved references
pub fn parseEnv(text: []const u8, allocator: std.mem.Allocator) !Config {
    var config: Config = Config.init(allocator);
    errdefer config.deinit();

    var raw_values = std.StringHashMap(Value).init(allocator);
    defer {
        var it = raw_values.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*); // Free the duplicated key
            entry.value_ptr.*.deinit(allocator); // Free nested content in Value
        }
        raw_values.deinit();
    }

    var dummy_buf = std.ArrayList(u8).init(allocator);
    defer dummy_buf.deinit();

    var lines = std.mem.splitSequence(u8, text, "\n");
    while (lines.next()) |line| {
        const trimmed: []const u8 = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') continue;

        const kv = try parseLine(trimmed);

        // Parse strings
        var single_line_iter = std.mem.splitSequence(u8, "", "\n");

        const parsed: []const u8 = try parseString(kv.value, &single_line_iter, &dummy_buf, allocator);
        defer allocator.free(parsed);

        const val_copy = try allocator.dupe(u8, parsed);

        const key_copy: []u8 = try allocator.dupe(u8, kv.key);
        errdefer allocator.free(key_copy);

        try raw_values.put(key_copy, .{ .string = val_copy });
    }

    // Resolve substitutions like ${VAR}, using env fallback
    var it = raw_values.iterator();
    while (it.next()) |entry| {
        const resolved: []const u8 = try resolveVariables(
            entry.value_ptr.string,
            &config,
            allocator,
            null,
            entry.key_ptr.*,
            &raw_values,
        );
        errdefer allocator.free(resolved);

        const key_copy: []u8 = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key_copy);

        if (config.map.getEntry(key_copy)) |entry2| {
            defer allocator.free(key_copy);
            entry2.value_ptr.deinit(allocator);
            try config.map.put(entry2.key_ptr.*, .{ .string = resolved });
        } else {
            try config.map.put(key_copy, .{ .string = resolved });
        }
    }

    return config;
}
