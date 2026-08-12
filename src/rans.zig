//! Order-0 rANS for byte streams (12-bit frequency precision); encode/decode bit-exact.
//! Wire: 256 x u16 LE freqs, u32 LE state, then renorm bytes (decode reads low-address-first).
//! Fail closed on truncation, trailing bytes, bad freqs, and invalid state.
//! Caller owns `*Alloc` buffers; `decodeInto` writes into caller `out`.

const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const Analysis = struct {
    counts: [256]u32,
    len: usize,
    estimated_total_bytes: usize,
};

const precision_bits: u5 = 12;
const precision: usize = 1 << precision_bits;
const table_entry_count = 256;
const freq_table_bytes = table_entry_count * @sizeOf(u16);
const state_bytes = @sizeOf(u32);
const encoded_header_bytes = freq_table_bytes + state_bytes;
const rans_lower_bound: u32 = 1 << 23;
const decode_table_mask: u32 = precision - 1;
const reciprocal_scale: u64 = 1 << 32;

/// Returns the largest encoded stream accepted for `decoded_len` bytes.
pub fn maxEncodedLen(decoded_len: usize) !usize {
    if (decoded_len == 0) return 0;
    return std.math.add(usize, encoded_header_bytes, try std.math.mul(usize, decoded_len, 2));
}

pub fn analyze(symbols: []const u8) Analysis {
    return buildAnalysis(countSymbols(symbols), symbols.len);
}

pub fn encodeAlloc(allocator: Allocator, symbols: []const u8) ![]u8 {
    return encodeFromCountsAlloc(allocator, symbols, countSymbols(symbols));
}

pub fn encodeAnalyzedAlloc(allocator: Allocator, symbols: []const u8, analysis: Analysis) ![]u8 {
    if (analysis.len != symbols.len) return error.InvalidAnalysis;
    return encodeFromCountsAlloc(allocator, symbols, analysis.counts);
}

pub fn decodeInto(encoded: []const u8, out: []u8) !void {
    if (out.len == 0) {
        if (encoded.len != 0) return error.TrailingData;
        return;
    }
    if (encoded.len < encoded_header_bytes) return error.UnexpectedEndOfStream;

    var freqs = [_]u16{0} ** table_entry_count;
    var offset: usize = 0;
    for (0..table_entry_count) |idx| {
        freqs[idx] = readIntLe(u16, encoded[offset .. offset + @sizeOf(u16)]);
        offset += @sizeOf(u16);
    }
    try validateFreqTable(freqs, out.len);

    const starts = buildStarts(freqs);
    const decode_table = buildDecodeTable(freqs, starts);

    var state = readIntLe(u32, encoded[offset .. offset + state_bytes]);
    offset += state_bytes;
    if (state < rans_lower_bound) return error.InvalidState;

    const encoded_end = encoded.len;
    for (out) |*symbol_out| {
        const slot = state & decode_table_mask;
        const entry = decode_table[slot];
        symbol_out.* = @truncate(entry >> 24);
        const start: u32 = entry & 0x0fff;
        const packed_freq: u32 = (entry >> 12) & 0x0fff;
        const freq: u32 = if (packed_freq == 0) @as(u32, precision) else packed_freq;

        // Product fits in u32: freq <= 4096, state >> 12 <= ~1M.
        state = (freq * (state >> precision_bits)) + (slot - start);

        while (state < rans_lower_bound) {
            if (offset >= encoded_end) return error.UnexpectedEndOfStream;
            state = (state << 8) | encoded[offset];
            offset += 1;
        }
    }

    if (offset != encoded.len) return error.TrailingData;
}

pub fn decodeAlloc(allocator: Allocator, encoded: []const u8, expected_len: usize) ![]u8 {
    if (expected_len == 0) {
        if (encoded.len != 0) return error.TrailingData;
        return allocator.alloc(u8, 0);
    }
    const decoded = try allocator.alloc(u8, expected_len);
    errdefer allocator.free(decoded);
    try decodeInto(encoded, decoded);
    return decoded;
}

