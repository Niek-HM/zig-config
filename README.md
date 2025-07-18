# zig-config

A lightweight configuration loader for `.env`, `.ini`, and `.toml` files written in Zig.  
It supports variable substitution, typed access, merging, and exporting to environment maps.

## Features

✅ Parse `.env`, `.ini`, and `.toml` formats  
✅ Access config values as `[]const u8`, `i64`, `f64`, `bool`, or arrays  
✅ Variable substitution (`${VAR}`, `${VAR:-default}`, etc.)  
✅ Merging with control over overwrite behavior  
✅ Load from file, buffer, or environment  
✅ Write back to `.env`, `.ini`, `.toml`  
✅ Fully tested, memory-safe, leak-free  
✅ No dependencies

## Example

```zig
const std = @import("std");
const Config = @import("zig-config").Config;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var cfg = try Config.loadEnvFile("config.env", allocator);
    defer cfg.deinit();

    const port = try cfg.getAs(i64, "PORT", allocator);
    defer port.deinit();

    const debug = try cfg.getAs(bool, "DEBUG", allocator);
    defer debug.deinit();

    const host = try cfg.getAs([]const u8, "HOST", allocator);
    defer host.deinit();

    std.debug.print("Running on {s}:{d} (debug = {})", .{ host, port, debug });
}
```

## Variable Substitution

Supports:

- `${VAR}` → error if `VAR` missing
- `${VAR:-default}` → fallback if missing or empty
- `${VAR-default}` → fallback if missing
- `${VAR:+alt}` → use `alt` if set and not empty
- `${VAR+alt}` → use `alt` if set

Nested substitutions and circular reference detection are supported.

## Merging Configs

```zig
var merged = try config.merge(&other, allocator, .overwrite);
defer merged.deinit();
```

`MergeBehavior` options:

- `.overwrite` → always use new value  
- `.skip_existing` → keep existing  
- `.error_on_conflict` → fail on duplicate keys

## Supported Formats

- `.env`: simple `KEY=value`, comments `#` or `;`
- `.ini`: `[section]` headers + key/value
- `.toml`: full support for strings, arrays, inline tables, booleans, numbers

## Writing Files

```zig
try config.writeEnvFile("output.env");
try config.writeIniFile("output.ini", allocator);
try config.writeTomlFile("output.toml");
```

## Typed Access

```zig
const db_port = try config.getAs(i64, "database.port", allocator);
const features = try config.getAs([]bool, "ENABLED_FLAGS", allocator);
```

Arrays supported: `[]i64`, `[]f64`, `[]bool`, `[][]const u8`

## Roadmap
✅ Short-term goals (v0.3.x)
- [x] Full TOML support (date-time)
- [ ] `.json` config input support
- [ ] `.env.example` validation (check for missing/extra keys)
- [ ] Null-delimited `EnvMap` export for subprocesses
- [ ] Improve write serialization (preserve formatting where possible)
- [ ] CLI tool: merge, diff, validate, and export config

🔭 Long-term goals (v0.4+)
- [ ] Live config reloading (file watching API)
- [ ] SQLite-backed config store (persistent, reloadable)
- [ ] Secrets injection from .secrets.env or Vault-compatible store
- [ ] Typed schema validation (define required fields, expected types)
- [ ] `YAML` support