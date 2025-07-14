pub fn parseListOld(
    config: *Config,
    raw_val: []const u8,
    lines: *std.mem.SplitIterator(u8, .sequence),
    multiline_buf: *std.ArrayList(u8),
    full_key: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var full_array: []const u8 = raw_val;
    var owns_full_array: bool = false;

    // Handle multiline arrays
    if (raw_val.len == 0 or raw_val[raw_val.len - 1] != ']') {
        multiline_buf.clearRetainingCapacity();
        try multiline_buf.appendSlice(raw_val);
        try multiline_buf.append('\n');

        var depth: usize = 1;
        while (lines.next()) |line| {
            const trimmed: []const u8 = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            for (trimmed) |c| switch (c) {
                '[', '{' => depth += 1,
                ']', '}' => if (depth > 0) {
                    depth -= 1;
                },
                else => {},
            };
            try multiline_buf.appendSlice(trimmed);
            try multiline_buf.append('\n');
            if (depth == 0) break;
        }

        full_array = try multiline_buf.toOwnedSlice();
        owns_full_array = true;
    }

    defer if (owns_full_array) allocator.free(full_array);

    var trimmed: []const u8 = std.mem.trim(u8, full_array, " \t\r\n");
    trimmed = try std.mem.replaceOwned(u8, allocator, trimmed, " ", "");
    defer allocator.free(trimmed);

    var content: []const u8 = trimmed;
    var owns_content: bool = false;

    if (std.mem.endsWith(u8, content, ",]")) {
        const cleaned: []u8 = try std.fmt.allocPrint(allocator, "{s}]", .{content[0 .. content.len - 2]});
        content = cleaned;
        owns_content = true;
    }

    defer if (owns_content) allocator.free(content);

    const result: []u8 = try allocator.dupe(u8, content);
    errdefer allocator.free(result);

    // Loop over array items
    var items = std.mem.tokenizeScalar(u8, result[1 .. result.len - 1], ',');
    while (items.next()) |entry| {
        const val: []const u8 = std.mem.trim(u8, entry, " \t\r\n");
        if (val.len == 0) continue;

        if ((val[0] == '{' and val[val.len - 1] == '}') or (val[0] == '[' and val[val.len - 1] == ']')) {
            const sub: Config = try Config.parseToml(val, allocator);
            var it = sub.map.iterator();
            while (it.next()) |sub_entry| {
                const nested: []u8 = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ full_key, sub_entry.key_ptr.* });

                const key_copy: []u8 = try allocator.dupe(u8, nested);
                errdefer allocator.free(key_copy);
                const val_copy: []u8 = try allocator.dupe(u8, sub_entry.value_ptr.*);
                errdefer allocator.free(val_copy);

                if (config.map.getEntry(key_copy)) |entry_ptr| {
                    allocator.free(entry_ptr.key_ptr.*);
                    allocator.free(entry_ptr.value_ptr.*);
                    _ = config.map.remove(key_copy);
                }
                try config.map.put(key_copy, val_copy);
            }
        }
    }

    return result;
}

pub fn parseTableOld(
    config: *Config,
    raw_val: []const u8,
    lines: *std.mem.SplitIterator(u8, .sequence),
    multiline_buf: *std.ArrayList(u8),
    full_key: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var full_table: []const u8 = raw_val;
    var owns_full_table: bool = false;

    if (raw_val.len == 0 or raw_val[raw_val.len - 1] != '}') {
        multiline_buf.clearRetainingCapacity();
        try multiline_buf.appendSlice(raw_val);
        try multiline_buf.append('\n');

        var depth: usize = 1;
        while (lines.next()) |line| {
            try multiline_buf.appendSlice(line);
            try multiline_buf.append('\n');

            const trimmed: []const u8 = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;

            for (trimmed) |c| switch (c) {
                '{', '[' => depth += 1,
                '}', ']' => if (depth > 0) {
                    depth -= 1;
                },
                else => {},
            };

            //try multiline_buf.appendSlice(trimmed);
            //try multiline_buf.append('\n');
            if (depth == 0) break;
        }

        full_table = try multiline_buf.toOwnedSlice();
        owns_full_table = true;
    }

    defer if (owns_full_table) allocator.free(full_table);

    const content: []const u8 = std.mem.trim(u8, full_table[1 .. full_table.len - 1], " \t\r\n");

    var pairs = std.ArrayList([]const u8).init(allocator);
    defer pairs.deinit();

    // smart split respecting nesting
    var start: usize = 0;
    var depth: usize = 0;
    var in_quote: ?u8 = null;
    var i: usize = 0;
    while (i < content.len) {
        const c: u8 = content[i];
        if (in_quote) |quote| {
            if (c == quote) {
                in_quote = null;
            } else if (c == '\\' and i + 1 < content.len) {
                i += 1;
            }
        } else {
            switch (c) {
                '"', '\'' => in_quote = c,
                '{', '[' => depth += 1,
                '}', ']' => if (depth > 0) {
                    depth -= 1;
                },
                ',' => if (depth == 0) {
                    try pairs.append(std.mem.trim(u8, content[start..i], " \t\r\n"));
                    start = i + 1;
                },
                else => {},
            }
        }
        i += 1;
    }

    if (start < content.len) {
        const last: []const u8 = std.mem.trim(u8, content[start..], " \t\r\n");
        if (last.len > 0) try pairs.append(last);
    }

    var nested_key: ?[]u8 = null;
    defer if (nested_key) |k| allocator.free(k);

    for (pairs.items) |pair| {
        if (nested_key) |k| allocator.free(k);
        nested_key = null;

        const trimmed_pair: []const u8 = std.mem.trim(u8, pair, " \t\r\n");
        if (trimmed_pair.len == 0 or !std.mem.containsAtLeast(u8, trimmed_pair, 1, "=")) continue;

        const sep: usize = std.mem.indexOfScalar(u8, pair, '=') orelse return ConfigError.ParseInvalidLine;
        const key: []const u8 = std.mem.trim(u8, pair[0..sep], " \t\r\n");
        const val: []const u8 = std.mem.trim(u8, pair[sep + 1 ..], " \t\r\n");

        nested_key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ full_key, key });

        if (val.len >= 2 and val[0] == '{' and val[val.len - 1] == '}') {
            const parsed: []const u8 = try parseTable(config, val, lines, multiline_buf, nested_key.?, allocator);
            allocator.free(parsed);
            allocator.free(nested_key.?);
            nested_key = null;
            continue;
        } else if (val.len >= 2 and val[0] == '[' and val[val.len - 1] == ']') {
            const parsed: []const u8 = try parseList(config, val, lines, multiline_buf, nested_key.?, allocator);
            allocator.free(parsed);
            allocator.free(nested_key.?);
            nested_key = null;
            continue;
        } else {
            const stripped_val: []const u8 = stripQuotes(val);
            const new_val: []u8 = try allocator.dupe(u8, stripped_val);
            errdefer allocator.free(new_val);

            const key_copy: []u8 = try allocator.dupe(u8, nested_key.?);
            errdefer allocator.free(key_copy);

            if (config.map.getEntry(key_copy)) |entry_ptr| {
                allocator.free(entry_ptr.key_ptr.*);
                allocator.free(entry_ptr.value_ptr.*);
                _ = config.map.remove(key_copy);
            }
            try config.map.put(key_copy, new_val);

            allocator.free(nested_key.?);
            nested_key = null;
        }
    }
    return try allocator.dupe(u8, std.mem.trim(u8, full_table, " \t\r\n"));
}
