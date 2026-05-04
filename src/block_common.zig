const std = @import("std");
const builtin = @import("builtin");
const binary_reader = @import("binary_reader");
const quantize = @import("quantize");
const bitpack = @import("bitpack");
const rans = @import("rans");

pub const Allocator = std.mem.Allocator;

pub const Mode = enum {
    lossless,
    lossy,
};

pub const EncodeOptions = struct {
    mode: Mode = .lossless,
    mz_scale_factor: u32 = 500_000,
    lossless_mz_scale_factor: u32 = 1_000_000_000,
    intensity_quant: u16 = 16384,
    mz_rans_min_gain_percent: u8 = 5,
    intensity_rans_min_gain_percent: u8 = 12,
    verbose_blocks: bool = false,
};

pub const IntensityEncodingMode = enum {
    raw_plain,
    split_plain,
    split_rans,
    lossy_plain,
    lossy_rans,
};

pub const BlockEncodeStats = struct {
    ms_level: u8,
    spectrum_count: usize,
    total_peaks: usize,
    mz_per_spectrum_widths: bool,
    mz_raw_bytes: usize,
    mz_stored_bytes: usize,
    mz_rans_used: bool,
    mz_estimated_rans_bytes: usize,
    intensity_raw_f32_bytes: usize,
    intensity_base_bytes: usize,
    intensity_stored_bytes: usize,
    intensity_rans_used: bool,
    intensity_estimated_rans_bytes: usize,
    intensity_mode: IntensityEncodingMode,
    payload_bytes: usize,
};

pub const EncodedBlock = struct {
    bytes: []u8,
    stats: BlockEncodeStats,

    pub fn deinit(self: EncodedBlock, allocator: Allocator) void {
        allocator.free(self.bytes);
    }
};

pub const RansCandidate = struct {
    encoded: ?[]u8,
    estimated_total_bytes: usize,
    raw_bytes: usize,

    pub fn storedBytes(self: RansCandidate) usize {
        if (self.encoded) |encoded| return encoded.len;
        return self.raw_bytes;
    }

    pub fn used(self: RansCandidate) bool {
        return self.encoded != null;
    }

    pub fn deinit(self: RansCandidate, allocator: Allocator) void {
        if (self.encoded) |encoded| allocator.free(encoded);
    }
};

pub const BlockHeader = struct {
    spectrum_count: u16,
    ms_level: u8,
    flags: u8,
    total_peaks: u32,
    mz_scale_factor: u32,
    intensity_quant: u16,
    reserved0: u16,
    mz_bit_width: u8,
    intensity_bit_width: u8,
    reserved1: u16,
    rt_min: f32,
    rt_max: f32,
    payload_bytes: u32,
    decompressed_bytes: u32,
    checksum: u32,
};

pub const BlockByteBreakdown = struct {
    header_bytes: usize,
    scan_id_bytes: usize,
    rt_bytes: usize,
    precursor_bytes: usize,
    peak_count_bytes: usize,
    mz_metadata_bytes: usize,
    mz_payload_bytes: usize,
    intensity_metadata_bytes: usize,
    intensity_payload_bytes: usize,
    total_bytes: usize,
};

pub const flag_lossless_intensity_raw: u8 = 0b0000_0001;
pub const flag_mz_per_spectrum_bit_widths: u8 = 0b0000_0010;
pub const flag_split_exponent: u8 = 0b0000_0100;
pub const flag_lossless_mz_f32: u8 = 0b0000_1000;
pub const flag_delta_scan_id: u8 = 0b0001_0000;
pub const flag_delta_rt: u8 = 0b0010_0000;
pub const flag_rans_mz: u8 = 0b0100_0000;
pub const flag_rans_intensity: u8 = 0b1000_0000;
pub const header_len = 40;

pub fn combineU32(low: u16, high: u16) u32 {
    return @as(u32, low) | (@as(u32, high) << 16);
}

