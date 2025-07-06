const std = @import("std");
const testing = std.testing;
const Config = @import("config").Config;

test "ini - basic section parsing" {
    const text =
        \\[server]
        \\port=3000
        \\host=localhost
        \\[database]
        \\user=admin
        \\pass=secret
    ;

    var cfg = try Config.parseIni(text, testing.allocator);
    defer cfg.deinit();

    try testing.expectEqualStrings("3000", cfg.get("server.port").?);
    try testing.expectEqualStrings("localhost", cfg.get("server.host").?);
    try testing.expectEqualStrings("admin", cfg.get("database.user").?);
    try testing.expectEqualStrings("secret", cfg.get("database.pass").?);

    std.debug.print("✔ ini - basic section parsing passed\n", .{});
}

test "ini - sectionless keys allowed" {
    const text =
        \\key=value
        \\[section]
        \\k2=v2
    ;

    var cfg = try Config.parseIni(text, testing.allocator);
    defer cfg.deinit();

    try testing.expectEqualStrings("value", cfg.get("key").?);
    try testing.expectEqualStrings("v2", cfg.get("section.k2").?);

    std.debug.print("✔ ini - sectionless keys allowed passed\n", .{});
}

test "ini - repeated keys overwrite" {
    const text =
        \\[app]
        \\key=val1
        \\key=val2
    ;

    var cfg = try Config.parseIni(text, testing.allocator);
    defer cfg.deinit();

    try testing.expectEqualStrings("val2", cfg.get("app.key").?);

    std.debug.print("✔ ini - repeated keys overwrite passed\n", .{});
}

test "ini - getSection extracts keys with prefix" {
    const text =
        \\[core]
        \\debug=true
        \\version=1.0
        \\[other]
        \\skip=yes
    ;

    var cfg = try Config.parseIni(text, testing.allocator);
    defer cfg.deinit();

    var section = try cfg.getSection("core", testing.allocator);
    defer section.deinit();

    try testing.expectEqualStrings("true", section.get("debug").?);
    try testing.expectEqualStrings("1.0", section.get("version").?);
    try testing.expectEqual(null, section.get("skip"));

    std.debug.print("✔ ini - getSection extracts keys passed\n", .{});
}

test "ini - getSection fails if section missing" {
    const text =
        \\[exists]
        \\a=1
    ;

    var cfg = try Config.parseIni(text, testing.allocator);
    defer cfg.deinit();

    try testing.expectError(Config.ConfigError.Missing, cfg.getSection("nope", testing.allocator));

    std.debug.print("✔ ini - getSection fails if section missing passed\n", .{});
}

test "ini - malformed lines cause error" {
    const bad1 = "justgarbage";
    const bad2 = "[ ]";

    try testing.expectError(Config.ConfigError.ParseInvalidLine, Config.parseIni(bad1, testing.allocator));
    try testing.expectError(Config.ConfigError.ParseUnterminatedSection, Config.parseIni(bad2, testing.allocator));

    std.debug.print("✔ ini - malformed lines trigger errors passed\n", .{});
}
