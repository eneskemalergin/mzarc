<!-- markdownlint-disable MD033 MD036 MD041 -->
<p align="center">
    <img src="assets/mzarc-readme-header.svg" alt="mzarc header logo" width="860" />
</p>

<p align="center">
    Domain-specific compression for mzML-derived mass spectrometry spectra. 75.55 MiB mzML to a 14.46 MiB lossless archive with an exact retained-field round trip.
</p>

<p align="center">
    <strong>Research prototype.</strong> Functional codec with a narrow validation corpus.
</p>

<p align="center">
    <a href="#v025-release"><img src="https://img.shields.io/badge/version-v0.2.5-0f766e?style=for-the-badge" alt="Version v0.2.5" /></a>
    <a href="#quick-start"><img src="https://img.shields.io/badge/zig-0.16.0-f7a41d?style=for-the-badge" alt="Zig 0.16.0" /></a>
    <a href="#quick-start"><img src="https://img.shields.io/badge/python-3.12-3776AB?style=for-the-badge" alt="Python 3.12" /></a>
</p>

<p align="center">
    <a href="#validation-state"><img src="https://img.shields.io/badge/status-research%20prototype-orange?style=for-the-badge" alt="Research prototype status" /></a>
</p>

<p align="center">
    <a href="https://github.com/eneskemalergin/mzarc/actions/workflows/ci.yml"><img src="https://github.com/eneskemalergin/mzarc/actions/workflows/ci.yml/badge.svg" alt="GitHub CI" /></a>
</p>

---

## What This Is

`mzarc` is a research codec for mzML-derived spectra. It asks whether a domain-specific entropy-coded pipeline can beat generic compression on a real proteomics benchmark while staying operationally simple and exactly lossless for the retained spectrum fields.

The tracked `15HCD_1` artifacts answer yes for size. mzarc lossless is smaller than xz on the same binary dump and smaller than the tracked mzMLb artifact. The lossy path trades controlled intensity precision for a smaller archive.

These formats do not have identical storage contracts. xz stores Dump V1 bytes, mzMLb stores mzML semantics in HDF5, and mzarc stores the fields retained by the dump boundary. A lossless mzarc round trip is exact against Dump V1, not byte-identical to the original mzML document.

The pipeline is intentionally split:

```txt
mzML -> Python dump tool -> flat binary -> Zig codec -> .mzarc
```

Python handles mzML ingestion. Zig owns the codec, validation, and performance-sensitive transforms. This keeps XML and schema handling outside the current codec. Native mzML input and output belong to v0.4.0.

## Quick Start

The repo carries its own Zig 0.16.0 toolchain. Python is managed with `uv`.

```bash
uv sync
./zig-0.16.0/zig build --release=fast
```

Convert, encode, and inspect:

```bash
uv run python tools/mzml_dump.py data/PXD075509/15HCD_1.mzML -o 15HCD_1.bin
./zig-out/bin/mzarc encode 15HCD_1.bin -o 15HCD_1.mzarc
./zig-out/bin/mzarc inspect 15HCD_1.mzarc
```

Run the local test and codec gates:

```bash
./zig-0.16.0/zig build test --summary all
./zig-0.16.0/zig build check-fixture
./zig-0.16.0/zig build --release=fast
bash tools/smoke_test.sh
```

## Benchmark Summary

Benchmark dataset: `data/PXD075509/15HCD_1.mzML` (9,001 spectra, 2.67 million peaks). The [tracked report](benchmark/report.md) was generated on 2026-07-28. Its artifact sizes describe the current format 1.0 payload layout. Its timing, RSS, throughput, ranking, and statistical sections are historical and are not v0.2.5 release claims.

| codec               |      size | vs mzML |
| ------------------- | --------: | ------: |
| mzML                | 75.55 MiB |  100.0% |
| mzarc lossless      | 14.46 MiB |   19.1% |
| mzarc lossy q=16384 | 12.66 MiB |   16.8% |
| mzMLb               | 16.25 MiB |   21.5% |
| xz dump             | 15.77 MiB |   20.9% |
| zstd dump           | 17.85 MiB |   23.6% |

