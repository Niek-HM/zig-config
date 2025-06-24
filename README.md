# zig-config

A lightweight configuration library for Zig. Supports parsing `.env` and `.ini` files with typed access, variable substitution, section handling, merging, and serialization.

# Features
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

## Writing config to disk
```zig
try cfg.writeEnvFile("output.env");
try cfg.writeIniFile("output.ini", allocator);
```

## Merge configs
```zig
try cfg1.merge(&cfg2, .overwrite);
```

## List keys
```zig
const keys = try cfg.keys(allocator);
defer allocator.free(keys);
```