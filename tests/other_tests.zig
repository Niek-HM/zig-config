const std = @import("std");
const testing = std.testing;
const Config = @import("config").Config;

test "merge - overwrite behavior" {
    const allocator = testing.allocator;

    var a = Config.init(allocator);
    defer a.deinit();
    try a.map.put(try allocator.dupe(u8, "port"), try allocator.dupe(u8, "8000"));

    var b = Config.init(allocator);
    defer b.deinit();
    try b.map.put(try allocator.dupe(u8, "port"), try allocator.dupe(u8, "9000"));
    try b.map.put(try allocator.dupe(u8, "extra"), try allocator.dupe(u8, "yes"));

    try a.merge(&b, allocator, .overwrite);
    try testing.expectEqualStrings("9000", a.get("port").?);
    try testing.expectEqualStrings("yes", a.get("extra").?);

    std.debug.print("✔ merge - overwrite behavior passed\n", .{});
}

test "merge - skip_existing behavior" {
    const allocator = testing.allocator;

    var a = Config.init(allocator);
    defer a.deinit();
    try a.map.put(try allocator.dupe(u8, "port"), try allocator.dupe(u8, "8000"));

    var b = Config.init(allocator);
    defer b.deinit();
    try b.map.put(try allocator.dupe(u8, "port"), try allocator.dupe(u8, "should_be_skipped"));
    try b.map.put(try allocator.dupe(u8, "new_key"), try allocator.dupe(u8, "ok"));

    try a.merge(&b, allocator, .skip_existing);
    try testing.expectEqualStrings("8000", a.get("port").?);
    try testing.expectEqualStrings("ok", a.get("new_key").?);

    std.debug.print("✔ merge - skip_existing behavior passed\n", .{});
}

test "merge - error_on_conflict behavior" {
    const allocator = testing.allocator;

    var a = Config.init(allocator);
    defer a.deinit();
    try a.map.put(try allocator.dupe(u8, "key"), try allocator.dupe(u8, "1"));

    var b = Config.init(allocator);
    defer b.deinit();
    try b.map.put(try allocator.dupe(u8, "key"), try allocator.dupe(u8, "2"));

    try testing.expectError(Config.ConfigError.KeyConflict, a.merge(&b, allocator, .error_on_conflict));

    std.debug.print("✔ merge - error_on_conflict behavior passed\n", .{});
}

test "typed getAs returns Missing" {
    const allocator = testing.allocator;
    var cfg = Config.init(allocator);
    defer cfg.deinit();

    try testing.expectError(Config.ConfigError.Missing, cfg.getAs(i64, "missing", allocator));
    try testing.expectError(Config.ConfigError.Missing, cfg.getAs(bool, "missing", allocator));
    try testing.expectError(Config.ConfigError.Missing, cfg.getAs([]const u8, "missing", allocator));

    std.debug.print("✔ typed getAs returns Missing on missing key\n", .{});
}

test "typed getAs errors for invalid values" {
    const allocator = testing.allocator;
    var cfg = Config.init(allocator);
    defer cfg.deinit();

    try cfg.map.put(try allocator.dupe(u8, "bad_int"), try allocator.dupe(u8, "abc"));
    try cfg.map.put(try allocator.dupe(u8, "bad_bool"), try allocator.dupe(u8, "maybe"));

    try testing.expectError(Config.ConfigError.InvalidInt, cfg.getAs(i64, "bad_int", allocator));
    try testing.expectError(Config.ConfigError.InvalidBool, cfg.getAs(bool, "bad_bool", allocator));

    std.debug.print("✔ typed getAs errors for invalid values passed\n", .{});
}
