//! Fixed-point m/z and block-scaled log-intensity quantization.
//! m/z uses a nominal half-step error plus f64 operation rounding. Intensity uses uniform log1p levels over [0, log_max].

const std = @import("std");

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
    const max_level = @as(f64, @floatFromInt(quant_levels));
    const encoded = @round((numerator / @as(f64, log_max)) * max_level);
    const clamped = std.math.clamp(encoded, 1.0, max_level);
    return @as(u16, @intFromFloat(clamped));
}

pub fn dequantizeIntensityValueScaled(value: u16, quant_levels: u16, log_max: f32) !f32 {
    if (quant_levels == 0) return error.InvalidQuantFactor;
    if (!std.math.isFinite(log_max) or log_max < 0.0) return error.InvalidIntensity;
    if (value == 0 or log_max == 0.0) return 0.0;

    const ratio = @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(quant_levels));
    const decoded = std.math.expm1(ratio * @as(f64, log_max));
    if (decoded >= std.math.floatMax(f32)) return std.math.floatMax(f32);
    return @as(f32, @floatCast(decoded));
}
