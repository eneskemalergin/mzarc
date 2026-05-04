const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const precision_bits: u5 = 12;
pub const precision: usize = 1 << precision_bits;

pub const Analysis = struct {
    counts: [256]u32,
    len: usize,
    entropy_bits_per_symbol: f64,
    estimated_payload_bytes: usize,
    estimated_total_bytes: usize,
};

const decode_table_mask: u32 = precision - 1;

fn packDecodeEntry(start: u16, freq: u16, symbol: u8) u32 {
    const freq_field: u32 = if (freq == precision) 0 else freq;
    return @as(u32, start) | (freq_field << 12) | (@as(u32, symbol) << 24);
}

const table_entry_count = 256;
const freq_table_bytes = table_entry_count * @sizeOf(u16);
const state_bytes = @sizeOf(u32);
const rans_lower_bound: u32 = 1 << 23;

fn appendIntLe(list: *std.ArrayList(u8), allocator: Allocator, comptime T: type, value: T) !void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .little);
    try list.appendSlice(allocator, &buffer);
}

fn readIntLe(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn countSymbols(symbols: []const u8) [table_entry_count]u32 {
    var counts = [_]u32{0} ** table_entry_count;
    for (symbols) |symbol| counts[symbol] += 1;
    return counts;
}

fn buildAnalysis(counts: [table_entry_count]u32, len: usize) Analysis {
    if (len == 0) {
        return .{
            .counts = counts,
            .len = 0,
            .entropy_bits_per_symbol = 0.0,
            .estimated_payload_bytes = 0,
            .estimated_total_bytes = 0,
        };
    }

    const len_f = @as(f64, @floatFromInt(len));
    var entropy_bits_per_symbol: f64 = 0.0;
    for (counts) |count| {
        if (count == 0) continue;
        const probability = @as(f64, @floatFromInt(count)) / len_f;
        entropy_bits_per_symbol -= probability * std.math.log2(probability);
    }

    const total_bits = entropy_bits_per_symbol * len_f;
    const estimated_payload_bytes = @as(usize, @intFromFloat(@ceil(total_bits / 8.0)));
    const estimated_total_bytes = freq_table_bytes + state_bytes + estimated_payload_bytes;

    return .{
        .counts = counts,
        .len = len,
        .entropy_bits_per_symbol = entropy_bits_per_symbol,
        .estimated_payload_bytes = estimated_payload_bytes,
        .estimated_total_bytes = estimated_total_bytes,
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
        const idx = bestIncrementIndex(counts, remainders);
        freqs[idx] += 1;
        assigned_total += 1;
    }

    while (assigned_total > precision) {
        const idx = bestDecrementIndex(freqs, remainders);
        freqs[idx] -= 1;
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
    var non_zero_symbols: usize = 0;
    for (freqs) |freq| {
        total += freq;
        if (freq != 0) non_zero_symbols += 1;
    }

    if (expected_len == 0) {
        if (non_zero_symbols != 0) return error.InvalidFrequencyTable;
        return;
    }

    if (total != precision) return error.InvalidFrequencyTable;
}

pub fn analyze(symbols: []const u8) Analysis {
    return buildAnalysis(countSymbols(symbols), symbols.len);
}

fn encodeFromCountsAlloc(allocator: Allocator, symbols: []const u8, counts: [table_entry_count]u32) ![]u8 {
    if (symbols.len == 0) return allocator.alloc(u8, 0);

    const freqs = normalizeCounts(counts);
    const starts = buildStarts(freqs);

    var renorm_bytes: std.ArrayList(u8) = .empty;
    defer renorm_bytes.deinit(allocator);

    var state: u32 = rans_lower_bound;
    var index = symbols.len;
    while (index > 0) {
        index -= 1;
        const symbol = symbols[index];
        const freq = freqs[symbol];
        if (freq == 0) return error.InvalidFrequencyTable;

        const x_max = @as(u32, @intCast((((@as(u64, rans_lower_bound) >> precision_bits) << 8) * freq)));
        while (state >= x_max) {
            try renorm_bytes.append(allocator, @truncate(state & 0xff));
            state >>= 8;
        }

        const quotient = @as(u64, state) / freq;
        const remainder = @as(u64, state) % freq;
        state = @intCast((quotient << precision_bits) + remainder + starts[symbol]);
    }

    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(allocator);

    for (freqs) |freq| try appendIntLe(&encoded, allocator, u16, freq);
    try appendIntLe(&encoded, allocator, u32, state);

    var renorm_idx = renorm_bytes.items.len;
    while (renorm_idx > 0) {
        renorm_idx -= 1;
        try encoded.append(allocator, renorm_bytes.items[renorm_idx]);
    }

    return encoded.toOwnedSlice(allocator);
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
    if (encoded.len < freq_table_bytes + state_bytes) return error.UnexpectedEndOfStream;

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
