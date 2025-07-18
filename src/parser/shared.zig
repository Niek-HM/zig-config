const std = @import("std");
const utils = @import("../utils.zig");

const Config = @import("../config.zig").Config;
const ConfigError = @import("../errors.zig").ConfigError;
const Value = @import("../value.zig").Value;
const ResolvedValue = @import("../value.zig").ResolvedValue;

/// Parses a TOML or INI-style string value, including support for:
/// - Basic strings: `"escaped"`
/// - Literal strings: `'raw'`
/// - Multiline strings: `'''...'''` or `"""..."""`
///
/// Automatically handles unescaping for basic strings (`\n`, `\"`, etc),
/// and preserves literal/multiline content as-is unless escaping is required.
///
/// Params:
/// - `raw_val`: the raw string value as it appears in the file
/// - `lines`: the remaining lines of the file, for multiline parsing
/// - `multiline_buf`: reusable buffer to collect multiline content
/// - `allocator`: for duplicating or unescaping content
///
/// Returns:
/// - Parsed string slice (owned, heap-allocated)
pub fn parseString(
    raw_val: []const u8,
    lines: *std.mem.SplitIterator(u8, .sequence),
    multiline_buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) ![]const u8 {
    if (raw_val.len == 0) return "";

    const is_basic: bool = raw_val[0] == '"';
    const is_literal: bool = raw_val[0] == '\'';
    const is_multiline: bool = raw_val.len >= 3 and
        (std.mem.startsWith(u8, raw_val, "\"\"\"") or
            std.mem.startsWith(u8, raw_val, "'''"));

    // Handle multiline case
    if (is_multiline) {
        const quote_type: *const [3:0]u8 = if (is_basic) "\"\"\"" else "'''";
        multiline_buf.clearRetainingCapacity();

        // Same-line triple quoted value
        if (std.mem.endsWith(u8, raw_val, quote_type)) {
            const inner: []const u8 = raw_val[3 .. raw_val.len - 3];
            return if (is_basic)
                try utils.unescapeString(inner, allocator)
            else
                try allocator.dupe(u8, inner);
        }

        // Start collecting multiline content
        if (raw_val.len > 3) {
            try multiline_buf.appendSlice(raw_val[3..]);
            try multiline_buf.append('\n');
        }

        while (lines.next()) |line| {
            const trimmed: []const u8 = std.mem.trim(u8, line, " \t\r\n");
            if (utils.findUnescaped(trimmed, quote_type)) |end_pos| {
                try multiline_buf.appendSlice(trimmed[0..end_pos]);
                break;
            } else {
                try multiline_buf.appendSlice(trimmed);
                try multiline_buf.append('\n');
            }
        }

        const joined = try multiline_buf.toOwnedSlice();

        if (is_basic) {
            const result: []const u8 = try utils.unescapeString(joined, allocator);
            allocator.free(joined);
            return result;
        } else {
            return joined;
        }
    }

    // Handle single-line quoted strings
    if (raw_val.len >= 2 and
        ((is_basic and raw_val[raw_val.len - 1] == '"') or
            (is_literal and raw_val[raw_val.len - 1] == '\'')))
    {
        const inner: []const u8 = raw_val[1 .. raw_val.len - 1];
        return if (is_basic)
            try utils.unescapeString(inner, allocator)
        else
            try allocator.dupe(u8, inner);
    }

    // Fallback for unquoted values
    const dupe_raw = try allocator.dupe(u8, raw_val);
    errdefer allocator.free(dupe_raw);
    return dupe_raw;
}

/// Parses a TOML list/array value from a string, including multiline support.
///
/// Supports:
/// - Nested arrays and tables (`[1, 2, [3, 4]]`, `[{x=1}, {x=2}]`)
/// - Quoted string values inside arrays
/// - Multiline array formatting using line continuation
///
/// Params:
/// - `raw`: full `[ ... ]` array slice
/// - `lines`: remaining lines (used for multiline continuation)
/// - `multiline_buf`: scratch buffer for joined values
/// - `allocator`: for allocating parsed Value elements
///
/// Returns:
/// - Slice of `Value` (owned by caller)
/// - Errors on malformed nesting or element parse failure
pub fn parseList(
    raw: []const u8,
    lines: *std.mem.SplitIterator(u8, .sequence),
    multiline_buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) ![]Value {
    const list_inner = std.mem.trim(u8, raw[1 .. raw.len - 1], " \t\r\n");

    var items = std.ArrayList(Value).init(allocator);
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit();
    }

    var start: usize = 0;
    var depth: usize = 0;
    var in_quote: ?u8 = null;
    var i: usize = 0;

    while (i < list_inner.len) {
        const c = list_inner[i];
        if (in_quote) |q| {
            if (c == q) in_quote = null else if (c == '\\' and i + 1 < list_inner.len) i += 1;
        } else switch (c) {
            '"', '\'' => in_quote = c,
            '[' => depth += 1,
            ']' => if (depth > 0) {
                depth -= 1;
            },
            ',' => if (depth == 0) {
                const slice = std.mem.trim(u8, list_inner[start..i], " \t\r\n");
                if (slice.len > 0) try items.append(try parseValue(slice, lines, multiline_buf, allocator));
                start = i + 1;
            },
            else => {},
        }
        i += 1;
    }

    if (start < list_inner.len) {
        const slice = std.mem.trim(u8, list_inner[start..], " \t\r\n");
        if (slice.len > 0) try items.append(try parseValue(slice, lines, multiline_buf, allocator));
    }

    return try items.toOwnedSlice();
}

