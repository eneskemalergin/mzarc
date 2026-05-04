<!-- markdownlint-disable MD024 -->
# Changelog

All notable changes to z-toml are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This project follows [Semantic Versioning](https://semver.org/).

## [0.2.0] — unreleased

### Added

- CI harness: `zig build ci` runs tests, fixture checks, lossless/lossy round-trips,
  adversarial corpus validation, and regression checks in under 3 seconds.
- `mzarc validate` subcommand for lossless and lossy round-trip fidelity checks.
- `mzarc validate-adversarial` subcommand for bulk adversarial corpus validation.
- Frozen test fixture (`test/fixtures/frozen.bin`): 1,000-spectrum deterministic
  slice with SHA-256 pinning via `zig build check-fixture`.
- Adversarial corpus (`test/adversarial/`): 13 edge-case binary dump files
  generated deterministically, covering empty, dense, zero-intensity, narrow
  exponent range, degenerate exponent, and more.
- Split-exponent intensity encoding: extracts the f32 exponent byte, packs it
  with FOR, stores the 3-byte mantissa raw. Reduces intensity payload by 18.75%
  on the `15HCD_1` dataset.
- rANS entropy coding on m/z FOR residuals: 30.91% reduction in m/z payload.
- rANS entropy coding on intensity exponent stream: applied when split-exponent
  is active and gain exceeds the threshold.
- Per-spectrum FOR bit-width granularity for m/z encoding: narrower bit-widths
  per spectrum when it improves over the block-wide width. 0.37 MiB gain on
  `15HCD_1`.
- `--verbose-blocks` encoder flag for per-block encoding statistics.
- `--mz-rans-min-gain` and `--intensity-rans-min-gain` encoder flags for rANS
  threshold tuning.
- `benchmark-rans-core` subcommand for isolated rANS codec micro-benchmarking.
- Benchmarkable external baselines: mzMLb, MS-Numpress, MScompress (single and
  threaded).
- Regression check (`tools/check_regression.py`): gates file size and decode
  time against the frozen v0.1.1 baseline.

### Changed

- Block container format version bumped to 1.2 (new flags for split-exponent,
  per-spectrum FOR, rANS m/z, rANS intensity).
- Lossless m/z encoding now prefers bit-exact f32 bit-cast delta when input
  values are already single-precision (true for all instrument data).
- Intensity encoding selects among raw f32, split-exponent, and split+rANS per
  block based on dry-run byte estimates.
- m/z encoding selects between block-wide and per-spectrum FOR based on dry-run
  byte estimates.
- scan_id and rt_seconds arrays are delta-encoded and FOR-packed.
- Test fixtures and adversarial corpus consolidated under `test/`.
- SHA-256 fixture check integrated into `zig build ci`.

### Fixed

- Release build mode works correctly (`-Drelease=true`).
- Checksum validation on block decode catches payload corruption.

### Known issues

- Lossless decode time regressed by ~35% vs v0.1.1 baseline. The rANS decode
  path and per-spectrum FOR unpack add per-byte overhead. Targeted for v0.3.0.

---

## [0.1.5] — 2026-03-27

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

## [0.1.0] — 2026-03-22

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
