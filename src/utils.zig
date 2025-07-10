const std = @import("std");
const Config = @import("config.zig").Config;
const ConfigError = Config.ConfigError;

const ResolvedValue = struct {
    value: []const u8,
    owned: bool,
};

pub const VariableExpr = struct {
    var_name: []const u8,
    fallback: ?[]const u8,
    operator: Operator,

    pub const Operator: type = enum {
        none,
        colon_dash,
        dash,
        colon_plus,
        plus,
    };
};

/// Parses a variable expression inside `${...}` and splits it into:
/// - The variable name
/// - Optional fallback string
/// - The operator used (`:-`, `-`, `:+`, `+`)
///
/// Used by variable substitution logic.
pub fn parseVariableExpression(expr: []const u8) !VariableExpr {
    const ops = [_]struct {
        str: []const u8,
        tag: VariableExpr.Operator,
    }{
        .{ .str = ":-", .tag = .colon_dash },
        .{ .str = "-", .tag = .dash },
        .{ .str = ":+", .tag = .colon_plus },
        .{ .str = "+", .tag = .plus },
    };

    for (ops) |op| {
        if (std.mem.indexOf(u8, expr, op.str)) |i| {
            return .{
                .var_name = expr[0..i],
                .fallback = expr[i + op.str.len ..],
                .operator = op.tag,
            };
        }
    }

    return .{
        .var_name = expr,
        .fallback = null,
        .operator = .none,
    };
}

/// Parses a TOML or INI-style string, handling quoted and multiline formats.
///
/// Supports:
/// - Basic strings (`"..."`) with escape sequences
/// - Literal strings (`'...'`) without escaping
/// - Multiline strings (`'''...'''` or `"""..."""`)
///
/// Returns the parsed content, optionally unescaped, allocated on the heap.
pub fn parseString(
    raw_val: []const u8,
    lines: *std.mem.SplitIterator(u8, .sequence),
    multiline_buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) ![]const u8 {
    if (raw_val.len == 0) return "";

    const is_basic = raw_val[0] == '"';
    const is_literal = raw_val[0] == '\'';
    const is_multiline = raw_val.len >= 3 and
        (std.mem.startsWith(u8, raw_val, "\"\"\"") or
            std.mem.startsWith(u8, raw_val, "'''"));

    // Handle multiline case
    if (is_multiline) {
        const quote_type = if (is_basic) "\"\"\"" else "'''";
        multiline_buf.clearRetainingCapacity();

        // Same-line triple quoted value
        if (std.mem.endsWith(u8, raw_val, quote_type)) {
            const inner = raw_val[3 .. raw_val.len - 3];
            return if (is_basic)
                try unescapeString(inner, allocator)
            else
                try allocator.dupe(u8, inner);
        }

        // Start collecting multiline content
        if (raw_val.len > 3) {
            try multiline_buf.appendSlice(raw_val[3..]);
            try multiline_buf.append('\n');
        }

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (findUnescaped(trimmed, quote_type)) |end_pos| {
                try multiline_buf.appendSlice(trimmed[0..end_pos]);
                break;
            } else {
                try multiline_buf.appendSlice(trimmed);
                try multiline_buf.append('\n');
            }
        }

        const joined = try multiline_buf.toOwnedSlice();

        if (is_basic) {
            const result = try unescapeString(joined, allocator);
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
        const inner = raw_val[1 .. raw_val.len - 1];
        return if (is_basic)
            try unescapeString(inner, allocator)
        else
            try allocator.dupe(u8, inner);
    }

    // Fallback for unquoted values
    return try allocator.dupe(u8, raw_val);
}

