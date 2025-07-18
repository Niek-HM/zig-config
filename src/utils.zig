const std = @import("std");

const parsed = @import("parser/mod.zig");
const parseValue = parsed.shared.parseValue;

const Value = @import("value.zig").Value;
const Table = @import("value.zig").Table;
const Config = @import("config.zig").Config;
const ConfigError = @import("errors.zig").ConfigError;

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

/// Parses a `key=value` pair string into a table entry.
/// Handles unquoting keys and parsing value (including multiline).
pub fn parseKeyValueIntoTable(
    pair: []const u8,
    table: *Table,
    lines: *std.mem.SplitIterator(u8, .sequence),
    multiline_buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) !void {
    const eq_idx = std.mem.indexOfScalar(u8, pair, '=') orelse return ConfigError.ParseInvalidLine;
    const key = std.mem.trim(u8, pair[0..eq_idx], " \t\r\n");
    const val = std.mem.trim(u8, pair[eq_idx + 1 ..], " \t\r\n");

    var value = try parseValue(val, lines, multiline_buf, allocator);
    errdefer value.deinit(allocator);

    const key_copy = try allocator.dupe(u8, stripQuotes(key));
    errdefer allocator.free(key_copy);

    try table.put(key_copy, value);
}

/// Internal helper for merging a single key/value with conflict handling.
pub fn insertEntry(
    cfg: *Config.Config,
    key: []const u8,
    value: []const u8,
    behavior: Config.Config.MergeBehavior,
    allocator: std.mem.Allocator,
) !void {
    const k: []u8 = try allocator.dupe(u8, key);
    errdefer allocator.free(k);

    const gop = try cfg.map.getOrPut(k);
    if (gop.found_existing) {
        switch (behavior) {
            .overwrite => {
                gop.key_ptr.*.deinit(allocator);
                gop.value_ptr.*.deinit(allocator);
                gop.key_ptr.* = k;
                gop.value_ptr.* = .{ .string = value };
            },
            .skip_existing => {
                allocator.free(k);
                value.deinit(allocator);
            },
            .error_on_conflict => {
                allocator.free(k);
                value.deinit(allocator);
                return ConfigError.KeyConflict;
            },
        }
    } else {
        gop.key_ptr.* = k;
        gop.value_ptr.* = .{ .string = value };
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
                    const hex: []const u8 = s[i + 1 .. i + 5];
                    const cp: u21 = std.fmt.parseInt(u21, hex, 16) catch return ConfigError.InvalidUnicodeEscape;
                    var buf: [4]u8 = undefined;
                    const len: u3 = std.unicode.utf8Encode(cp, &buf) catch return ConfigError.InvalidUnicodeEscape;
                    try out.appendSlice(buf[0..len]);
                    i += 5;
                    continue;
                },
                'U' => {
                    if (i + 8 >= s.len)
                        return ConfigError.InvalidUnicodeEscape;
                    const hex: []const u8 = s[i + 1 .. i + 9];
                    const cp: u21 = std.fmt.parseInt(u21, hex, 16) catch return ConfigError.InvalidUnicodeEscape;
                    var buf: [4]u8 = undefined;
                    const len: u3 = std.unicode.utf8Encode(cp, &buf) catch return ConfigError.InvalidUnicodeEscape;
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
    defer out.deinit();

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
                // Handle printable characters and encode them back to UTF-8 if not escaped
                if (cp < 0x20 or cp == 0x7F) {
                    try out.appendSlice("\\u");
                    var buf: [8]u8 = undefined;
                    const raw: []u8 = try std.fmt.bufPrint(&buf, "{x}", .{cp});
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

/// Recursively deep clones a Value, including all nested lists and tables.
/// Returns a fully owned duplicate.
pub fn deepCloneValue(src: *const Value, allocator: std.mem.Allocator) ConfigError!Value {
    return switch (src.*) {
        .string => |s| blk: {
            const copy = try allocator.dupe(u8, s);
            errdefer allocator.free(copy);
            break :blk .{ .string = copy };
        },
        .list => |orig| blk: {
            const new_list = try allocator.alloc(Value, orig.len);
            for (orig, 0..) |*v, i| {
                new_list[i] = try deepCloneValue(v, allocator);
            }
            break :blk .{ .list = new_list };
        },
        .table => |orig| blk: {
            const new_table = try allocator.create(Table);
            new_table.* = Table.init(allocator);
            var it = orig.iterator();
            while (it.next()) |e| {
                const k = try allocator.dupe(u8, e.key_ptr.*);
                errdefer allocator.free(k);
                const v_copy = try deepCloneValue(e.value_ptr, allocator);
                try new_table.put(k, v_copy);
            }
            break :blk .{ .table = new_table };
        },
        .int => |v| .{ .int = v },
        .float => |v| .{ .float = v },
        .bool => |v| .{ .bool = v },
    };
}

/// Converts an in-place `Value` to an owned deep copy version.
/// Used after parsing when the Value was borrowed from input buffer.
/// TODO: Consider folding into `deepCloneValue`.
fn deepCopyValue(val: *Value, allocator: std.mem.Allocator) anyerror!void {
    switch (val.*) {
        .string => {
            const val_str = val.string;
            const tmp_copy = try allocator.dupe(u8, val_str);
            errdefer allocator.free(tmp_copy);
            val.* = .{ .string = tmp_copy };
        },
        .list => {
            const orig = val.list;
            const new_list = try allocator.alloc(Value, orig.len);
            for (orig, 0..) |*v, i| {
                new_list[i] = try deepCloneValue(v, allocator);
            }
            val.* = .{ .list = new_list };
        },
        .table => {
            const orig = val.table;
            const new_table = try allocator.create(Table);
            new_table.* = Table.init(allocator);
            var it = orig.iterator();
            while (it.next()) |e| {
                const k = try allocator.dupe(u8, e.key_ptr.*);
                const v_copy = try deepCloneValue(e.value_ptr, allocator);
                try new_table.put(k, v_copy);
            }
            val.* = .{ .table = new_table };
        },
        else => {}, // int, float, bool – nothing to copy
    }
}
