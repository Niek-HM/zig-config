const std = @import("std");
const testing = std.testing;
const Config = @import("root.zig").Config;

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
    try testing.expectEqual(true, try cfg.getBool("DEBUG"));
    try testing.expectEqualStrings("xyz123", cfg.get("API_KEY").?);
    try testing.expectError(Config.ConfigError.InvalidInt, cfg.getInt("EMPTY"));
    try testing.expectEqual(null, cfg.get("NOT_FOUND"));
}

test "ini parsing with sections" {
    const allocator = testing.allocator;
    const text =
        \\[server]
        \\port=3000
        \\host=localhost
        \\[database]
        \\user=admin
        \\pass=secret
    ;

    var cfg = try Config.parseIni(text, allocator);
    defer cfg.deinit();

    try testing.expectEqualStrings("3000", cfg.get("server.port").?);
    try testing.expectEqualStrings("admin", cfg.get("database.user").?);

    var section = try cfg.getSection("server", allocator);
    defer section.deinit();

    try testing.expectEqualStrings("localhost", section.get("host").?);
}

test "merge behavior overwrite and skip_existing" {
    const allocator = testing.allocator;

    var cfg1 = Config.init(allocator);
    defer cfg1.deinit();
    try cfg1.map.put(try allocator.dupe(u8, "PORT"), try allocator.dupe(u8, "8000"));

    var cfg2 = Config.init(allocator);
    defer cfg2.deinit();
    try cfg2.map.put(try allocator.dupe(u8, "PORT"), try allocator.dupe(u8, "9000"));
    try cfg2.map.put(try allocator.dupe(u8, "NEW"), try allocator.dupe(u8, "val"));

    try cfg1.merge(&cfg2, allocator, .overwrite);
    try testing.expectEqualStrings("9000", cfg1.get("PORT").?);

    try cfg1.merge(&cfg2, allocator, .skip_existing);
    try testing.expectEqualStrings("val", cfg1.get("NEW").?);
}

test "merge behavior error_on_conflict" {
    const allocator = testing.allocator;

    var a = Config.init(allocator);
    defer a.deinit();
    var b = Config.init(allocator);
    defer b.deinit();

    try a.map.put(try allocator.dupe(u8, "X"), try allocator.dupe(u8, "1"));
    try b.map.put(try allocator.dupe(u8, "X"), try allocator.dupe(u8, "2"));

    try testing.expectError(Config.ConfigError.KeyConflict, a.merge(&b, allocator, .error_on_conflict));
}

test "invalid int, float, and bool" {
    const allocator = testing.allocator;
    var cfg = Config.init(allocator);
    defer cfg.deinit();

    try cfg.map.put(try allocator.dupe(u8, "num"), try allocator.dupe(u8, "abc"));
    try testing.expectError(Config.ConfigError.InvalidInt, cfg.getInt("num"));
    try testing.expectError(Config.ConfigError.InvalidFloat, cfg.getFloat("num"));

    try cfg.map.put(try allocator.dupe(u8, "bool"), try allocator.dupe(u8, "maybe"));
    try testing.expectError(Config.ConfigError.InvalidBool, cfg.getBool("bool"));
}

test "variable substitution: plain and :- fallback" {
    const allocator = testing.allocator;
    const text =
        \\HOST=localhost
        \\URL=http://${HOST:-fallback}
    ;

    var cfg = try Config.parseEnv(text, allocator);
    defer cfg.deinit();

    try testing.expectEqualStrings("http://localhost", cfg.get("URL").?);
}

test "substitution with :+ and +" {
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
}

test "escaped dollar sign \\$" {
    const allocator = testing.allocator;
    const text =
        \\KEY=\$100
        \\KEY2=\${100}
    ;

    var cfg = try Config.parseEnv(text, allocator);
    defer cfg.deinit();

    try testing.expectEqualStrings("$100", cfg.get("KEY").?);
    try testing.expectEqualStrings("${100}", cfg.get("KEY2").?);
}

