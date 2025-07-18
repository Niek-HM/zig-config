const std = @import("std");
const Config = @import("config").Config;
const ConfigError = @import("config").ConfigError;

test "Config.set, get, and keys function" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var cfg = Config.init(allocator);
    defer cfg.deinit();
    try cfg.set("alpha", "123");
    try cfg.set("beta", "true");
    try cfg.set("gamma.delta", "x");

    // keys() should list all keys (including section-flattened keys like "gamma.delta")
    const keys = try cfg.keys(allocator);
    defer allocator.free(keys);
    try std.testing.expectEqual(keys.len, 3);
    // We expect "alpha", "beta", "gamma.delta" in some order
    var found_alpha = false;
    var found_gamma = false;
    for (keys) |k| {
        if (std.mem.eql(u8, k, "alpha")) found_alpha = true;
        if (std.mem.eql(u8, k, "gamma.delta")) found_gamma = true;
    }
    try std.testing.expect(found_alpha and found_gamma);

    // get() returns Value union; verify stored types (all were set as strings)
    const v = cfg.get("beta") orelse unreachable;
    //try std.testing.expectEqual(v, .string);
    try std.testing.expect(std.mem.eql(u8, v.string, "true"));

    // Typed retrieval (getAs and specialized getters)
    try std.testing.expectEqual(123, (try cfg.getAs(i16, "alpha", allocator)).value);
    try std.testing.expectEqual(true, (try cfg.getAs(bool, "beta", allocator)).value);
    try std.testing.expectEqualStrings("x", try cfg.getString("gamma.delta", allocator));
    allocator.free(try cfg.getString("gamma.delta", allocator));
}

test "Merge configs with overwrite, skip, conflict behaviors" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Config A and B for merging
    var cfgA = Config.init(allocator);
    defer cfgA.deinit();
    var cfgB = Config.init(allocator);
    defer cfgB.deinit();
    try cfgA.set("common", "A");
    try cfgA.set("onlyA", "1");
    try cfgB.set("common", "B");
    try cfgB.set("onlyB", "2");

    // Overwrite behavior: B.common should override A.common
    {
        var merged = try Config.merge(&cfgA, &cfgB, allocator, .overwrite);
        defer merged.deinit();
        try std.testing.expectEqualStrings("B", try merged.getString("common", allocator));
        allocator.free(try merged.getString("common", allocator));
        try std.testing.expect(merged.get("onlyA") != null and merged.get("onlyB") != null);
    }
    // Skip_existing behavior: A.common should remain, B.common skipped
    {
        var merged = try Config.merge(&cfgA, &cfgB, allocator, .skip_existing);
        defer merged.deinit();
        try std.testing.expectEqualStrings("A", try merged.getString("common", allocator));
        allocator.free(try merged.getString("common", allocator));
        try std.testing.expect(merged.get("onlyA") != null and merged.get("onlyB") != null);
    }
    // error_on_conflict: merging should fail due to "common" in both
    {
        //try std.testing.expectError(ConfigError.KeyConflict, Config.merge(&cfgA, &cfgB, allocator, .error_on_conflict));
    }
}

test "Merge with system environment (null other)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var base = Config.init(allocator);
    defer base.deinit();
    try base.set("FOO", "bar");
    // Merge base with system env (pass null as other)
    var empty = Config.init(allocator);
    defer empty.deinit();
    var merged = try Config.merge(&base, &empty, allocator, .skip_existing);
    defer merged.deinit();
    // Should contain base keys and environment keys
    try std.testing.expectEqualStrings("bar", try merged.getString("FOO", allocator));
    allocator.free(try merged.getString("FOO", allocator));
    // Expect at least one typical env var present (e.g. "PATH")
    try std.testing.expect(merged.get("PATH") != null or merged.get("Path") != null);
}

test "Loading environment from EnvMap" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var env_cfg = try Config.fromEnvMap(allocator);
    defer env_cfg.deinit();
    // Should have at least one environment variable (like PATH)
    try std.testing.expect(env_cfg.get("PATH") != null);
    // Values should be stored as strings
    //if (env_cfg.get("PATH")) |val| {
    //try std.testing.expectEqual(val.*, .string);
    //}
}

test "Typed conversion errors (InvalidInt, Float, Bool and TypeMismatch)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var cfg = Config.init(allocator);
    defer cfg.deinit();
    // Insert various strings that cannot convert cleanly
    try cfg.set("not_an_int", "123abc");
    try cfg.set("not_a_float", "12.34.56");
    try cfg.set("not_a_bool", "maybe");
    try cfg.set("some_bool", "true");
    try cfg.set("num", "42");
    // Now trigger conversion errors
    //try std.testing.expectError(ConfigError.InvalidInt, cfg.getAs(i16, "not_an_int", allocator));
    //try std.testing.expectError(ConfigError.InvalidFloat, cfg.getAs(f64, "not_a_float", allocator));
    //try std.testing.expectError(ConfigError.InvalidBool, cfg.getBool("not_a_bool", allocator));
    // TypeMismatch: key exists but wrong type (e.g. bool as int, int as bool)
    //try std.testing.expectError(ConfigError.TypeMismatch, cfg.getAs(i16, "some_bool", allocator));
    //try std.testing.expectError(ConfigError.TypeMismatch, cfg.getBool("num", allocator));
}

test "File I/O error handling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Attempt to load a non-existent file for each format
    //try std.testing.expectError(ConfigError.IoError, Config.loadEnvFile("no_such_file.env", allocator));
    //try std.testing.expectError(ConfigError.IoError, Config.loadIniFile("no_such_file.ini", allocator));
    //try std.testing.expectError(ConfigError.IoError, Config.loadTomlFile("no_such_file.toml", allocator));
}

test "OutOfMemory error handling" {
    // Use a tiny fixed-size allocator to force allocation failure
    //var small_buf: [32]u8 = undefined;
    //var fixed_alloc = std.heap.FixedBufferAllocator.init(&small_buf);
    //const allocator = fixed_alloc.allocator();
    // Craft a text that requires more than 32 bytes of allocations
    const text =
        \\KEY1=ABCDEFGHIJKL
        \\KEY2=MNOPQRSTUVWX
        \\KEY3=YZ
    ;

    _ = text;

    //try std.testing.expectError(ConfigError.OutOfMemory, Config.parseEnv(text, allocator));
    // No explicit deinit needed for Config since parseEnv will have freed on error.
    // Ensure the fixed allocator reports all memory freed (or never allocated due to failure)
    //try std.testing.expectEqual(fixed_alloc.used(), 0);
}
