## zig-config
A simple `.env` and `.ini` config loader for Zig.
Version: 0.1.1

## Features
- ✅ Load and parse `.env` and `.ini` config strings or files
- ✅ Get values as string, int, float, or bool
- ✅ Merge configs (override values)
- ✅ Extract sections as sub-configs
- ✅ Save config as `.env` or `.ini`
- ✅ Debug print and list all keys
- ✅ Zero dependencies

## Usage
```zig
const Config = @import("zig-config").Config;
const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var cfg = try Config.parseEnv(
        \\API_KEY=secret
        \\PORT=3000
        , allocator);
    defer cfg.deinit();

    const port = cfg.getInt("PORT") orelse 8080;
    std.debug.print("Port: {}
", .{port});
}
```

## Examples
Load from .env buffer

```zig
var cfg = try Config.parseEnv("FOO=bar\nDEBUG=true\n", allocator);
```

Load from .ini buffer
```zig
var cfg = try Config.parseIni("[server]\nport=8080\n", allocator);
```

Get string
```zig
if (cfg.get("FOO")) |val| std.debug.print("{s}\n", .{val});
```

Get int
```zig
if (cfg.getInt("PORT")) |port| {
    std.debug.print("Port: {d}\n", .{port});
}
```

Get float
```zig
if (cfg.getFloat("THRESHOLD")) |t| {
    std.debug.print("Threshold: {e}\n", .{t});
}
```

Get bool
```zig
if (cfg.getBool("DEBUG")) |flag| {
    std.debug.print("Debug mode: {s}\n", .{flag});
}
```

List all keys
```zig
const keys = try cfg.keys(allocator);
defer allocator.free(keys);
for (keys) |k| std.debug.print("Key: {s}\n", .{k});
```

Get section
```zig
var section = try cfg.getSection("server", allocator);
defer section.deinit();

if (section.getInt("port")) |p| {
    std.debug.print("Server port: {d}\n", .{p});
}
```

Save as .env file
```zig
try cfg.writeEnvFile("output.env");
```

Save as .ini file
```zig
try cfg.writeIniFile("output.ini", allocator);
```

Merge configs
```zig
try cfg1.merge(&cfg2); // values in cfg2 override cfg1
```
