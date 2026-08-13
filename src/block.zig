//! Public block API surface. Logic lives in `block_common`, `block_encode`, and `block_decode`.

const common = @import("block_common");
const encode = @import("block_encode");
const decode = @import("block_decode");

pub const EncodeOptions = common.EncodeOptions;
pub const IntensityEncodingMode = common.IntensityEncodingMode;
pub const BlockEncodeStats = common.BlockEncodeStats;
pub const BlockHeader = common.BlockHeader;
pub const BlockByteBreakdown = common.BlockByteBreakdown;
pub const flag_lossless_intensity_raw = common.flag_lossless_intensity_raw;
pub const flag_lossless_mz_f64 = common.flag_lossless_mz_f64;
pub const flag_split_exponent = common.flag_split_exponent;
pub const flag_lossless_mz_f32 = common.flag_lossless_mz_f32;
pub const flag_delta_scan_id = common.flag_delta_scan_id;
pub const flag_delta_rt = common.flag_delta_rt;
pub const flag_rans_mz = common.flag_rans_mz;
pub const flag_rans_intensity = common.flag_rans_intensity;
pub const header_len = common.header_len;
pub const packedByteLen = common.packedByteLen;
pub const MAX_BLOCK_SPECTRA = common.MAX_BLOCK_SPECTRA;
pub const MAX_BLOCK_PEAKS = common.MAX_BLOCK_PEAKS;
pub const logicalBlockBytes = common.logicalBlockBytes;
pub const maxBlockPayloadBytes = common.maxBlockPayloadBytes;
pub const validateBlockCounts = common.validateBlockCounts;
pub const validateBlockHeaderResources = common.validateBlockHeaderResources;
pub const blockNeedsFlush = common.blockNeedsFlush;

pub const encodeBlockDetailed = encode.encodeBlockDetailed;
pub const encodeBlock = encode.encodeBlock;

pub const parseHeader = decode.parseHeader;
pub const verifyBlockChecksum = decode.verifyBlockChecksum;
pub const decodeBlock = decode.decodeBlock;
pub const decodeBlockWithScratch = decode.decodeBlockWithScratch;
pub const inspectBlockByteBreakdown = decode.inspectBlockByteBreakdown;
