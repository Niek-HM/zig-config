const std = @import("std");

pub const Config = struct {
    map: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) Config {
        return Config{
            .map = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Config) void {
        self.map.deinit();
    }

    pub fn get(self: *Config, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    pub fn loadFromFile(path: []const u8, allocator: std.mem.Allocator) !Config {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const content = try allocator.alloc(u8, stat.size);
        defer allocator.free(content);

        _ = try file.readAll(content);
        return try parseEnv(content, allocator);
    }

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

    pub fn getInt(self: *Config, key: []const u8) ?i64 {
        const val = self.get(key) orelse return null;
        return std.fmt.parseInt(i64, val, 10) catch return null;
    }

    pub fn getFloat(self: *Config, key: []const u8) ?f64 {
        const val = self.get(key) orelse return null;
        return std.fmt.parseFloat(f64, val) catch return null;
    }

    pub fn getBool(self: *Config, key: []const u8) ?bool {
        const val = self.get(key) orelse return null;

        // Lowercase match
        if (std.ascii.eqlIgnoreCase(val, "true")) return true;
        if (std.ascii.eqlIgnoreCase(val, "false")) return false;

        // Uppercase match
        if (std.ascii.eqlIgnoreCase(val, "True")) return true;
        if (std.ascii.eqlIgnoreCase(val, "False")) return false;

        // 0/1 match
        if (std.ascii.eqlIgnoreCase(val, "1")) return true;
        if (std.ascii.eqlIgnoreCase(val, "0")) return false;

        return null;
    }
};
