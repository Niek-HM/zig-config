const std = @import("std");
const utils = @import("utils.zig");

const ConfigError = @import("errors.zig").ConfigError;

const parseList = @import("parser/shared.zig").parseList;

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    bool: bool,
    list: []Value,
    table: *Table,

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => {
                allocator.free(self.string);
            },
            .list => {
                for (self.list) |*v| {
                    v.deinit(allocator);
                }
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

/// Wraps a value and allows automatic deallocation.
/// Used by `getAs` and similar accessors to manage lifetimes safely.
pub fn OwnedValue(comptime T: type) type {
    return struct {
        value: T,
        allocator: std.mem.Allocator,

        pub fn init(value: T, allocator: std.mem.Allocator) !@This() {
            const Self = @This();

            switch (@typeInfo(T)) {
                .pointer => |ptr| {
                    if (ptr.size != .slice) return error.Unsupported;

                    const Elem = ptr.child;

                    // Case: [][]const u8 — deep copy
                    if (T == [][]const u8) {
                        const out = try allocator.alloc([]const u8, value.len);
                        for (value, 0..) |item, i| {
                            out[i] = try allocator.dupe(u8, item);
                        }
                        return Self{ .value = out, .allocator = allocator };
                    }

                    // Generic case: []T (shallow copy)
                    const out = try allocator.alloc(Elem, value.len);
                    std.mem.copyForwards(Elem, out, value);
                    return Self{ .value = out, .allocator = allocator };
                },
                else => {
                    // Basic types like i64, bool, etc. — just store them
                    return Self{ .value = value, .allocator = allocator };
                },
            }
        }

        pub fn deinit(self: @This()) void {
            switch (@typeInfo(T)) {
                .pointer => |out| {
                    if (out.size != .slice) return;

                    //const Elem = out.child;
                    //const elem_info = @typeInfo(Elem);

                    // Case: [][]const u8 — free each inner slice then outer
                    if (T == [][]const u8) {
                        for (self.value) |item| self.allocator.free(item);
                        self.allocator.free(self.value);
                        return;
                    }

                    // Case: []T — free entire slice
                    self.allocator.free(self.value);
                },
                else => {}, // e.g. ints, bools — nothing to free
            }
        }
    };
}

pub const ResolvedValue = struct {
    value: []const u8,
    owned: bool,
};

pub const Table = std.StringHashMap(Value);

/// Converts a generic `Value` into a specific type `T`, optionally allocating memory.
/// Used for typed access (`getAs`) to interpret string/int/float/complex values.
pub fn valueToType(comptime T: type, val: Value, allocator: std.mem.Allocator) !T {
    return switch (val) {
        .string => |s| {
            if (T == [][]const u8) {
                var dummy_lines = std.mem.splitSequence(u8, "", "\n");
                var dummy_buf = std.ArrayList(u8).init(allocator);
                defer dummy_buf.deinit();

                const parsed = try parseList(s, &dummy_lines, &dummy_buf, allocator);
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
    };
}

/// Parses a raw string into a primitive type (int, bool, float, etc).
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

/// Parses a primitive type (int, bool, float, etc) into a raw string.
pub fn valueToString(val: Value, allocator: std.mem.Allocator) ![]const u8 {
    var list_buf = std.ArrayList(u8).init(allocator);
    errdefer list_buf.deinit();

    switch (val) {
        .string => |s| return allocator.dupe(u8, s),

        .int => |i| {
            try std.fmt.formatInt(i, 10, .Lower, &list_buf);
            return list_buf.toOwnedSlice();
        },

        .float => |f| {
            try std.fmt.formatFloat(f, .{}, &list_buf);
            return list_buf.toOwnedSlice();
        },

        .bool => |b| {
            try list_buf.writer().writeAll(if (b) "true" else "false");
            return list_buf.toOwnedSlice();
        },

        .list => |list| {
            for (list, 0..) |elem, i| {
                if (i != 0) try list_buf.append(',');

                const str = try valueToString(elem, allocator);
                defer allocator.free(str);

                // Quote if it contains comma or space
                if (std.mem.indexOfAny(u8, str, " ,") != null) {
                    try list_buf.writer().print("\"{s}\"", .{str});
                } else {
                    try list_buf.writer().writeAll(str);
                }
            }
            return list_buf.toOwnedSlice();
        },

        .table => |tbl| {
            var is_first = true;
            try list_buf.append('{');

            var it = tbl.iterator();
            while (it.next()) |entry| {
                if (!is_first) try list_buf.append(',');
                is_first = false;

                const k = entry.key_ptr.*;
                const v_str = try valueToString(entry.value_ptr.*, allocator);
                defer allocator.free(v_str);

                try list_buf.writer().print("{s}=\"{s}\"", .{ k, v_str });
            }

            try list_buf.append('}');
            return list_buf.toOwnedSlice();
        },
    }
}
