const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub fn quantizeMzValue(value: f64, scale_factor: u32) !u64 {
    if (scale_factor == 0) return error.InvalidScaleFactor;
    if (!std.math.isFinite(value)) return error.InvalidMz;
    if (value < 0.0) return error.NegativeMz;

    const scale = @as(f64, @floatFromInt(scale_factor));
    const scaled = value * scale;
    if (!std.math.isFinite(scaled)) return error.Overflow;

    const rounded = @round(scaled);
    const max_value = @as(f64, @floatFromInt(std.math.maxInt(u64)));
    if (rounded < 0.0 or rounded > max_value) return error.Overflow;

    return @as(u64, @intFromFloat(rounded));
}

pub fn dequantizeMzValue(value: u64, scale_factor: u32) !f64 {
    if (scale_factor == 0) return error.InvalidScaleFactor;

    const scale = @as(f64, @floatFromInt(scale_factor));
    return @as(f64, @floatFromInt(value)) / scale;
}

pub fn quantizeMzArray(allocator: Allocator, values: []const f64, scale_factor: u32) ![]u64 {
    var out = try allocator.alloc(u64, values.len);
    errdefer allocator.free(out);

    for (values, 0..) |value, idx| {
        out[idx] = try quantizeMzValue(value, scale_factor);
    }

    return out;
}

pub fn dequantizeMzArray(allocator: Allocator, values: []const u64, scale_factor: u32) ![]f64 {
    var out = try allocator.alloc(f64, values.len);
    errdefer allocator.free(out);

    for (values, 0..) |value, idx| {
        out[idx] = try dequantizeMzValue(value, scale_factor);
    }

    return out;
}

pub fn quantizeIntensityValue(value: f32, quant_factor: u16) !u16 {
    if (quant_factor == 0) return error.InvalidQuantFactor;
    if (!std.math.isFinite(value)) return error.InvalidIntensity;
    if (value <= 0.0) return 0;

    const scale = @as(f64, @floatFromInt(quant_factor));
    const encoded = @round(std.math.log1p(@as(f64, value)) * scale);
    if (!std.math.isFinite(encoded)) return std.math.maxInt(u16);

    const max_value = @as(f64, @floatFromInt(std.math.maxInt(u16)));
    const clamped = std.math.clamp(encoded, 1.0, max_value);
    return @as(u16, @intFromFloat(clamped));
}

pub fn dequantizeIntensityValue(value: u16, quant_factor: u16) !f32 {
    if (quant_factor == 0) return error.InvalidQuantFactor;
    if (value == 0) return 0.0;

    const scale = @as(f64, @floatFromInt(quant_factor));
    const decoded = std.math.exp(@as(f64, @floatFromInt(value)) / scale) - 1.0;
    if (decoded >= std.math.floatMax(f32)) return std.math.floatMax(f32);
    return @as(f32, @floatCast(decoded));
}

pub fn intensityLogMax(values: []const f32) f32 {
    var max_log: f64 = 0.0;
    for (values) |value| {
        if (value <= 0.0 or !std.math.isFinite(value)) continue;
        const log_value = std.math.log1p(@as(f64, value));
        if (log_value > max_log) max_log = log_value;
    }
    return @as(f32, @floatCast(max_log));
}

pub fn quantizeIntensityValueScaled(value: f32, quant_levels: u16, log_max: f32) !u16 {
    if (quant_levels == 0) return error.InvalidQuantFactor;
    if (!std.math.isFinite(value)) return error.InvalidIntensity;
    if (!std.math.isFinite(log_max) or log_max < 0.0) return error.InvalidIntensity;
    if (value <= 0.0 or log_max == 0.0) return 0;

    const numerator = std.math.log1p(@as(f64, value));
    const denominator = @as(f64, log_max);
    if (denominator <= 0.0) return 0;

    const max_level = @as(f64, @floatFromInt(quant_levels));
    const encoded = @round((numerator / denominator) * max_level);
    const clamped = std.math.clamp(encoded, 1.0, max_level);
    return @as(u16, @intFromFloat(clamped));
}

pub fn dequantizeIntensityValueScaled(value: u16, quant_levels: u16, log_max: f32) !f32 {
    if (quant_levels == 0) return error.InvalidQuantFactor;
    if (!std.math.isFinite(log_max) or log_max < 0.0) return error.InvalidIntensity;
    if (value == 0 or log_max == 0.0) return 0.0;

    const ratio = @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(quant_levels));
    const decoded = std.math.exp(ratio * @as(f64, log_max)) - 1.0;
    if (decoded >= std.math.floatMax(f32)) return std.math.floatMax(f32);
    return @as(f32, @floatCast(decoded));
}

pub fn quantizeIntensityArrayScaled(allocator: Allocator, values: []const f32, quant_levels: u16, log_max: f32) ![]u16 {
    var out = try allocator.alloc(u16, values.len);
    errdefer allocator.free(out);

    for (values, 0..) |value, idx| {
        out[idx] = try quantizeIntensityValueScaled(value, quant_levels, log_max);
    }

    return out;
}

pub fn dequantizeIntensityArrayScaled(allocator: Allocator, values: []const u16, quant_levels: u16, log_max: f32) ![]f32 {
    var out = try allocator.alloc(f32, values.len);
    errdefer allocator.free(out);

    for (values, 0..) |value, idx| {
        out[idx] = try dequantizeIntensityValueScaled(value, quant_levels, log_max);
    }

    return out;
}

pub fn quantizeIntensityArray(allocator: Allocator, values: []const f32, quant_factor: u16) ![]u16 {
    var out = try allocator.alloc(u16, values.len);
    errdefer allocator.free(out);

    for (values, 0..) |value, idx| {
        out[idx] = try quantizeIntensityValue(value, quant_factor);
    }

    return out;
}

pub fn dequantizeIntensityArray(allocator: Allocator, values: []const u16, quant_factor: u16) ![]f32 {
    var out = try allocator.alloc(f32, values.len);
    errdefer allocator.free(out);

    for (values, 0..) |value, idx| {
        out[idx] = try dequantizeIntensityValue(value, quant_factor);
    }

    return out;
}
