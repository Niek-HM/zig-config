# zig-config

A lightweight config file parser for `.env` and `.ini` formats written in Zig.

## Supports:
- Flat `.env` and multi-section `.ini` formats
- Access to config values as `string`, `int`, `float`, `bool`
- Section-aware lookup for `.ini` files
- Debug printing and serialization to `.ini`
- Works with `std.StringHashMap`

## Usage

```zig
const std = @import("std");
const config = @import("zig_ini_reader_lib");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var cfg = try config.Config.loadEnvFile(".env", allocator);
    defer cfg.deinit();

    if (cfg.get("API_KEY")) |v| {
        std.debug.print("API_KEY = {s}\n", .{v});
    }
}
```

## 📁 Example .env
```env
API_KEY=abc123
DEBUG=true
PORT=8080
THRESHOLD=0.95
```

## 🧪 Example .ini
```ini
[database]
host = localhost
port = 5432
user = admin

[auth]
enabled = true
```

## 🧰 Usage
### Load .env file
```zig
var cfg = try config.Config.loadEnvFile(".env", allocator);
defer cfg.deinit();
```

### Load .ini file
```zig
var cfg = try config.Config.loadIniFile("config.ini", allocator);
defer cfg.deinit();
```

## 🔍 Lookup Examples
### Get string
```zig
if (cfg.get("API_KEY")) |v| {
    std.debug.print("API_KEY = {s}\n", .{v});
}
```

### Get int
```zig
if (cfg.getInt("PORT")) |port| {
    std.debug.print("Port as int: {d}\n", .{port});
}
```

### Get bool
```zig
if (cfg.getBool("DEBUG")) |debug| {
    std.debug.print("Debug enabled: {}\n", .{debug});
}
```

### Get float
```zig
if (cfg.getFloat("THRESHOLD")) |th| {
    std.debug.print("Threshold: {f}\n", .{th});
}
```

## 🗂 Accessing .ini Sections
```zig
var db = try cfg.getSection("database", allocator);
defer db.deinit();

if (db.get("host")) |host| std.debug.print("Host: {s}\n", .{host});
if (db.getInt("port")) |port| std.debug.print("Port: {}\n", .{port});
```

## 🖨 Debug Print All
```zig
cfg.debugPrint();
```

## 📝 Save to .ini / .env
```zig
try cfg.writeIniFile("out.ini", allocator);
try cfg.writeEnvFile("out.env", allocator);
```

## 🔑 List All Keys
```zig
var keys = try cfg.keys(allocator);
defer allocator.free(keys);

for (keys) |k| {
    std.debug.print("Key: {s}\n", .{k});
}
```