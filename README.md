# zig-ini-reader

A lightweight config file parser for `.env` and `.ini` formats written in Zig.

## Features

- Supports `.env` and `.ini` formats
- Key/value parsing with comments and quotes
- Typed access: `get()`, `getInt()`, `getBool()`, `getFloat()`
- Flat `StringHashMap` API with optional section-based keys
- No external dependencies

## Usage

```zig
const std = @import("std");
const config = @import("zig_ini_reader");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var cfg = try config.Config.loadEnvFile(".env", allocator);
    defer cfg.deinit();

    if (cfg.get("API_KEY")) |v| {
        std.debug.print("API_KEY = {s}\n", .{v});
    }
}
```