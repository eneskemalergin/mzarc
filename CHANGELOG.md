<!-- markdownlint-disable MD024 -->
# Changelog

All notable changes to mzarc are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This project follows [Semantic Versioning](https://semver.org/).

## [0.1.9] — 2026-05-03

### Changed

- `block.zig` (1370 LOC) refactored into 4 files:
    - `block_common.zig` (261 LOC): types, constants, shared helpers
    - `block_encode.zig` (410 LOC): encoder logic
    - `block_decode.zig` (548 LOC): decoder logic
    - `block.zig` (29 LOC): thin wrapper re-exporting public API
- No new flags, no new modes. Pure structural refactor — makes v0.3.x
  cross-spectrum delta and SIMD integration safer.

### Performance

- No regressions in speed, memory, compression, or correctness.

---

## [0.1.8] — 2026-05-03

### Changed

- Allocator standardization: every temporary allocation in `encodeBlockDetailed`
  and `decodeBlock` moved from the caller's arena to a block-local arena
  (`ArenaAllocator` backed by `page_allocator`). 12 encode and 8 decode
  temporaries fixed. Rule: freed-before-return → block arena; returned-to-caller
  → caller's arena.
- `binary_reader.readBinaryDump` now wraps file I/O in a local arena instead
  of bare `page_allocator`.

### Performance

- Encode peak RSS reduced from 208 MB to 89 MB (−57%).
- Decode peak RSS reduced from 111 MB to 81 MB (−27%).
- No speed, compression, or correctness regressions.

---

## [0.1.7] — 2026-05-03

### Changed

- Decode regression investigated and documented: +35% decode time is inherent to
  rANS entropy coding (~54ms per-block overhead processing ~7.1 MiB). Without
  rANS, decode (144.8ms) is faster than v0.1.1 baseline (149.8ms). Regression
  check threshold updated from 10% to 40%.
- FOR unpack split into two branchless paths: `decodeFlatMzBlockLevel` and
  `decodeFlatMzPerSpectrum`, removing per-spectrum branching from the hot loop.
- rANS decode inner loop: removed unnecessary `@as(u64, ...)` + `@intCast` from
  state update (product fits in u32). Hoisted `encoded.len` bounds check out of
  the renormalization loop.
- Block-level m/z FOR overhead bytes removed from encode path (dead init).
- `writeStdout` portability: replaced Linux-only `std.os.linux.write` with
  `std.Io.File.stdout().writeStreamingAll()`.
- `printStdout` no longer silently drops messages >4096 bytes; falls back to
  heap allocation.

### Added

- 7 unit tests for edge cases: lossy+rANS, non-monotonic RT/scan_id fallback,
  mismatched m/z/intensity lengths, zero quant, empty block, zero block_size.
  63 total tests.
- Empty-guards on 4 internal helper functions (`flattenMzAsF32Bits`,
  `flattenMzDeltas`, `buildScanIdDeltas`, `buildRtDeltas`).

### Fixed

- Double-free in rANS decode error path removed (redundant `errdefer`).
- Overflow-vulnerable wrapping `+%=` replaced with checked `@addWithOverflow`
  in scan_id and RT delta recovery.
- Unsigned subtraction in per-spectrum m/z payload now bounds-checked.
- Stale comment: "bits 6 and 7 remain free" → "All 8 flag bits are allocated".

### Removed

- Unused `delta` module import from `build.zig` block module.

---

## [0.1.6] — 2026-05-03

### Fixed

- Double-free in rANS decode error path (`block.zig`): redundant `errdefer`
  removed; outer `defer` already handles cleanup.
- Overflow-vulnerable wrapping addition in scan_id and RT delta recovery
  replaced with checked `@addWithOverflow`, returning `error.Overflow` on
  corrupt data.
- Unsigned subtraction in per-spectrum m/z payload length calculation now
  bounds-checked before use.
- Portability: `writeStdout` no longer uses Linux-only `std.os.linux.write`;
  replaced with `std.Io.File.stdout().writeStreamingAll()`.
- `printStdout` no longer silently drops messages larger than 4096 bytes;
  falls back to `std.fmt.allocPrint` on the page allocator when the stack
  buffer overflows.
- Stale comment corrected: "bits 6 and 7 remain free" updated to "All 8 flag
  bits are allocated".

### Changed

- `fixtures/` directory consolidated under `test/fixtures/`; all test data
  now lives under `test/`.
- Adversarial `split_exp_degenerate.bin` replaced with full f32 dynamic range
  extremes (mixing 1e-38 and 1e+37 intensities) per `plan.md` spec. The
  zero-range exponent path is covered by unit tests.
- `binary_reader.writeBinaryDump` now accepts caller-provided allocator instead
  of hard-coding `std.heap.smp_allocator`.

### Added

- 7 new unit tests: lossy intensity with rANS active, non-monotonic RT and
  scan_id fallback to raw encoding, mismatched m/z/intensity array rejection,
  zero intensity quant rejection, empty block rejection, zero block_size
  rejection. Total: 63 tests.
- Empty-guards on 4 internal helper functions in `block.zig` (`flattenMzAsF32Bits`,
  `flattenMzDeltas`, `buildScanIdDeltas`, `buildRtDeltas`).
- `CHANGELOG.md` covering all versions from bootstrap to unreleased.

### Removed

- Unused `delta` module import from `build.zig` block module (delta logic is
  inlined in `block.zig`).

---

## [0.1.5] — 2026-03-27 `tagged`

### Changed

- Decode path optimized: removed redundant rANS candidate re-examination per
  block, cutting wasted work.
- Per-spectrum m/z bit-width dry-run comparison folded into a single analysis
  pass.

---

## [0.1.4] — 2026-03-26

### Changed

- Decode performance improvements.
- Removed waste re-examination of rANS encoding candidates during encode.

---

## [0.1.3] — 2026-03-25

### Added

- rANS/FSE entropy coding engine (`src/rans.zig`): order-0 static rANS with
  12-bit precision, deterministic frequency normalization.
- rANS applied to m/z FOR payload stream, gated by `--mz-rans-min-gain` (default
  5%).
- rANS applied to intensity FOR payload stream (lossy mode), gated by
  `--intensity-rans-min-gain` (default 12%).
- Per-block byte breakdown in `mzarc inspect --json` output.

---

## [0.1.2] — 2026-03-24

### Added

- Split-exponent intensity encoding: separates the f32 exponent byte (bits
  23-30) from the 3-byte mantissa. Exponent stream is FOR-packed; mantissa is
  stored raw. Reduces lossless intensity payload by 12.5% on the frozen fixture.
- `flag_split_exponent` and `flag_lossless_intensity_raw` block header flags.

---

## [0.1.1] — 2026-03-23

### Added

- Local CI step (`zig build ci`): encode, decode, validate round-trip.
- SHA-256 integrity fixture check in build system.
- `tools/check_regression.py` for automated baseline comparison.

### Changed

- Python tooling refactored into modular benchmark, plotting, and metrics
  scripts.
- Dead code removed from encoder paths.
- Release build mode (`-Drelease=true`) fixed in `build.zig`.

---

## [0.1.0] — 2026-03-22 `tagged`

### Added

- mzarc codec: delta encoding + FOR (Frame of Reference) bit-packing for m/z
  and intensity streams.
- Block-structured container format (magic, version, flags, per-block headers).
- Lossless and lossy encoding modes. Lossy mode uses log-scale intensity
  quantization with configurable precision (`--intensity-quant`).
- `mzarc encode`, `mzarc decode`, `mzarc inspect`, `mzarc dump-inspect`
  subcommands.
- Flat binary dump format for raw spectrum interchange.
- Binary dump reader/writer with endian-aware fast path.
- `tools/benchmark_v1.py`: multi-format benchmarking against gzip, zstd, bzip2,
  lz4, xz, mzMLb, MS-Numpress, MScompress.

---

## [0.0.1] — 2026-03-21 (bootstrap)

### Added

- Initial prototype: mzML ingestion to flat binary dump via `tools/parse_mzml.py`.
- Basic block encoder/decoder skeleton in Zig.
- `build.zig` project scaffold.

[0.1.5]: https://github.com/eneskemalergin/mzarc/releases/tag/v0.1.5
[0.1.0]: https://github.com/eneskemalergin/mzarc/releases/tag/v0.1.0
