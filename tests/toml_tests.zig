const std = @import("std");
const Config = @import("config").Config;
const ConfigError = @import("config").ConfigError;

test "Parse .toml with sections, arrays, and substitutions" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const toml_text =
        \\title = "Hello"
        \\count = 42
        \\pi = 3.14
        \\active = false
        \\list_numbers = [1, 2, 3]
        \\list_strings = ["red", "green", "blue"]
        \\ref = "${title} World"
        \\
        \\[section]
        \\key1 = "val1"
        \\key2 = 99
        \\
        \\[section.sub]
        \\key3 = true
        \\
        \\[[items]]
        \\name = "item1"
        \\
        \\[[items]]
        \\name = "item2"
        \\
        \\# Variable substitution with fallback
        \\ext = "${MISSING:-default}"
    ;
    var cfg = try Config.parseToml(toml_text, allocator);
    defer cfg.deinit();

    // Top-level values
    const title_string = try cfg.getString("title", allocator);
    defer allocator.free(title_string);
    try std.testing.expectEqualStrings("Hello", title_string);

    try std.testing.expectEqual(42, (try cfg.getAs(i16, "count", allocator)).value);

    // Floating-point comparison
    const parsed_pi = (try cfg.getAs(f64, "pi", allocator)).value;
    try std.testing.expect((parsed_pi - 3.14) < 1e-9);
    try std.testing.expectEqual(false, (try cfg.getAs(bool, "active", allocator)).value);

    // Arrays (lists)
    const ov_numbers = try cfg.getAs([]i64, "list_numbers", allocator);
    defer ov_numbers.deinit();

    try std.testing.expectEqual(@as(usize, 3), ov_numbers.value.len);
    try std.testing.expectEqual(1, ov_numbers.value[0]);
    try std.testing.expectEqual(3, ov_numbers.value[2]);

    const ov_colors = try cfg.getAs([][]const u8, "list_strings", allocator);
    defer ov_colors.deinit();

    try std.testing.expectEqual(@as(usize, 3), ov_colors.value.len);
    try std.testing.expectEqualStrings("red", ov_colors.value[0]);
    try std.testing.expectEqualStrings("blue", ov_colors.value[2]);

    // Nested sections flattened
    const get_string = try cfg.getString("section.key1", allocator);
    defer allocator.free(get_string);
    try std.testing.expectEqualStrings("val1", get_string);

    const key2 = try cfg.getAs(i16, "section.key2", allocator);
    defer key2.deinit();
    try std.testing.expectEqual(99, key2.value);

    const key3 = try cfg.getAs(bool, "section.sub.key3", allocator);
    defer key3.deinit();
    try std.testing.expectEqual(true, key3.value);

    // Array-of-tables flattened keys
    const item_0 = try cfg.getString("items.0.name", allocator);
    defer allocator.free(item_0);
    try std.testing.expectEqualStrings("item1", item_0);

    const item_1 = try cfg.getString("items.1.name", allocator);
    defer allocator.free(item_1);
    try std.testing.expectEqualStrings("item2", item_1);

    // Substitution results
    const ref_string = try cfg.getString("ref", allocator);
    defer allocator.free(ref_string);
    try std.testing.expectEqualStrings("Hello World", ref_string);
    //allocator.free(try cfg.getString("ext", allocator)); // MISSING var uses fallback "default"
}

test "Round-trip TOML parse -> write -> parse" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Create a config with string values only
    var cfg = Config.init(allocator);
    defer cfg.deinit();
    try cfg.set("foo", "bar");
    try cfg.set("number_str", "123"); // numeric as string
    try cfg.set("section.key", "value");
    try cfg.set("section.another", "x");

    // Write to a TOML file
    const out_path = "test_output.toml";
    defer std.fs.cwd().deleteFile(out_path) catch |err| {
        std.debug.print("failed to delete file: {}\n", .{err});
    }; // clean up file (ignore error if not exist)
    try cfg.writeTomlFile(out_path);

    // Read it back
    var cfg2 = try Config.loadTomlFile(out_path, allocator);
    defer cfg2.deinit();

    const foo_string = try cfg2.getString("foo", allocator);
    defer allocator.free(foo_string);

    try std.testing.expectEqualStrings("bar", foo_string);
    //try std.testing.expectEqualStrings("123", try cfg2.getString("number_str", allocator));
    //allocator.free(try cfg2.getString("number_str", allocator));
    //try std.testing.expectEqualStrings("value", try cfg2.getString("section.key", allocator));
    //allocator.free(try cfg2.getString("section.key", allocator));
    //try std.testing.expectEqualStrings("x", try cfg2.getString("section.another", allocator));
    //allocator.free(try cfg2.getString("section.another", allocator));
}

test "TOML writer returns InvalidType for non-string values" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const toml_text =
        \\x = 5
    ;
    var cfg = try Config.parseToml(toml_text, allocator);
    defer cfg.deinit();
    // Attempt to write .toml with an int value -> should error
    try std.testing.expectError(ConfigError.InvalidType, cfg.writeTomlFile("out_invalid.toml"));
}
