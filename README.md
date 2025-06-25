# zig-config V0.1.3

A lightweight config parser for Zig with support for `.env` and `.ini` formats, shell-style variable substitution, type-safe access, merging, and system environment fallback.

# Features
### ✅ Parsing
- `.env` files (key=value)
- `.ini` files (with `[sections]`)
- Quoted values (`"..."`) and comments (`#`, `;`)

### ✅ Variable Substitution
Supports shell-like substitution patterns:
- `${VAR}` — simple substitution
- `${VAR:-fallback}` — fallback if unset or empty
- `${VAR-default}` — fallback if unset
- `${VAR:+alt}` — use `alt` if set and non-empty
- `${VAR+alt}` — use `alt` if set
- Supports nesting: `${A:-${B:-default}}`
- Escaping via `\$` for literal dollar signs

### ✅ Environment Integration (New in v0.1.3)
- Load config from `std.process.environ`
- Substitution falls back to system environment (`std.process.getEnvVarOwned`)
- Merge system env into config with conflict behavior:
  - `.overwrite`, `.skip_existing`, `.error_on_conflict`

### ✅ Accessors
- `get(key)` → `?[]const u8`
- `getInt(key)` → `?i64`
- `getBool(key)` → `?bool`
- `getFloat(key)` → `?f64`
- `getAs(comptime T, key)` → `!T`

### ✅ Serialization
- Write back `.env` or `.ini` files
- Optional variable expansion (coming soon)

### ✅ Merging
- Merge configs with conflict behavior:
  - `.overwrite`, `.skip_existing`, `.error_on_conflict`

### ✅ Other
- Detects circular references during substitution
- Clean memory management, no leaks
- Tested on Linux and Windows

# Usage:
## Loading a `.ini` file
```ini
; settings.ini
[database]
host=localhost
user=root
port=5432
```

```zig
const cfg = try Config.loadIniFile("settings.ini", allocator);
// .loadEnvFile for .env and .fromEnvMap(allocator) to load sys variables
defer cfg.deinit();

const host = cfg.get("database.host") orelse "localhost";

const db = try cfg.getSection("database", allocator);
defer db.deinit();

const user = db.get("user") orelse "root";
```

## Variable substitution
```env
HOST=localhost
PORT=8080
URL=http://${HOST}:${PORT}
FALLBACK=${NOT_SET:-default}
```

```zig
const url = try cfg.get("URL"); // http://localhost:8080
const fallback = try cfg.get("FALLBACK"); // "default"
```

### Supported operators:
- `${VAR}` — error if unset
- `${VAR:-fallback}` — fallback if unset or empty
- `${VAR-fallback}` — fallback if unset
- `${VAR:+value}` — use `value` if set and not empty
- `${VAR+value}` — use `value` if set (even if empty)
- Escaped: `\$` → `$`
- Resolution order: `raw` → `config` → `system env`

## Writing config to disk
```zig
try cfg.writeEnvFile("output.env");
try cfg.writeIniFile("output.ini", allocator);
```

## Merge configs
```zig
try cfg1.merge(&cfg2, .overwrite);
```

## List keys and getAs
```zig
const keys = try cfg.keys(allocator);
defer allocator.free(keys);

const get_int: i64 = try cfg.getAs(i64, "ITEM", allocator);
Note: All strings are allocator-owned unless sys env (copied).
```