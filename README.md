# zig-config

A lightweight configuration library for Zig. Supports parsing `.env` and `.ini` files with typed access, variable substitution, section handling, merging, and serialization.

## **Features**
- ✅ Parse `.env` files with support for:
  - Comments, quoted values, empty lines
  - Variable substitution: `${VAR}`, `${VAR:-fallback}`, `${VAR:+val}`, etc.
  - Escaped variables like `\$HOME`
- ✅ Parse `.ini` files with `[sections]` and `key=value`
- ✅ Typed access: `getInt()`, `getFloat()`, `getBool()`
- ✅ Section-aware access: `getSection("database")`
- ✅ Merge configs with `overwrite`, `skip_existing`, or `error_on_conflict`
- ✅ Serialize back to `.env` or `.ini` format
- ✅ Full error handling (`InvalidPlaceholder`, `UnknownVariable`, etc.)

## **Usage**
```zig
const Config = @import("config").Config;

const cfg = try Config.parseEnv(
    \PORT=3000
    \DEBUG=true
    \URL=http://${HOST:-localhost}
, allocator);
defer cfg.deinit();

try std.debug.print("Port = {}", .{try cfg.getInt("PORT")});
```

## **INI Sections**
```ini
[database]
host=localhost
port=5432
```
```zig
const db = try cfg.getSection("database", allocator);
try std.debug.print("Host = {s}\n", .{db.get("host").?});
```