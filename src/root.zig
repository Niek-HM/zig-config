pub const Config = @import("config.zig").Config;
pub const Value = @import("value.zig").Value;
pub const OwnedValue = @import("value.zig").OwnedValue;
pub const ConfigError = @import("errors.zig").ConfigError;

pub const utils = @import("utils.zig");
pub const merge = @import("merge.zig");

pub const accessors = @import("accessors.zig");

// Parser modules
pub const parser = struct {
    pub const env = @import("parser/env.zig");
    pub const ini = @import("parser/ini.zig");
    pub const toml = @import("parser/toml.zig");
};

// Writer modules
pub const writer = struct {
    pub const env = @import("writer/env.zig");
    pub const ini = @import("writer/ini.zig");
};