/// Parses a TOML array value and inserts any nested tables/arrays into the config.
///
/// Handles multiline arrays, and if items are tables (`{}`) or arrays (`[]`),
/// recursively flattens their contents into `config` under dot-prefixed keys.
///
/// Returns the full array value as a string, trimmed and owned by caller.
pub fn parseList(
    config: *Config,
    raw_val: []const u8,
    lines: *std.mem.SplitIterator(u8, .sequence),
    multiline_buf: *std.ArrayList(u8),
    full_key: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var full_array: []const u8 = raw_val;
    var owns_full_array: bool = false;

    // Handle multiline arrays
    if (raw_val.len == 0 or raw_val[raw_val.len - 1] != ']') {
        multiline_buf.clearRetainingCapacity();
        try multiline_buf.appendSlice(raw_val);
        try multiline_buf.append('\n');

        var depth: usize = 1;
        while (lines.next()) |line| {
            const trimmed: []const u8 = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            for (trimmed) |c| switch (c) {
                '[', '{' => depth += 1,
                ']', '}' => if (depth > 0) {
                    depth -= 1;
                },
                else => {},
            };
            try multiline_buf.appendSlice(trimmed);
            try multiline_buf.append('\n');
            if (depth == 0) break;
        }

        full_array = try multiline_buf.toOwnedSlice();
        owns_full_array = true;
    }

    defer if (owns_full_array) allocator.free(full_array);

    var trimmed = std.mem.trim(u8, full_array, " \t\r\n");
    trimmed = try std.mem.replaceOwned(u8, allocator, trimmed, " ", "");
    defer allocator.free(trimmed);

    var content = trimmed;
    var owns_content: bool = false;

    if (std.mem.endsWith(u8, content, ",]")) {
        const cleaned: []u8 = try std.fmt.allocPrint(allocator, "{s}]", .{content[0 .. content.len - 2]});
        content = cleaned;
        owns_content = true;
    }

    defer if (owns_content) allocator.free(content);

    const result: []u8 = try allocator.dupe(u8, content);
    errdefer allocator.free(result);

    // Loop over array items
    var items = std.mem.tokenizeScalar(u8, result[1 .. result.len - 1], ',');
    while (items.next()) |entry| {
        const val: []const u8 = std.mem.trim(u8, entry, " \t\r\n");
        if (val.len == 0) continue;

        if ((val[0] == '{' and val[val.len - 1] == '}') or (val[0] == '[' and val[val.len - 1] == ']')) {
            const sub: Config = try Config.parseToml(val, allocator);
            var it = sub.map.iterator();
            while (it.next()) |sub_entry| {
                const nested: []u8 = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ full_key, sub_entry.key_ptr.* });

                const key_copy = try allocator.dupe(u8, nested);
                errdefer allocator.free(key_copy);
                const val_copy = try allocator.dupe(u8, sub_entry.value_ptr.*);
                errdefer allocator.free(val_copy);

                if (config.map.getEntry(key_copy)) |entry_ptr| {
                    allocator.free(entry_ptr.key_ptr.*);
                    allocator.free(entry_ptr.value_ptr.*);
                    _ = config.map.remove(key_copy);
                }
                try config.map.put(key_copy, val_copy);
            }
        }
    }

    return result;
}

