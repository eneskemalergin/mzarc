<!-- markdownlint-disable MD033 MD041 -->

<p align="center">
  <img src="assets/mzarc-readme-header.svg" alt="mzarc" width="760" />
</p>

<p align="center">
  Domain-specific compression for mzML-derived mass spectrometry spectra.<br />
  On the current reference file: 75.55 MiB mzML to a 14.46 MiB lossless archive with an exact retained-field round trip.
</p>

<p align="center">
  <a href="#quick-start"><img src="https://img.shields.io/badge/zig-0.16.0-F7A41D?style=flat-square&amp;logo=zig&amp;logoColor=white" alt="Zig 0.16.0" /></a>
  <a href="#format-and-validation"><img src="https://img.shields.io/badge/status-research%20prototype-C17D10?style=flat-square" alt="Research prototype" /></a>
  <a href="CHANGELOG.md#025---2026-08-09"><img src="https://img.shields.io/badge/version-0.2.5-8B5CF6?style=flat-square" alt="Version 0.2.5" /></a>
  <a href="https://github.com/eneskemalergin/mzarc/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/eneskemalergin/mzarc/ci.yml?branch=main&amp;style=flat-square&amp;logo=github&amp;label=CI" alt="CI" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-4B9D6E?style=flat-square" alt="MIT License" /></a>
</p>

<p align="center">
  <a href="CHANGELOG.md"><img src="https://img.shields.io/badge/changelog-CHANGELOG-E05D44?style=flat-square" alt="Changelog" /></a>
  <a href="benchmark/report.md"><img src="https://img.shields.io/badge/benchmark-REPORT-0066CC?style=flat-square" alt="Benchmark report" /></a>
  <a href="https://github.com/eneskemalergin/mzarc/issues"><img src="https://img.shields.io/badge/issues-GitHub-8B5CF6?style=flat-square" alt="GitHub issues" /></a>
</p>

---

## What mzarc does

`mzarc` is a research codec for mass spectrometry spectra retained from mzML. It combines spectrum-aware transforms with entropy coding, keeps the CLI natively single-threaded, and processes one active block at a time.

The current input path is intentionally split:

```text
mzML -> Python Dump V1 converter -> Zig codec -> .mzarc
```

Python handles mzML parsing through Pyteomics. Zig owns Dump V1 validation, compression, decompression, and the performance-sensitive transforms. A lossless mzarc round trip preserves the fields retained by Dump V1; it does not reproduce the original mzML document.

The CLI also provides a controlled lossy intensity mode. The `.mzarc` 1.0 format remains under development, so neither mode is use-ready yet.

## Quick start