fn readIntLe(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn packDecodeEntry(start: u16, freq: u16, symbol: u8) u32 {
    // freq==precision does not fit in 12 bits; 0 is the decode sentinel.
    const freq_field: u32 = if (freq == precision) 0 else freq;
    return @as(u32, start) | (freq_field << 12) | (@as(u32, symbol) << 24);
}

fn countSymbols(symbols: []const u8) [table_entry_count]u32 {
    var counts = [_]u32{0} ** table_entry_count;
    for (symbols) |symbol| counts[symbol] += 1;
    return counts;
}

fn buildAnalysis(counts: [table_entry_count]u32, len: usize) Analysis {
    if (len == 0) {
        return .{ .counts = counts, .len = 0, .estimated_total_bytes = 0 };
    }

    const len_f = @as(f64, @floatFromInt(len));
    var entropy_bits: f64 = 0.0;
    for (counts) |count| {
        if (count == 0) continue;
        const probability = @as(f64, @floatFromInt(count)) / len_f;
        entropy_bits -= probability * std.math.log2(probability);
    }

    const estimated_payload_bytes = @as(usize, @intFromFloat(@ceil(entropy_bits * len_f / 8.0)));
    return .{
        .counts = counts,
        .len = len,
        .estimated_total_bytes = freq_table_bytes + state_bytes + estimated_payload_bytes,
    };
}

fn bestIncrementIndex(counts: [table_entry_count]u32, remainders: [table_entry_count]u64) usize {
    var best_idx: usize = 0;
    var found = false;
    for (0..table_entry_count) |idx| {
        if (counts[idx] == 0) continue;
        if (!found or remainders[idx] > remainders[best_idx] or (remainders[idx] == remainders[best_idx] and counts[idx] > counts[best_idx])) {
            best_idx = idx;
            found = true;
        }
    }
    return best_idx;
}

fn bestDecrementIndex(freqs: [table_entry_count]u16, remainders: [table_entry_count]u64) usize {
    var best_idx: usize = 0;
    var found = false;
    for (0..table_entry_count) |idx| {
        if (freqs[idx] <= 1) continue;
        if (!found or remainders[idx] < remainders[best_idx] or (remainders[idx] == remainders[best_idx] and freqs[idx] > freqs[best_idx])) {
            best_idx = idx;
            found = true;
        }
    }
    return best_idx;
}

fn normalizeCounts(counts: [table_entry_count]u32) [table_entry_count]u16 {
    var total: u64 = 0;
    for (counts) |count| total += count;
    if (total == 0) return [_]u16{0} ** table_entry_count;

    var freqs = [_]u16{0} ** table_entry_count;
    var remainders = [_]u64{0} ** table_entry_count;
    var assigned_total: usize = 0;

    for (0..table_entry_count) |idx| {
        const count = counts[idx];
        if (count == 0) continue;

        const scaled = @as(u64, count) * precision;
        var assigned: u16 = @intCast(scaled / total);
        if (assigned == 0) assigned = 1;

        freqs[idx] = assigned;
        remainders[idx] = scaled % total;
        assigned_total += assigned;
    }

    while (assigned_total < precision) {
        freqs[bestIncrementIndex(counts, remainders)] += 1;
        assigned_total += 1;
    }
    while (assigned_total > precision) {
        freqs[bestDecrementIndex(freqs, remainders)] -= 1;
        assigned_total -= 1;
    }
    return freqs;
}

fn buildStarts(freqs: [table_entry_count]u16) [table_entry_count]u16 {
    var starts = [_]u16{0} ** table_entry_count;
    var running: u16 = 0;
    for (0..table_entry_count) |idx| {
        starts[idx] = running;
        running += freqs[idx];
    }
    return starts;
}

fn buildDecodeTable(freqs: [table_entry_count]u16, starts: [table_entry_count]u16) [precision]u32 {
    var table = [_]u32{0} ** precision;
    for (0..table_entry_count) |idx| {
        const start = starts[idx];
        const freq = freqs[idx];
        for (0..freq) |slot| table[start + slot] = packDecodeEntry(start, freq, @intCast(idx));
    }
    return table;
}

fn validateFreqTable(freqs: [table_entry_count]u16, expected_len: usize) !void {
    var total: usize = 0;
    for (freqs) |freq| total += freq;
    if (expected_len == 0) {
        if (total != 0) return error.InvalidFrequencyTable;
        return;
    }
    if (total != precision) return error.InvalidFrequencyTable;
}

fn reciprocalFor(freq: u16) u64 {
    return (reciprocal_scale + freq - 1) / freq;
}

fn exactQuotient(state: u32, freq: u16, reciprocal: u64) u64 {
    const state_wide: u64 = state;
    const freq_wide: u64 = freq;
    // The ceil reciprocal can overestimate the u32 quotient by at most one.
    const estimate = (state_wide * reciprocal) >> 32;
    return estimate - @intFromBool(estimate * freq_wide > state_wide);
}

fn encodeFromCountsAlloc(allocator: Allocator, symbols: []const u8, counts: [table_entry_count]u32) ![]u8 {
    if (symbols.len == 0) return allocator.alloc(u8, 0);

    const freqs = normalizeCounts(counts);
    const starts = buildStarts(freqs);
    var reciprocals = [_]u64{0} ** table_entry_count;
    for (freqs, 0..) |freq, idx| {
        if (freq != 0) reciprocals[idx] = reciprocalFor(freq);
    }
    const initial_capacity = std.math.add(usize, encoded_header_bytes, symbols.len) catch return error.OutOfMemory;

    var encoded = try std.ArrayList(u8).initCapacity(allocator, initial_capacity);
    errdefer encoded.deinit(allocator);
    _ = encoded.addManyAsSliceAssumeCapacity(encoded_header_bytes);

    var state: u32 = rans_lower_bound;
    var index = symbols.len;
    while (index > 0) {
        index -= 1;
        const symbol = symbols[index];
        const freq = freqs[symbol];
        if (freq == 0) return error.InvalidFrequencyTable;

        const x_max: u32 = @intCast((((@as(u64, rans_lower_bound) >> precision_bits) << 8) * freq));
        while (state >= x_max) {
            try encoded.append(allocator, @truncate(state & 0xff));
            state >>= 8;
        }

        const quotient = exactQuotient(state, freq, reciprocals[symbol]);
        const remainder = @as(u64, state) - quotient * freq;
        state = @intCast((quotient << precision_bits) + remainder + starts[symbol]);
    }

    std.mem.reverse(u8, encoded.items[encoded_header_bytes..]);
    var offset: usize = 0;
    for (freqs) |freq| {
        std.mem.writeInt(u16, encoded.items[offset..][0..@sizeOf(u16)], freq, .little);
        offset += @sizeOf(u16);
    }
    std.mem.writeInt(u32, encoded.items[offset..][0..state_bytes], state, .little);

    return encoded.toOwnedSlice(allocator);
}
