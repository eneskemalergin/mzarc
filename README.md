<!-- markdownlint-disable MD033 MD036 MD041 -->
<p align="center">
    <img src="assets/mzarc-readme-header.svg" alt="mzarc header logo" width="860" />
</p>

<p align="center">
    Feasibility-first compression prototype for mzML-derived mass spectrometry spectra.
</p>

<p align="center">
    Current version: <strong>v0.2.0</strong> - Full release, all exit criteria green, benchmarked and documented
</p>

<p align="center">
    <a href="#v020-release"><img src="https://img.shields.io/badge/version-v0.2.0-0f766e?style=for-the-badge" alt="Version v0.2.0" /></a>
    <a href="#quick-start"><img src="https://img.shields.io/badge/zig-0.16.0-f7a41d?style=for-the-badge" alt="Zig 0.16.0" /></a>
    <a href="#quick-start"><img src="https://img.shields.io/badge/python-3.12-3776AB?style=for-the-badge" alt="Python 3.12" /></a>
    <a href="#github-ci"><img src="https://img.shields.io/badge/ci-all%20green-22c55e?style=for-the-badge" alt="CI all green" /></a>
</p>

<p align="center">
    <a href="#validation-state"><img src="https://img.shields.io/badge/status-research%20prototype-orange?style=for-the-badge" alt="Research prototype status" /></a>
</p>

<p align="center">
    <a href="https://github.com/eneskemalergin/mzarc/actions/workflows/ci.yml"><img src="https://github.com/eneskemalergin/mzarc/actions/workflows/ci.yml/badge.svg" alt="GitHub CI" /></a>
</p>

---

## What This Repository Is

`mzarc` is an experiment around a narrow question: can a domain-specific codec for mzML-derived spectra beat generic compression on a practical benchmark while staying exact and operationally simple?

The current pipeline is intentionally split in two:

`mzML -> Python dump tool -> flat binary dump -> Zig codec -> .mzarc`

Python handles mzML ingestion and normalization. Zig owns the codec, validation, and performance-sensitive transforms. That separation keeps XML and schema handling out of the codec bring-up path.

## v0.2.0 Release

`v0.2.0` is the first full release of the entropy-coded scalar pipeline. It includes:

- flat dump ingest and inspection tools for mzML
- lossless and lossy `.mzarc` encode/decode CLI paths
- split-exponent intensity coding with rANS entropy coding on m/z and intensity streams
- per-spectrum m/z width support in the container format
- block-scoped arena allocators for bounded, predictable memory use
- zebrac-primary benchmark timing with hyperfine validation
- `zig build ci`: 2.4 s, 11-step pipeline covering fixture, roundtrips, adversarial corpus, and regression
- unit tests, frozen fixture validation, and adversarial corpus coverage (13 categories)

Deferred to v0.3.x: SIMD FOR unpack and cross-spectrum delta (requires a DIA dataset).

## Benchmark Summary

The checked-in public benchmark is based on `data/PXD075509/15HCD_1.mzML` (9,001 spectra, 2.67M peaks). Full report at [benchmark/report.md](benchmark/report.md).

Size results:

| codec | size | vs mzML |
| --- | ---: | ---: |
| mzML | 75.55 MiB | 100.0% |
| mzarc lossless | 15.27 MiB | 20.2% |
| mzarc lossy q=16384 | 12.62 MiB | 16.7% |
| mzMLb | 16.25 MiB | 21.5% |
| xz dump | 15.77 MiB | 20.9% |
| zstd dump | 17.85 MiB | 23.6% |

mzarc lossless (15.27 MiB) is 3.1% smaller than xz on the same binary dump. It beats every other format in the MS-domain codec group. The lossy path at q=16384 reaches 16.7% of mzML with p95 relative intensity error of 0.055%.

<p align="center">
  <img src="benchmark/plots/size_comparison.png" width="720" alt="Artifact size comparison across mzarc, MS-domain codecs, and generic compressors on 15HCD_1" />
  <br><em>Size comparison: mzarc lossless and lossy vs MS-domain and generic alternatives.</em>
</p>

Throughput (zebrac medians, release build, single thread):

