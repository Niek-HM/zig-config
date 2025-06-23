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

    try cfg1.merge(&cfg2, .overwrite);
    try testing.expectEqualStrings("9000", cfg1.get("PORT").?);

    try cfg1.merge(&cfg2, .skip_existing);
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

    try testing.expectError(Config.ConfigError.KeyConflict, a.merge(&b, .error_on_conflict));
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

test "substitution with fallback dash - and empty value" {
    const allocator = testing.allocator;
    const text =
        \\HOST=
        \\URL=http://${HOST-fallback}
    ;

    var cfg = try Config.parseEnv(text, allocator);
    defer cfg.deinit();

    try testing.expectEqualStrings("http://fallback", cfg.get("URL").?);
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
        \\KEY=\\$100
    ;

    var cfg = try Config.parseEnv(text, allocator);
    defer cfg.deinit();

    try testing.expectEqualStrings("$100", cfg.get("KEY").?);
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
