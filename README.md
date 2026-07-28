<!-- markdownlint-disable MD033 MD036 MD041 -->
<p align="center">
    <img src="assets/mzarc-readme-header.svg" alt="mzarc header logo" width="860" />
</p>

<p align="center">
    Domain-specific compression for mzML-derived mass spectrometry spectra. 75 MB mzML to 15 MB lossless, exact round-trip, 155 MB/s decode.
</p>

<p align="center">
    <strong>Research prototype.</strong> Minimally functional. Quirks present. Still in development.
</p>

<p align="center">
    <a href="#v020-release"><img src="https://img.shields.io/badge/version-v0.2.0-0f766e?style=for-the-badge" alt="Version v0.2.0" /></a>
    <a href="#quick-start"><img src="https://img.shields.io/badge/zig-0.16.0-f7a41d?style=for-the-badge" alt="Zig 0.16.0" /></a>
    <a href="#quick-start"><img src="https://img.shields.io/badge/python-3.12-3776AB?style=for-the-badge" alt="Python 3.12" /></a>
    <a href="#ci"><img src="https://img.shields.io/badge/ci-all%20green-22c55e?style=for-the-badge" alt="CI all green" /></a>
</p>

<p align="center">
    <a href="#validation-state"><img src="https://img.shields.io/badge/status-research%20prototype-orange?style=for-the-badge" alt="Research prototype status" /></a>
</p>

<p align="center">
    <a href="https://github.com/eneskemalergin/mzarc/actions/workflows/ci.yml"><img src="https://github.com/eneskemalergin/mzarc/actions/workflows/ci.yml/badge.svg" alt="GitHub CI" /></a>
</p>

---

## What This Is

`mzarc` is a research codec for mzML-derived spectra. The question it explores: can a domain-specific, entropy-coded pipeline beat generic compression on a real proteomics benchmark while remaining operationally simple and exactly lossless?

The answer on the current benchmark is yes. mzarc lossless is smaller than xz on the same binary dump and smaller than mzMLb with no HDF5 dependency. The lossy path pushes further at controlled intensity error.

**Why not mzMLb or xz?** mzMLb requires HDF5 tooling and has no lossy mode. xz has no domain awareness and cannot trade intensity precision for size. mzarc does both.

The pipeline is intentionally split:

```txt
mzML -> Python dump tool -> flat binary -> Zig codec -> .mzarc
```

Python handles mzML ingestion. Zig owns the codec, validation, and all performance-sensitive transforms. This keeps XML and schema handling out of the codec bring-up path. A native Zig ingest is on the roadmap.

## Quick Start

The repo carries its own Zig 0.16.0 toolchain. Python is managed with `uv`.

```bash
uv sync
./zig-0.16.0/zig build -Drelease=true
```

Convert, encode, and inspect:

```bash
uv run python tools/mzml_dump.py data/PXD075509/15HCD_1.mzML -o 15HCD_1.bin
./zig-out/bin/mzarc encode 15HCD_1.bin -o 15HCD_1.mzarc
./zig-out/bin/mzarc inspect 15HCD_1.mzarc
```

Run the full CI gate (fixture, roundtrips, adversarial corpus, regression):

```bash
./zig-0.16.0/zig build ci
```

## Benchmark Summary

Benchmark dataset: `data/PXD075509/15HCD_1.mzML` (9,001 spectra, 2.67M peaks). Full report at [benchmark/report.md](benchmark/report.md).

| codec               |      size | vs mzML |
| ------------------- | --------: | ------: |
| mzML                | 75.55 MiB |  100.0% |
| mzarc lossless      | 15.27 MiB |   20.2% |
| mzarc lossy q=16384 | 12.62 MiB |   16.7% |
| mzMLb               | 16.25 MiB |   21.5% |
| xz dump             | 15.77 MiB |   20.9% |
| zstd dump           | 17.85 MiB |   23.6% |

mzarc lossless beats every other codec in the comparison. It is 3.1% smaller than xz on the same binary dump and 1.3% smaller than mzMLb. The lossy path at q=16384 reaches 16.7% of raw mzML size with p95 relative intensity error of 0.055%.

<p align="center">
  <img src="benchmark/plots/size_comparison.png" width="720" alt="Artifact size comparison across mzarc, MS-domain codecs, and generic compressors on 15HCD_1" />
  <br><em>Size comparison: mzarc lossless and lossy vs MS-domain and generic alternatives.</em>
</p>

Throughput (zebrac medians, release build, single thread):

- encode lossless: `51.92 MiB/s` (median wall time `0.294 s`)
- decode lossless: `155.4 MiB/s` (median wall time `0.198 s`)

<p align="center">
  <img src="benchmark/plots/performance_overview.png" width="720" alt="Encode and decode throughput across all tested codecs on 15HCD_1" />
  <br><em>Throughput overview: encode and decode speed across all codec groups.</em>
</p>

Lossless fidelity: exact round-trip, mean absolute m/z error `0.0`, global scan order preserved.

## v0.2.0 Release

`v0.2.0` is the first entropy-coded release. Key additions over v0.1.1:

- lossless and lossy `.mzarc` encode/decode CLI paths
- split-exponent intensity coding with rANS entropy coding on m/z and intensity streams
- per-spectrum m/z width support in the container format
- block-scoped arena allocators (encode peak RSS dropped from 208 MB to 89 MB)
- `zig build ci`: 2.4 s local gate covering fixture, roundtrips, adversarial corpus, and regression
- adversarial corpus coverage across 13 categories