/// Parses any single TOML value (string, int, float, bool, list, or table).
///
/// Automatically detects the type based on syntax:
/// - `{}` → inline table
/// - `[]` → array
/// - quoted → string
/// - number → int/float
/// - `true`/`false` → bool
///
/// Fallback behavior:
/// - If unquoted, assumed to be a string (quotes stripped)
///
/// Returns:
/// - A fully parsed `Value` with owned memory
pub fn parseValue(
    val: []const u8,
    lines: *std.mem.SplitIterator(u8, .sequence),
    multiline_buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) ConfigError!Value {
    if (val.len >= 2 and val[0] == '{' and val[val.len - 1] == '}') {
        const table = try parseTable(val, lines, multiline_buf, allocator);
        const boxed = try allocator.create(Config.Table);
        boxed.* = table;
        return .{ .table = boxed };
    } else if (val.len >= 2 and val[0] == '[' and val[val.len - 1] == ']') {
        return .{ .list = try parseList(val, lines, multiline_buf, allocator) };
    }

    // Try int
    if (std.fmt.parseInt(i64, val, 10)) |i| {
        return .{ .int = i };
    } else |_| {}

    // Try float
    if (std.fmt.parseFloat(f64, val)) |f| {
        return .{ .float = f };
    } else |_| {}

    // Try bool
    if (utils.getBool(val)) |b| {
        return .{ .bool = b };
    }

    // Fallback: string
    const stripped_val = try allocator.dupe(u8, utils.stripQuotes(val));
    errdefer allocator.free(stripped_val);

    return .{ .string = stripped_val };
}

/// Parses a TOML inline table (`{ key = val, key2 = val2 }`) and returns a `Table`.
///
/// Supports:
/// - Quoted and unquoted keys
/// - Nested values: `{ a = { x = 1 }, b = [1, 2] }`
/// - Multiline inline tables using continuation lines
///
/// Params:
/// - `raw_val`: the `{...}` string
/// - `lines`: remaining file lines for multiline support
/// - `multiline_buf`: scratch buffer for continuation
/// - `allocator`: for table key/value allocation
///
/// Returns:
/// - `Config.Table` (owned and caller must deinit)
pub fn parseTable(
    raw_val: []const u8,
    lines: *std.mem.SplitIterator(u8, .sequence),
    multiline_buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) ConfigError!Config.Table {
    var full_table: []const u8 = raw_val;
    var owns_full_table: bool = false;

    if (raw_val.len == 0 or raw_val[raw_val.len - 1] != '}') {
        multiline_buf.clearRetainingCapacity();
        try multiline_buf.appendSlice(raw_val);
        try multiline_buf.append('\n');

        var depth: usize = 1;
        while (lines.next()) |line| {
            try multiline_buf.appendSlice(line);
            try multiline_buf.append('\n');

            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;

            for (trimmed) |c| switch (c) {
                '{', '[' => depth += 1,
                '}', ']' => if (depth > 0) {
                    depth -= 1;
                },
                else => {},
            };

            if (depth == 0) break;
        }

        full_table = try multiline_buf.toOwnedSlice();
        owns_full_table = true;
    }

    defer if (owns_full_table) allocator.free(full_table);

    const content = std.mem.trim(u8, full_table[1 .. full_table.len - 1], " \t\r\n");
    var table = Config.Table.init(allocator);
    errdefer table.deinit();

    var start: usize = 0;
    var depth: usize = 0;
    var in_quote: ?u8 = null;
    var i: usize = 0;
    while (i < content.len) {
        const c = content[i];
        if (in_quote) |q| {
            if (c == q) {
                in_quote = null;
            } else if (c == '\\' and i + 1 < content.len) {
                i += 1;
            }
        } else switch (c) {
            '"', '\'' => in_quote = c,
            '{', '[' => depth += 1,
            '}', ']' => if (depth > 0) {
                depth -= 1;
            },
            ',' => if (depth == 0) {
                const slice = std.mem.trim(u8, content[start..i], " \t\r\n");
                if (slice.len > 0) try utils.parseKeyValueIntoTable(slice, &table, lines, multiline_buf, allocator);
                start = i + 1;
            },
            else => {},
        }
        i += 1;
    }

    if (start < content.len) {
        const slice = std.mem.trim(u8, content[start..], " \t\r\n");
        if (slice.len > 0) try utils.parseKeyValueIntoTable(slice, &table, lines, multiline_buf, allocator);
    }

    return table;
}

