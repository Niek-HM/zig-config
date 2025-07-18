const std = @import("std");
const Config = @import("config.zig").Config;
const ConfigError = @import("errors.zig").ConfigError;
const utils = @import("utils.zig");

pub const MergeBehavior = enum {
    overwrite,
    skip_existing,
    error_on_conflict,
};

/// Merges entries from another config or the OS environment into this one.
///
/// Behavior is controlled by the `MergeBehavior` enum:
/// - `.overwrite`: overwrite existing keys
/// - `.skip_existing`: keep current value if key exists
/// - `.error_on_conflict`: return `KeyConflict` if duplicate is found
///
/// - If `other` is `null`, the system environment is used instead.
/// - Both keys and values are duplicated into this config’s allocator.
///
/// Example:
/// ```zig
/// try cfg.merge(other, allocator, .overwrite);
/// ```
pub fn merge(
    a: *const Config,
    b: *const Config,
    allocator: std.mem.Allocator,
    behavior: MergeBehavior,
) !Config {
    // Create a new config to hold the merged result
    var result = Config.init(allocator);

    // Keep track of inserted keys to avoid duplicates
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    // Insert from a with logic
    var it_a = a.map.iterator();
    while (it_a.next()) |entry| {
        const key = entry.key_ptr.*;
        const in_b = b.map.get(key);

        switch (behavior) {
            .overwrite => {
                if (in_b) |val_b| {
                    const key_copy = try allocator.dupe(u8, key);
                    const val_copy = try utils.deepCloneValue(&val_b, allocator);
                    try result.map.put(key_copy, val_copy);
                    try seen.put(key, {});
                    continue;
                }
            },
            .error_on_conflict => {
                if (in_b != null)
                    return ConfigError.KeyConflict;
            },
            .skip_existing => {}, // just copy from a
        }

        const key_copy = try allocator.dupe(u8, key);
        const val_copy = try utils.deepCloneValue(entry.value_ptr, allocator);
        try result.map.put(key_copy, val_copy);
        try seen.put(key, {});
    }

    // Add remaining b-only entries
    var it_b = b.map.iterator();
    while (it_b.next()) |entry| {
        const key = entry.key_ptr.*;
        if (seen.contains(key)) continue;

        const key_copy = try allocator.dupe(u8, key);
        const val_copy = try utils.deepCloneValue(entry.value_ptr, allocator);
        try result.map.put(key_copy, val_copy);
    }

    return result;
}
