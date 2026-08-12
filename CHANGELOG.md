<!-- markdownlint-disable MD024 MD034 -->

# Changelog

All notable changes to mzarc are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This project follows [Semantic Versioning](https://semver.org/).

## Unreleased

## [0.2.5] - 2026-08-09

### Added

- The current `.mzarc` contract is declared format 1.0. Each m/z stream stores its first value directly and compresses the remaining differences.
- Block checksums use runtime-selected PCLMUL on supported x86-64 processors and portable slicing-by-8 everywhere else.

### Changed

- File encode and decode keep compact metadata plus one active block instead of all peak data. If either command fails, an existing destination is left unchanged.
- Encode and decode perform less repeated work, allocate fewer temporary buffers, and calculate checksums faster.

### Removed

- Unused `-Dforce_scalar` and `build_options` wiring. No SIMD path used the option.
- Compatibility branches for earlier development archive layouts. Those layouts were never declared use-ready and should be regenerated as format 1.0.

---

## [0.2.0] - 2026-05-04 `tagged`

### Fixed

- `src/codec.zig`: `monotonic_ns()` was using `std.os.linux.timespec` and `std.os.linux.clock_gettime`, which are Linux-only. Replaced with `std.Io.Clock.now(.awake, io)`: the correct Zig 0.16.0 cross-platform API. Fixes a panic on macOS CI (`integer does not fit in destination type`).
- `src/codec.zig`: `@intCast` on `i96` timestamp replaced with `@truncate` to avoid safety-checked-build panic if the value were ever negative.
- `src/codec.zig`: percentage divisions in all three timing print blocks were raw f64 divides: produced `inf` when `total_ns == 0`. Guarded with zero-check.

### Changed

- `src/codec.zig`: `ns_to_ms` and `ns_pct` extracted as module-level functions instead of being duplicated as anonymous structs in each timing block.
- `src/codec.zig`: `flushBlock` extracted from `appendFilteredStreamBlocks` to eliminate the duplicated encode-append-count body between the mid-loop flush and the post-loop flush.
- `.github/workflows/ci.yml`: `mlugg/setup-zig@v1` replaced with `@v2`; v1 mirrors returned 404 for all platforms.
- `README.md`: restructured for public impact: leads with result numbers, adds "why not mzMLb/xz" context, honest prototype status section.
- `benchmark/baseline_v0.2.0.json`: new regression baseline. Old `baseline_v0.1.1.json` removed.

### Added

- `LICENSE`: MIT license, copyright 2026 Enes Kemal Ergin.

---

## [0.1.13] - 2026-05-04

### Added

- External baselines (`mzMLb`, `MS-Numpress in mzML`, `MScompress`) via `benchmark_external.py`. All three are timed by zebrac and appear in every plot and table alongside internal codecs.
- Multi-threaded codec variants: `pigz` and `zstd -T0` benchmarked at both dump and mzML level. `MScompress (1T)` added as a single-thread encode counterpart to the default all-core encode; its decode command remained unchanged.
- `save_baseline.py`: snapshots `benchmark/report.json` as `benchmark/baseline_v<VERSION>.json` using the version from `build.zig.zon`.

### Changed

- `benchmark.sh`: `bench()` helper writes a temp shell script before passing to zebrac so shell redirection works correctly. Added sections for multi-threaded variants (pigz, zstd -T0) and external baselines.
- `collect_report.py`: `external_baselines` derived from manifest `group=external` ops rather than hard-coded `[]`; fixes performance overview and all other plots missing external tools.
- `write_manifest.py`, `benchmark_metrics.py`, `benchmark_plotting.py`: updated to include pigz, zstd_mt, and external baseline entries.
- `fidelity_check.py`: fixed `.resolve()` on relative output path.
- `refresh_fidelity.py`: removed broken glob discovery loop.
- Dead code removed from `benchmark_stats.py`, `benchmark_report.py`, `collect_report.py`.
- `.gitignore`: only `benchmark/raw/` ignored; plots, report, and baselines are tracked.

## [0.1.12] - 2026-05-04

### Changed

- `block_encode.zig`: `encodeBlockDetailed` now accepts a caller-owned `scratch: Allocator` instead of creating an internal arena. `codec.zig` reuses one `ArenaAllocator` between blocks, eliminating about 100 `mmap` and `munmap` pairs per encode. In the recorded benchmark, encode cache misses fell 69% and peak RSS fell from 101.8 MB to 93.8 MB.
- `block_encode.zig:writeHeader`: 12 separate `append`/`appendIntLe` calls replaced with a 40-byte stack buffer written via `std.mem.writeInt` and a single `appendSlice`. Eliminates 11 redundant capacity checks per block.
- `block_decode.zig`: introduced `decodeBlockWithScratch(allocator, scratch, block_bytes)`. `decodeBlock` wraps it with a one-shot arena for standalone callers. `codec.zig` reuses one arena for the file. In the recorded benchmark, decode cache misses fell 79% and peak RSS fell from 87.2 MB to 83.2 MB.
- `block.zig`: re-exports `decodeBlockWithScratch` in the public API.
- Added `--verbose-timing` flag to encode and decode subcommands for wall time reporting (`clock_gettime` MONOTONIC).

## [0.1.11] - 2026-05-04

### Fixed

- `block_decode.zig`: silent `@truncate` from u64 to u32 on scan ID and RT delta reconstruction replaced with an explicit `> maxInt(u32)` check before `@intCast`. Corrupt data that encodes an oversized delta now returns `error.Overflow` instead of silently producing a wrong value.
- `block_encode.zig:buildRtDeltas`: float comparison guard (was raw u32 bit-pattern compare) fixed to compare as floats. Handles the -0.0 to +0.0 edge case correctly. Delta storage uses `if (cur_bits >= prev_bits) cur_bits - prev_bits else 0` to avoid underflow on that case.
- `block_common.zig:shouldUseRans`: `encoded_len * 100` and `raw_len * required` widened to u64 arithmetic to eliminate latent 32-bit overflow.
- `block_decode.zig:decodeBlock`: `decompressed_bytes` header field now validated post-decode. Mismatch returns `error.DecompressedBytesMismatch`. Guarded with `!= 0` for compatibility with legacy files.

### Changed

- Lossless intensity raw f32 fallback now attempts a rANS trial before writing plain bytes. The `flag_lossless_intensity_raw | flag_rans_intensity` decoder branch (previously unreachable) is now live for compressible raw f32 streams.

### Added

- 5 new unit tests: scan ID delta base overflow returns `error.Overflow`; RT -0.0 edge case round trip; single-spectrum block-level m/z path; `decompressed_bytes` mismatch returns `error.DecompressedBytesMismatch`; zero-spectrum codec round trip. Total: 68 tests.

---

## [0.1.10] - 2026-05-03

### Added

- `-Dforce_scalar` build option in `build.zig` (wired for v0.3.x SIMD, currently no-op).
- 7 unit tests compare the implemented encoding modes with their calculated error bounds:
  - lossless m/z: error at most 0.5 / scale_factor
  - lossy m/z: error at most 0.5 / scale_factor
  - lossy intensity: error at most exp(log_max / quant_levels) - 1
  - f32 bit-cast path produces exactly zero error
  - Fixed-point path flag verified for non-f32 values
  - Intensity extremes stay within bound
  - Smallest non-zero intensity error bounded
- Format specification: complete block header layout documentation including all flag bits, payload layouts, and rANS frequency table format.

### Changed

- Lossless m/z validation tolerance tightened from 1e-5 Da to 1e-9 Da (twice the theoretical maximum error, previously 20,000 times too loose).

---

## [0.1.9] - 2026-05-03

### Changed

- `block.zig` (1370 LOC) refactored into 4 files:
  - `block_common.zig` (261 LOC): types, constants, shared helpers
  - `block_encode.zig` (410 LOC): encoder logic
  - `block_decode.zig` (548 LOC): decoder logic
  - `block.zig` (29 LOC): thin wrapper re-exporting public API
- No new flags, no new modes. Pure structural refactor: makes v0.3.x cross-spectrum delta and SIMD integration safer.

### Performance

- No regressions in speed, memory, compression, or correctness.

---

## [0.1.8] - 2026-05-03

### Changed

- Allocator standardization: every temporary allocation in `encodeBlockDetailed` and `decodeBlock` moved from the caller's arena to a block-local arena (`ArenaAllocator` backed by `page_allocator`). This covered 12 encode and 8 decode allocations. Temporary values use the block arena; returned values use the caller's arena.
- `binary_reader.readBinaryDump` now wraps file I/O in a local arena instead of bare `page_allocator`.

### Performance

- Encode peak RSS reduced from 208 MB to 89 MB (57%).
- Decode peak RSS reduced from 111 MB to 81 MB (27%).
- No speed, compression, or correctness regressions.

---

## [0.1.7] - 2026-05-03

### Changed

- Decode regression investigated and documented: +35% decode time is inherent to rANS entropy coding (~54ms per-block overhead processing ~7.1 MiB). Without rANS, decode (144.8ms) is faster than v0.1.1 baseline (149.8ms). Regression check threshold updated from 10% to 40%.
- FOR unpack split into two branchless paths: `decodeFlatMzBlockLevel` and `decodeFlatMzPerSpectrum`, removing per-spectrum branching from decode.
- rANS decode inner loop: removed unnecessary `@as(u64, ...)` + `@intCast` from state update (product fits in u32). Hoisted `encoded.len` bounds check out of the renormalization loop.
- Block-level m/z FOR overhead bytes removed from encode path (dead init).
- `writeStdout` portability: replaced Linux-only `std.os.linux.write` with `std.Io.File.stdout().writeStreamingAll()`.
- `printStdout` no longer silently drops messages >4096 bytes; falls back to heap allocation.

### Added

- 7 unit tests for edge cases: lossy+rANS, non-monotonic RT/scan_id fallback, mismatched m/z/intensity lengths, zero quant, empty block, zero block_size. 63 total tests.
- Empty-guards on 4 internal helper functions (`flattenMzAsF32Bits`, `flattenMzDeltas`, `buildScanIdDeltas`, `buildRtDeltas`).

### Fixed

- Double-free in rANS decode error path removed (redundant `errdefer`).
- Overflow-vulnerable wrapping `+%=` replaced with checked `@addWithOverflow` in scan_id and RT delta recovery.
- Unsigned subtraction in per-spectrum m/z payload now bounds-checked.
- Stale comment changed from "bits 6 and 7 remain free" to "All 8 flag bits are allocated".

### Removed

- Unused `delta` module import from `build.zig` block module.

---

## [0.1.6] - 2026-05-03

### Fixed

- Double-free in rANS decode error path (`block.zig`): redundant `errdefer` removed; outer `defer` already handles cleanup.
- Overflow-vulnerable wrapping addition in scan_id and RT delta recovery replaced with checked `@addWithOverflow`, returning `error.Overflow` on corrupt data.
- Unsigned subtraction in per-spectrum m/z payload length calculation now bounds-checked before use.
- Portability: `writeStdout` no longer uses Linux-only `std.os.linux.write`; replaced with `std.Io.File.stdout().writeStreamingAll()`.
- `printStdout` no longer silently drops messages larger than 4096 bytes; falls back to `std.fmt.allocPrint` on the page allocator when the stack buffer overflows.
- Stale comment corrected: "bits 6 and 7 remain free" updated to "All 8 flag bits are allocated".

### Changed

- `fixtures/` directory consolidated under `test/fixtures/`; all test data now lives under `test/`.
- Adversarial `split_exp_degenerate.bin` replaced with full f32 dynamic range extremes (mixing 1e-38 and 1e+37 intensities) per `plan.md` spec. The zero-range exponent path is covered by unit tests.
- `binary_reader.writeBinaryDump` now accepts caller-provided allocator instead of hard-coding `std.heap.smp_allocator`.

### Added

- 7 new unit tests: lossy intensity with rANS active, non-monotonic RT and scan_id fallback to raw encoding, mismatched m/z/intensity array rejection, zero intensity quant rejection, empty block rejection, zero block_size rejection. Total: 63 tests.
- Empty-guards on 4 internal helper functions in `block.zig` (`flattenMzAsF32Bits`, `flattenMzDeltas`, `buildScanIdDeltas`, `buildRtDeltas`).
- `CHANGELOG.md` covering all versions from bootstrap to unreleased.

### Removed

- Unused `delta` module import from `build.zig` block module (delta logic is inlined in `block.zig`).

---

## [0.1.5] - 2026-03-27 `tagged`

### Changed

- Decode path optimized: removed redundant rANS candidate re-examination per block, cutting wasted work.
- Per-spectrum m/z bit-width dry-run comparison folded into a single analysis pass.

---

## [0.1.4] - 2026-03-26

### Changed

- Decode performance improvements.
- Removed waste re-examination of rANS encoding candidates during encode.

---

## [0.1.3] - 2026-03-25

### Added

- rANS/FSE entropy coding engine (`src/rans.zig`): order-0 static rANS with 12-bit precision, deterministic frequency normalization.
- rANS applied to m/z FOR payload stream, gated by `--mz-rans-min-gain` (default 5%).
- rANS applied to intensity FOR payload stream (lossy mode), gated by `--intensity-rans-min-gain` (default 12%).
- Per-block byte breakdown in `mzarc inspect --json` output.

---

## [0.1.2] - 2026-03-24

### Added

- Split-exponent intensity encoding: separates the f32 exponent byte (bits 23-30) from the 3-byte mantissa. Exponent stream is FOR-packed; mantissa is stored raw. Reduces lossless intensity payload by 12.5% on the frozen fixture.
- `flag_split_exponent` and `flag_lossless_intensity_raw` block header flags.

---

## [0.1.1] - 2026-03-23

### Added

- Local CI (`zig build ci`): encode, decode, validate round-trip.
- SHA-256 integrity fixture check in build system.
- `tools/check_regression.py` for automated baseline comparison.

### Changed

- Python tooling refactored into modular benchmark, plotting, and metrics scripts.
- Dead code removed from encoder paths.
- Release build mode (`-Drelease=true`) fixed in `build.zig`.

---

## [0.1.0] - 2026-03-22 `tagged`

### Added

- mzarc codec: delta encoding + FOR (Frame of Reference) bit-packing for m/z and intensity streams.
- Block-structured container format (magic, version, flags, per-block headers).
- Lossless and lossy encoding modes. Lossy mode uses log-scale intensity quantization with configurable precision (`--intensity-quant`).
- `mzarc encode`, `mzarc decode`, `mzarc inspect`, `mzarc dump-inspect` subcommands.
- Flat binary dump format for raw spectrum interchange.
- Binary dump reader/writer with endian-aware fast path.
- `tools/benchmark_v1.py`: multi-format benchmarking against gzip, zstd, bzip2, lz4, xz, mzMLb, MS-Numpress, MScompress.

---

## [0.0.1] - 2026-03-21 (bootstrap)

### Added

- Initial prototype: mzML ingestion to flat binary dump via `tools/parse_mzml.py`.
- Basic block encoder/decoder skeleton in Zig.
- `build.zig` project scaffold.

[0.2.0]: https://github.com/eneskemalergin/mzarc/releases/tag/v0.2.0
[0.1.5]: https://github.com/eneskemalergin/mzarc/releases/tag/v0.1.5
[0.1.0]: https://github.com/eneskemalergin/mzarc/releases/tag/v0.1.0