/// Parses a TOML inline table (e.g., `{ a = 1, b = 2 }`) and inserts nested keys into `config`.
///
/// If nested tables or arrays are present, they are recursively parsed and flattened.
///
/// Returns the entire raw table string, trimmed and heap-allocated.
pub fn parseTable(
    config: *Config,
    raw_val: []const u8,
    lines: *std.mem.SplitIterator(u8, .sequence),
    multiline_buf: *std.ArrayList(u8),
    full_key: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var full_table: []const u8 = raw_val;
    var owns_full_table: bool = false;

    if (raw_val.len == 0 or raw_val[raw_val.len - 1] != '}') {
        multiline_buf.clearRetainingCapacity();
        try multiline_buf.appendSlice(raw_val);
        try multiline_buf.append('\n');

        var depth: usize = 1;
        while (lines.next()) |line| {
            const trimmed: []const u8 = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            for (trimmed) |c| switch (c) {
                '{', '[' => depth += 1,
                '}', ']' => if (depth > 0) {
                    depth -= 1;
                },
                else => {},
            };

            try multiline_buf.appendSlice(trimmed);
            try multiline_buf.append('\n');
            if (depth == 0) break;
        }

        full_table = try multiline_buf.toOwnedSlice();
        owns_full_table = true;
    }

    defer if (owns_full_table) allocator.free(full_table);

    const content: []const u8 = std.mem.trim(u8, full_table[1 .. full_table.len - 1], " \t\r\n");

    var pairs = std.ArrayList([]const u8).init(allocator);
    defer pairs.deinit();

    // smart split respecting nesting
    var start: usize = 0;
    var depth: usize = 0;
    var in_quote: ?u8 = null;
    var i: usize = 0;
    while (i < content.len) {
        const c = content[i];
        if (in_quote) |quote| {
            if (c == quote) {
                in_quote = null;
            } else if (c == '\\' and i + 1 < content.len) {
                i += 1;
            }
        } else {
            switch (c) {
                '"', '\'' => in_quote = c,
                '{', '[' => depth += 1,
                '}', ']' => if (depth > 0) {
                    depth -= 1;
                },
                ',' => if (depth == 0) {
                    try pairs.append(std.mem.trim(u8, content[start..i], " \t\r\n"));
                    start = i + 1;
                },
                else => {},
            }
        }
        i += 1;
    }

    if (start < content.len) {
        const last = std.mem.trim(u8, content[start..], " \t\r\n");
        if (last.len > 0) try pairs.append(last);
    }

    var nested_key: ?[]u8 = null;
    defer if (nested_key) |k| allocator.free(k);

    for (pairs.items) |pair| {
        if (nested_key) |k| allocator.free(k);
        nested_key = null;

        const sep = std.mem.indexOfScalar(u8, pair, '=') orelse return ConfigError.ParseInvalidLine;
        const key = std.mem.trim(u8, pair[0..sep], " \t\r\n");
        const val = std.mem.trim(u8, pair[sep + 1 ..], " \t\r\n");

        nested_key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ full_key, key });

        if (val.len >= 2 and val[0] == '{' and val[val.len - 1] == '}') {
            const parsed = try parseTable(config, val, lines, multiline_buf, nested_key.?, allocator);
            allocator.free(parsed);
            allocator.free(nested_key.?);
            nested_key = null;
            continue;
        } else if (val.len >= 2 and val[0] == '[' and val[val.len - 1] == ']') {
            const parsed = try parseList(config, val, lines, multiline_buf, nested_key.?, allocator);
            allocator.free(parsed);
            allocator.free(nested_key.?);
            nested_key = null;
            continue;
        } else {
            const stripped_val = stripQuotes(val);
            const new_val = try allocator.dupe(u8, stripped_val);
            errdefer allocator.free(new_val);

            const key_copy = try allocator.dupe(u8, nested_key.?);
            errdefer allocator.free(key_copy);

            if (config.map.getEntry(key_copy)) |entry_ptr| {
                allocator.free(entry_ptr.key_ptr.*);
                allocator.free(entry_ptr.value_ptr.*);
                _ = config.map.remove(key_copy);
            }
            try config.map.put(key_copy, new_val);

            allocator.free(nested_key.?);
            nested_key = null;
        }
    }

    return try allocator.dupe(u8, std.mem.trim(u8, full_table, " \t\r\n"));
}

