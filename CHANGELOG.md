<!-- markdownlint-disable MD024 MD034 -->

# Changelog

All notable changes to mzarc are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows [Semantic Versioning](https://semver.org/). Each version starts with a short release summary, followed by user-visible changes grouped by area.

## [0.3.0] - 2026-08-13

This codec-focused release comes before native mzML I/O. It makes lossless m/z bit exact, caps file and block work so memory stays bounded, strengthens malformed-input checks, and trims the Zig source package. Format 1.0 remains a development format until it is declared use-ready.

### Added

- **Benchmarking:**
  - Adds a direct comparison against gzip, pigz, zstd, xz, and native MScompress.
  - Adds a native MScompress builder and optional Gnuplot summaries without a Python plotting stack.

### Changed

- **Format and fidelity:**
  - Preserves every supported lossless m/z value with the same f64 bits.
  - Uses four interleaved rANS states for faster decoding at a small archive cost. Earlier development archives must be regenerated.
- **Resources:**
  - Adds explicit file and block limits, rejects excessive work before allocation, and lowers encode and decode RSS.
- **Validation:**
  - Recomputes the lossy m/z transform instead of accepting a loose tolerance.
  - Checks lossy intensity in `log1p` space and accepts the matching custom intensity level.
- **Packaging:**
  - Ships only the Zig build, source, tests, smoke check, licenses, README, and changelog.
- **Benchmark reporting:**
  - Records commands, tool versions, validation rules, and measured results in `benchmark/report.md`.

### Fixed

- **Lossy intensity:**
  - Uses `expm1` for reconstruction so the smallest positive f32 values do not collapse to zero.

### Removed

- **Benchmarking:**
  - Removes the former Python reporting stack and old generated benchmark output.

## [0.2.5] - 2026-08-09

Format 1.0 gains its current development layout, and file commands move to bounded block processing. Checksums also gain a fast x86-64 path with a portable fallback.

### Added

- **Format:**
  - Stores the first m/z value directly and compresses the remaining differences.
- **Checksums:**
  - Selects PCLMUL at runtime on supported x86-64 processors and uses portable slicing-by-8 elsewhere.

### Changed

- **File processing:**
  - Keeps compact metadata plus one active block instead of retaining all peak data.
  - Leaves an existing destination unchanged when encode or decode fails.
- **Performance:**
  - Removes repeated work and shortens temporary allocation lifetimes in both file commands.

### Removed

- **Build:**
  - Removes the unused `-Dforce_scalar` option.
- **Compatibility:**
  - Removes readers for earlier development layouts that were never declared use-ready.

## [0.2.0] - 2026-05-04

This tagged release fixes the macOS timing path, refreshes CI and public documentation, and establishes the MIT-licensed project baseline.

### Added

- **Project:**
  - Adds the MIT license.

### Changed

- **CI and documentation:**
  - Updates the Zig setup action and rewrites the README around measured results and prototype status.

### Fixed

- **Portability:**
  - Uses Zig's cross-platform clock API and safe timestamp conversion on macOS.
- **Timing output:**
  - Avoids invalid percentages when an operation completes within the timer resolution.

## [0.1.13] - 2026-05-04

The comparison suite expands beyond general-purpose codecs with mass-spectrometry formats, fixed-worker rows, and repeatable benchmark baselines.

### Added

- **Comparators:**
  - Adds mzMLb, MS-Numpress, MScompress, pigz, and multi-worker zstd rows.
- **Baselines:**
  - Adds versioned benchmark snapshots for later comparisons.

### Changed

- **Reporting:**
  - Includes external tools throughout the benchmark tables and figures.
  - Simplifies the reporting code and fixes missing external rows.

## [0.1.12] - 2026-05-04

File encode and decode now reuse temporary block memory. This lowers allocation overhead and exposes optional timing output for both commands.

### Added

- **CLI:**
  - Adds `--verbose-timing` to encode and decode.

### Changed

- **Memory:**
  - Reuses caller-owned scratch storage between blocks instead of creating fresh block arenas.
- **Encoding:**
  - Writes block headers through one fixed buffer rather than many small appends.

## [0.1.11] - 2026-05-04

Block decoding now rejects corrupt arithmetic and decoded-size mismatches instead of silently narrowing values. Compressible raw intensity streams can also use rANS.

### Added

- **Compression:**
  - Tries rANS before storing lossless raw f32 intensity bytes unchanged.

### Fixed

- **Decoder safety:**
  - Rejects scan, retention-time, packing, and decoded-size overflows.
- **Retention time:**
  - Handles the negative-zero to positive-zero edge case without unsigned underflow.

## [0.1.10] - 2026-05-03

The block format and numeric error rules gain their first detailed documentation and checks. The release also tightens the then-current lossless m/z validator.

### Added

- **Format:**
  - Documents block headers, flags, payload layouts, and the rANS frequency table.
- **Validation:**
  - Adds numeric checks for m/z and intensity modes, including extreme values.
- **Build:**
  - Adds the temporary `-Dforce_scalar` development option.

### Changed

- **Validation:**
  - Tightens the former lossless m/z tolerance from `1e-5` Da to `1e-9` Da.

## [0.1.9] - 2026-05-03

The original block module splits into smaller encode, decode, and shared components. Flags, modes, and file behavior stay the same.

### Changed

- **Code organization:**
  - Separates block encoding, decoding, shared types, and the public block surface.

## [0.1.8] - 2026-05-03

Block operations gain clear temporary-memory ownership. Block-local arenas and file-read scratch substantially reduce peak memory without changing output.

### Changed

- **Memory:**
  - Moves temporary block allocations into block-local arenas.
  - Gives Dump V1 file reads one local arena for their temporary I/O state.

## [0.1.7] - 2026-05-03

rANS and FOR decoding do less repeated work, several corrupt-input paths close, and command output becomes portable. The format and modes stay the same.

### Changed

- **Decode performance:**
  - Splits the FOR decode paths and removes repeated checks from the rANS loop.
- **Output:**
  - Uses portable streaming output and handles messages larger than the fixed buffer.

### Fixed

- **Safety:**
  - Removes a double free and rejects arithmetic overflow in metadata and m/z reconstruction.

## [0.1.6] - 2026-05-03

Fixtures move under `test/`, block error paths become stricter, and Dump V1 writing starts using caller-owned allocation.

### Changed

- **Fixtures:**
  - Moves fixtures and adversarial data under `test/`.
- **Ownership:**
  - Makes Dump V1 writing use the caller's allocator.

### Fixed

- **Decoder safety:**
  - Rejects overflow and removes duplicate cleanup in corrupt-data paths.
- **Portability:**
  - Replaces Linux-only standard output calls with Zig I/O.

## [0.1.5] - 2026-03-27

This tagged performance release removes repeated rANS candidate work and combines the per-spectrum m/z analysis pass.

### Changed

- **Performance:**
  - Reuses rANS decisions during decode and analyzes m/z widths in one pass.

## [0.1.4] - 2026-03-26

Encode and decode perform less repeated work without changing the archive format.

### Changed

- **Performance:**
  - Avoids rechecking rejected rANS candidates and streamlines decode work.

## [0.1.3] - 2026-03-25

Order-0 rANS now compresses packed m/z and lossy intensity streams when it clears a caller-selected minimum gain.

### Added

- **Compression:**
  - Adds deterministic 12-bit rANS for m/z and intensity payloads.
  - Adds separate minimum-gain controls for the two streams.
- **Inspection:**
  - Adds per-block byte accounting to JSON inspection output.

## [0.1.2] - 2026-03-24

Split-top-byte coding compresses the high intensity byte separately while retaining the lower three bytes exactly.

### Added

- **Compression:**
  - Adds split-top-byte and raw-intensity block layouts with explicit flags.

## [0.1.1] - 2026-03-23

The first repeatable local correctness gate and release build path arrive alongside automated benchmark comparison.

### Added

- **Verification:**
  - Adds local encode, decode, and validation checks plus frozen-fixture integrity.
- **Benchmarking:**
  - Adds automated comparison with a saved baseline.

### Changed

- **Build:**
  - Fixes the ReleaseFast selection used by the release command.

## [0.1.0] - 2026-03-22

The first tagged codec release introduces Dump V1, the `.mzarc` container, lossless and lossy modes, and the core CLI.

### Added

- **Codec:**
  - Adds delta transforms, FOR packing, block headers, and versioned file metadata.
- **Modes:**
  - Adds lossless coding and configurable log-scale intensity quantization.
- **CLI:**
  - Adds `encode`, `decode`, `inspect`, and `dump-inspect`.
- **Interchange:**
  - Adds the flat Dump V1 spectrum representation and reader.
- **Benchmarking:**
  - Adds the first multi-format comparison tool.

## [0.0.1] - 2026-03-21

The initial prototype bootstraps mzarc as a Zig codec experiment with Python mzML ingestion and a basic block encoder and decoder.

### Added

- **Project:**
  - Adds the Zig build, initial codec skeleton, and mzML-to-dump converter.

[0.2.0]: https://github.com/eneskemalergin/mzarc/releases/tag/v0.2.0
[0.1.5]: https://github.com/eneskemalergin/mzarc/releases/tag/v0.1.5
[0.1.0]: https://github.com/eneskemalergin/mzarc/releases/tag/v0.1.0
