const std = @import("std");
const config = @import("root.zig");

pub fn main() void {}

test "load env from buffer" {
    const allocator = std.testing.allocator;
    const text = "API_KEY=12345\n" ++
        "DEBUG=true\n" ++
        "PORT=8080\n" ++
        "THRESHOLD=0.75\n";

    var cfg = try config.Config.parseEnv(text, allocator);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("12345", cfg.get("API_KEY") orelse return error.Missing);
    try std.testing.expect(cfg.getBool("DEBUG") orelse false);
    try std.testing.expectEqual(@as(i64, 8080), cfg.getInt("PORT") orelse return error.Missing);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), cfg.getFloat("THRESHOLD") orelse return error.Missing, 0.001);
}

test "load ini from buffer and get section" {
    const allocator = std.testing.allocator;
    const text = "[database]\n" ++
        "host=localhost\n" ++
        "port=5432\n" ++
        "[auth]\n" ++
        "enabled=true\n" ++
        "[misc]\n" ++
        "pi=3.14\n";

    var cfg = try config.Config.parseIni(text, allocator);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("localhost", cfg.get("database.host") orelse return error.Missing);
    try std.testing.expectEqual(@as(i64, 5432), cfg.getInt("database.port") orelse return error.Missing);
    try std.testing.expect(cfg.getBool("auth.enabled") orelse false);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), cfg.getFloat("misc.pi") orelse return error.Missing, 0.001);

    var db_section = try cfg.getSection("database", allocator);
    defer db_section.deinit();

    try std.testing.expectEqualStrings("localhost", db_section.get("host") orelse return error.Missing);
    try std.testing.expectEqual(@as(i64, 5432), db_section.getInt("port") orelse return error.Missing);
}

test "merge configs" {
    const allocator = std.testing.allocator;

    const text1 = "A=1\nB=2\n";
    const text2 = "B=3\nC=4\n";

    var cfg1 = try config.Config.parseEnv(text1, allocator);
    defer cfg1.deinit();

    var cfg2 = try config.Config.parseEnv(text2, allocator);
    defer cfg2.deinit();

    try cfg1.merge(&cfg2);

    try std.testing.expectEqualStrings("1", cfg1.get("A") orelse return error.Missing);
    try std.testing.expectEqualStrings("3", cfg1.get("B") orelse return error.Missing);
    try std.testing.expectEqualStrings("4", cfg1.get("C") orelse return error.Missing);
}

test "no leaks" {
    const allocator = std.testing.allocator;

    var cfg = try config.Config.parseEnv("KEY=val\n", allocator);
    defer cfg.deinit();

    // Ensure no leaks
    //try std.testing.expect(gpa.deinit() == .ok);
}
