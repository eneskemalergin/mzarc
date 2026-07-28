//! Public block API surface. Logic lives in `block_common`, `block_encode`, and `block_decode`.

const common = @import("block_common");
const encode = @import("block_encode");
const decode = @import("block_decode");

pub const Allocator = common.Allocator;
pub const Mode = common.Mode;
pub const EncodeOptions = common.EncodeOptions;
pub const IntensityEncodingMode = common.IntensityEncodingMode;
pub const BlockEncodeStats = common.BlockEncodeStats;
pub const EncodedBlock = common.EncodedBlock;
pub const BlockHeader = common.BlockHeader;
pub const BlockByteBreakdown = common.BlockByteBreakdown;
pub const flag_lossless_intensity_raw = common.flag_lossless_intensity_raw;
pub const flag_mz_per_spectrum_bit_widths = common.flag_mz_per_spectrum_bit_widths;
pub const flag_split_exponent = common.flag_split_exponent;
pub const flag_lossless_mz_f32 = common.flag_lossless_mz_f32;
pub const flag_delta_scan_id = common.flag_delta_scan_id;
pub const flag_delta_rt = common.flag_delta_rt;
pub const flag_rans_mz = common.flag_rans_mz;
pub const flag_rans_intensity = common.flag_rans_intensity;
pub const header_len = common.header_len;
pub const packedByteLen = common.packedByteLen;
pub const perSpectrumPayloadLen = common.perSpectrumPayloadLen;

pub const encodeBlockDetailed = encode.encodeBlockDetailed;
pub const encodeBlock = encode.encodeBlock;

pub const parseHeader = decode.parseHeader;
pub const decodeBlock = decode.decodeBlock;
pub const decodeBlockWithScratch = decode.decodeBlockWithScratch;
pub const inspectBlockByteBreakdown = decode.inspectBlockByteBreakdown;
