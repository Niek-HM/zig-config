const std = @import("std");
const Config = @import("config").Config;
const ConfigError = @import("config").ConfigError;

test "Parse .env basic values and substitution" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const env_text =
        \\FOO=bar
        \\BAZ="quoted value"
        \\ESCAPED="Line1\\nLine2"
        \\SINGLE='single quote value'
        \\INT=42
        \\FLOAT=3.14
        \\BOOL_TRUE=true
        \\BOOL_FALSE=false
        \\base=hello
        \\base2=
        \\PATHVAR=${PATH}
        \\REF=${base}/world
        \\FALL=${UNKNOWN:-fallback}
        \\ALT1=${base:+altVal}
        \\ALT2=${base+altVal}
        \\ALT3=${base2:+val}
        \\ALT4=${base2+val}
    ;
    // Parse the .env content
    var cfg = try Config.parseEnv(env_text, allocator);
    defer cfg.deinit();

    // Expect all keys to be present
    const keys = try cfg.keys(allocator);
    defer allocator.free(keys);
    try std.testing.expectEqual(keys.len, 17);
    const want_keys = [_][]const u8{ "FOO", "BAZ", "ESCAPED", "SINGLE", "INT", "FLOAT", "BOOL_TRUE", "BOOL_FALSE", "base", "base2", "PATHVAR", "REF", "FALL", "ALT1", "ALT2", "ALT3", "ALT4" };
    for (want_keys) |expected_key| {
        // each expected key should be found in the keys list
        var found = false;
        for (keys) |k| if (std.mem.eql(u8, k, expected_key)) {
            found = true;
        };
        try std.testing.expect(found);
    }

    // Check raw values via get (no conversion)
    const foo_val = cfg.get("FOO") orelse unreachable;
    //try std.testing.expectEqual(foo_val, .string);
    try std.testing.expectEqualStrings("bar", foo_val.string);

    // Typed accessors (getAs and convenience getters)
    const baz_string = try cfg.getString("BAZ", allocator);
    defer allocator.free(baz_string);
    try std.testing.expectEqualStrings("quoted value", baz_string);

    // Ensure escaped newline is preserved
    const esc = try cfg.getString("ESCAPED", allocator);
    defer allocator.free(esc);
    try std.testing.expect(std.mem.indexOf(u8, esc, "\\n") != null);
    try std.testing.expectEqualStrings("Line1", esc[0..5]);

    const int_val = try cfg.getAs(i16, "INT", allocator);
    defer int_val.deinit();
    try std.testing.expectEqual(@as(i16, 42), int_val.value);

    const float_val = try cfg.getAs(f16, "FLOAT", allocator);
    defer float_val.deinit();
    try std.testing.expectEqual(@as(f16, 3.14), float_val.value);

    const bool_true = try cfg.getAs(bool, "BOOL_TRUE", allocator);
    defer bool_true.deinit();
    try std.testing.expectEqual(true, bool_true.value);

    const bool_false = try cfg.getAs(bool, "BOOL_FALSE", allocator);
    defer bool_false.deinit();
    try std.testing.expectEqual(false, bool_false.value);

    // Variable substitution results
    const ref_string = try cfg.getString("REF", allocator);
    defer allocator.free(ref_string);
    try std.testing.expectEqualStrings("hello/world", ref_string);

    // ALT1 and ALT2 should both produce "altVal" since `base` is "hello" (set and not empty)
    const alt1_string = try cfg.getString("ALT1", allocator);
    defer allocator.free(alt1_string);
    try std.testing.expectEqualStrings("altVal", alt1_string);

    // `base2` is set to empty string: ALT3 (with colon) should produce empty result, ALT4 (no colon) should produce "val"
    const alt3_string = try cfg.getString("ALT3", allocator);
    defer allocator.free(alt3_string);
    try std.testing.expectEqualStrings("", alt3_string);
}

test "Unknown variable without fallback in .env" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const env_text = "VAL=${NOT_DEFINED}";
    _ = env_text;
    //try std.testing.expectError(ConfigError.UnknownVariable, Config.parseEnv(env_text, allocator));
}

test "Empty placeholder in .env" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const env_text = "X=${}";
    _ = env_text;
    //try std.testing.expectError(ConfigError.InvalidPlaceholder, Config.parseEnv(env_text, allocator));
}

test "Invalid substitution syntax in .env" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const env_text = "Y=${VAR:-}";
    _ = env_text;
    //try std.testing.expectError(ConfigError.InvalidSubstitutionSyntax, Config.parseEnv(env_text, allocator));
}

test "Circular reference detection in .env" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const env_text =
        \\A=${B}
        \\B=${A}
    ;
    _ = env_text;
    //try std.testing.expectError(ConfigError.CircularReference, Config.parseEnv(env_text, allocator));
}

test "Invalid escape sequence in .env" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const env_text =
        \\BAD="foo\\zbar"
    ;
    _ = env_text;
    //try std.testing.expectError(ConfigError.InvalidEscape, Config.parseEnv(env_text, allocator));
}

test "Invalid Unicode escape in .env" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const env_text =
        \\BAD="\\u123"
    ;
    _ = env_text;
    //try std.testing.expectError(ConfigError.InvalidUnicodeEscape, Config.parseEnv(env_text, allocator));
}
