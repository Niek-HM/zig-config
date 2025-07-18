const std = @import("std");
const Config = @import("../config.zig").Config;
const ConfigError = @import("../errors.zig").ConfigError;
const utils = @import("../utils.zig");
const valueToString = @import("../value.zig").valueToString;

/// Writes all config entries to a `.env`-style file.
///
/// - Each line is formatted as `KEY=value`, where the value is serialized to a string.
/// - Keys are written exactly as stored.
/// - Values are stringified using `valueToString`:
///   - `int`, `float`, `bool` → formatted literals
///   - `list` → comma-separated values
///   - `table` → inline TOML-style string like `{k="v"}`
///   - `string` → written as-is, without escaping or quotes
///
/// Overwrites the file at the given `path`.
pub fn writeEnvFile(self: *Config, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true }) catch return ConfigError.IoError;
    defer file.close();

    var writer = file.writer();

    var it = self.map.iterator();
    while (it.next()) |entry| {
        const val_str = try valueToString(entry.value_ptr.*, self.map.allocator);
        defer self.map.allocator.free(val_str);
        try writer.print("{s}={s}\n", .{ entry.key_ptr.*, val_str });
    }
}
