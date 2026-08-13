//! Fixed-point m/z and block-scaled intensity quantization checks.

const std = @import("std");
const quantize = @import("quantize");

test "[property] - [m/z quantization]: representative values stay within the nominal half-step" {
    const scale_factor: u32 = 500_000;
    const tolerance = 0.5 / @as(f64, @floatFromInt(scale_factor));
    const values = [_]f64{ 100.1234567, 456.7890123, 999.9999991 };

    for (values) |value| {
        const encoded = try quantize.quantizeMzValue(value, scale_factor);
        const decoded = try quantize.dequantizeMzValue(encoded, scale_factor);
        try std.testing.expectApproxEqAbs(value, decoded, tolerance);
    }
}

test "[failure] - [m/z quantization]: rejects invalid inputs" {
    try std.testing.expectError(error.InvalidScaleFactor, quantize.quantizeMzValue(100.0, 0));
    try std.testing.expectError(error.NegativeMz, quantize.quantizeMzValue(-1.0, 500_000));
    try std.testing.expectError(error.InvalidMz, quantize.quantizeMzValue(std.math.nan(f64), 500_000));
    try std.testing.expectError(error.InvalidMz, quantize.quantizeMzValue(std.math.inf(f64), 500_000));
    try std.testing.expectError(error.InvalidMz, quantize.quantizeMzValue(-std.math.inf(f64), 500_000));
    try std.testing.expectError(error.Overflow, quantize.quantizeMzValue(std.math.floatMax(f64), 500_000));
    try std.testing.expectError(error.InvalidScaleFactor, quantize.dequantizeMzValue(1, 0));
}

test "[property] - [m/z quantization]: preserves ordering" {
    const input = [_]f64{ 100.0, 100.000002, 100.000004, 101.5 };
    var encoded: [input.len]u64 = undefined;
    for (input, 0..) |value, idx| {
        encoded[idx] = try quantize.quantizeMzValue(value, 500_000);
    }
    for (encoded[1..], encoded[0 .. encoded.len - 1]) |current, previous| {
        try std.testing.expect(current >= previous);
    }
}

test "[property] - [intensity quantization]: uses the block range without saturation" {
    const quant_levels: u16 = 4096;
    const values = [_]f32{ 1.0, 1000.0, 1_000_000.0, 1_400_000_000.0 };
    const log_max = quantize.intensityLogMax(&values);

    var last_encoded: u16 = 0;
    for (values) |value| {
        const encoded = try quantize.quantizeIntensityValueScaled(value, quant_levels, log_max);
        const decoded = try quantize.dequantizeIntensityValueScaled(encoded, quant_levels, log_max);

        try std.testing.expect(encoded >= last_encoded);
        try std.testing.expectApproxEqRel(value, decoded, 0.01);
        last_encoded = encoded;
    }
}

test "[edge] - [intensity quantization]: preserves the smallest positive f32 at the block maximum" {
    const value = std.math.floatTrueMin(f32);
    const quant_levels: u16 = 16384;
    const log_max = quantize.intensityLogMax(&.{value});
    const encoded = try quantize.quantizeIntensityValueScaled(value, quant_levels, log_max);
    const decoded = try quantize.dequantizeIntensityValueScaled(encoded, quant_levels, log_max);

    try std.testing.expectEqual(quant_levels, encoded);
    try std.testing.expectEqual(@as(u32, @bitCast(value)), @as(u32, @bitCast(decoded)));
}

test "[failure] - [intensity quantization]: rejects invalid parameters" {
    try std.testing.expectError(error.InvalidQuantFactor, quantize.quantizeIntensityValueScaled(1.0, 0, 1.0));
    try std.testing.expectError(error.InvalidQuantFactor, quantize.dequantizeIntensityValueScaled(1, 0, 1.0));
    try std.testing.expectError(error.InvalidIntensity, quantize.quantizeIntensityValueScaled(1.0, 4096, std.math.nan(f32)));
    try std.testing.expectError(error.InvalidIntensity, quantize.quantizeIntensityValueScaled(1.0, 4096, -1.0));
    try std.testing.expectError(error.InvalidIntensity, quantize.dequantizeIntensityValueScaled(1, 4096, std.math.nan(f32)));
    try std.testing.expectError(error.InvalidIntensity, quantize.dequantizeIntensityValueScaled(1, 4096, -1.0));
}
