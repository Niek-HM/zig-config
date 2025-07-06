const std = @import("std");
const testing = std.testing;
const Config = @import("root.zig").Config;

test "toml - types, tables, inline tables" {
    const input =
        \\ title = "Test"
        \\ count = 123
        \\ [owner]
        \\ name = "Bob"
        \\ [nested.child]
        \\ key = "value"
    ;

    var cfg = try Config.parseToml(input, testing.allocator);
    defer cfg.deinit();

    const title = try cfg.getAs([]const u8, "title", testing.allocator);
    defer testing.allocator.free(title);
    try testing.expectEqualStrings("Test", title);

    try testing.expectEqual(@as(i64, 123), try cfg.getAs(i64, "count", testing.allocator));

    const name = try cfg.getAs([]const u8, "owner.name", testing.allocator);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("Bob", name);

    const nested = try cfg.getAs([]const u8, "nested.child.key", testing.allocator);
    defer testing.allocator.free(nested);
    try testing.expectEqualStrings("value", nested);
}

test "toml - arrays, trailing comma, multiline, empty" {
    const input =
        \\ tags = ["x", "y", "z",]
        \\ nums = [1, 2, 3]
        \\ floats = [1.1, 2.2, 3.3]
        \\ multi = [
        \\   "a",
        \\   "b",
        \\   "c",
        \\ ]
        \\ empty = []
    ;

    var cfg = try Config.parseToml(input, testing.allocator);
    defer cfg.deinit();

    const tags = try cfg.getAs([][]const u8, "tags", testing.allocator);
    defer {
        for (tags) |t| testing.allocator.free(t);
        testing.allocator.free(tags);
    }

    const multi = try cfg.getAs([][]const u8, "multi", testing.allocator);
    defer {
        for (multi) |m| testing.allocator.free(m);
        testing.allocator.free(multi);
    }

    const nums = try cfg.getAs([]i64, "nums", testing.allocator);
    defer testing.allocator.free(nums);

    const floats = try cfg.getAs([]f64, "floats", testing.allocator);
    defer testing.allocator.free(floats);

    const empty = try cfg.getAs([][]const u8, "empty", testing.allocator);
    defer testing.allocator.free(empty);
}

test "toml - strings, escapes, unicode, substitution" {
    const input =
        \\ basic = "line\\nnext"
        \\ literal = 'C:\Program Files\App'
        \\ triple = """multi\nline"""
        \\ raw_triple = '''
        \\A
        \\B
        \\C'''
        \\ quoted = "name: \\\"bob\\\""
        \\ euro = "\u00A3"
        \\ smile = "\U0001F600"
        \\ fallback = "${UNSET_VAR:-hello}"
    ;

    var cfg = try Config.parseToml(input, testing.allocator);
    defer cfg.deinit();

    const basic = try cfg.getAs([]const u8, "basic", testing.allocator);
    defer testing.allocator.free(basic);
    try testing.expectEqualStrings("line\\nnext", basic);

    const literal = try cfg.getAs([]const u8, "literal", testing.allocator);
    defer testing.allocator.free(literal);
    try testing.expectEqualStrings("C:\\Program Files\\App", literal);

    const triple = try cfg.getAs([]const u8, "triple", testing.allocator);
    defer testing.allocator.free(triple);
    try testing.expectEqualStrings("multi\nline", triple);

    const raw_triple = try cfg.getAs([]const u8, "raw_triple", testing.allocator);
    defer testing.allocator.free(raw_triple);
    try testing.expectEqualStrings("A\nB\nC", raw_triple);

    const quoted = try cfg.getAs([]const u8, "quoted", testing.allocator);
    defer testing.allocator.free(quoted);
    try testing.expectEqualStrings("name: \\\"bob\\\"", quoted);

    const euro = try cfg.getAs([]const u8, "euro", testing.allocator);
    defer testing.allocator.free(euro);
    try testing.expectEqualStrings("£", euro);

    const smile = try cfg.getAs([]const u8, "smile", testing.allocator);
    defer testing.allocator.free(smile);
    try testing.expectEqualStrings("😀", smile);

    const fallback = try cfg.getAs([]const u8, "fallback", testing.allocator);
    defer testing.allocator.free(fallback);
    try testing.expectEqualStrings("hello", fallback);

    std.debug.print("✔ toml - strings, escapes, unicode, substitution passed\n", .{});
}

test "toml - array of tables" {
    const input =
        \\ [[fruit]]
        \\ name = "apple"
        \\ color = "red"
        \\
        \\ [[fruit]]
        \\ name = "banana"
        \\ color = "yellow"
    ;

    var cfg = try Config.parseToml(input, testing.allocator);
    defer cfg.deinit();

    const fruit1 = try cfg.getAs([]const u8, "fruit.0.name", testing.allocator);
    defer testing.allocator.free(fruit1);
    try testing.expectEqualStrings("apple", fruit1);

    const fruit2 = try cfg.getAs([]const u8, "fruit.1.color", testing.allocator);
    defer testing.allocator.free(fruit2);
    try testing.expectEqualStrings("yellow", fruit2);
}