mzarc lossless is the smallest lossless artifact in the tracked comparison. It is 8.3% smaller than xz on the same binary dump and 11.0% smaller than the tracked mzMLb artifact. The lossy path at `q=16384` reaches 16.8% of the original mzML size with p95 relative intensity error of 0.055%.

<p align="center">
  <img src="benchmark/plots/size_comparison.png" width="720" alt="Artifact size comparison across mzarc, MS-domain codecs, and generic compressors on 15HCD_1" />
  <br><em>Size comparison: mzarc lossless and lossy vs MS-domain and generic alternatives.</em>
</p>

v0.2.5 writes format 1.0 through a single-threaded file path that retains compact metadata plus one active block. Lossless fidelity remains exact against Dump V1, and global scan order is preserved. This release does not declare format 1.0 use-ready. The benchmark harness and public report will be corrected in v0.2.6.

## v0.2.5 Release

`v0.2.5` is a research snapshot of the current codec. Key changes since v0.2.0:

- `.mzarc` format 1.0 stores the first m/z value directly and compresses the remaining differences.
- Encode and decode retain compact metadata plus one active block instead of all peak data.
- Failed encode or decode commands leave an existing destination unchanged.
- The rANS, FOR, intensity, and checksum paths perform less repeated work and allocate fewer temporary buffers.
- CRC-32/ISO-HDLC uses runtime-selected PCLMUL on supported x86-64 processors and a portable fallback everywhere else.
- The CLI remains natively single-threaded.

The tracked report does not describe the final combined v0.2.5 implementation. This release therefore makes no new timing, throughput, RSS, ranking, or significance claim.

## Implementation

### Ingest and dump layer

`tools/mzml_dump.py` converts mzML to the flat binary format the codec expects. The Python dump is intentional: it isolates XML parsing from the codec. A native Zig ingest path is planned once the codec core is stable.

`src/binary_reader.zig` reads and writes the dump format. `mzarc dump-inspect` reports dump statistics.

### Codec core

- `src/quantize.zig`: m/z fixed-point conversion and lossy intensity quantization
- `src/bitpack.zig`: FOR bit-packing and multi-byte unpacking
- `src/block_encode.zig` and `src/block_decode.zig`: block transforms, entropy decisions, and validation
- `src/crc32.zig`: portable CRC-32/ISO-HDLC with runtime-selected x86-64 PCLMUL
- `src/block.zig`: shared block namespace
- `src/codec.zig`: `.mzarc` file processing with one active block and destination preservation after failure
- `src/binary_reader.zig`: Dump V1 scanning, positional reads, and positional writes
- `src/main.zig`: CLI subcommands, validation, inspection, and rANS benchmark command

### Benchmark and analysis

- `tools/benchmark.sh`: historical real-data orchestration for mzarc and peer codecs
- `tools/validate.sh`: adversarial, binary roundtrip, fidelity, and regression checks
- `tools/collect_report.py`: assembles report.json, generates 8 plots, writes report.md
- `tools/check_regression.py`: regression comparison owner; currently targets a missing baseline

The benchmark pipeline will be corrected in v0.2.6. The current runner and report must not be used for new timing, throughput, RSS, ranking, or significance claims.

## CI

The workflow runs on Ubuntu and macOS on every push and pull request. No mzML data or Python required. Checks use the frozen binary fixture in `test/fixtures/`.

Jobs: build with `-Drelease=true`, unit tests, frozen fixture SHA-256 integrity check, lossless/lossy roundtrips and adversarial corpus via `tools/smoke_test.sh`.

The local `zig build ci` step also invokes the regression script. That script still targets the missing `benchmark/baseline_v0.1.1.json`, so it currently reports a skip instead of enforcing a performance regression comparison.

## Validation State

Lossless fidelity on `15HCD_1` is exact against Dump V1: zero m/z error and preserved scan order. The lossy path at `q=16384` yields p95 relative intensity error of 0.055%.

This is a research prototype. It has been validated on one dataset from one instrument type. Quirks in edge cases are expected and will surface with broader use.

The `.mzarc` 1.0 format is still under development and is not use-ready. Development archives may need regeneration until the project explicitly declares 1.0 use-ready. After that declaration, persisted-layout changes require a new file version and compatibility coverage.

## Repository Layout

