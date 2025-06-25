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
        CircularReference,
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

    /// Retrieves and parses the value for a key as the given type `T`.
    ///
    /// Supported types:
    /// - `i64`, `f64`, `bool` → parsed with appropriate checks
    /// - `[]const u8` → returns an allocator-owned copy
    ///
    /// Example usage:
    /// ```zig
    /// const port = try cfg.getAs(i64, "PORT", allocator);
    /// const debug = try cfg.getAs(bool, "DEBUG", allocator);
    /// ```
    ///
    /// Returns:
    /// - Parsed value as `T`
    /// - Error if the key is missing or the value is invalid for the given type
    pub fn getAs(self: *Config, comptime T: type, key: []const u8, allocator: std.mem.Allocator) !T {
        return switch (T) {
            i64 => @as(T, try self.getInt(key)),
            f64 => @as(T, try self.getFloat(key)),
            bool => @as(T, try self.getBool(key)),
            []const u8 => blk: {
                const val = self.get(key) orelse return ConfigError.Missing;
                break :blk try allocator.dupe(u8, val);
            },
            else => @compileError("Unsupported type for getAs(): " ++ @typeName(T)),
        };
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

    /// Parses raw `.env` text into a `Config`, supporting variable substitution and comments.
    ///
    /// Supports:
    /// - Lines in `KEY=VALUE` format
    /// - Quoted values (`"abc"` or `'abc'`)
    /// - Ignoring lines starting with `#` or `;`
    /// - Variable substitution using `${VAR}`, `${VAR:-fallback}`, etc.
    /// - Detection of circular references during substitution
    ///
    /// Returns a new `Config` with fully resolved values.
    pub fn parseEnv(text: []const u8, allocator: std.mem.Allocator) !Config {
        var config = Config.init(allocator);

        var raw_values = std.StringHashMap([]const u8).init(allocator);
        defer {
            var it = raw_values.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            raw_values.deinit();
        }

        var lines = std.mem.splitSequence(u8, text, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, "\t\r\n");
            if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') continue;

            const kv = try parseLine(trimmed);
            const key_copy = try allocator.dupe(u8, kv.key);
            const val_copy = try allocator.dupe(u8, kv.value);

            try raw_values.put(key_copy, val_copy);
        }

        var it = raw_values.iterator();
        while (it.next()) |entry| {
            const resolved_val = try utils.resolveVariables(
                entry.value_ptr.*,
                &config,
                allocator,
                null,
                entry.key_ptr.*,
                &raw_values,
            );

            const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
            const val_copy = try allocator.dupe(u8, resolved_val);

            try config.map.put(key_copy, val_copy);
            allocator.free(resolved_val);
        }

        return config;
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

    /// Parses raw `.ini` text into a `Config`, grouping keys by section.
    ///
    /// Supports:
    /// - `[section]` headers
    /// - Lines in `key=value` format
    /// - Quoted values (`"abc"` or `'abc'`)
    /// - Ignoring lines starting with `#` or `;`
    /// - Keys are stored as `section.key` internally
    /// - Keys outside any section are stored as-is
    ///
    /// Returns a new `Config` with all keys fully parsed and namespaced by section.
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
                const name = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
                if (name.len == 0) {
                    config.deinit();
                    return ConfigError.ParseUnterminatedSection;
                }
                current_section = name;
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

            const gop = try config.map.getOrPut(full_key);
            if (gop.found_existing) {
                config.map.allocator.free(gop.key_ptr.*); // free old key
                config.map.allocator.free(gop.value_ptr.*); // free old val
                gop.key_ptr.* = full_key;
                gop.value_ptr.* = val_copy;
            } else {
                gop.key_ptr.* = full_key;
                gop.value_ptr.* = val_copy;
            }
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
    /// Returns `InvalidBool` if the value is unrecognized or key is missing.
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

    /// Returns a new config containing only keys from the given section.
    ///
    /// Extracts all keys prefixed with `section.` and returns them in a new `Config`
    /// with the prefix removed from each key (e.g., "database.port" → "port").
    ///
    /// Returns:
    /// - `Config` with section keys
    /// - `ConfigError.Missing` if no matching section keys found
    ///
    /// Caller must `deinit` the returned config.
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

    /// Writes all config entries to an `.ini`-style file.
    ///
    /// - Keys in the form `section.key` are grouped under `[section]` headers
    /// - Keys without a section are written at the top of the file
    /// - The output is sorted by insertion order
    ///
    /// Example output:
    /// ```ini
    /// host = localhost
    ///
    /// [server]
    /// port = 3000
    /// ```
    ///
    /// Overwrites the file at `path`.
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

    /// Merges entries from another config into this one.
    ///
    /// Behavior is controlled by the `MergeBehavior` enum:
    /// - `.overwrite`: overwrite existing keys
    /// - `.skip_existing`: keep existing keys, skip duplicates
    /// - `.error_on_conflict`: fail if any key already exists
    ///
    /// All merged keys and values are duplicated using the current config’s allocator.
    ///
    /// Returns:
    /// - `KeyConflict` if a conflict occurs and behavior is `.error_on_conflict`
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
                    .error_on_conflict => {
                        self.map.allocator.free(key);
                        self.map.allocator.free(val);
                        return ConfigError.KeyConflict;
                    },
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
