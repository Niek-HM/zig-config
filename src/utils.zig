const std = @import("std");

pub fn parseVariableExpression(expr: []const u8) !struct {
    var_name: []const u8,
    fallback: ?[]const u8,
    operator: enum { none, colon_dash, dash, colon_plus, plus },
} {
    // Determine the opirator
    if (std.mem.indexOf(u8, expr, ":-")) |idx| {
        return .{
            .var_name = expr[0..idx],
            .fallback = expr[idx + 2 ..],
            .operator = .colon_dash,
        };
    } else if (std.mem.indexOf(u8, expr, "-")) |idx| {
        return .{
            .var_name = expr[0..idx],
            .fallback = expr[idx + 1 ..],
            .operator = .dash,
        };
    } else if (std.mem.indexOf(u8, expr, ":+")) |idx| {
        return .{
            .var_name = expr[0..idx],
            .fallback = expr[idx + 2 ..],
            .operator = .colon_plus,
        };
    } else if (std.mem.indexOf(u8, expr, "+")) |idx| {
        return .{
            .var_name = expr[0..idx],
            .fallback = expr[idx + 1 ..],
            .operator = .plus,
        };
    } else {
        return .{
            .var_name = expr,
            .fallback = null,
            .operator = .none,
        };
    }
}