Size gains on `15HCD_1` relative to v0.1.1:

- total lossless size: `20.23 MiB -> 15.27 MiB` (24.5% reduction)
- m/z payload: 30.9% smaller via rANS
- intensity payload: 17.5% smaller via split-exponent + rANS

## Implementation

### Ingest and dump layer

`tools/mzml_dump.py` converts mzML to the flat binary format the codec expects. The Python dump is intentional: it isolates XML parsing from the codec. A native Zig ingest path is planned once the codec core is stable.

`src/binary_reader.zig` reads and writes the dump format. `mzarc dump-inspect` reports dump statistics.

### Codec core

- `src/quantize.zig`: m/z fixed-point conversion and lossy intensity quantization
- `src/bitpack.zig`: scalar FOR bit-packing and unpacking
- `src/block.zig`: block encode/decode (deltas, CRC, entropy decisions, per-spectrum widths)
- `src/codec.zig`: `.mzarc` container stream read/write
- `src/main.zig`: CLI subcommands (encode, decode, inspect, validate, benchmark)

### Benchmark and analysis

- `tools/benchmark.sh`: full benchmark pipeline (zebrac timing, external baselines, fidelity sweep)
- `tools/validate.sh`: adversarial, binary roundtrip, fidelity, and regression checks
- `tools/collect_report.py`: assembles report.json, generates 8 plots, writes report.md
- `tools/check_regression.py`: compares the current report against the versioned baseline

## CI

The workflow runs on Ubuntu and macOS on every push and pull request. No mzML data or Python required. Checks use the frozen binary fixture in `test/fixtures/`.

Jobs: build with `-Drelease=true`, unit tests, frozen fixture SHA-256 integrity check, lossless/lossy roundtrips and adversarial corpus via `tools/smoke_test.sh`.

The full local gate (`zig build ci`) additionally runs a regression check against the versioned baseline and is intended for pre-commit use.

## Validation State

CI is green on the current build. Lossless fidelity on `15HCD_1` is exact: zero m/z error, scan order preserved. The lossy path at `q=16384` yields p95 relative intensity error of 0.055%.

This is a research prototype. It has been validated on one dataset from one instrument type. Quirks in edge cases are expected and will surface with broader use.

## Repository Layout

```text
mzarc/
├── benchmark/              public benchmark artifacts and plots
├── data/                   local datasets and benchmark workdirs (gitignored)
├── src/                    Zig codec implementation
├── test/                   Zig tests, frozen fixtures, and adversarial inputs
├── tools/                  Python ingest, benchmark, and analysis scripts
├── build.zig
├── build.zig.zon
├── pyproject.toml
└── README.md
```

## Roadmap

v0.2.0 is released. Broad directions from here:

- Native Zig mzML parser so the default ingest path does not need the Python dump
- SIMD acceleration for hot decode paths
- Native multithreading as the default encode/decode mode
- Cross-spectrum delta coding (requires a DIA dataset)
- Streaming encode/decode without full-file buffering
- Native parsers for vendor formats (.d, .raw, and others) as the ecosystem matures
- Multi-instrument validation beyond the current E. coli benchmark

## References

**Format and codec**

- Martens, L. et al. [mzML -- a community standard for mass spectrometry data](https://doi.org/10.1074/mcp.R110.000133). _Molecular & Cellular Proteomics_.
- Bhamber, R. S. et al. (2020). [mzMLb: a future-proof raw mass spectrometry data format based on standards-compliant mzML and optimized for speed and storage requirements](https://doi.org/10.1021/acs.jproteome.0c00192). _Journal of Proteome Research_.
- [ms-numpress](https://github.com/ms-numpress/ms-numpress): Lossless compression of high precision numerical data for mass spectrometry.
- [mscompress](https://github.com/chrisagrams/mscompress): Domain-specific compression for tandem mass spectrometry data.

**Entropy coding**

- Duda, J. (2013). [Asymmetric numeral systems: entropy coding combining speed of Huffman coding with compression rate of arithmetic coding](https://arxiv.org/abs/1311.2540). _arXiv:1311.2540_.
- Giesen, F. (2014). [rANS notes](https://fgiesen.wordpress.com/2014/02/02/rans-notes/). Practical derivation and proofs for streaming rANS; reference implementation at [github.com/rygorous/ryg_rans](https://github.com/rygorous/ryg_rans).

**Dataset**

- [PXD075509](https://www.ebi.ac.uk/pride/archive/projects/PXD075509): HCD fragmentation energy series, _E. coli_ rRNA digest. Primary benchmark dataset.

**Tooling**

- [Zig](https://ziglang.org): systems programming language used for the codec, CLI, and test harness.
- [pyteomics](https://github.com/levitsky/pyteomics): Python library for mzML/mzMLb ingestion in the dump tool. Cite: Goloborodko et al. (2013), DOI [10.1007/s13361-012-0516-6](https://doi.org/10.1007/s13361-012-0516-6); Levitsky et al. (2018), DOI [10.1021/acs.jproteome.8b00717](https://doi.org/10.1021/acs.jproteome.8b00717).
- [zebrac](https://github.com/eneskemalergin/zebrac): Linux perf-counter profiling tool used as the primary timing source (binary at `tools/zebrac`).

---

## License

MIT. See [LICENSE](LICENSE).

---

<br />

<p align="center">
    <em>
        Ions drift to ground<br />
        Folded into bit-packed frames -<br />
        The machine breathes light.
    </em>
</p>