test "error on unknown variable without fallback" {
    const allocator = testing.allocator;
    const text =
        \\VAR=${NOT_SET}
    ;

    const result = Config.parseEnv(text, allocator);
    try testing.expectError(Config.ConfigError.UnknownVariable, result);
}

test "error on unterminated placeholder" {
    const allocator = testing.allocator;
    const text =
        \\BROKEN=${UNFINISHED
    ;

    const result = Config.parseEnv(text, allocator);
    try testing.expectError(Config.ConfigError.InvalidPlaceholder, result);
}

test "invalid key should trigger InvalidKey error" {
    const allocator = testing.allocator;
    const text =
        \\=no_key
    ;

    const result = Config.parseEnv(text, allocator);
    try testing.expectError(Config.ConfigError.InvalidKey, result);
}

test "substitution precedence for :- vs - with empty, missing, and present values" {
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

    try testing.expectEqualStrings("fallback", cfg.get("R1").?); // empty + :-
    try testing.expectEqualStrings("value", cfg.get("R2").?); // present + :-
    try testing.expectEqualStrings("fallback", cfg.get("R3").?); // missing + :-
    try testing.expectEqualStrings("", cfg.get("R4").?); // empty + -
    try testing.expectEqualStrings("value", cfg.get("R5").?); // present + -
    try testing.expectEqualStrings("fallback", cfg.get("R6").?); // missing + -
}

test "getInt/getFloat/getBool return Missing on missing key" {
    const allocator = testing.allocator;
    var cfg = Config.init(allocator);
    defer cfg.deinit();

    try testing.expectError(Config.ConfigError.Missing, cfg.getInt("nope"));
    try testing.expectError(Config.ConfigError.Missing, cfg.getFloat("nope"));
    try testing.expectError(Config.ConfigError.Missing, cfg.getBool("nope"));
}

test "malformed .env lines are handled properly" {
    const allocator = testing.allocator;

    const bad1 = "=novar"; // InvalidKey
    const bad2 = "novalue="; // valid key with empty value
    const bad3 = "justgarbage"; // no '=' → ParseInvalidLine

    try testing.expectError(Config.ConfigError.InvalidKey, Config.parseEnv(bad1, allocator));

    var cfg = try Config.parseEnv(bad2, allocator);
    defer cfg.deinit();
    try testing.expectEqualStrings("", cfg.get("novalue").?);

    try testing.expectError(Config.ConfigError.ParseInvalidLine, Config.parseEnv(bad3, allocator));
}

test "ini sectionless keys are allowed" {
    const allocator = testing.allocator;
    const text =
        \\key=value
        \\[section]
        \\k2=v2
    ;

    var cfg = try Config.parseIni(text, allocator);
    defer cfg.deinit();

    try testing.expectEqualStrings("value", cfg.get("key").?);
    try testing.expectEqualStrings("v2", cfg.get("section.k2").?);
}

test "getSection returns Missing if no matching keys" {
    const allocator = testing.allocator;
    const text =
        \\[app]
        \\k=v
    ;

    var cfg = try Config.parseIni(text, allocator);
    defer cfg.deinit();

    try testing.expectError(Config.ConfigError.Missing, cfg.getSection("notfound", allocator));
}

test "deinit does not double-free or leak with mixed keys" {
    const allocator = testing.allocator;
    var cfg = Config.init(allocator);
    defer cfg.deinit();

    try cfg.map.put(try allocator.dupe(u8, "key1"), try allocator.dupe(u8, "val1"));
    try cfg.map.put(try allocator.dupe(u8, "key2"), try allocator.dupe(u8, "val2"));
    // implicit test: deferred deinit
}

test "keys() returns all config keys" {
    const allocator = testing.allocator;
    const text =
        \\A=1
        \\B=2
    ;

    var cfg = try Config.parseEnv(text, allocator);
    defer cfg.deinit();

    const keys = try cfg.keys(allocator);
    defer allocator.free(keys);

    var found_a = false;
    var found_b = false;
    for (keys) |k| {
        if (std.mem.eql(u8, k, "A")) found_a = true;
        if (std.mem.eql(u8, k, "B")) found_b = true;
    }
    try testing.expect(found_a and found_b);
}

test "circular reference inside fallback still triggers error" {
    const allocator = testing.allocator;
    const text =
        \\A=${B:-${C}}
        \\B=${C}
        \\C=${A}
    ;

    try testing.expectError(Config.ConfigError.CircularReference, Config.parseEnv(text, allocator));
}

test "ini section with only brackets and whitespace is invalid" {
    const allocator = testing.allocator;
    const text = "[ ]";
    try testing.expectError(Config.ConfigError.ParseUnterminatedSection, Config.parseIni(text, allocator));
}

test "ini last key wins for repeated keys" {
    const allocator = testing.allocator;
    const text =
        \\[app]
        \\key=val1
        \\key=val2
    ;

    var cfg = try Config.parseIni(text, allocator);
    defer cfg.deinit();

    try testing.expectEqualStrings("val2", cfg.get("app.key").?);
}

test "ini empty section name is invalid" {
    const allocator = testing.allocator;
    const text = "[ ]\nkey=value";
    try testing.expectError(Config.ConfigError.ParseUnterminatedSection, Config.parseIni(text, allocator));
}

test "loadFromBuffer parses both formats" {
    const allocator = testing.allocator;
    const env = "X=42";
    const ini = "[s]\ny=val";

    var cfg1 = try Config.loadFromBuffer(env, .env, allocator);
    defer cfg1.deinit();
    try testing.expectEqualStrings("42", cfg1.get("X").?);

    var cfg2 = try Config.loadFromBuffer(ini, .ini, allocator);
    defer cfg2.deinit();
    try testing.expectEqualStrings("val", cfg2.get("s.y").?);
}

test "system env merge and substitution behavior" {
    const allocator = testing.allocator;

    // Load current system env
    var env_config = try Config.fromEnvMap(allocator);
    defer env_config.deinit();

    // Check if at least one known variable exists (platform-specific fallback)
    const check_var = "Path"; // Use common variable
    if (!env_config.has(check_var)) {
        // Skip test if no known variable found
        return error.SkipZigTest;
    }

    // Parse a config with substitution from env
    const text =
        \\MY_PATH=${Path}
        \\DEFAULTED=${MISSING_VAR:-fallback}
        \\COND1=${Path:+present}
        \\COND2=${MISSING_VAR:+ignored}
        \\COND3=${Path+used}
    ;

    var cfg = try Config.parseEnv(text, allocator);
    defer cfg.deinit();

    try testing.expect(cfg.has("MY_PATH"));
    try testing.expectEqualStrings("fallback", cfg.get("DEFAULTED").?);
    try testing.expectEqualStrings("present", cfg.get("COND1").?);
    try testing.expectEqualStrings("", cfg.get("COND2").?);
    try testing.expectEqualStrings("used", cfg.get("COND3").?);

    // Merge env into parsed config, check overwrite behavior
    var merged = try Config.parseEnv("Path=custom_path\nFOO=bar", allocator);
    defer merged.deinit();

    // Case: skip_existing (should keep original PATH)
    try merged.merge(&env_config, allocator, .skip_existing);
    try testing.expectEqualStrings("custom_path", merged.get("Path").?);

    // Case: overwrite (should take system PATH)
    var merged_overwrite = try Config.parseEnv("Path=custom_path\nFOO=bar", allocator);
    defer merged_overwrite.deinit();

    try merged_overwrite.merge(&env_config, allocator, .overwrite);
    try testing.expect(!std.mem.eql(u8, merged_overwrite.get("Path").?, "custom_path"));

    // Case: error_on_conflict (should fail)
    var merged_conflict = try Config.parseEnv("Path=custom_path", allocator);
    defer merged_conflict.deinit();

    const conflict_result = merged_conflict.merge(&env_config, allocator, .error_on_conflict);
    try testing.expectError(Config.ConfigError.KeyConflict, conflict_result);
}
