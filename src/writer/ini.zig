const std = @import("std");
const utils = @import("../utils.zig");

const Config = @import("../config.zig").Config;
const ConfigError = @import("../errors.zig").ConfigError;

const valueToString = @import("../value.zig").valueToString;

/// Writes all config entries to an `.ini`-style file.
///
/// - Keys in the form `section.key` are grouped under `[section]` headers
/// - Keys without a section appear at the top
/// - Values are always written as unquoted strings (e.g. `key = value`)
/// - Values are serialized using `value.valueToString`
///
/// Output order is based on insertion order.
///
/// Example:
/// ```ini
/// host = localhost
///
/// [server]
/// port = 3000
/// ```
///
/// The file at `path` will be overwritten if it exists.
pub fn writeIniFile(self: *Config, path: []const u8, allocator: std.mem.Allocator) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true }) catch return ConfigError.IoError;
    defer file.close();
    var writer = file.writer();

    // Use a named struct to represent each key-value pair
    const IniEntry = struct {
        key: []const u8,
        value: []const u8,
    };

    // Group keys by section
    var by_section = std.StringHashMap(std.ArrayList(IniEntry)).init(allocator);
    defer {
        var it = by_section.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        by_section.deinit();
    }

    var it = self.map.iterator();
    while (it.next()) |entry| {
        const full_key: []const u8 = entry.key_ptr.*;

        // Convert value to string (copied per entry, freed after each iteration)
        const val_str = try valueToString(entry.value_ptr.*, self.map.allocator);
        defer self.map.allocator.free(val_str);

        // Split section and subkey at the first `.` (e.g., `server.port`)
        const dot: usize = std.mem.indexOfScalar(u8, full_key, '.') orelse {
            // Keys without a section (no dot) are written immediately
            try writer.print("{s} = {s}\n", .{ full_key, val_str });
            continue;
        };

        const section: []const u8 = full_key[0..dot];
        const key: []const u8 = full_key[dot + 1 ..];

        const entry_val = IniEntry{
            .key = key,
            .value = val_str,
        };

        // Append entry under its corresponding section
        const list = try by_section.getOrPut(section);
        if (!list.found_existing) {
            list.value_ptr.* = std.ArrayList(IniEntry).init(allocator);
        }
        try list.value_ptr.*.append(entry_val);
    }

    // Write grouped `[section]` headers and their keys
    var sec_it = by_section.iterator();
    var first: bool = true;
    while (sec_it.next()) |entry| {
        if (!first) {
            try writer.writeAll("\n") catch return ConfigError.IoError;
        } else {
            first = false;
        }

        try writer.print("[{s}]\n", .{entry.key_ptr.*}) catch return ConfigError.IoError;
        for (entry.value_ptr.*.items) |pair| {
            try writer.print("{s} = {s}\n", .{ pair.key, pair.value }) catch return ConfigError.IoError;
        }
    }
}