```text
mzarc/
  benchmark/   public benchmark artifacts and plots
  data/        local datasets and benchmark workdirs (gitignored)
  src/         Zig codec implementation
  test/        Zig tests, frozen fixtures, and adversarial inputs
  tools/       Python ingest, benchmark, and analysis scripts
  build.zig
  build.zig.zon
  pyproject.toml
  README.md
```

## Roadmap

v0.2.5 is the current release. The next releases have separate scopes:

**v0.2.6: benchmark harness**

- Correct benchmark execution, provenance, validation, byte bases, thread labels, statistics, and regression handling.
- Replace the historical report only after clean matched Tier B and Tier C runs.

**v0.2.7: code quality and optimization**

- Audit source, tests, and tools for consistent project standards and simpler ownership.
- Continue optimization only where current measurements show a material program cost.

**v0.3.0: codec closure, in progress**

- Reduce file read and write calls without whole-file loading, default mapping, or threading.
- Retest block sizes 64, 128, 256, and 512 for wall time, archive size, and peak RSS.
- Decide whether rANS4 earns inclusion in format 1.0 before it is declared use-ready.
- Measure and verify the final combined artifact on the primary benchmark, the retained scaling corpus, Ubuntu, and macOS.

**v0.4.0: native mzML I/O**

- Native streaming mzML reader with Python dump parity and mzValidate-backed reliability.
- Indexed mzML writer with round-trip parity and validation.
- Direct mzML-to-mzarc integration with one active block through the finalized v0.3.0 codec boundary.

Later directions include DIA-specific coding after DIA data exists, native vendor-format readers as the ecosystem matures, and multi-instrument validation beyond the current E. coli benchmark.

## References

**Format and codec**

- Martens, L. et al. [mzML -- a community standard for mass spectrometry data](https://doi.org/10.1074/mcp.R110.000133). _Molecular & Cellular Proteomics_.
- Bhamber, R. S. et al. (2020). [mzMLb: a future-proof raw mass spectrometry data format based on standards-compliant mzML and optimized for speed and storage requirements](https://doi.org/10.1021/acs.jproteome.0c00192). _Journal of Proteome Research_.
- [ms-numpress](https://github.com/ms-numpress/ms-numpress): Numerical compression methods for mass spectrometry data.
- [mscompress](https://github.com/chrisagrams/mscompress): Domain-specific compression for tandem mass spectrometry data.

**Entropy coding**

- Duda, J. (2013). [Asymmetric numeral systems: entropy coding combining speed of Huffman coding with compression rate of arithmetic coding](https://arxiv.org/abs/1311.2540). _arXiv:1311.2540_.
- Giesen, F. (2014). [rANS notes](https://fgiesen.wordpress.com/2014/02/02/rans-notes/). Practical derivation and proofs for streaming rANS; reference implementation at [github.com/rygorous/ryg_rans](https://github.com/rygorous/ryg_rans).

**Dataset**

- [PXD075509](https://www.ebi.ac.uk/pride/archive/projects/PXD075509): HCD fragmentation energy series, _E. coli_ rRNA digest. Primary benchmark dataset.

**Tooling**

- [Zig](https://ziglang.org): systems programming language used for the codec, CLI, and test harness.
- [pyteomics](https://github.com/levitsky/pyteomics): Python library for mzML/mzMLb ingestion in the dump tool. Cite: Goloborodko et al. (2013), DOI [10.1007/s13361-012-0516-6](https://doi.org/10.1007/s13361-012-0516-6); Levitsky et al. (2018), DOI [10.1021/acs.jproteome.8b00717](https://doi.org/10.1021/acs.jproteome.8b00717).
- [zebrac](https://github.com/eneskemalergin/zebrac): Linux measurement tool. The bundled 0.6.1 binary produced historical results; new hardware-counter claims wait for the 0.6.2 interface audit.

---

## License

MIT. See [LICENSE](LICENSE). The x86-64 CRC path includes an MIT-licensed adaptation from `crc32fast`; see [LICENSES/crc32fast-MIT.txt](LICENSES/crc32fast-MIT.txt).

---

<br />

<p align="center">
    <em>
        Ions drift to ground<br />
        Folded into bit-packed frames -<br />
        The machine breathes light.
    </em>
</p>
