const std = @import("std");
const Config = @import("config.zig").Config;
const ConfigError = Config.ConfigError;

pub fn parseVariableExpression(expr: []const u8) !struct {
    var_name: []const u8,
    fallback: ?[]const u8,
    operator: enum { none, colon_dash, dash, colon_plus, plus },
} {
    // Determine the opirator
    if (std.mem.indexOf(u8, expr, ":-")) |idx| {
        return .{
            .var_name = expr[0..idx],
            .fallback = expr[idx + 2 ..],
            .operator = .colon_dash,
        };
    } else if (std.mem.indexOf(u8, expr, "-")) |idx| {
        return .{
            .var_name = expr[0..idx],
            .fallback = expr[idx + 1 ..],
            .operator = .dash,
        };
    } else if (std.mem.indexOf(u8, expr, ":+")) |idx| {
        return .{
            .var_name = expr[0..idx],
            .fallback = expr[idx + 2 ..],
            .operator = .colon_plus,
        };
    } else if (std.mem.indexOf(u8, expr, "+")) |idx| {
        return .{
            .var_name = expr[0..idx],
            .fallback = expr[idx + 1 ..],
            .operator = .plus,
        };
    } else {
        return .{
            .var_name = expr,
            .fallback = null,
            .operator = .none,
        };
    }
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
    defer result.deinit();

    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == '\\' and i + 1 < value.len and value[i + 1] == '$') {
            try result.append('$');
            i += 2;
        } else if (value[i] == '$' and i + 1 < value.len and value[i + 1] == '{') {
            // Brace matching (nested-safe)
            var brace_depth: usize = 1;
            var j = i + 2;
            while (j < value.len and brace_depth > 0) {
                if (value[j] == '{') brace_depth += 1 else if (value[j] == '}') brace_depth -= 1;
                j += 1;
            }
            if (brace_depth != 0) return ConfigError.InvalidPlaceholder;
            const end = j - 1;
            const inside = value[i + 2 .. end];

            const parsed = try parseVariableExpression(inside);

            // Check for circular reference
            if (visited.contains(parsed.var_name)) return ConfigError.CircularReference;
            if (current_key) |ck| {
                if (std.mem.eql(u8, parsed.var_name, ck)) return ConfigError.CircularReference;
            }

            try visited.put(parsed.var_name, {});
            defer _ = visited.remove(parsed.var_name);

            // Lookup value from resolved or raw set
            const val_opt = if (source_raw_values) |raw| raw.get(parsed.var_name) else cfg.get(parsed.var_name);

            const resolved = switch (parsed.operator) {
                .none => blk: {
                    if (val_opt) |val| {
                        const rec = try resolveVariables(val, cfg, allocator, visited, parsed.var_name, source_raw_values);
                        try result.appendSlice(rec);
                        allocator.free(rec);
                        break :blk "";
                    }
                    if (parsed.fallback) |fb| {
                        const fb_val = try resolveVariables(fb, cfg, allocator, visited, current_key, source_raw_values);
                        try result.appendSlice(fb_val);
                        allocator.free(fb_val);
                        break :blk "";
                    }
                    return ConfigError.UnknownVariable;
                },
                .colon_dash => blk: {
                    if (val_opt) |val| {
                        if (val.len > 0) {
                            const rec = try resolveVariables(val, cfg, allocator, visited, parsed.var_name, source_raw_values);
                            try result.appendSlice(rec);
                            allocator.free(rec);
                            break :blk "";
                        }
                    }
                    if (parsed.fallback) |fb| {
                        const fb_val = try resolveVariables(fb, cfg, allocator, visited, current_key, source_raw_values);
                        try result.appendSlice(fb_val);
                        allocator.free(fb_val);
                        break :blk "";
                    }
                    return ConfigError.UnknownVariable;
                },
                .dash => blk: {
                    if (val_opt) |val| {
                        const rec = try resolveVariables(val, cfg, allocator, visited, parsed.var_name, source_raw_values);
                        try result.appendSlice(rec);
                        allocator.free(rec);
                        break :blk "";
                    }
                    if (parsed.fallback) |fb| {
                        const fb_val = try resolveVariables(fb, cfg, allocator, visited, current_key, source_raw_values);
                        try result.appendSlice(fb_val);
                        allocator.free(fb_val);
                        break :blk "";
                    }
                    return ConfigError.UnknownVariable;
                },
                .colon_plus => blk: {
                    if (val_opt) |val| {
                        if (val.len > 0) {
                            if (parsed.fallback) |fb| {
                                const fb_val = try resolveVariables(fb, cfg, allocator, visited, current_key, source_raw_values);
                                try result.appendSlice(fb_val);
                                allocator.free(fb_val);
                                break :blk "";
                            }
                        }
                    }
                    break :blk "";
                },
                .plus => blk: {
                    const exists = if (source_raw_values) |raw| raw.contains(parsed.var_name) else cfg.has(parsed.var_name);
                    if (exists) {
                        if (parsed.fallback) |fb| {
                            const fb_val = try resolveVariables(fb, cfg, allocator, visited, current_key, source_raw_values);
                            try result.appendSlice(fb_val);
                            allocator.free(fb_val);
                            break :blk "";
                        }
                    }
                    break :blk "";
                },
            };

            try result.appendSlice(resolved);
            i = end + 1;
        } else {
            try result.append(value[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice();
}
