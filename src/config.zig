const std = @import("std");
const utils = @import("utils.zig");

/// Provides `.env` configuration parsing and typed access utilities.
///
/// This module allows you to:
/// - Load a `.env` file containing `KEY=VALUE` lines.
/// - Access values as strings, integers, floats, or booleans.
/// - Automatically trim whitespace and strip quotes.
/// - Ignore blank lines and comments (`#`, `;`).
///
/// Version: 0.1.2
pub const Config = struct {
    pub const Version = "0.1.2";

    /// A string-to-string hash map storing the configuration entries.
    map: std.StringHashMap([]const u8),
    pub const Format = enum { env, ini };

    pub const MergeBehavior = enum {
        overwrite,
        skip_existing,
        error_on_conflict,
    };

    pub const ConfigError = error{
        Missing,
        InvalidInt,
        InvalidFloat,
        InvalidBool,
        InvalidKey,
        InvalidPlaceholder,
        InvalidSubstitutionSyntax,
        UnknownVariable,
        KeyConflict,
        IoError,
        ParseError,
        ParseInvalidLine,
        ParseUnterminatedSection,
        ParseInvalidFormat,
    };

    /// Creates a new empty config with the given allocator.
    pub fn init(allocator: std.mem.Allocator) Config {
        return Config{
            .map = std.StringHashMap([]const u8).init(allocator),
        };
    }

    /// Frees all memory used by the config map.
    pub fn deinit(self: *Config) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.map.allocator.free(entry.key_ptr.*);
            self.map.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    /// Returns the raw string value for a key, or `null` if not found.
    pub fn get(self: *Config, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    /// Checks if a key exists in the config.
    pub fn has(self: *Config, key: []const u8) bool {
        return self.map.contains(key);
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
        const file = try std.fs.cwd().openFile(path, .{}) catch return ConfigError.IoError;
        defer file.close();

        const stat = try file.stat();
        const content = try allocator.alloc(u8, stat.size) catch return ConfigError.IoError;
        defer allocator.free(content);

        _ = try file.readAll(content) catch return ConfigError.IoError;
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

            const kv = try parseLine(trimmed);
            const key_copy = try allocator.dupe(u8, kv.key);

            const resolved_val: []const u8 = resolveVariables(kv.value, &config, allocator) catch |e| {
                allocator.free(key_copy);
                config.deinit();
                return e;
            };

            const val_copy: []const u8 = allocator.dupe(u8, resolved_val) catch |e| {
                allocator.free(key_copy);
                allocator.free(resolved_val);
                config.deinit();
                return e;
            };

            try config.map.put(key_copy, val_copy);
            allocator.free(resolved_val);
        }

        return config;
    }

    // Helper func for parseEnv (Resolve variables)
    fn resolveVariables(value: []const u8, cfg: *Config, allocator: std.mem.Allocator) ![]const u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        var i: usize = 0;
        while (i < value.len) {
            if (value[i] == '\\' and i + 1 < value.len and value[i + 1] == '$') {
                // Handle escaped dollar: \$ -> $
                try result.append('$');
                i += 2;
            } else if (value[i] == '$' and i + 1 < value.len and value[i + 1] == '{') {
                const end = std.mem.indexOfScalarPos(u8, value, i + 2, '}') orelse return ConfigError.InvalidPlaceholder;
                const inside = value[i + 2 .. end];

                const parsed = try utils.parseVariableExpression(inside);

                const val_opt = cfg.get(parsed.var_name);
                const resolved = switch (parsed.operator) {
                    .none => val_opt orelse return ConfigError.UnknownVariable,

                    // ${VAR:-fallback} → fallback if VAR unset or empty
                    .colon_dash => if (val_opt) |val| if (val.len > 0) val else parsed.fallback orelse return ConfigError.UnknownVariable else parsed.fallback orelse return ConfigError.UnknownVariable,

                    // ${VAR-fallback} → fallback if VAR is unset (but use empty if set)
                    .dash => val_opt orelse parsed.fallback orelse return ConfigError.UnknownVariable,

                    // ${VAR:+fallback} → fallback if VAR set and not empty
                    .colon_plus => if (val_opt) |val| if (val.len > 0) parsed.fallback orelse "" else "" else "",

                    // ${VAR+fallback} → fallback if VAR is set (even if empty)
                    .plus => if (cfg.map.contains(parsed.var_name)) parsed.fallback orelse "" else "",
                };

                //const resolved = cfg.get(var_name) orelse fallback orelse return errors.UnknownVariable;
                try result.appendSlice(resolved);
                i = end + 1;
            } else {
                try result.append(value[i]);
                i += 1;
            }
        }
        return result.toOwnedSlice();
    }

    /// Loads and parses a `.ini` file into a config map.
    /// Returns a Config where keys are in `section.key` format.
    pub fn loadIniFile(path: []const u8, allocator: std.mem.Allocator) !Config {
        const file = try std.fs.cwd().openFile(path, .{}) catch return ConfigError.IoError;
        defer file.close();

        const stat = try file.stat();
        const content = try allocator.alloc(u8, stat.size) catch return ConfigError.IoError;
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

            if (trimmed.len < 3 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                return ConfigError.ParseUnterminatedSection;
            }

            if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                current_section = trimmed[1 .. trimmed.len - 1];
                continue;
            }

            const kv = try parseLine(trimmed);

            const full_key = blk: {
                if (current_section) |sec| {
                    const joined_len = sec.len + 1 + kv.key.len;
                    var buf = allocator.alloc(u8, joined_len) catch {
                        config.deinit();
                        return error.OutOfMemory;
                    };
                    std.mem.copyForwards(u8, buf[0..sec.len], sec);
                    buf[sec.len] = '.';
                    std.mem.copyForwards(u8, buf[sec.len + 1 ..], kv.key);
                    break :blk buf;
                } else {
                    break :blk allocator.dupe(u8, kv.key) catch {
                        config.deinit();
                        return error.OutOfMemory;
                    };
                }
            };

            const val_copy = allocator.dupe(u8, kv.value) catch {
                allocator.free(full_key);
                config.deinit();
                return error.OutOfMemory;
            };

            try config.map.put(full_key, val_copy);
        }

        return config;
    }

    /// Parses a single `KEY=VALUE` line, stripping quotes and whitespace.
    ///
    /// Returns null if the line is malformed or empty.
    fn parseLine(line: []const u8) !struct { key: []const u8, value: []const u8 } {
        const eq_index = std.mem.indexOf(u8, line, "=") orelse return ConfigError.ParseInvalidLine;
        const key = std.mem.trim(u8, line[0..eq_index], " \t");
        var value = std.mem.trim(u8, line[eq_index + 1 ..], " \t");

        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\'')))
        {
            value = value[1 .. value.len - 1]; // Remove surrounding quotes
        }

        if (key.len == 0) return ConfigError.InvalidKey;

        return .{ .key = key, .value = value };
    }

    /// Attempts to parse the value of `key` as an integer.
    ///
    /// Returns `null` if the key is missing or the value is not a valid number.
    pub fn getInt(self: *Config, key: []const u8) !i64 {
        const val = self.get(key) orelse return ConfigError.Missing;
        return std.fmt.parseInt(i64, val, 10) catch return ConfigError.InvalidInt;
    }

    /// Attempts to parse the value of `key` as a float (f64).
    ///
    /// Returns `null` if the key is missing or the value is not a valid float.
    pub fn getFloat(self: *Config, key: []const u8) !f64 {
        const val = self.get(key) orelse return ConfigError.Missing;
        return std.fmt.parseFloat(f64, val) catch return ConfigError.InvalidFloat;
    }

    /// Attempts to parse the value of `key` as a boolean.
    ///
    /// Accepts `true`, `false`, `1`, `0` in any case.
    /// Returns `null` if the value is unrecognized or key is missing.
    pub fn getBool(self: *Config, key: []const u8) !bool {
        const val = self.get(key) orelse return ConfigError.Missing;

        // true/false match (upper and lower cases)
        if (std.ascii.eqlIgnoreCase(val, "true")) return true;
        if (std.ascii.eqlIgnoreCase(val, "false")) return false;

        // 0/1 match
        if (std.ascii.eqlIgnoreCase(val, "1")) return true;
        if (std.ascii.eqlIgnoreCase(val, "0")) return false;

        return ConfigError.InvalidBool;
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
        var found: bool = false;

        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.startsWith(u8, key, prefix)) {
                const stripped = key[prefix.len..];
                const k_copy = try allocator.dupe(u8, stripped);
                const v_copy = try allocator.dupe(u8, entry.value_ptr.*);

                try result.map.put(k_copy, v_copy);
                found = true;
            }
        }

        if (!found) {
            result.deinit();
            return ConfigError.Missing;
        }

        return result;
    }

    /// Writes all config key-value pairs to a `.env`-style file.
    /// Each line will be formatted as `KEY=value`.
    pub fn writeEnvFile(self: *Config, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true }) catch return ConfigError.IoError;
        defer file.close();

        var writer = file.writer();

        var it = self.map.iterator();
        while (it.next()) |entry| {
            try writer.print("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* }) catch return ConfigError.IoError;
        }
    }

    /// Writes config to an `.ini`-style file, grouped by section headers.
    /// Keys without sections go at the top.
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
            const full_key = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            const dot = std.mem.indexOfScalar(u8, full_key, '.') orelse {
                // Keys without section go at the top
                try writer.print("{s} = {s}\n", .{ full_key, val });
                continue;
            };

            const section = full_key[0..dot];
            const key = full_key[dot + 1 ..];

            const entry_val = IniEntry{
                .key = key,
                .value = val,
            };

            const list = try by_section.getOrPut(section);
            if (!list.found_existing) {
                list.value_ptr.* = std.ArrayList(IniEntry).init(allocator);
            }
            try list.value_ptr.*.append(entry_val);
        }

        // Write grouped sections
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

    /// Merges another config into this one, overriding existing keys if needed.
    pub fn merge(self: *Config, other: *Config, behavior: MergeBehavior) !void {
        var it = other.map.iterator();

        while (it.next()) |entry| {
            const key = try self.map.allocator.dupe(u8, entry.key_ptr.*);
            const val = try self.map.allocator.dupe(u8, entry.value_ptr.*);

            const gop = try self.map.getOrPut(key);
            if (gop.found_existing) {
                switch (behavior) {
                    .overwrite => {
                        self.map.allocator.free(gop.key_ptr.*);
                        self.map.allocator.free(gop.value_ptr.*);
                        gop.key_ptr.* = key;
                        gop.value_ptr.* = val;
                    },
                    .skip_existing => {
                        self.map.allocator.free(key);
                        self.map.allocator.free(val);
                        continue;
                    },
                    .error_on_conflict => return ConfigError.KeyConflict,
                }
            } else {
                gop.key_ptr.* = key;
                gop.value_ptr.* = val;
            }
        }
    }

    /// Loads a config from an in-memory buffer.
    /// Accepts format `.env` or `.ini`.
    pub fn loadFromBuffer(text: []const u8, format: Format, allocator: std.mem.Allocator) !Config {
        return switch (format) {
            .env => Config.parseEnv(text, allocator),
            .ini => Config.parseIni(text, allocator),
        };
    }
};