- encode lossless: `51.92 MiB/s` median `0.294 s`
- decode lossless: `155.4 MiB/s` median `0.198 s`

<p align="center">
  <img src="benchmark/plots/performance_overview.png" width="720" alt="Encode and decode throughput across all tested codecs on 15HCD_1" />
  <br><em>Throughput overview: encode and decode speed across all codec groups.</em>
</p>

Lossless fidelity: exact round-trip, mean absolute m/z error `0.0`, global scan order preserved.

Payload breakdown (lossless):

- m/z payload: `7,143,905` bytes (44.6% of file)
- intensity payload: `8,671,992` bytes (54.2% of file)

## What Changed Since v0.1.1

The original `v0.1.1` baseline proved that a scalar, domain-aware codec could be worthwhile. `v0.2.0` is the first release where the thesis is validated with real entropy coding, bounded memory, and a full CI harness.

Key gains on `15HCD_1` relative to the v0.1.1 scalar baseline:

- total lossless size: `20.23 MiB -> 15.27 MiB` (24.5% reduction)
- m/z payload: reduced 30.9% via rANS entropy coding
- intensity payload: reduced 17.5% via split-exponent + rANS
- encode peak RSS: 208 MB -> 89 MB (57% reduction)
- exact lossless round-trip on all tested data

## Implemented Pieces

### Ingest and dump layer

- `tools/mzml_dump.py` converts mzML into the flat binary dump used by the codec pipeline. This Python step is intentional for now: it keeps mzML XML parsing and schema handling out of the codec. A native Zig ingest path is planned for a future release once the codec core is stable.
- `tools/inspect_dump.py` inspects dump contents and basic statistics
- `src/binary_reader.zig` reads and writes the dump format

### Codec core

- `src/quantize.zig` handles m/z fixed-point conversion and lossy intensity quantization
- `src/delta.zig` handles intra-spectrum delta transforms
- `src/bitpack.zig` handles scalar FOR packing and unpacking
- `src/block.zig` handles block encode/decode, CRC validation, entropy decisions, and per-spectrum width support
- `src/codec.zig` writes and reads `.mzarc` container streams
- `src/main.zig` exposes encode, decode, inspect, validate, and benchmark helpers

### Benchmark and analysis

- `tools/benchmark.sh` runs the full benchmark pipeline (zebrac timing, external baselines, fidelity sweep)
- `tools/validate.sh` runs adversarial, binary roundtrip, fidelity, and regression checks
- `tools/collect_report.py` assembles report.json, generates 8 plots, and writes report.md
- `tools/check_regression.py` compares the current report against the versioned baseline
- [benchmark/report.md](benchmark/report.md) is the human-readable benchmark summary
- [benchmark/report.json](benchmark/report.json) is the machine-readable benchmark artifact

## GitHub CI

The CI workflow runs on Ubuntu and macOS on every push and pull request. It does not require mzML data or Python: all steps operate on the frozen binary fixture committed in `test/fixtures/`.

Steps:

1. Build with `-Drelease=true`
2. Unit tests (`zig build test`)
3. Frozen fixture SHA-256 integrity check
4. Lossless roundtrip, lossy roundtrip, and adversarial corpus validation via `tools/smoke_test.sh`

The full local CI gate (`zig build ci`) also includes a regression check against the versioned baseline and is intended for pre-commit runs rather than remote CI.

## Validation State

`zig build ci` covers frozen fixture verification, lossless and lossy roundtrips, an adversarial corpus (13 categories), and a regression check against the versioned baseline. All pass on the current build.

Lossless fidelity on `15HCD_1` is exact: zero m/z error, global scan order preserved. The lossy path at `q=16384` yields p95 relative intensity error of 0.055%.

Decode throughput is higher than the pre-entropy scalar codec for the same compression ratio. The rANS overhead is an accepted trade-off for the 24.5% size reduction.

## Quick Start

Python is managed with `uv`. The repo carries its own Zig 0.16.0 toolchain at `./zig-0.16.0/zig`.

```bash
uv sync
./zig-0.16.0/zig build -Drelease=true
./zig-0.16.0/zig build test
```

Convert mzML to the internal dump, then encode and decode `.mzarc`:

```bash
uv run python tools/mzml_dump.py data/PXD075509/15HCD_1.mzML -o data/PXD075509/15HCD_1.bin
./zig-out/bin/mzarc encode data/PXD075509/15HCD_1.bin -o data/PXD075509/15HCD_1.lossless.mzarc
./zig-out/bin/mzarc decode data/PXD075509/15HCD_1.lossless.mzarc -o data/PXD075509/15HCD_1.roundtrip.bin
./zig-out/bin/mzarc inspect data/PXD075509/15HCD_1.lossless.mzarc
```

Run the full CI gate (fixture, roundtrips, adversarial, regression):

```bash
./zig-0.16.0/zig build ci
```

Run the benchmark pipeline from scratch:

```bash
bash tools/benchmark.sh data/PXD075509/15HCD_1.mzML
bash tools/validate.sh
source .venv/bin/activate && python3 tools/collect_report.py benchmark/raw/manifest.json
```

## Repository Layout

```text
mzarc/
├── benchmark/              public benchmark artifacts and plots
├── data/                   local datasets and generated benchmark workdirs
├── plan/                   project plans and milestone notes
├── src/                    Zig codec implementation
├── test/                   Zig tests, fixtures, and adversarial inputs
├── tools/                  Python ingest, benchmark, and analysis scripts
├── build.zig
├── build.zig.zon
├── pyproject.toml
└── README.md
```

## Roadmap

v0.2.0 is released. The next milestones:

1. v0.3.0: SIMD FOR unpack.
2. v0.3.1: Cross-spectrum delta. Requires a DIA dataset; not viable on the current DDA acquisition.
3. v0.5.3: Streaming encode/decode.
4. v0.7.1: Multi-instrument validation.

## References

**Format and codec**

- Martens, L. et al. [mzML — a community standard for mass spectrometry data](https://doi.org/10.1074/mcp.R110.000133). *Molecular & Cellular Proteomics*.
- Bhamber, R. S. et al. (2020). [mzMLb: a future-proof raw mass spectrometry data format based on standards-compliant mzML and optimized for speed and storage requirements](https://doi.org/10.1021/acs.jproteome.0c00192). *Journal of Proteome Research*.
- [ms-numpress](https://github.com/ms-numpress/ms-numpress): Lossless compression of high precision numerical data for mass spectrometry.
- [mscompress](https://github.com/chrisagrams/mscompress): Domain-specific compression for tandem mass spectrometry data.

**Entropy coding**

- Duda, J. (2013). [Asymmetric numeral systems: entropy coding combining speed of Huffman coding with compression rate of arithmetic coding](https://arxiv.org/abs/1311.2540). *arXiv:1311.2540*.
- Giesen, F. (2014). [rANS notes](https://fgiesen.wordpress.com/2014/02/02/rans-notes/). Practical derivation and proofs for streaming rANS; reference implementation at [github.com/rygorous/ryg_rans](https://github.com/rygorous/ryg_rans).

**Dataset**

- [PXD075509](https://www.ebi.ac.uk/pride/archive/projects/PXD075509): HCD fragmentation energy series, *E. coli* rRNA digest. Used as the primary benchmark dataset throughout this project.

**Tooling**

- [Zig](https://ziglang.org): systems programming language used for the codec, CLI, and test harness.
- [pyteomics](https://github.com/levitsky/pyteomics): Python library used for mzML/mzMLb ingestion in the dump tool. Cite: Goloborodko et al. (2013), DOI [10.1007/s13361-012-0516-6](https://doi.org/10.1007/s13361-012-0516-6); Levitsky et al. (2018), DOI [10.1021/acs.jproteome.8b00717](https://doi.org/10.1021/acs.jproteome.8b00717).
- [zebrac](https://github.com/eneskemalergin/zebrac): Linux perf-counter profiling tool used as the primary timing source (used binary in [tools/zebrac/](tools/zebrac/)).

---

<br />

<p align="center">
    <em>
        Ions drift to ground<br />
        Folded into bit-packed frames -<br />
        The machine breathes light.
    </em>
</p>
<!-- markdownlint-enable MD033 MD041 -->
