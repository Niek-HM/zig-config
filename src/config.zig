const std = @import("std");

/// Provides `.env` configuration parsing and typed access utilities.
///
/// This module allows you to:
/// - Load a `.env` file containing `KEY=VALUE` lines.
/// - Access values as strings, integers, floats, or booleans.
/// - Automatically trim whitespace and strip quotes.
/// - Ignore blank lines and comments (`#`, `;`).
pub const Config = struct {
    /// A string-to-string hash map storing the configuration entries.
    map: std.StringHashMap([]const u8),

    /// Creates a new empty config with the given allocator.
    pub fn init(allocator: std.mem.Allocator) Config {
        return Config{
            .map = std.StringHashMap([]const u8).init(allocator),
        };
    }

    /// Frees all memory used by the config map.
    pub fn deinit(self: *Config) void {
        self.map.deinit();
    }

    /// Returns the raw string value for a key, or `null` if not found.
    pub fn get(self: *Config, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    /// Loads a `.env`-style file from the given path and parses it into a config map.
    ///
    /// The format supports:
    /// - `KEY=value` lines
    /// - optional quotes around values
    /// - ignores lines starting with `#` or `;`
    ///
    /// Returns a new `Config` or an error if file loading or parsing fails.
    pub fn loadFromFile(path: []const u8, allocator: std.mem.Allocator) !Config {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const content = try allocator.alloc(u8, stat.size);
        defer allocator.free(content);

        _ = try file.readAll(content);
        return try parseEnv(content, allocator);
    }

    /// Parses raw `.env` text into a `Config`, splitting by line and parsing each `KEY=VALUE`.
    ///
    /// Does not validate or enforce any required keys.
    pub fn parseEnv(text: []const u8, allocator: std.mem.Allocator) !Config {
        var config = Config.init(allocator);

        var lines = std.mem.splitSequence(u8, text, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, "\t\r\n");
            if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') continue;

            if (parseLine(trimmed)) |kv| {
                const key_copy = try allocator.dupe(u8, kv.key);
                const val_copy = try allocator.dupe(u8, kv.value);
                try config.map.put(key_copy, val_copy);
            }
        }

        return config;
    }

    /// Parses a single `KEY=VALUE` line, stripping quotes and whitespace.
    ///
    /// Returns null if the line is malformed or empty.
    fn parseLine(line: []const u8) ?struct { key: []const u8, value: []const u8 } {
        const eq_index = std.mem.indexOf(u8, line, "=") orelse return null;
        const key = std.mem.trim(u8, line[0..eq_index], " \t");
        var value = std.mem.trim(u8, line[eq_index + 1 ..], " \t");

        // Remove quotes if present:
        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\'')))
        {
            value = value[1 .. value.len - 1]; // Remove first and last char
        }

        if (key.len == 0 or value.len == 0) return null;

        return .{ .key = key, .value = value };
    }

    /// Attempts to parse the value of `key` as an integer.
    ///
    /// Returns `null` if the key is missing or the value is not a valid number.
    pub fn getInt(self: *Config, key: []const u8) ?i64 {
        const val = self.get(key) orelse return null;
        return std.fmt.parseInt(i64, val, 10) catch return null;
    }

    /// Attempts to parse the value of `key` as a float (f64).
    ///
    /// Returns `null` if the key is missing or the value is not a valid float.
    pub fn getFloat(self: *Config, key: []const u8) ?f64 {
        const val = self.get(key) orelse return null;
        return std.fmt.parseFloat(f64, val) catch return null;
    }

    /// Attempts to parse the value of `key` as a boolean.
    ///
    /// Accepts `true`, `false`, `1`, `0` in any case.
    /// Returns `null` if the value is unrecognized or key is missing.
    pub fn getBool(self: *Config, key: []const u8) ?bool {
        const val = self.get(key) orelse return null;

        // true/false match (upper and lower cases)
        if (std.ascii.eqlIgnoreCase(val, "true")) return true;
        if (std.ascii.eqlIgnoreCase(val, "false")) return false;

        // 0/1 match
        if (std.ascii.eqlIgnoreCase(val, "1")) return true;
        if (std.ascii.eqlIgnoreCase(val, "0")) return false;

        return null;
    }
};
