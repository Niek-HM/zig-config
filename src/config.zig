const std = @import("std");
const utils = @import("utils.zig");

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    bool: bool,
    list: []Value,
    table: *Table,

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => allocator.free(self.string),
            .list => {
                for (self.list) |*v| v.deinit(allocator);
                allocator.free(self.list);
            },
            .table => {
                var it = self.table.iterator();
                while (it.next()) |kv| {
                    allocator.free(kv.key_ptr.*);
                    kv.value_ptr.*.deinit(allocator);
                }
                self.table.deinit();
                allocator.destroy(self.table);
            },
            else => {}, // int, float, bool: no-op
        }
    }
};

pub fn OwnedValue(comptime T: type) type {
    return struct {
        value: T,
        allocator: std.mem.Allocator,
        owns_memory: bool = true,

        pub fn init(value: T, allocator: std.mem.Allocator) !@This() {
            const Self = @This();

            switch (@typeInfo(T)) {
                .pointer => |p| switch (@typeInfo(p.child)) {
                    .array => return error.Unsupported,

                    // Case: [][]const u8
                    .pointer => {
                        const outer = value;
                        const out = try allocator.alloc([]const u8, outer.len);
                        for (outer, 0..) |item, i| {
                            out[i] = try allocator.dupe(u8, item);
                        }
                        return Self{
                            .value = out,
                            .allocator = allocator,
                            .owns_memory = true,
                        };
                    },

                    // Case: []const u8
                    .int, .bool, .float, .vector, .error_union, .optional, .error_set, .comptime_int, .comptime_float, .undefined, .null, .enum_literal => {
                        const out = try allocator.dupe(u8, value);
                        return Self{
                            .value = out,
                            .allocator = allocator,
                            .owns_memory = true,
                        };
                    },

                    else => return error.Unsupported,
                },
                else => {
                    // Basic types like i64, bool
                    return Self{
                        .value = value,
                        .allocator = allocator,
                        .owns_memory = true, // TODO: Might need to be false;
                    };
                },
            }
        }

        pub fn deinit(self: @This()) void {
            if (!self.owns_memory) return;

            switch (@typeInfo(T)) {
                .pointer => |out| {
                    if (out.size != .slice) return;

                    const child_info = @typeInfo(out.child);
                    switch (child_info) {
                        .pointer => {
                            // Case: [][]const u8
                            for (self.value) |item| {
                                self.allocator.free(item);
                            }
                            self.allocator.free(self.value);
                        },
                        else => {
                            // Case: []const u8
                            self.allocator.free(self.value);
                        },
                    }
                },
                else => {}, // e.g. ints, bools — nothing to free
            }
        }
    };
}

