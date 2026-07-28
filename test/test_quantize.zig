const std = @import("std");
const quantize = @import("quantize");

test "m/z quantization round-trips within half a step" {
    const scale_factor: u32 = 500_000;
    const tolerance = 0.5 / @as(f64, @floatFromInt(scale_factor));
    const values = [_]f64{ 100.1234567, 456.7890123, 999.9999991 };

    for (values) |value| {
        const encoded = try quantize.quantizeMzValue(value, scale_factor);
        const decoded = try quantize.dequantizeMzValue(encoded, scale_factor);
        try std.testing.expectApproxEqAbs(value, decoded, tolerance);
    }
}

test "m/z quantization rejects invalid inputs" {
    try std.testing.expectError(error.InvalidScaleFactor, quantize.quantizeMzValue(100.0, 0));
    try std.testing.expectError(error.NegativeMz, quantize.quantizeMzValue(-1.0, 500_000));
    try std.testing.expectError(error.InvalidMz, quantize.quantizeMzValue(std.math.nan(f64), 500_000));
    try std.testing.expectError(error.InvalidMz, quantize.quantizeMzValue(std.math.inf(f64), 500_000));
    try std.testing.expectError(error.InvalidMz, quantize.quantizeMzValue(-std.math.inf(f64), 500_000));
    try std.testing.expectError(error.Overflow, quantize.quantizeMzValue(std.math.floatMax(f64), 500_000));
    try std.testing.expectError(error.InvalidScaleFactor, quantize.dequantizeMzValue(1, 0));
}

test "m/z quantization preserves ordering" {
    const input = [_]f64{ 100.0, 100.000002, 100.000004, 101.5 };
    var encoded: [input.len]u64 = undefined;
    for (input, 0..) |value, idx| {
        encoded[idx] = try quantize.quantizeMzValue(value, 500_000);
    }
    for (encoded[1..], encoded[0 .. encoded.len - 1]) |current, previous| {
        try std.testing.expect(current >= previous);
    }
}

test "intensity quantization maps non-positive values to zero" {
    try std.testing.expectEqual(@as(u16, 0), try quantize.quantizeIntensityValue(0.0, 1024));
    try std.testing.expectEqual(@as(u16, 0), try quantize.quantizeIntensityValue(-4.0, 1024));
    try std.testing.expectEqual(@as(f32, 0.0), try quantize.dequantizeIntensityValue(0, 1024));
}

test "intensity quantization is monotonic and approximately invertible" {
    const quant_factor: u16 = 4096;
    const values = [_]f32{ 0.1, 1.0, 10.0, 100.0, 1000.0 };

    var last_encoded: u16 = 0;
    for (values) |value| {
        const encoded = try quantize.quantizeIntensityValue(value, quant_factor);
        const decoded = try quantize.dequantizeIntensityValue(encoded, quant_factor);

        try std.testing.expect(encoded > last_encoded);
        try std.testing.expectApproxEqRel(value, decoded, 0.01);
        last_encoded = encoded;
    }
}

test "intensity quantization rejects invalid configuration and NaN" {
    try std.testing.expectError(error.InvalidQuantFactor, quantize.quantizeIntensityValue(1.0, 0));
    try std.testing.expectError(error.InvalidQuantFactor, quantize.dequantizeIntensityValue(1, 0));
    try std.testing.expectError(error.InvalidIntensity, quantize.quantizeIntensityValue(std.math.nan(f32), 1024));
    try std.testing.expectError(error.InvalidIntensity, quantize.quantizeIntensityValue(std.math.inf(f32), 1024));
    try std.testing.expectError(error.InvalidIntensity, quantize.quantizeIntensityValue(-std.math.inf(f32), 1024));
}

test "scaled intensity quantization uses block-local range without saturating large values" {
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

test "intensity quantization handles near-zero and saturation boundaries" {
    const tiny = std.math.floatMin(f32);
    const encoded_tiny = try quantize.quantizeIntensityValue(tiny, 4096);
    try std.testing.expect(encoded_tiny >= 1);

    const saturated = try quantize.quantizeIntensityValue(std.math.floatMax(f32), 4096);
    try std.testing.expectEqual(std.math.maxInt(u16), saturated);

    const decoded_saturated = try quantize.dequantizeIntensityValue(std.math.maxInt(u16), 4096);
    try std.testing.expect(std.math.isFinite(decoded_saturated));
}

test "scaled intensity quantization rejects invalid log maxima" {
    try std.testing.expectError(error.InvalidQuantFactor, quantize.quantizeIntensityValueScaled(1.0, 0, 1.0));
    try std.testing.expectError(error.InvalidQuantFactor, quantize.dequantizeIntensityValueScaled(1, 0, 1.0));
    try std.testing.expectError(error.InvalidIntensity, quantize.quantizeIntensityValueScaled(1.0, 4096, std.math.nan(f32)));
    try std.testing.expectError(error.InvalidIntensity, quantize.quantizeIntensityValueScaled(1.0, 4096, -1.0));
    try std.testing.expectError(error.InvalidIntensity, quantize.dequantizeIntensityValueScaled(1, 4096, std.math.nan(f32)));
    try std.testing.expectError(error.InvalidIntensity, quantize.dequantizeIntensityValueScaled(1, 4096, -1.0));
}
