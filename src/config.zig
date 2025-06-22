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
    pub fn loadEnvFile(path: []const u8, allocator: std.mem.Allocator) !Config {
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

    /// Loads and parses a `.ini` file into a config map.
    /// Returns a Config where keys are in `section.key` format.
    pub fn loadIniFile(path: []const u8, allocator: std.mem.Allocator) !Config {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const content = try allocator.alloc(u8, stat.size);
        defer allocator.free(content);

        _ = try file.readAll(content);
        return try parseIni(content, allocator);
    }

    /// Parses a `.ini`-style config into a float map.
    /// Sections are prefixed to keys as `section.key`.
    pub fn parseIni(text: []const u8, allocator: std.mem.Allocator) !Config {
        var config = Config.init(allocator);
        var current_section: ?[]const u8 = null;

        var lines = std.mem.splitSequence(u8, text, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, "\t\r\n");
            if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') continue;

            // Section header: [Section]
            if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                current_section = trimmed[1 .. trimmed.len - 1];
                continue;
            }

            if (parseLine(trimmed)) |kv| {
                var full_key: []u8 = undefined;

                if (current_section) |sec| {
                    const joined_len = sec.len + 1 + kv.key.len; // Section key
                    full_key = try allocator.alloc(u8, joined_len);
                    std.mem.copyForwards(u8, full_key[0..sec.len], sec);
                    full_key[sec.len] = '.';
                    std.mem.copyForwards(u8, full_key[sec.len + 1 ..], kv.key);
                } else {
                    full_key = try allocator.dupe(u8, kv.key);
                }

                const val_copy = try allocator.dupe(u8, kv.value);
                try config.map.put(full_key, val_copy);
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

    /// Prints all key-value pairs to std.debug
    pub fn debugPrint(self: *Config) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            std.debug.print("{s} = {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    /// Returns a list of all keys in the config
    /// Caller is responsible for freeing the returned array
    pub fn keys(self: *Config, allocator: std.mem.Allocator) ![][]const u8 {
        var key = try allocator.alloc([]const u8, self.map.count());
        var it = self.map.iterator();
        var i: usize = 0;

        while (it.next()) |entry| {
            key[i] = entry.key_ptr.*;
            i += 1;
        }

        return key;
    }

    /// Return all key-value pairs that begin with a given section prefix.
    /// Keys returned will have the prefix **removed** (e.g., "port" instead of "database.port").
    pub fn getSection(self: *Config, section: []const u8, allocator: std.mem.Allocator) !Config {
        var result = Config.init(allocator);
        const prefix = try std.fmt.allocPrint(allocator, "{s}.", .{section});
        defer allocator.free(prefix);

        var it = self.map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.startsWith(u8, key, prefix)) {
                const stripped = key[prefix.len..];
                const k_copy = try allocator.dupe(u8, stripped);
                const v_copy = try allocator.dupe(u8, entry.value_ptr.*);
                try result.map.put(k_copy, v_copy);
            }
        }

        return result;
    }

    /// Writes all config key-value pairs to a `.env`-style file.
    /// Each line will be formatted as `KEY=value`.
    pub fn writeEnvFile(self: *Config, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();

        var writer = file.writer();

        var it = self.map.iterator();
        while (it.next()) |entry| {
            try writer.print("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    /// Writes config to an `.ini`-style file, grouped by section headers.
    /// Keys without sections go at the top.
    pub fn writeIniFile(self: *Config, path: []const u8, allocator: std.mem.Allocator) !void {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        var writer = file.writer();

        // Group keys by section
        var by_section = std.StringHashMap(std.ArrayList(struct {
            key: []const u8,
            value: []const u8,
        })).init(allocator);
        defer {
            var it = by_section.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.deinit();
            }
            by_section.deinit();
        }

        var it = self.map.iterator();
        while (it.next()) |entry| {
            const full_key = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            const dot = std.mem.indexOfScalar(u8, full_key, '.') orelse {
                try writer.print("{s} = {s}\n", .{ full_key, val });
                continue;
            };

            const section = full_key[0..dot];
            const key = full_key[dot + 1 ..];

            const entry_val = struct { key: []const u8, value: []const u8 }{
                .key = key,
                .value = val,
            };

            const list = try by_section.getOrPut(section);
            if (!list.found_existing) {
                list.value_ptr.* = std.ArrayList(@TypeOf(entry_val)).init(allocator);
            }
            try list.value_ptr.*.append(entry_val);
        }

        // Write sections
        var sec_it = by_section.iterator();
        while (sec_it.next()) |entry| {
            try writer.print("\n[{s}]\n", .{entry.key_ptr.*});
            for (entry.value_ptr.*.items) |pair| {
                try writer.print("{s} = {s}\n", .{ pair.key, pair.value });
            }
        }
    }
};