pub const Table = std.StringHashMap(Value);

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
    InvalidType,
    InvalidCharacter,
    InvalidValue,
    UnknownVariable,
    KeyConflict,
    IoError,
    ParseError,
    ParseInvalidLine,
    ParseUnterminatedSection,
    ParseInvalidFormat,
    CircularReference,
    OutOfMemory,
    TypeMismatch,
};

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
    pub const Version = "0.2.0";

    /// A string-to-string hash map storing the entries.
    map: std.StringHashMap(Value),
    pub const Format = enum { env, ini, toml };

    pub const MergeBehavior = enum {
        overwrite,
        skip_existing,
        error_on_conflict,
    };

    /// Creates a new empty config with the given allocator.
    pub fn init(allocator: std.mem.Allocator) Config {
        return Config{
            .map = std.StringHashMap(Value).init(allocator),
        };
    }

    /// Frees all memory used by the config map.
    pub fn deinit(self: *Config) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.map.allocator);
            self.map.allocator.free(entry.key_ptr.*);
        }
        self.map.deinit();
    }

    /// Returns the raw (unparsed) string value for the given key.
    /// This is the exact value as stored internally (after substitution),
    /// including quotes or escape characters if present.
    ///
    /// Returns:
    /// - `null` if the key is not found
    pub fn get(self: *Config, key: []const u8) ?Value {
        // 1. Try direct map lookup
        if (self.map.get(key)) |val| return val;

        // 2. Try fallback: lookup by prefix match and descent
        const k = self.keys(self.map.allocator) catch return null;
        defer self.map.allocator.free(k);

        for (k) |candidate| {
            if (std.mem.startsWith(u8, key, candidate) and key.len > candidate.len and key[candidate.len] == '.') {
                const suffix = key[(candidate.len + 1)..];
                const val = self.map.get(candidate) orelse continue;
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

    pub fn getString(self: *Config, key: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        const val = self.get(key) orelse return ConfigError.Missing;
        return switch (val) {
            .string => |s| try allocator.dupe(u8, s),
            else => return ConfigError.InvalidPlaceholder,
        };
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
    pub fn getAs(self: *Config, comptime T: type, key: []const u8, allocator: std.mem.Allocator) !OwnedValue(T) {
        const val = self.get(key) orelse return ConfigError.Missing;

        const result = try valueToType(T, val, allocator);
        const final = try OwnedValue(T).init(result, allocator);

        switch (@typeInfo(T)) { // TODO: clean up free of result somehow
            .pointer => |ptr| {
                if (ptr.child == u8) {
                    allocator.free(result); // free []const u8
                } else if (ptr.child == []const u8) {
                    for (result) |item| allocator.free(item); // free each inner []const u8
                    allocator.free(result); // free outer [][]const u8
                } else {
                    @compileError("Don't know how to free pointer type: " ++ @typeName(T));
                }
            },
            else => {},
        }
        return final;
    }

    fn valueFromString(comptime T: type, s: []const u8) !T {
        if (T == []const u8) {
            return s;
        } else if (@typeInfo(T) == .bool) {
            return utils.getBool(s) orelse return ConfigError.InvalidBool;
        } else if (@typeInfo(T) == .float) {
            return std.fmt.parseFloat(T, s) catch return ConfigError.InvalidFloat;
        } else if (@typeInfo(T) == .int or @typeInfo(T) == .comptime_int) {
            return std.fmt.parseInt(T, s, 10) catch return ConfigError.InvalidInt;
        } else {
            return ConfigError.InvalidType;
        }
    }

    fn valueToType(comptime T: type, val: Value, allocator: std.mem.Allocator) !T {
        return switch (val) {
            .string => |s| {
                if (T == [][]const u8) {
                    var dummy_lines = std.mem.splitSequence(u8, "", "\n");
                    var dummy_buf = std.ArrayList(u8).init(allocator);
                    defer dummy_buf.deinit();

                    const parsed = try utils.parseList(s, &dummy_lines, &dummy_buf, allocator);
                    errdefer {
                        for (parsed) |*val_p| {
                            val_p.deinit(allocator);
                        }
                        allocator.free(parsed);
                    }

                    var result = try allocator.alloc([]const u8, parsed.len);
                    for (parsed, 0..) |v, i| {
                        if (v != .string) return ConfigError.InvalidType;
                        const str_dupe = try allocator.dupe(u8, v.string);
                        errdefer allocator.free(str_dupe);
                        result[i] = str_dupe;
                    }

                    for (parsed) |*val_p| val_p.deinit(allocator);
                    allocator.free(parsed);

                    return result;
                } else if (T == []const u8) {
                    return try allocator.dupe(u8, s);
                } else {
                    return try valueFromString(T, s);
                }
            },
            .int => |i| {
                if (@typeInfo(T) == .int or @typeInfo(T) == .comptime_int) {
                    if (i >= std.math.minInt(T) and i <= std.math.maxInt(T)) {
                        return @intCast(i);
                    } else {
                        return ConfigError.InvalidInt;
                    }
                } else if (@typeInfo(T) == .float) {
                    return @floatFromInt(i);
                } else {
                    return ConfigError.InvalidType;
                }
            },
            .float => |f| {
                if (@typeInfo(T) == .float) {
                    return @floatCast(f);
                } else if (@typeInfo(T) == .int or @typeInfo(T) == .comptime_int) {
                    return @as(T, @intFromFloat(f));
                } else {
                    return ConfigError.InvalidType;
                }
            },
            .bool => |b| if (T == bool) b else ConfigError.InvalidType,
            .list => |l| {
                const ti = @typeInfo(T);
                if (ti != .pointer) return ConfigError.InvalidType;

                const child_info = @typeInfo(ti.pointer.child);
                if (child_info != .array and child_info != .pointer) return ConfigError.InvalidType;

                const Elem = ti.pointer.child;
                var result = try allocator.alloc(Elem, l.len);

                for (l, 0..) |item, i| {
                    result[i] = try valueToType(Elem, item, allocator);
                }

                return result;
            },
            .table => |raw| {
                if (@typeInfo(T) != .@"struct") return ConfigError.InvalidType;
                var result: T = undefined;
                inline for (@typeInfo(T).@"struct".fields) |field| {
                    const field_val = raw.get(field.name) orelse return ConfigError.Missing;
                    @field(result, field.name) = try valueToType(field.field_type, field_val, allocator);
                }
                return result;
            },
            //else => return ConfigError.InvalidType,
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
        try self.map.put(key_copy, .{ .string = val_copy });
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
            errdefer allocator.free(key);
            const val: []u8 = try allocator.dupe(u8, entry.value_ptr.*);
            errdefer allocator.free(val);

            try config.map.put(key, .{ .string = val });
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

        var raw_values = std.StringHashMap(Value).init(allocator);
        defer {
            var it = raw_values.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*); // Free the duplicated key
                entry.value_ptr.*.deinit(allocator); // Free nested content in Value
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

            const parsed: []const u8 = try utils.parseString(kv.value, &single_line_iter, &dummy_buf, allocator);
            defer allocator.free(parsed);

            const val_copy = try allocator.dupe(u8, parsed);

            const key_copy: []u8 = try allocator.dupe(u8, kv.key);
            errdefer allocator.free(key_copy);

            try raw_values.put(key_copy, .{ .string = val_copy });
        }

        // Resolve substitutions like ${VAR}, using env fallback
        var it = raw_values.iterator();
        while (it.next()) |entry| {
            const resolved: []const u8 = try utils.resolveVariables(
                entry.value_ptr.string,
                &config,
                allocator,
                null,
                entry.key_ptr.*,
                &raw_values,
            );
            errdefer allocator.free(resolved);

            const key_copy: []u8 = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key_copy);

            try config.map.put(key_copy, .{ .string = resolved });
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
            //errdefer allocator.free(full_key);

            var dummy_lines = std.mem.splitSequence(u8, "", "\n");
            var dummy_buf = std.ArrayList(u8).init(allocator);
            defer dummy_buf.deinit();

            // Parse strings
            const parsed = try utils.parseString(kv.value, &dummy_lines, &dummy_buf, allocator);
            //defer allocator.free(parsed);
            const needs_resolve = std.mem.indexOfScalar(u8, parsed, '$') != null;

            const resolved = if (needs_resolve)
                try utils.resolveVariables(parsed, &config, allocator, null, full_key, null)
            else
                parsed;
            errdefer if (needs_resolve) allocator.free(resolved);
            // TODO: Maybe need to remove parsed if resolve runs?

            try config.map.put(full_key, .{ .string = resolved });
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
                const array_key = std.mem.trim(u8, line_clean[2 .. line_clean.len - 2], " ");
                const key_copy = try allocator.dupe(u8, array_key);
                errdefer allocator.free(key_copy);

                var list_val: Value = blk: {
                    if (config.map.get(array_key)) |existing| {
                        if (existing == .list) break :blk existing;
                        return ConfigError.ParseError;
                    } else {
                        const new_list = try allocator.alloc(Value, 0);
                        break :blk .{ .list = new_list };
                    }
                };

                const new_table = try allocator.create(Table);
                new_table.* = Table.init(allocator);

                try config.map.put(array_key, list_val); // insert or update

                // Push new table into the list
                {
                    const old_list = list_val.list;
                    const grown = try allocator.realloc(old_list, old_list.len + 1);
                    grown[old_list.len] = .{ .table = new_table };
                    list_val.list = grown;

                    try config.map.put(key_copy, list_val);
                }

                if (current_prefix.len > 0) allocator.free(current_prefix);
                current_prefix = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ array_key, list_val.list.len - 1 });

                continue;
            } else if (line_clean[0] == '[' and line_clean[line_clean.len - 1] == ']') {
                if (current_prefix.len > 0) allocator.free(current_prefix);
                current_prefix = try allocator.dupe(u8, std.mem.trim(u8, line_clean[1 .. line_clean.len - 1], " "));
                errdefer allocator.free(current_prefix);
                continue;
            }

            const eq_idx: usize = std.mem.indexOfScalar(u8, line_clean, '=') orelse continue;
            const raw_key: []const u8 = std.mem.trim(u8, line_clean[0..eq_idx], " \t\r\n");
            const raw_val: []const u8 = std.mem.trim(u8, line_clean[eq_idx + 1 ..], " \t\r\n");

            const full_key: []u8 = if (current_prefix.len > 0)
                try std.fmt.allocPrint(allocator, "{s}.{s}", .{ current_prefix, raw_key })
            else
                try allocator.dupe(u8, raw_key);
            defer allocator.free(full_key);

            // Handle strings
            if (raw_val.len >= 1 and (raw_val[0] == '"' or raw_val[0] == '\'' or
                std.mem.startsWith(u8, raw_val, "\"\"\"") or std.mem.startsWith(u8, raw_val, "'''")))
            {
                const parsed: []const u8 = try utils.parseString(raw_val, &lines, &multiline_buf, allocator);
                defer allocator.free(parsed);

                const needs_resolve: bool = std.mem.indexOfScalar(u8, parsed, '$') != null;

                const resolved: []const u8 = if (needs_resolve)
                    try utils.resolveVariables(parsed, &config, allocator, null, full_key, null)
                else
                    try allocator.dupe(u8, parsed);
                errdefer allocator.free(resolved);

                if (config.map.getEntry(full_key)) |entry_ptr| {
                    allocator.free(entry_ptr.key_ptr.*);
                    entry_ptr.value_ptr.*.deinit(allocator);
                    _ = config.map.remove(full_key);
                }

                const key_copy = try allocator.dupe(u8, full_key);
                errdefer allocator.free(key_copy);

                try config.map.put(key_copy, .{ .string = resolved });
                continue;
            }

            // Handle bool
            if (utils.getBool(raw_val)) |bool_val| {
                const key_copy = try allocator.dupe(u8, full_key);
                errdefer allocator.free(key_copy);
                try config.map.put(key_copy, .{ .bool = bool_val });
                continue;
            }

            // Handle int
            if (std.fmt.parseInt(i64, raw_val, 10) catch null) |parsed_int| {
                const key_copy = try allocator.dupe(u8, full_key);
                errdefer allocator.free(key_copy);
                try config.map.put(key_copy, .{ .int = parsed_int });
                continue;
            }

            // Handle float
            if (std.fmt.parseFloat(f64, raw_val) catch null) |parsed_float| {
                const key_copy = try allocator.dupe(u8, full_key);
                errdefer allocator.free(key_copy);
                try config.map.put(key_copy, .{ .float = parsed_float });
                continue;
            }

            // Handle array
            if (raw_val[0] == '[') {
                const parsed_list = try utils.parseList(raw_val, &lines, &multiline_buf, allocator);
                const key_copy = try allocator.dupe(u8, full_key);
                errdefer allocator.free(key_copy);
                try config.map.put(key_copy, .{ .list = parsed_list });
                continue;
            }

            // Handle inline table
            if (raw_val[0] == '{') {
                const parsed_table = try utils.parseTable(raw_val, &lines, &multiline_buf, allocator);
                const boxed = try allocator.create(Table);
                boxed.* = parsed_table;

                const key_copy = try allocator.dupe(u8, full_key);
                errdefer allocator.free(key_copy);
                try config.map.put(key_copy, .{ .table = boxed });
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
            errdefer allocator.free(resolved);

            const key_copy = try allocator.dupe(u8, full_key);
            errdefer allocator.free(key_copy);

            try config.map.put(key_copy, .{ .string = resolved });
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
            std.debug.print("{s} = {any}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
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
                const val_copy = try deepCloneValue(original, allocator);

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
            const val_str = try utils.valueToString(entry.value_ptr.*, self.map.allocator);
            defer self.map.allocator.free(val_str);
            try writer.print("{s}={s}\n", .{ entry.key_ptr.*, val_str });
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
            const val_str = try utils.valueToString(entry.value_ptr.*, self.map.allocator);
            defer self.map.allocator.free(val_str);
            const dot: usize = std.mem.indexOfScalar(u8, full_key, '.') orelse {
                // Keys without section go at the top
                try writer.print("{s} = {s}\n", .{ full_key, val_str });
                continue;
            };

            const section: []const u8 = full_key[0..dot];
            const key: []const u8 = full_key[dot + 1 ..];

            const entry_val = IniEntry{
                .key = key,
                .value = val_str,
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

            const entry = cfg.map.get(key) orelse return ConfigError.Missing;
            if (entry != .string)
                return ConfigError.InvalidType;

            const val: []const u8 = entry.string;

            try writer.print("{s} = ", .{key});
            try utils.writeTomlValue(.{ .string = val }, writer, cfg.map.allocator);
            try writer.writeAll("\n");
        }

        // * 2. Then write sectioned keys grouped under [section]
        var current_section: ?[]const u8 = null;
        for (sorted_keys.items) |key| {
            const sep_index = std.mem.lastIndexOfScalar(u8, key, '.');
            if (sep_index == null) continue;

            const section = key[0..sep_index.?];
            const subkey = key[sep_index.? + 1 ..];

            if (!std.mem.eql(u8, current_section orelse "", section)) {
                current_section = section;
                try writer.print("\n[{s}]\n", .{section});
            }

            const entry = cfg.map.get(key) orelse return ConfigError.Missing;
            if (entry != .string)
                return ConfigError.InvalidType;

            const val: []const u8 = entry.string;
            try writer.print("{s} = ", .{subkey});
            try utils.writeTomlValue(.{ .string = val }, writer, cfg.map.allocator);
            try writer.writeAll("\n");
        }
    }

    /// Converts the config into an `EnvMap`, suitable for use with subprocesses.
    pub fn toEnvMap(self: *Config, allocator: std.mem.Allocator) !std.process.EnvMap {
        var env_map = std.process.EnvMap.init(allocator);
        errdefer env_map.deinit();

        var it = self.map.iterator();
        while (it.next()) |entry| {
            const val_str = try utils.valueToString(entry.value_ptr.*, self.map.allocator);
            defer self.map.allocator.free(val_str);
            try env_map.put(entry.key_ptr.*, val_str);
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
    pub fn merge(
        a: *const Config,
        b: *const Config,
        allocator: std.mem.Allocator,
        behavior: MergeBehavior,
    ) !Config {
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
                        const val_copy = try deepCloneValue(&val_b, allocator);
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
            const val_copy = try deepCloneValue(entry.value_ptr, allocator);
            try result.map.put(key_copy, val_copy);
            try seen.put(key, {});
        }

        // Add remaining b-only entries
        var it_b = b.map.iterator();
        while (it_b.next()) |entry| {
            const key = entry.key_ptr.*;
            if (seen.contains(key)) continue;

            const key_copy = try allocator.dupe(u8, key);
            const val_copy = try deepCloneValue(entry.value_ptr, allocator);
            try result.map.put(key_copy, val_copy);
        }

        return result;
    }

    // TODO: PUT IN UTILS
    fn deepCopyValue(val: *Value, allocator: std.mem.Allocator) anyerror!void {
        switch (val.*) {
            .string => {
                const val_str = val.string;
                const tmp_copy = try allocator.dupe(u8, val_str);
                errdefer allocator.free(tmp_copy);
                val.* = .{ .string = tmp_copy };
            },
            .list => {
                const orig = val.list;
                const new_list = try allocator.alloc(Value, orig.len);
                for (orig, 0..) |*v, i| {
                    new_list[i] = try deepCloneValue(v, allocator);
                }
                val.* = .{ .list = new_list };
            },
            .table => {
                const orig = val.table;
                const new_table = try allocator.create(Table);
                new_table.* = Table.init(allocator);
                var it = orig.iterator();
                while (it.next()) |e| {
                    const k = try allocator.dupe(u8, e.key_ptr.*);
                    const v_copy = try deepCloneValue(e.value_ptr, allocator);
                    try new_table.put(k, v_copy);
                }
                val.* = .{ .table = new_table };
            },
            else => {}, // int, float, bool – nothing to copy
        }
    }

    fn deepCloneValue(src: *const Value, allocator: std.mem.Allocator) anyerror!Value {
        return switch (src.*) {
            .string => |s| blk: {
                const copy = try allocator.dupe(u8, s);
                errdefer allocator.free(copy);
                break :blk .{ .string = copy };
            },
            .list => |orig| blk: {
                const new_list = try allocator.alloc(Value, orig.len);
                for (orig, 0..) |*v, i| {
                    new_list[i] = try deepCloneValue(v, allocator);
                }
                break :blk .{ .list = new_list };
            },
            .table => |orig| blk: {
                const new_table = try allocator.create(Table);
                new_table.* = Table.init(allocator);
                var it = orig.iterator();
                while (it.next()) |e| {
                    const k = try allocator.dupe(u8, e.key_ptr.*);
                    errdefer allocator.free(k);
                    const v_copy = try deepCloneValue(e.value_ptr, allocator);
                    try new_table.put(k, v_copy);
                }
                break :blk .{ .table = new_table };
            },
            .int => |v| .{ .int = v },
            .float => |v| .{ .float = v },
            .bool => |v| .{ .bool = v },
        };
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
