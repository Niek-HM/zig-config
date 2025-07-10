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
/// Version: 0.2.0
pub const Config = struct {
    pub const Version = "0.1.3";

    /// A string-to-string hash map storing the entries.
    map: std.StringHashMap([]const u8),
    pub const Format = enum { env, ini, toml };

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
        InvalidEscape,
        InvalidUnicodeEscape,
        UnknownVariable,
        KeyConflict,
        IoError,
        ParseError,
        ParseInvalidLine,
        ParseUnterminatedSection,
        ParseInvalidFormat,
        CircularReference,
        OutOfMemory,
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

    /// Returns the raw (unparsed) string value for the given key.
    /// This is the exact value as stored internally (after substitution),
    /// including quotes or escape characters if present.
    ///
    /// Returns:
    /// - `null` if the key is not found
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
        const val: []const u8 = self.get(key) orelse return ConfigError.Missing;
        const s: []const u8 = std.mem.trim(u8, val, " \t\r\n");
        const info = @typeInfo(T);

        return switch (info) {
            .int, .comptime_int => std.fmt.parseInt(T, s, 10) catch ConfigError.InvalidInt,
            .float, .comptime_float => std.fmt.parseFloat(T, s) catch ConfigError.InvalidFloat,
            .bool => utils.getBool(s) orelse return ConfigError.InvalidBool,
            .pointer => |ptr| switch (ptr.size) {
                .slice => if (ptr.child == u8) blk_string: {
                    var str = s;
                    if (str.len >= 6 and
                        (std.mem.startsWith(u8, str, "\"\"\"") and std.mem.endsWith(u8, str, "\"\"\"")))
                    {
                        // Multiline basic string: strip and unescape
                        str = str[3 .. str.len - 3];
                        break :blk_string str;
                    } else if (str.len >= 6 and
                        (std.mem.startsWith(u8, str, "'''") and std.mem.endsWith(u8, str, "'''")))
                    {
                        // Multiline literal string: strip, no unescape
                        str = str[3 .. str.len - 3];
                        break :blk_string try allocator.dupe(u8, str);
                    }
                    break :blk_string try allocator.dupe(u8, str);
                } else blk_array: {
                    // handle []T arrays like []u8, []bool, []f64, [][]const u8
                    if (s.len < 2 or s[0] != '[' or s[s.len - 1] != ']')
                        return ConfigError.InvalidPlaceholder;

                    const Item = ptr.child;
                    const item_info = @typeInfo(Item);
                    const content = std.mem.trim(u8, s[1 .. s.len - 1], " \t\r\n");

                    // choose correct list type
                    var list = std.ArrayList(Item).init(allocator);
                    if (content.len == 0) return try list.toOwnedSlice();

                    var it = std.mem.splitSequence(u8, content, ",");

                    while (it.next()) |raw| {
                        const part = std.mem.trim(u8, raw, " \t\r\n");

                        const value = switch (item_info) {
                            .int, .comptime_int => std.fmt.parseInt(Item, part, 10) catch return ConfigError.InvalidInt,
                            .float, .comptime_float => std.fmt.parseFloat(Item, part) catch return ConfigError.InvalidFloat,
                            .bool => utils.getBool(part) orelse return ConfigError.InvalidBool,
                            .pointer => |item_ptr| if (item_ptr.size == .slice and item_ptr.child == u8) blk_str_arr: {
                                const p = utils.stripQuotes(part);
                                const duped = try allocator.dupe(u8, p);
                                break :blk_str_arr duped;
                            } else return ConfigError.InvalidPlaceholder,
                            else => return ConfigError.InvalidPlaceholder,
                        };
                        try list.append(value);
                    }

                    break :blk_array try list.toOwnedSlice();
                },
                else => return ConfigError.InvalidPlaceholder,
            },
            else => {
                std.debug.print("Unsupported getAs type: {}\n", .{info});
                return ConfigError.InvalidPlaceholder;
            },
        };
    }

    /// Sets a value in the config map, overwriting any existing key.
    /// The key and value are duplicated using the config's allocator.
    ///
    /// Example:
    /// ```zig
    /// try cfg.set("port", "8080");
    /// ```
    pub fn set(self: *Config, key: []const u8, value: []const u8) !void {
        const key_copy: []u8 = try self.map.allocator.dupe(u8, key);
        const val_copy: []u8 = try self.map.allocator.dupe(u8, value);
        try self.map.put(key_copy, val_copy);
    }

    /// Checks if a key exists in the config.
    pub fn has(self: *Config, key: []const u8) bool {
        return self.map.contains(key);
    }

    /// Loads from the system environment into the Config;
    /// All variables from the process evironment are copied in.
    pub fn fromEnvMap(allocator: std.mem.Allocator) !Config {
        var config: Config = Config.init(allocator);
        errdefer config.deinit();
        var env_map = try std.process.getEnvMap(allocator);
        defer env_map.deinit();

        var it = env_map.iterator();
        while (it.next()) |entry| {
            const key: []u8 = try allocator.dupe(u8, entry.key_ptr.*);
            const val: []u8 = try allocator.dupe(u8, entry.value_ptr.*);
            try config.map.put(key, val);
        }

        return config;
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
        var config: Config = Config.init(allocator);
        errdefer config.deinit();

        var raw_values = std.StringHashMap([]const u8).init(allocator);
        defer {
            var it = raw_values.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            raw_values.deinit();
        }

        var dummy_buf = std.ArrayList(u8).init(allocator);
        defer dummy_buf.deinit();

        var lines = std.mem.splitSequence(u8, text, "\n");
        while (lines.next()) |line| {
            const trimmed: []const u8 = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') continue;

            const kv = try parseLine(trimmed);

            // Parse strings
            var single_line_iter = std.mem.splitSequence(u8, "", "\n");

            const parsed_value: []const u8 = try utils.parseString(kv.value, &single_line_iter, &dummy_buf, allocator);
            errdefer allocator.free(parsed_value);

            const key_copy: []u8 = try allocator.dupe(u8, kv.key);
            errdefer allocator.free(key_copy);
            try raw_values.put(key_copy, parsed_value);
        }

        // Resolve substitutions like ${VAR}, using env fallback
        var it = raw_values.iterator();
        while (it.next()) |entry| {
            const resolved: []const u8 = try utils.resolveVariables(
                entry.value_ptr.*,
                &config,
                allocator,
                null,
                entry.key_ptr.*,
                &raw_values,
            );
            errdefer allocator.free(resolved);

            const key_copy: []u8 = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key_copy);
            const val_copy: []u8 = try allocator.dupe(u8, resolved);
            errdefer allocator.free(val_copy);
            try config.map.put(key_copy, val_copy);

            allocator.free(resolved);
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
        var config: Config = Config.init(allocator);
        errdefer config.deinit();
        var current_section: ?[]const u8 = null;

        var lines = std.mem.splitSequence(u8, text, "\n");
        while (lines.next()) |line| {
            const trimmed: []const u8 = std.mem.trim(u8, line, "\t\r\n");
            if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') continue;

            if (trimmed.len < 3 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']')
                return ConfigError.ParseUnterminatedSection;

            // Handle section headers
            if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                const name: []const u8 = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
                if (name.len == 0) return ConfigError.ParseUnterminatedSection;
                current_section = name;
                continue;
            }

            // Parse key=value from the line
            const kv = try parseLine(trimmed);

            // Create full key as "section.key" or just "key"
            const full_key: []u8 = blk: {
                if (current_section) |sec| {
                    break :blk try std.fmt.allocPrint(allocator, "{s}.{s}", .{ sec, kv.key });
                } else {
                    break :blk try allocator.dupe(u8, kv.key);
                }
            };
            errdefer allocator.free(full_key);

            var dummy_lines = std.mem.splitSequence(u8, "", "\n");
            var dummy_buf = std.ArrayList(u8).init(allocator);
            defer dummy_buf.deinit();

            // Parse strings
            const parsed: []const u8 = try utils.parseString(kv.value, &dummy_lines, &dummy_buf, allocator);
            defer allocator.free(parsed);

            var resolved: []const u8 = parsed;
            const needs_resolve: bool = std.mem.indexOfScalar(u8, parsed, '$') != null;
            var resolved_owned: bool = false;

            if (needs_resolve) {
                resolved = try utils.resolveVariables(parsed, &config, allocator, null, full_key, null);
                resolved_owned = true;
            }
            defer if (resolved_owned) allocator.free(resolved);

            const val_copy: []u8 = try allocator.dupe(u8, resolved);
            errdefer allocator.free(val_copy);

            const gop = try config.map.getOrPut(full_key);
            if (gop.found_existing) {
                allocator.free(gop.key_ptr.*);
                allocator.free(gop.value_ptr.*);
            }
            gop.key_ptr.* = full_key;
            gop.value_ptr.* = val_copy;
        }

        return config;
    }

    /// Loads and parses a `.toml` file into a Config.
    pub fn loadTomlFile(path: []const u8, allocator: std.mem.Allocator) !Config {
        const file = try std.fs.cwd().openFile(path, .{}) catch return ConfigError.IoError;
        defer file.close();

        const stat = try file.stat();
        const content = try allocator.alloc(u8, stat.size) catch return ConfigError.IoError;

        _ = try file.readAll(content);
        return try parseToml(content, allocator);
    }

    /// Parses TOML content into a Config.
    /// Currently supports:
    /// - Nested sections via `[section]` and `[section.sub]`
    /// - Key-value pairs with basic types: strings, numbers, booleans
    /// - Arrays (including multiline)
    /// - Inline tables: `key = {a=1, b=2}` accessible via `key.a`
    /// - Mid-line comments
    /// - Multiline strings (triple-quoted)
    /// Fully unescapes strings and flattens all data into a dot-separated key map.
    pub fn parseToml(text: []const u8, allocator: std.mem.Allocator) ConfigError!Config {
        var config: Config = Config.init(allocator);
        errdefer config.deinit();
        var current_prefix: []const u8 = "";

        var multiline_buf = std.ArrayList(u8).init(allocator);
        defer multiline_buf.deinit();

        var table_arrays = std.StringHashMap(usize).init(allocator);
        defer table_arrays.deinit();

        var lines = std.mem.splitSequence(u8, text, "\n");
        while (lines.next()) |line| {
            const trimmed: []const u8 = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            const comment_pos: ?usize = std.mem.indexOfScalar(u8, trimmed, '#');
            const line_clean = if (comment_pos) |i|
                std.mem.trim(u8, trimmed[0..i], " \t\r\n")
            else
                trimmed;
            if (line_clean.len == 0) continue;

            // Section: [[array]]
            if (std.mem.startsWith(u8, line_clean, "[[") and std.mem.endsWith(u8, line_clean, "]]")) {
                const table_key: []const u8 = std.mem.trim(u8, line_clean[2 .. line_clean.len - 2], " ");
                const count: usize = table_arrays.get(table_key) orelse 0;
                try table_arrays.put(table_key, count + 1);

                if (current_prefix.len > 0) allocator.free(current_prefix);
                current_prefix = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ table_key, count });
                continue;
            } else if (line_clean[0] == '[' and line_clean[line_clean.len - 1] == ']') {
                if (current_prefix.len > 0) allocator.free(current_prefix);
                current_prefix = try allocator.dupe(u8, std.mem.trim(u8, line_clean[1 .. line_clean.len - 1], " "));
                continue;
            }

            const eq_idx: usize = std.mem.indexOfScalar(u8, line_clean, '=') orelse continue;
            const raw_key: []const u8 = std.mem.trim(u8, line_clean[0..eq_idx], " \t\r\n");
            const raw_val: []const u8 = std.mem.trim(u8, line_clean[eq_idx + 1 ..], " \t\r\n");

            const full_key: []u8 = if (current_prefix.len > 0)
                try std.fmt.allocPrint(allocator, "{s}.{s}", .{ current_prefix, raw_key })
            else
                try allocator.dupe(u8, raw_key);
            errdefer allocator.free(full_key);

            // Handle strings
            if (raw_val.len >= 1 and (raw_val[0] == '"' or raw_val[0] == '\'' or
                std.mem.startsWith(u8, raw_val, "\"\"\"") or std.mem.startsWith(u8, raw_val, "'''")))
            {
                const parsed: []const u8 = try utils.parseString(raw_val, &lines, &multiline_buf, allocator);
                defer allocator.free(parsed);

                var resolved: []const u8 = parsed;
                const needs_resolve: bool = std.mem.indexOfScalar(u8, parsed, '$') != null;
                var resolved_owned: bool = false;

                if (needs_resolve) {
                    resolved = try utils.resolveVariables(parsed, &config, allocator, null, full_key, null);
                    resolved_owned = true;
                }
                defer if (resolved_owned) allocator.free(resolved);

                const val_copy: []u8 = try allocator.dupe(u8, resolved);
                errdefer allocator.free(val_copy);

                if (config.map.getEntry(full_key)) |entry_ptr| {
                    allocator.free(entry_ptr.key_ptr.*);
                    allocator.free(entry_ptr.value_ptr.*);
                    _ = config.map.remove(full_key);
                }
                try config.map.put(full_key, val_copy);
                continue;
            }

            // Handle bool
            if (utils.getBool(raw_val)) |bool_val| {
                const bool_str = if (bool_val) "true" else "false";
                const val_copy = try allocator.dupe(u8, bool_str);
                errdefer allocator.free(val_copy);

                if (config.map.getEntry(full_key)) |entry_ptr| {
                    allocator.free(entry_ptr.key_ptr.*);
                    allocator.free(entry_ptr.value_ptr.*);
                    _ = config.map.remove(full_key);
                }
                try config.map.put(full_key, val_copy);
                continue;
            }

            // Handle int / float
            if (std.fmt.parseInt(i64, raw_val, 10) catch null) |_| {
                const val_copy = try allocator.dupe(u8, raw_val);
                errdefer allocator.free(val_copy);

                if (config.map.getEntry(full_key)) |entry_ptr| {
                    allocator.free(entry_ptr.key_ptr.*);
                    allocator.free(entry_ptr.value_ptr.*);
                    _ = config.map.remove(full_key);
                }
                try config.map.put(full_key, val_copy);
                continue;
            } else if (std.fmt.parseFloat(f64, raw_val) catch null) |_| {
                const val_copy = try allocator.dupe(u8, raw_val);
                errdefer allocator.free(val_copy);

                if (config.map.getEntry(full_key)) |entry_ptr| {
                    allocator.free(entry_ptr.key_ptr.*);
                    allocator.free(entry_ptr.value_ptr.*);
                    _ = config.map.remove(full_key);
                }
                try config.map.put(full_key, val_copy);
                continue;
            }

            // Handle array
            if (raw_val[0] == '[') {
                const parsed_list = try utils.parseList(&config, raw_val, &lines, &multiline_buf, full_key, allocator);
                errdefer allocator.free(parsed_list);

                if (config.map.getEntry(full_key)) |entry_ptr| {
                    allocator.free(entry_ptr.key_ptr.*);
                    allocator.free(entry_ptr.value_ptr.*);
                    _ = config.map.remove(full_key);
                }
                try config.map.put(full_key, parsed_list);
                continue;
            }

            // Handle inline table
            if (raw_val[0] == '{') {
                const parsed_table: []const u8 = try utils.parseTable(&config, raw_val, &lines, &multiline_buf, full_key, allocator);
                errdefer allocator.free(parsed_table);

                if (config.map.getEntry(full_key)) |entry_ptr| {
                    allocator.free(entry_ptr.key_ptr.*);
                    allocator.free(entry_ptr.value_ptr.*);
                    _ = config.map.remove(full_key);
                }
                try config.map.put(full_key, parsed_table);
                continue;
            }

            // Fallback: try parsing as string
            const parsed = try utils.parseString(raw_val, &lines, &multiline_buf, allocator);
            defer allocator.free(parsed);

            var resolved: []const u8 = parsed;
            const needs_resolve = std.mem.indexOfScalar(u8, parsed, '$') != null;
            var resolved_owned = false;

            if (needs_resolve) {
                resolved = try utils.resolveVariables(parsed, &config, allocator, null, full_key, null);
                resolved_owned = true;
            }
            defer if (resolved_owned) allocator.free(resolved);

            const val_copy = try allocator.dupe(u8, resolved);
            errdefer allocator.free(val_copy);

            if (config.map.getEntry(full_key)) |entry_ptr| {
                allocator.free(entry_ptr.key_ptr.*);
                allocator.free(entry_ptr.value_ptr.*);
                _ = config.map.remove(full_key);
            }
            try config.map.put(full_key, val_copy);
        }

        if (current_prefix.len > 0) allocator.free(current_prefix);
        return config;
    }

    /// Parses a single `KEY=VALUE` line into a key-value struct.
    /// - Strips leading/trailing whitespace around both key and value.
    /// - Unquotes the value if quoted (e.g. `"abc"` → `abc`)
    ///
    /// Errors:
    /// - `ParseInvalidLine` if no `=` is found
    /// - `InvalidKey` if the key is empty
    fn parseLine(line: []const u8) !struct { key: []const u8, value: []const u8 } {
        const eq_index: usize = std.mem.indexOf(u8, line, "=") orelse return ConfigError.ParseInvalidLine;
        const key: []const u8 = std.mem.trim(u8, line[0..eq_index], " \t");
        var value: []const u8 = std.mem.trim(u8, line[eq_index + 1 ..], " \t");

        value = utils.stripQuotes(value);

        if (key.len == 0) return ConfigError.InvalidKey;

        return .{ .key = key, .value = value };
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
        var key: [][]const u8 = try allocator.alloc([]const u8, self.map.count());
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
        var result: Config = Config.init(allocator);
        const prefix: []u8 = try std.fmt.allocPrint(allocator, "{s}.", .{section});
        defer allocator.free(prefix);

        var it = self.map.iterator();
        var found: bool = false;

        while (it.next()) |entry| {
            const key: []const u8 = entry.key_ptr.*;
            if (std.mem.startsWith(u8, key, prefix)) {
                const stripped: []const u8 = key[prefix.len..];
                const k_copy: []u8 = try allocator.dupe(u8, stripped);
                const v_copy: []u8 = try allocator.dupe(u8, entry.value_ptr.*);

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

    /// Writes all config entries to a `.env`-style file.
    /// Each line is formatted as `KEY=value`, with no quoting or escaping.
    ///
    /// - Keys and values are written exactly as stored.
    /// - Lines are written in insertion order.
    /// - Keys with dots (e.g., `db.user`) are written as-is.
    ///
    /// Overwrites the file at the given `path`.
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
            const full_key: []const u8 = entry.key_ptr.*;
            const val: []const u8 = entry.value_ptr.*;
            const dot: usize = std.mem.indexOfScalar(u8, full_key, '.') orelse {
                // Keys without section go at the top
                try writer.print("{s} = {s}\n", .{ full_key, val });
                continue;
            };

            const section: []const u8 = full_key[0..dot];
            const key: []const u8 = full_key[dot + 1 ..];

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

    /// Writes all config entries to a `.toml`-style file.
    ///
    /// - Keys without a section (no dot `.` in the name) are written first.
    /// - Keys with a `section.key` format are grouped under `[section]` headers.
    /// - Values are written as double-quoted TOML strings, with proper escaping for:
    ///   - `"` as `\"`
    ///   - `\` as `\\`
    ///   - control characters (like newline, tab, Unicode, etc.)
    ///
    /// Example output:
    /// ```toml
    /// host = "localhost"
    /// port = "8080"
    ///
    /// [db]
    /// user = "admin"
    /// pass = "p@ss\"w\\rd"
    /// ```
    ///
    /// Overwrites the file at `path`.
    ///
    /// Note:
    /// - All values are emitted as double-quoted strings, even numbers or booleans.
    /// - Unicode and escape sequences are properly encoded using TOML-safe escaping.
    /// - Keys are grouped by section if in the form `section.key`, and sorted by section/key.
    pub fn writeTomlFile(cfg: *Config, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        const writer = file.writer();

        var sorted_keys = std.ArrayList([]const u8).init(cfg.map.allocator);
        defer sorted_keys.deinit();

        var it = cfg.map.iterator();
        while (it.next()) |entry| {
            try sorted_keys.append(entry.key_ptr.*);
        }

        // * 1. First write all top-level keys (no section)
        for (sorted_keys.items) |key| {
            const sep_index: ?usize = std.mem.lastIndexOfScalar(u8, key, '.');
            if (sep_index != null) continue;

            const val: []const u8 = cfg.map.get(key).?;
            const escaped: []const u8 = try utils.escapeString(val, cfg.map.allocator);
            defer cfg.map.allocator.free(escaped);

            try writer.print("{s} = \"{s}\"\n", .{ key, escaped });
        }

        // * 2. Then write sectioned keys grouped under [section]
        var current_section: ?[]const u8 = null;
        for (sorted_keys.items) |key| {
            const sep_index: ?usize = std.mem.lastIndexOfScalar(u8, key, '.');
            if (sep_index == null) continue;

            const section = key[0..sep_index.?];
            const subkey = key[sep_index.? + 1 ..];
            const val: []const u8 = cfg.map.get(key).?;

            if (!std.mem.eql(u8, current_section orelse "", section)) {
                current_section = section;
                try writer.print("\n[{s}]\n", .{section});
            }

            const escaped: []const u8 = try utils.escapeString(val, cfg.map.allocator);
            defer cfg.map.allocator.free(escaped);

            try writer.print("{s} = \"{s}\"\n", .{ subkey, escaped });
        }
    }

    /// Converts the config into an `EnvMap`, suitable for use with subprocesses.
    pub fn toEnvMap(self: *Config, allocator: std.mem.Allocator) !std.process.EnvMap {
        var env_map = std.process.EnvMap.init(allocator);
        errdefer env_map.deinit();

        var it = self.map.iterator();
        while (it.next()) |entry| {
            try env_map.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        return env_map;
    }

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
    pub fn merge(self: *Config, other: ?*Config, allocator: std.mem.Allocator, behavior: MergeBehavior) !void {
        if (other) |o| {
            var it = o.map.iterator();
            while (it.next()) |entry| {
                try utils.insertEntry(self, entry.key_ptr.*, entry.value_ptr.*, behavior, allocator);
            }
        } else {
            // Merge from system environment
            var env_map = try std.process.getEnvMap(allocator);
            defer env_map.deinit();

            var it = env_map.iterator();
            while (it.next()) |entry| {
                try utils.insertEntry(self, entry.key_ptr.*, entry.value_ptr.*, behavior, allocator);
            }
        }
    }

    /// Loads a config from an in-memory buffer.
    /// Accepts format `.env`, `.ini` or `.toml`.
    pub fn loadFromBuffer(text: []const u8, format: Format, allocator: std.mem.Allocator) !Config {
        return switch (format) {
            .env => Config.parseEnv(text, allocator),
            .ini => Config.parseIni(text, allocator),
            .toml => Config.parseToml(text, allocator),
        };
    }
};