/// Resolves all `${...}` variable placeholders in a string value recursively.
///
/// Supports extended substitution syntax:
/// - `${VAR}` → plain substitution, error if undefined
/// - `${VAR:-fallback}` → fallback if VAR is missing or empty
/// - `${VAR-default}` → fallback if VAR is missing
/// - `${VAR:+alt}` → use alt if VAR is non-empty
/// - `${VAR+alt}` → use alt if VAR is set (even if empty)
///
/// Fallback resolution order:
/// 1. Provided raw map (`source_raw_values`)
/// 2. Current config map
/// 3. OS environment (`std.process.getEnvVarOwned`)
///
/// Params:
/// - `value`: the raw string with placeholders
/// - `cfg`: config used for lookup
/// - `allocator`: memory allocator
/// - `visited_opt`: used to detect circular references
/// - `current_key`: optional key to protect against self-referencing
/// - `source_raw_values`: optional map of pre-substitution values
///
/// Returns:
/// - Fully substituted string value (owned by caller)
pub fn resolveVariables(
    value: []const u8,
    cfg: *Config,
    allocator: std.mem.Allocator,
    visited_opt: ?*std.StringHashMap(void),
    current_key: ?[]const u8,
    source_raw_values: ?*const std.StringHashMap(Value),
) ![]const u8 {
    var owned_visited_storage: ?std.StringHashMap(void) = null;
    const visited: *std.StringHashMap(void) = visited_opt orelse blk: {
        owned_visited_storage = std.StringHashMap(void).init(allocator);
        break :blk &owned_visited_storage.?;
    };
    defer if (owned_visited_storage) |*map| map.deinit();

    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == '\\' and i + 1 < value.len and value[i + 1] == '$') {
            try result.append('$');
            i += 2;
        } else if (value[i] == '$' and i + 1 < value.len and value[i + 1] == '{') {
            // Parse placeholder
            var brace_depth: usize = 1;
            var j = i + 2;
            while (j < value.len and brace_depth > 0) {
                if (value[j] == '{') brace_depth += 1 else if (value[j] == '}') brace_depth -= 1;
                j += 1;
            }
            if (brace_depth != 0) return ConfigError.InvalidPlaceholder;
            const inside: []const u8 = value[i + 2 .. j - 1];

            const parsed = try utils.parseVariableExpression(inside);
            const parsed_name = parsed.var_name;

            if (visited.contains(parsed_name)) return ConfigError.CircularReference;
            if (current_key) |ck| {
                if (std.mem.eql(u8, parsed_name, ck)) return ConfigError.CircularReference;
            }

            try visited.put(parsed_name, {});
            defer _ = visited.remove(parsed_name);

            // Lookup value
            const val_opt: ?ResolvedValue = blk: {
                if (source_raw_values) |raw| {
                    if (raw.get(parsed_name)) |val| {
                        if (val == .string) {
                            break :blk ResolvedValue{ .value = val.string, .owned = false };
                        } else {
                            return ConfigError.InvalidType;
                        }
                    }
                }
                if (cfg.get(parsed.var_name)) |val| {
                    if (val == .string) {
                        break :blk ResolvedValue{ .value = val.string, .owned = false };
                    } else {
                        return ConfigError.InvalidType;
                    }
                }
                const env_val = std.process.getEnvVarOwned(allocator, parsed.var_name) catch null;
                if (env_val) |e| {
                    const copy: []u8 = try allocator.dupe(u8, e);
                    allocator.free(e);
                    break :blk ResolvedValue{ .value = copy, .owned = true };
                }
                break :blk null;
            };

            // Evaluate substitution
            switch (parsed.operator) {
                .none => {
                    if (val_opt) |val_data| {
                        const val: []const u8 = val_data.value;
                        const rec: []const u8 = try resolveVariables(val, cfg, allocator, visited, parsed.var_name, source_raw_values);
                        errdefer allocator.free(rec);
                        try result.appendSlice(rec);
                        allocator.free(rec);
                        if (val_data.owned) allocator.free(val);
                        i = j;
                        continue;
                    }
                    if (parsed.fallback) |fb| {
                        const fb_val: []const u8 = try resolveVariables(fb, cfg, allocator, visited, current_key, source_raw_values);
                        errdefer allocator.free(fb_val);
                        try result.appendSlice(fb_val);
                        allocator.free(fb_val);
                        i = j;
                        continue;
                    }
                    return ConfigError.UnknownVariable;
                },
                .colon_dash => {
                    if (val_opt) |val_data| {
                        const val: []const u8 = val_data.value;
                        if (val.len > 0) {
                            const rec: []const u8 = try resolveVariables(val, cfg, allocator, visited, parsed.var_name, source_raw_values);
                            errdefer allocator.free(rec);
                            try result.appendSlice(rec);
                            allocator.free(rec);
                            if (val_data.owned) allocator.free(val);
                            i = j;
                            continue;
                        }
                        if (val_data.owned) allocator.free(val);
                    }
                    if (parsed.fallback) |fb| {
                        const fb_val: []const u8 = try resolveVariables(fb, cfg, allocator, visited, current_key, source_raw_values);
                        errdefer allocator.free(fb_val);
                        try result.appendSlice(fb_val);
                        allocator.free(fb_val);
                        i = j;
                        continue;
                    }
                    return ConfigError.UnknownVariable;
                },
                .dash => {
                    if (val_opt) |val_data| {
                        const val: []const u8 = val_data.value;
                        const rec: []const u8 = try resolveVariables(val, cfg, allocator, visited, parsed.var_name, source_raw_values);
                        errdefer allocator.free(rec);
                        try result.appendSlice(rec);
                        allocator.free(rec);
                        if (val_data.owned) allocator.free(val);
                        i = j;
                        continue;
                    }
                    if (parsed.fallback) |fb| {
                        const fb_val: []const u8 = try resolveVariables(fb, cfg, allocator, visited, current_key, source_raw_values);
                        errdefer allocator.free(fb_val);
                        try result.appendSlice(fb_val);
                        allocator.free(fb_val);
                        i = j;
                        continue;
                    }
                    return ConfigError.UnknownVariable;
                },
                .colon_plus => {
                    if (val_opt) |val_data| {
                        const val: []const u8 = val_data.value;
                        if (val.len > 0) {
                            if (parsed.fallback) |fb| {
                                const fb_val: []const u8 = try resolveVariables(fb, cfg, allocator, visited, current_key, source_raw_values);
                                errdefer allocator.free(fb_val);
                                try result.appendSlice(fb_val);
                                allocator.free(fb_val);
                                if (val_data.owned) allocator.free(val);
                                i = j;
                                continue;
                            }
                        }
                        if (val_data.owned) allocator.free(val);
                    }
                    i = j;
                    continue;
                },
                .plus => {
                    if (val_opt) |val_data| {
                        if (parsed.fallback) |fb| {
                            const fb_val: []const u8 = try resolveVariables(fb, cfg, allocator, visited, current_key, source_raw_values);
                            errdefer allocator.free(fb_val);
                            try result.appendSlice(fb_val);
                            allocator.free(fb_val);
                            if (val_data.owned) allocator.free(val_data.value);
                            i = j;
                            continue;
                        }
                        if (val_data.owned) allocator.free(val_data.value);
                    }
                    i = j;
                    continue;
                },
            }
        } else {
            try result.append(value[i]);
            i += 1;
        }
    }

    const out = try result.toOwnedSlice();
    return out;
}

/// Parses a single `KEY=VALUE` line (used for `.env` or `.ini`).
///
/// Trims whitespace and strips quotes around the value if present.
///
/// Errors:
/// - `ParseInvalidLine` if `=` is missing
/// - `InvalidKey` if the key is empty
///
/// Returns:
/// - Struct with trimmed key and value slices
pub fn parseLine(line: []const u8) !struct { key: []const u8, value: []const u8 } {
    const eq_index: usize = std.mem.indexOf(u8, line, "=") orelse return ConfigError.ParseInvalidLine;
    const key: []const u8 = std.mem.trim(u8, line[0..eq_index], " \t");
    var value: []const u8 = std.mem.trim(u8, line[eq_index + 1 ..], " \t");

    value = utils.stripQuotes(value);

    if (key.len == 0) return ConfigError.InvalidKey;

    return .{ .key = key, .value = value };
}