mzarc uses Zig 0.16.0. The current mzML converter requires Python 3.12 or 3.13 and is managed with [uv](https://docs.astral.sh/uv/). Place Zig at `./zig-0.16.0/zig`; the local compiler directory is not tracked.

```bash
uv sync
./zig-0.16.0/zig build --release=fast
```

Convert an mzML file, encode its retained spectra, and inspect the archive:

```bash
uv run python tools/mzml_dump.py input.mzML -o input.bin
./zig-out/bin/mzarc encode input.bin -o input.mzarc
./zig-out/bin/mzarc inspect input.mzarc
```

Decode and validate a lossless round trip:

```bash
./zig-out/bin/mzarc decode input.mzarc -o restored.bin
./zig-out/bin/mzarc validate input.bin restored.bin --mode=lossless
```

The release build installs a stripped ReleaseFast binary for the host architecture's baseline CPU. It retains frame pointers and unwind metadata. Run `./zig-0.16.0/zig build` for a native-host Debug binary with symbols.

## Benchmark

The [reference report](benchmark/report.md) measures `data/PXD075509/15HCD_1.mzML`: 9,001 spectra and 2,668,458 peaks. Each operation has five measured samples after one warmup. Rows marked `[P]` use four workers; mzarc remains single-threaded.

| Representation          | Size      | Relative to original mzML |
| ----------------------- | --------: | ------------------------: |
| Original mzML           | 75.55 MiB |                   100.00% |
| Dump V1 retained fields | 30.78 MiB |                    40.74% |
| mzarc lossless          | 14.46 MiB |                    19.14% |

Against the shared Dump V1 input, mzarc writes a 14.46 MiB artifact, 46.99% of that input and 8.23% smaller than single-threaded xz. mzarc records the fastest single-threaded encode at 206.22 MiB/s. zstd decodes faster, while gzip records lower peak RSS.

The 19.14% figure describes the current mzML-to-Dump-V1-to-mzarc storage path. It does not mean mzarc can reconstruct the original XML document.

<p align="center">
  <img src="benchmark/dump-summary.svg" width="900" alt="Artifact size, throughput, and peak RSS for the Dump V1 comparison" />
  <br /><em>Dump V1 comparison. Lower is better for size and RSS; higher is better for throughput.</em>
</p>

These are measured results from one file, one acquisition shape, and one host. The report records the commands, tool versions, validation boundaries, direct-child RSS, and separate original-mzML comparison.

## Format and validation

Version 0.2.5 writes `.mzarc` format 1.0 through a single-threaded file path. The codec keeps compact metadata plus one active block, preserves global scan order, and leaves an existing destination unchanged when encode or decode fails.

The current lossless mode passes the semantic validator on the tracked Dump V1 fixture and reference file; the reference file is also byte exact. Format closure still has to define the public m/z fidelity rule for every supported Dump V1 value. Until format 1.0 is declared use-ready, development archives may need regeneration and no compatibility with earlier development layouts is promised.

CRC-32/ISO-HDLC uses runtime-selected PCLMUL on supported x86-64 processors and a portable fallback on other targets. CI verifies Debug and ReleaseFast behavior on Ubuntu and macOS. Windows and aarch64 are not supported claims.

## Development

Run the focused and combined local gates with the pinned compiler:

```bash
./zig-0.16.0/zig build test --summary all
./zig-0.16.0/zig build ci --release=fast --summary all
```

The combined release gate runs ReleaseFast tests, verifies the frozen fixture, and exercises adversarial, lossless, and lossy CLI round trips against the stripped binary. It does not require Python or local mzML data.

The local comparison requires the peer tools described in [tools/README.md](tools/README.md) and an ignored local copy of the reference mzML file:

```bash
bash tools/benchmark.sh data/PXD075509/15HCD_1.mzML
```

Repository responsibilities stay narrow:

```text
src/         Zig codec and CLI
test/        Unit, property, malformed-input, fixture, and CLI data
tools/       mzML conversion and local benchmark commands
benchmark/   Reference report, baseline row, and summary figures
data/        Local real-data inputs, ignored by Git
```

## Roadmap

Current directions include:

- Close the format, fidelity, and bounded-memory contracts before declaring `.mzarc` use-ready.
- Replace the Python conversion boundary with native, bounded mzML input and validated indexed mzML output.
- Broaden correctness, performance, and memory checks across acquisition shapes, file sizes, and supported hosts.
- Keep improving archive size, throughput, and RSS where measurements show a material cost.
- Explore DIA-specific coding and native vendor-format readers when representative data and stable interfaces justify them.

Concurrency remains outside the current product scope.

## References

### Formats and compression

- Martens, L. et al. [mzML -- a community standard for mass spectrometry data](https://doi.org/10.1074/mcp.R110.000133). _Molecular & Cellular Proteomics_.
- Bhamber, R. S. et al. (2020). [mzMLb: a future-proof raw mass spectrometry data format based on standards-compliant mzML and optimized for speed and storage requirements](https://doi.org/10.1021/acs.jproteome.0c00192). _Journal of Proteome Research_.
- Duda, J. (2013). [Asymmetric numeral systems: entropy coding combining speed of Huffman coding with compression rate of arithmetic coding](https://arxiv.org/abs/1311.2540). _arXiv:1311.2540_.
- Giesen, F. (2014). [rANS notes](https://fgiesen.wordpress.com/2014/02/02/rans-notes/) and the [ryg_rans reference implementation](https://github.com/rygorous/ryg_rans).
- [ms-numpress](https://github.com/ms-numpress/ms-numpress) and [MScompress](https://github.com/chrisagrams/mscompress), mass-spectrometry compression peers.

### Data and tooling

- [PXD075509](https://www.ebi.ac.uk/pride/archive/projects/PXD075509), the current reference dataset.
- [Zig](https://ziglang.org), the language used for the codec, CLI, and tests.
- [Pyteomics](https://github.com/levitsky/pyteomics), the current mzML ingestion library.
- [zebrac](https://github.com/eneskemalergin/zebrac), the Linux measurement tool used by the reference report.

---

## License and acknowledgements

**mzarc is licensed under the MIT License.** See [LICENSE](LICENSE) for the full terms.

**mzarc stands on the shoulders of giants.** I am building the codec in Zig, but rewriting an idea does not erase where it came from. The list below distinguishes design references from adapted code and records the logic mzarc uses from each. The full bibliography, external dependencies, and benchmark peers remain in [References](#references).

- **[rANS and `ryg_rans`](https://github.com/rygorous/ryg_rans)**
  - **Relationship:** Design reference, not vendored code.
  - **Credit:** Jarek Duda for asymmetric numeral systems and Fabian Giesen for the byte-aligned reference implementation and notes.
  - **Terms:** [`ryg_rans` is released into the public domain](https://github.com/rygorous/ryg_rans/blob/master/LICENSE).
  - **Logic used:** The reverse-order encoder, state update, and byte-renormalization model behind order-0 rANS.
  - **How it is used:** `src/rans.zig` implements a local 32-bit rANS codec with 12-bit frequency precision, its own normalized frequency table and wire layout, and mzarc-specific validation.
- **[`crc32fast` 1.5.0](https://github.com/srijs/rust-crc32fast/tree/v1.5.0)**
  - **Relationship:** Adapted code.
  - **Credit:** Sam Rijs, Alex Crichton, and contributors.
  - **License:** Upstream offers MIT or Apache-2.0. mzarc uses the MIT option and retains the full notice in [LICENSES/crc32fast-MIT.txt](LICENSES/crc32fast-MIT.txt).
  - **Logic used:** The x86-64 PCLMUL folding schedule and polynomial constants.
  - **How it is used:** `src/crc32.zig` adapts that path to Zig and selects it at runtime on supported x86-64 processors. The local slicing-by-8 implementation remains the portable fallback.
  - **Integration:** No upstream crate or binary is linked or vendored.

---

<p align="center">
  <em>Ions drift to ground</em><br />
  <em>Folded into bit-packed frames -</em><br />
  <em>The machine breathes light.</em>
</p>
