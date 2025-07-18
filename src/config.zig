const std = @import("std");
const utils = @import("utils.zig");
const accessors = @import("accessors.zig");
const merge = @import("merge.zig");
const values = @import("value.zig");

const parser = @import("parser/mod.zig");
const writers = @import("writer/mod.zig");

const Value = @import("value.zig").Value;
const OwnedValue = @import("value.zig").OwnedValue;
const valueToString = @import("value.zig").valueToString;
const ConfigError = @import("errors.zig").ConfigError;

const parse_env = @import("parser/env.zig");
const parse_ini = @import("parser/ini.zig");
const parse_toml = @import("parser/toml.zig");

/// Provides `.env`, `.ini`, and `.toml` configuration parsing and typed access utilities.
///
/// This module allows you to:
/// - Load and merge config from `.env`, `.ini`, `.toml`, or system environment
/// - Access values as strings, integers, floats, booleans, lists, or tables
/// - Perform variable substitution and error-safe parsing
/// - Serialize back to `.env`, `.ini`, or EnvMap for subprocesses
pub const Config = struct {
    pub const Version = "0.3.0";

    /// A string-to-string hash map storing the entries.
    map: std.StringHashMap(Value),

    /// Used to indicate which file format to parse when loading from buffer
    pub const Format = enum { env, ini, toml };

    // Re-export functions
    pub const parseEnv = parse_env.parseEnv;
    pub const parseIni = parse_ini.parseIni;
    pub const parseToml = parse_toml.parseToml;

    pub const writeTomlFile = writers.writeToml;
    pub const writeEnvFile = writers.writeEnv;
    pub const writeIniFile = writers.writeIni;

    // Attach namespaces
    pub usingnamespace accessors;
    pub usingnamespace merge;
    pub usingnamespace values;
    pub usingnamespace utils;

    /// Creates a new empty config with the given allocator.
    pub fn init(allocator: std.mem.Allocator) Config {
        return Config{
            .map = std.StringHashMap(Value).init(allocator),
        };
    }

    /// Frees all memory owned by this Config, including keys and values.
    pub fn deinit(self: *Config) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.map.allocator);
            self.map.allocator.free(entry.key_ptr.*);
        }
        self.map.deinit();
    }

    /// Sets a string value in the config map (key and value are copied).
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

    /// Loads all current process environment variables into a Config instance.
    /// Keys and values are duplicated using the given allocator.
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

    /// Loads a file from disk and parses it as `.env` format.
    ///
    /// Lines like `KEY=value` are supported; blank lines and comments are ignored.
    /// Returns a `Config` or an error if file reading or parsing fails.
    pub fn loadEnvFile(path: []const u8, allocator: std.mem.Allocator) !Config {
        const file = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch |err| {
            std.log.err("Could not open file: {}", .{err});
            return ConfigError.IoError;
        };
        defer file.close();
        const stat = try file.stat();
        const content = try allocator.alloc(u8, stat.size);
        defer allocator.free(content);

        _ = try file.readAll(content);
        return try parseEnv(content, allocator);
    }

    /// Loads a file from disk and parses it as `.ini` format.
    ///
    /// Lines like `KEY=value` are supported; blank lines and comments are ignored.
    /// Returns a `Config` or an error if file reading or parsing fails.
    pub fn loadIniFile(path: []const u8, allocator: std.mem.Allocator) !Config {
        const file = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch |err| {
            std.log.err("Could not open file: {}", .{err});
            return ConfigError.IoError;
        };
        defer file.close();
        const stat = try file.stat();
        const content = try allocator.alloc(u8, stat.size);
        defer allocator.free(content);

        _ = try file.readAll(content);
        return try parseIni(content, allocator);
    }

    /// Loads a file from disk and parses it as `.toml` format.
    ///
    /// Lines like `KEY=value` are supported; blank lines and comments are ignored.
    /// Returns a `Config` or an error if file reading or parsing fails.
    pub fn loadTomlFile(path: []const u8, allocator: std.mem.Allocator) !Config {
        const file = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch |err| {
            std.log.err("Could not open file: {}", .{err});
            return ConfigError.IoError;
        };
        defer file.close();
        const stat = try file.stat();
        const content = try allocator.alloc(u8, stat.size);
        defer allocator.free(content);

        _ = try file.readAll(content);
        const parsed = try parseToml(content, allocator);
        return parsed;
    }

    /// Debug helper to print all keys and values in the config.
    /// Values are shown using their internal representation.
    pub fn debugPrint(self: *Config) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            std.debug.print("{s} = {any}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    /// Converts the config into a `std.process.EnvMap`
    ///
    /// All values are converted to strings using `valueToString`,
    /// and used as environment variables for subprocess launching.
    pub fn toEnvMap(self: *Config, allocator: std.mem.Allocator) !std.process.EnvMap {
        var env_map = std.process.EnvMap.init(allocator);
        errdefer env_map.deinit();

        var it = self.map.iterator();
        while (it.next()) |entry| {
            const val_str = try valueToString(entry.value_ptr.*, self.map.allocator);
            defer self.map.allocator.free(val_str);
            try env_map.put(entry.key_ptr.*, val_str);
        }

        return env_map;
    }

    /// Parses the given in-memory buffer as a `.env`, `.ini`, or `.toml` config.
    ///
    /// This is useful for loading from strings, embedded files, or remote content.
    pub fn loadFromBuffer(text: []const u8, format: Format, allocator: std.mem.Allocator) !Config {
        return switch (format) {
            .env => parseEnv(text, allocator),
            .ini => parseIni(text, allocator),
            .toml => parseToml(text, allocator),
        };
    }
};
