const std = @import("std");
const Config = @import("config.zig").Config;
const ConfigError = @import("errors.zig").ConfigError;

const utils = @import("utils.zig");

const values = @import("value.zig");

const Value = values.Value;
const OwnedValue = values.OwnedValue;
const valueToType = values.valueToType;

/// Returns the resolved value for the given key, if it exists.
///
/// If the key is not found directly in the config, this performs a fallback
/// section lookup using dotted keys. For example, if `database.host` is requested
/// and the map contains a key `database` with a table value, it will descend into
/// that table and look up `host`.
///
/// Returns `null` if no matching key is found.
pub fn get(self: *Config, key: []const u8) ?Value {
    // 1. Try direct map lookup
    if (self.map.get(key)) |val| return val;

    // 2. Try fallback: lookup by prefix match and descent
    var it = self.map.iterator();
    while (it.next()) |entry| {
        const candidate = entry.key_ptr.*;
        if (std.mem.startsWith(u8, key, candidate) and key.len > candidate.len and key[candidate.len] == '.') {
            const suffix = key[(candidate.len + 1)..];
            const val = entry.value_ptr.*;
            if (val != .table) continue;

            var current: ?*const Value = &val;
            var parts = std.mem.tokenizeScalar(u8, suffix, '.');
            while (parts.next()) |part| {
                if (current == null or current.?.* != .table) return null;
                current = current.?.table.getPtr(part);
            }
            return if (current) |ptr| ptr.* else null;
        }
    }

    return null; // Nothing found
}

/// Retrieves and parses the value for a key as the given type `T`.
///
/// Supported types:
/// - `i64`, `f64`, `bool` → parsed using appropriate type logic
/// - `[]const u8` → string (copy is heap-allocated)
/// - `[][]const u8` → parsed from TOML/INI arrays
///
/// Returns:
/// - `OwnedValue(T)` that must be deinitialized by the caller
/// - Error if the key is missing or the value is invalid
///
/// Example:
/// ```zig
/// const port = try cfg.getAs(i64, "PORT", allocator);
/// defer port.deinit();
/// ```
pub fn getAs(self: *Config, comptime T: type, key: []const u8, allocator: std.mem.Allocator) !OwnedValue(T) {
    const val = self.get(key) orelse return ConfigError.Missing;

    const result = try valueToType(T, val, allocator);
    const final = try OwnedValue(T).init(result, allocator);

    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.size != .slice) return;

            if (T == [][]const u8) {
                // [][]const u8
                for (result) |item| allocator.free(item);
                allocator.free(result);
            } else {
                // []T where T is primitive (int, bool, float, etc.)
                allocator.free(result);
            }
        },
        else => {},
    }
    return final;
}

/// Retrieves the value for the given key as a string.
/// Returns a heap-allocated copy of the string.
///
/// Returns:
/// - `[]const u8` string
/// - `ConfigError.Missing` if key not found
/// - `ConfigError.InvalidPlaceholder` if value is not a string
pub fn getString(self: *Config, key: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const val = self.get(key) orelse return ConfigError.Missing;
    return switch (val) {
        .string => |s| try allocator.dupe(u8, s),
        else => return ConfigError.InvalidPlaceholder,
    };
}

/// If no keys match the given section prefix, returns `ConfigError.Missing`.
/// If keys like `database.port`, `database.user` exist, calling `getSection("database")`
/// returns a config with keys `port`, `user`.
pub fn getSection(self: *Config, section: []const u8, allocator: std.mem.Allocator) !Config {
    var result: Config = Config.init(allocator);
    var prefix_buf: [256]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "{s}.", .{section});

    var it = self.map.iterator();
    var found: bool = false;

    while (it.next()) |entry| {
        const key: []const u8 = entry.key_ptr.*;
        if (std.mem.startsWith(u8, key, prefix)) {
            const stripped: []const u8 = key[prefix.len..];
            const k_copy: []u8 = try allocator.dupe(u8, stripped);
            const original = entry.value_ptr;
            const val_copy = try utils.deepCloneValue(original, allocator);

            try result.map.put(k_copy, val_copy);
            found = true;
        }
    }

    if (!found) {
        result.deinit();
        return ConfigError.Missing;
    }

    return result;
}

/// Checks if a key exists directly in the config (no dotted fallback).
/// TODO: Add dotted fallback
pub fn has(self: *Config, key: []const u8) bool {
    return self.map.contains(key);
}

/// Returns a list of all top-level keys in the config.
///
/// Caller is responsible for freeing the returned array.
/// This does not include nested keys in `.table` values unless flattened manually.
pub fn keys(self: *Config, allocator: std.mem.Allocator) ![][]const u8 {
    var key: [][]const u8 = try allocator.alloc([]const u8, self.map.count());
    var it = self.map.iterator();
    var i: usize = 0;

    while (it.next()) |entry| {
        key[i] = entry.key_ptr.*;
        i += 1;
    }

    return key;
}