pub fn encodeIntensityLogScale(value: f32) struct { low: u16, high: u16 } {
    const bits = @as(u32, @bitCast(value));
    return .{
        .low = @intCast(bits & 0xffff),
        .high = @intCast((bits >> 16) & 0xffff),
    };
}

pub fn decodeIntensityLogScale(header: BlockHeader) f32 {
    return @as(f32, @bitCast(combineU32(header.reserved0, header.reserved1)));
}

pub fn appendIntLe(list: *std.ArrayList(u8), allocator: Allocator, comptime T: type, value: T) !void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .little);
    try list.appendSlice(allocator, &buffer);
}

pub fn appendF32Le(list: *std.ArrayList(u8), allocator: Allocator, value: f32) !void {
    try appendIntLe(list, allocator, u32, @as(u32, @bitCast(value)));
}

pub fn appendF64Le(list: *std.ArrayList(u8), allocator: Allocator, value: f64) !void {
    try appendIntLe(list, allocator, u64, @as(u64, @bitCast(value)));
}

pub fn readIntLe(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

pub fn readF32Le(bytes: []const u8) f32 {
    return @bitCast(readIntLe(u32, bytes));
}

pub fn readF64Le(bytes: []const u8) f64 {
    return @bitCast(readIntLe(u64, bytes));
}

pub fn packedByteLen(bit_width: u8, count: usize) usize {
    if (bit_width == 0) return 0;
    return ((@as(usize, bit_width) * count) + 7) / 8;
}

pub fn totalPeakCount(spectra: []const binary_reader.RawSpectrum) !usize {
    var total: usize = 0;
    for (spectra) |spectrum| {
        if (spectrum.mz.len != spectrum.intensity.len) return error.MismatchedPeakArrays;
        total += spectrum.mz.len;
    }
    return total;
}

pub fn allMzExactlyF32(spectra: []const binary_reader.RawSpectrum) bool {
    for (spectra) |spectrum| {
        for (spectrum.mz) |value| {
            if (@as(f64, @as(f32, @floatCast(value))) != value) return false;
        }
    }
    return true;
}

pub fn perSpectrumPayloadLen(bit_widths: []const u8, peak_counts: []const u32) !usize {
    if (bit_widths.len != peak_counts.len) return error.InvalidPeakCount;

    var total: usize = 0;
    for (peak_counts, 0..) |peak_count, idx| {
        total += packedByteLen(bit_widths[idx], peak_count);
    }
    return total;
}

pub fn shouldUseRans(encoded_len: usize, raw_len: usize, min_gain_percent: u8) bool {
    if (raw_len == 0 or encoded_len >= raw_len) return false;
    const required = 100 - @min(@as(usize, min_gain_percent), 99);
    return encoded_len * 100 < raw_len * required;
}

pub fn maybeEncodeRansAlloc(allocator: Allocator, raw: []const u8, min_gain_percent: u8) !RansCandidate {
    if (raw.len == 0) {
        return .{
            .encoded = null,
            .estimated_total_bytes = 0,
            .raw_bytes = 0,
        };
    }

    const analysis = rans.analyze(raw);
    if (!shouldUseRans(analysis.estimated_total_bytes, raw.len, min_gain_percent)) {
        return .{
            .encoded = null,
            .estimated_total_bytes = analysis.estimated_total_bytes,
            .raw_bytes = raw.len,
        };
    }

    const encoded = try rans.encodeAnalyzedAlloc(allocator, raw, analysis);
    errdefer allocator.free(encoded);
    if (!shouldUseRans(encoded.len, raw.len, min_gain_percent)) {
        allocator.free(encoded);
        return .{
            .encoded = null,
            .estimated_total_bytes = analysis.estimated_total_bytes,
            .raw_bytes = raw.len,
        };
    }

    return .{
        .encoded = encoded,
        .estimated_total_bytes = analysis.estimated_total_bytes,
        .raw_bytes = raw.len,
    };
}
