const std = @import("std");
const testing = std.testing;
const Config = @import("config").Config;

test "basic .env parsing and accessors" {
    const allocator = testing.allocator;
    const text =
        \\# comment
        \\PORT=8080
        \\DEBUG=true
        \\API_KEY="xyz123"
        \\EMPTY=
    ;

    var cfg = try Config.parseEnv(text, allocator);
    defer cfg.deinit();

    try testing.expectEqualStrings("8080", cfg.get("PORT").?);
    try testing.expectEqual(true, try cfg.getAs(bool, "DEBUG", allocator));
    try testing.expectEqualStrings("xyz123", cfg.get("API_KEY").?);
    try testing.expectError(Config.ConfigError.InvalidInt, cfg.getAs(i64, "EMPTY", allocator));
    try testing.expectEqual(null, cfg.get("NOT_FOUND"));

    std.debug.print("✅ basic .env parsing and accessors passed\n", .{});
}

test "escaped dollar sign $ and ${}" {
    const allocator = testing.allocator;
    const text =
        \\KEY=\$100
        \\KEY2=\${100}
    ;

    var cfg = try Config.parseEnv(text, allocator);
    defer cfg.deinit();

    try testing.expectEqualStrings("$100", cfg.get("KEY").?);
    try testing.expectEqualStrings("${100}", cfg.get("KEY2").?);

    std.debug.print("✅ env - escaped $ and ${{}} literal passed\n", .{});
}

test "substitution fallback variations" {
    const allocator = testing.allocator;
    const text =
        \\A1=
        \\A2=value
        \\R1=${A1:-fallback}
        \\R2=${A2:-fallback}
        \\R3=${MISSING:-fallback}
        \\R4=${A1-fallback}
        \\R5=${A2-fallback}
        \\R6=${MISSING-fallback}
    ;

    var cfg = try Config.parseEnv(text, allocator);
    defer cfg.deinit();

    try testing.expectEqualStrings("fallback", cfg.get("R1").?);
    try testing.expectEqualStrings("value", cfg.get("R2").?);
    try testing.expectEqualStrings("fallback", cfg.get("R3").?);
    try testing.expectEqualStrings("", cfg.get("R4").?);
    try testing.expectEqualStrings("value", cfg.get("R5").?);
    try testing.expectEqualStrings("fallback", cfg.get("R6").?);

    std.debug.print("✅ env - substitution fallback variations passed\n", .{});
}

test ":+ and + substitution forms" {
    const allocator = testing.allocator;
    const text =
        \\A1=value
        \\B1=${A1:+present}
        \\B2=${A1+present}
        \\B3=${UNKNOWN:+nope}
        \\B4=${UNKNOWN+nope}
    ;

    var cfg = try Config.parseEnv(text, allocator);
    defer cfg.deinit();

    try testing.expectEqualStrings("present", cfg.get("B1").?);
    try testing.expectEqualStrings("present", cfg.get("B2").?);
    try testing.expectEqualStrings("", cfg.get("B3").?);
    try testing.expectEqualStrings("", cfg.get("B4").?);

    std.debug.print("✅ env - :+ and + substitution passed\n", .{});
}

test "missing variable without fallback gives error" {
    const allocator = testing.allocator;
    const text = "VAR=${NOT_SET}";

    try testing.expectError(Config.ConfigError.UnknownVariable, Config.parseEnv(text, allocator));

    std.debug.print("✅ env - missing variable without fallback triggers error\n", .{});
}

test "unterminated placeholder triggers error" {
    const allocator = testing.allocator;
    const text = "BROKEN=${UNFINISHED";

    try testing.expectError(Config.ConfigError.InvalidPlaceholder, Config.parseEnv(text, allocator));

    std.debug.print("✅ env - unterminated placeholder triggers error\n", .{});
}

test "invalid key gives InvalidKey error" {
    const allocator = testing.allocator;
    const text = "=no_key";

    try testing.expectError(Config.ConfigError.InvalidKey, Config.parseEnv(text, allocator));

    std.debug.print("✅ env - invalid key gives InvalidKey error\n", .{});
}

test "malformed lines and empty value" {
    const allocator = testing.allocator;

    const bad1 = "=novar"; // InvalidKey
    const bad2 = "novalue="; // valid key with empty value
    const bad3 = "justgarbage"; // no '=' → ParseInvalidLine

    try testing.expectError(Config.ConfigError.InvalidKey, Config.parseEnv(bad1, allocator));

    var cfg = try Config.parseEnv(bad2, allocator);
    defer cfg.deinit();
    try testing.expectEqualStrings("", cfg.get("novalue").?);

    try testing.expectError(Config.ConfigError.ParseInvalidLine, Config.parseEnv(bad3, allocator));

    std.debug.print("✅ env - malformed lines handled correctly\n", .{});
}

test "Missing errors for typed getters" {
    const allocator = testing.allocator;
    var cfg = Config.init(allocator);
    defer cfg.deinit();

    try testing.expectError(Config.ConfigError.Missing, cfg.getAs(i64, "nope", allocator));
    try testing.expectError(Config.ConfigError.Missing, cfg.getAs(f64, "nope", allocator));
    try testing.expectError(Config.ConfigError.Missing, cfg.getAs(bool, "nope", allocator));

    std.debug.print("✅ env - typed getters return Missing for missing key\n", .{});
}

test "invalid int/float/bool parsing triggers error" {
    const allocator = testing.allocator;
    var cfg = Config.init(allocator);
    defer cfg.deinit();

    try cfg.map.put(try allocator.dupe(u8, "num"), try allocator.dupe(u8, "abc"));
    try testing.expectError(Config.ConfigError.InvalidInt, cfg.getAs(i64, "num", allocator));
    try testing.expectError(Config.ConfigError.InvalidFloat, cfg.getAs(f64, "num", allocator));

    try cfg.map.put(try allocator.dupe(u8, "bool"), try allocator.dupe(u8, "maybe"));
    try testing.expectError(Config.ConfigError.InvalidBool, cfg.getAs(bool, "bool", allocator));

    std.debug.print("✅ env - invalid typed value errors work\n", .{});
}

test "circular fallback detection" {
    const allocator = testing.allocator;
    const text =
        \\A=${B:-${C}}
        \\B=${C}
        \\C=${A}
    ;

    try testing.expectError(Config.ConfigError.CircularReference, Config.parseEnv(text, allocator));

    std.debug.print("✅ env - circular fallback detected\n", .{});
}

test "empty value parsed correctly" {
    const allocator = testing.allocator;
    var valid = try Config.parseEnv("valid=", allocator);
    defer valid.deinit();

    try testing.expectEqualStrings("", valid.get("valid").?);

    std.debug.print("✅ env - empty value parsed as empty string\n", .{});
}