/// Resolves variable placeholders in a string (e.g. `${VAR}`), including fallbacks.
///
/// Recursively resolves nested variables and applies these substitution rules:
/// - `${VAR}` → replaced with VAR's value, or error if not found
/// - `${VAR:-default}` → use `default` if VAR is missing or empty
/// - `${VAR-default}` → use `default` if VAR is missing
/// - `${VAR:+alt}` → use `alt` if VAR is set and non-empty
/// - `${VAR+alt}` → use `alt` if VAR is set (even if empty)
///
/// Tracks visited variable names to detect and prevent circular references.
/// Raw values are resolved in two phases:
/// 1. From `source_raw_values` if provided (pre-resolution phase)
/// 2. From the config map itself (post-resolution phase)
pub fn resolveVariables(
    value: []const u8,
    cfg: *Config,
    allocator: std.mem.Allocator,
    visited_opt: ?*std.StringHashMap(void),
    current_key: ?[]const u8,
    source_raw_values: ?*const std.StringHashMap([]const u8),
) ![]const u8 {
    var owned_visited_storage: ?std.StringHashMap(void) = null;
    const visited: *std.StringHashMap(void) = visited_opt orelse blk: {
        owned_visited_storage = std.StringHashMap(void).init(allocator);
        break :blk &owned_visited_storage.?;
    };
    defer if (owned_visited_storage) |*map| map.deinit();

    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

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
            const inside = value[i + 2 .. j - 1];

            const parsed = try parseVariableExpression(inside);

            if (visited.contains(parsed.var_name)) return ConfigError.CircularReference;
            if (current_key) |ck| {
                if (std.mem.eql(u8, parsed.var_name, ck)) return ConfigError.CircularReference;
            }

            try visited.put(parsed.var_name, {});
            defer _ = visited.remove(parsed.var_name);

            // Lookup value
            const val_opt: ?ResolvedValue = blk: {
                if (source_raw_values) |raw| {
                    if (raw.get(parsed.var_name)) |val| {
                        break :blk ResolvedValue{ .value = val, .owned = false };
                    }
                }
                if (cfg.get(parsed.var_name)) |val| {
                    break :blk ResolvedValue{ .value = val, .owned = false };
                }
                const env_val = std.process.getEnvVarOwned(allocator, parsed.var_name) catch null;
                if (env_val) |e| {
                    const copy = try allocator.dupe(u8, e);
                    allocator.free(e);
                    break :blk ResolvedValue{ .value = copy, .owned = true };
                }
                break :blk null;
            };

            // Evaluate substitution
            switch (parsed.operator) {
                .none => {
                    if (val_opt) |val_data| {
                        const val = val_data.value;
                        const rec = try resolveVariables(val, cfg, allocator, visited, parsed.var_name, source_raw_values);
                        errdefer allocator.free(rec);
                        try result.appendSlice(rec);
                        allocator.free(rec);
                        if (val_data.owned) allocator.free(val);
                        i = j;
                        continue;
                    }
                    if (parsed.fallback) |fb| {
                        const fb_val = try resolveVariables(fb, cfg, allocator, visited, current_key, source_raw_values);
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
                        const val = val_data.value;
                        if (val.len > 0) {
                            const rec = try resolveVariables(val, cfg, allocator, visited, parsed.var_name, source_raw_values);
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
                        const fb_val = try resolveVariables(fb, cfg, allocator, visited, current_key, source_raw_values);
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
                        const val = val_data.value;
                        const rec = try resolveVariables(val, cfg, allocator, visited, parsed.var_name, source_raw_values);
                        errdefer allocator.free(rec);
                        try result.appendSlice(rec);
                        allocator.free(rec);
                        if (val_data.owned) allocator.free(val);
                        i = j;
                        continue;
                    }
                    if (parsed.fallback) |fb| {
                        const fb_val = try resolveVariables(fb, cfg, allocator, visited, current_key, source_raw_values);
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
                        const val = val_data.value;
                        if (val.len > 0) {
                            if (parsed.fallback) |fb| {
                                const fb_val = try resolveVariables(fb, cfg, allocator, visited, current_key, source_raw_values);
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
                            const fb_val = try resolveVariables(fb, cfg, allocator, visited, current_key, source_raw_values);
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

    return result.toOwnedSlice();
}

/// Internal helper for merging a single key/value with conflict handling.
pub fn insertEntry(
    cfg: *Config,
    key: []const u8,
    value: []const u8,
    behavior: Config.MergeBehavior,
    allocator: std.mem.Allocator,
) !void {
    const k: []u8 = try allocator.dupe(u8, key);
    const v: []u8 = try allocator.dupe(u8, value);

    const gop = try cfg.map.getOrPut(k);
    if (gop.found_existing) {
        switch (behavior) {
            .overwrite => {
                cfg.map.allocator.free(gop.key_ptr.*);
                cfg.map.allocator.free(gop.value_ptr.*);
                gop.key_ptr.* = k;
                gop.value_ptr.* = v;
            },
            .skip_existing => {
                allocator.free(k);
                allocator.free(v);
            },
            .error_on_conflict => {
                allocator.free(k);
                allocator.free(v);
                return ConfigError.KeyConflict;
            },
        }
    } else {
        gop.key_ptr.* = k;
        gop.value_ptr.* = v;
    }
}

pub fn unescapeString(s: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            if (i >= s.len) break;

            switch (s[i]) {
                'n' => try out.append('\n'),
                'r' => try out.append('\r'),
                't' => try out.append('\t'),
                '\\' => try out.append('\\'),
                '"' => try out.append('"'),
                '\'' => try out.append('\''),
                'b' => try out.append('\x08'),
                'f' => try out.append('\x0C'),
                'u' => {
                    if (i + 4 >= s.len)
                        return ConfigError.InvalidUnicodeEscape;
                    const hex = s[i + 1 .. i + 5];
                    const cp = std.fmt.parseInt(u21, hex, 16) catch return ConfigError.InvalidUnicodeEscape;
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &buf) catch return ConfigError.InvalidUnicodeEscape;
                    try out.appendSlice(buf[0..len]);
                    i += 5;
                    continue;
                },
                'U' => {
                    if (i + 8 >= s.len)
                        return ConfigError.InvalidUnicodeEscape;
                    const hex = s[i + 1 .. i + 9];
                    const cp = std.fmt.parseInt(u21, hex, 16) catch return ConfigError.InvalidUnicodeEscape;
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &buf) catch return ConfigError.InvalidUnicodeEscape;
                    try out.appendSlice(buf[0..len]);
                    i += 9;
                    continue;
                },
                else => try out.append(s[i]),
            }
        } else {
            try out.append(s[i]);
        }
        i += 1;
    }

    return out.toOwnedSlice();
}

pub fn escapeString(s: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var out = std.ArrayList(u8).init(allocator);
    //defer out.deinit();

    var it = std.unicode.Utf8Iterator{
        .bytes = s,
        .i = 0,
    };

    while (it.nextCodepoint()) |cp| {
        switch (cp) {
            '\n' => try out.appendSlice("\\n"),
            '\r' => try out.appendSlice("\\r"),
            '\t' => try out.appendSlice("\\t"),
            '\\' => try out.appendSlice("\\\\"),
            '"' => try out.appendSlice("\\\""),
            '\'' => try out.appendSlice("\\\'"),
            '\x08' => try out.appendSlice("\\b"),
            '\x0C' => try out.appendSlice("\\f"),
            else => {
                if (cp < 0x20 or cp == 0x7F) {
                    try out.appendSlice("\\u");
                    var buf: [8]u8 = undefined;
                    const raw = try std.fmt.bufPrint(&buf, "{x}", .{cp});
                    const pad_len = 4 - raw.len;
                    for (0..pad_len) |_| try out.append('0');
                    try out.appendSlice(raw);
                } else {
                    // Normal printable → encode back to utf-8
                    var buf: [4]u8 = undefined;
                    const len = try std.unicode.utf8Encode(cp, &buf);
                    try out.appendSlice(buf[0..len]);
                }
            },
        }
    }

    return out.toOwnedSlice();
}

/// Finds the first unescaped occurrence of `needle` in `haystack`.
///
/// Returns the index of `needle` if it's not preceded by a backslash (`\`), else `null`.
pub fn findUnescaped(haystack: []const u8, needle: []const u8) ?usize {
    var i: usize = 0;
    while (i + needle.len <= haystack.len) {
        if (std.mem.eql(u8, haystack[i..][0..needle.len], needle)) {
            if (i == 0 or haystack[i - 1] != '\\') {
                return i;
            }
        }
        i += 1;
    }
    return null;
}

/// Remove quotes from a string
pub fn stripQuotes(val: []const u8) []const u8 {
    if (val.len > 2 and
        ((val[0] == '"' and val[val.len - 1] == '"') or
            (val[0] == '\'' and val[val.len - 1] == '\'')))
    {
        return val[1 .. val.len - 1];
    }
    return val;
}

/// Attempts to parse the value of `key` as a boolean.
///
/// Accepts `true`, `false`, `1`, `0` in any case.
/// Returns `InvalidBool` if the value is unrecognized or key is missing.
pub fn getBool(s: []const u8) ?bool {
    const true_vals: [4][]const u8 = [_][]const u8{ "true", "yes", "on", "1" };
    const false_vals: [4][]const u8 = [_][]const u8{ "false", "no", "off", "0" };

    inline for (true_vals) |val| {
        if (std.ascii.eqlIgnoreCase(s, val))
            return true;
    }
    inline for (false_vals) |val| {
        if (std.ascii.eqlIgnoreCase(s, val))
            return false;
    }
    return null;
}
