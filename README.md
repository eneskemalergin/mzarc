<!-- markdownlint-disable MD033 MD041 -->
<p align="center">
    <img src="assets/mzarc-readme-header.svg" alt="mzarc header logo" width="860" />
</p>

<p align="center">
    Feasibility-first compression prototype for mzML-derived mass spectrometry spectra.
</p>

<p align="center">
    Current version: <strong>v0.1.5</strong> &mdash; entropy snapshot, benchmarked and documented
</p>

<p align="center">
    <a href="#v015-snapshot"><img src="https://img.shields.io/badge/version-v0.1.5-0f766e?style=for-the-badge" alt="Version v0.1.5" /></a>
    <a href="#quick-start"><img src="https://img.shields.io/badge/zig-0.16.0--dev-f7a41d?style=for-the-badge" alt="Zig 0.16.0 dev" /></a>
    <a href="#quick-start"><img src="https://img.shields.io/badge/python-3.12-3776AB?style=for-the-badge" alt="Python 3.12" /></a>
    <a href="#validation-state"><img src="https://img.shields.io/badge/status-research%20prototype-orange?style=for-the-badge" alt="Research prototype status" /></a>
    <a href="#validation-state"><img src="https://img.shields.io/badge/release%20gate-decode%20regression%20open-bd561d?style=for-the-badge" alt="Decode regression still open" /></a>
</p>

---

## What This Repository Is

`mzarc` is an experiment around a narrow question: can a domain-specific codec for mzML-derived spectra beat generic compression on a practical benchmark while staying exact and operationally simple?

The current pipeline is intentionally split in two:

`mzML -> Python dump tool -> flat binary dump -> Zig codec -> .mzarc`

Python handles mzML ingestion and normalization. Zig owns the codec, validation, and performance-sensitive transforms. That separation keeps XML and schema handling out of the codec bring-up path.

## v0.1.5 Snapshot

`v0.1.5` is the current public snapshot of the entropy-coded scalar pipeline. It includes:

- flat dump ingest and inspection tools for mzML
- lossless and lossy `.mzarc` encode/decode CLI paths
- split-exponent intensity coding
- rANS on m/z and intensity streams with dry-run gates
- per-spectrum m/z width support in the container format
- benchmark report generation, plots, and cached `--mzarc-only` refresh mode
- unit tests, frozen fixture validation, and adversarial validation coverage

What it does not claim yet:

- this is not the final v0.2.0 release state
- decode throughput is still above the current regression gate versus the `v0.1.1` baseline
- cross-spectrum delta and SIMD decode work are still deferred

## Current Benchmark Status

The checked-in public benchmark is based on `data/PXD075509/15HCD_1.mzML`.

Current lossless result:

- input mzML: `75.55 MiB`
- dump: `30.78 MiB`
- mzarc lossless: `15.27 MiB` (`16016009` bytes)
- mzarc lossy `q=16384`: `12.62 MiB` (`13233307` bytes)

Current lossless throughput from [benchmark/report.md](benchmark/report.md):

- encode: `0.32102s` mean, `95.88 MiB/s`
- decode: `0.20311s` mean, `151.53 MiB/s`

Current lossless payload breakdown:

- m/z payload: `7143905` bytes
- intensity payload: `8671992` bytes

What this means relative to the baselines in the same report:

- lossless `.mzarc` is smaller than `gzip dump` (`19.82 MiB`)
- lossless `.mzarc` is smaller than `zstd dump` (`17.85 MiB`)
- lossless `.mzarc` is smaller than `mzMLb` (`16.25 MiB`)
- lossless `.mzarc` is still slightly larger than `xz dump` (`15.77 MiB`)
- the lossless path remains exact: mean absolute m/z error is `0.0` and round-trip order is preserved

The unresolved issue is throughput regression against the `v0.1.1` baseline. The current decode median is about `+35.25%` slower than that baseline, so the compression target is met but the release gate is not fully closed yet.

## What Changed Since v0.1.1

The original `v0.1.1` baseline proved that a scalar, domain-aware codec could be worthwhile. `v0.1.5` is the first snapshot where that thesis is pushed with real entropy coding rather than only delta + FOR packing.

Key gains versus `v0.1.1` on `15HCD_1`:

- total lossless size: `20.23 MiB -> 15.27 MiB`
- m/z payload: `10340312 -> 7143905` bytes
- intensity payload: `10673832 -> 8671992` bytes
- exact lossless round-trip remains intact

Key tradeoff in the current default:

- the per-spectrum m/z-width machinery is implemented in the format
- the encoder now uses a cheap precheck and skips marginal per-spectrum wins on `15HCD_1`
- that keeps encode materially faster than the earlier fully materialized 3a.4 path while only giving back `1635` bytes on this dataset

## Implemented Pieces

### Ingest and dump layer

- `tools/mzml_dump.py` converts mzML into the flat binary dump used by the codec pipeline
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

- `tools/benchmark_v1.py` produces the main benchmark report and plots
- `tools/check_regression.py` compares the current report against `benchmark/baseline_v0.1.1.json`
- [benchmark/report.md](benchmark/report.md) is the human-readable benchmark summary
- [benchmark/report.json](benchmark/report.json) is the machine-readable benchmark artifact
- [benchmark/entropy_analysis.txt](benchmark/entropy_analysis.txt) tracks the entropy-coding investigation and tradeoffs

## Validation State

The repo currently has three different confidence levels and they should not be conflated:

- correctness work is in good shape: unit tests, frozen lossless/lossy validation, and adversarial validation are passing in the current codec state
- benchmarked fidelity is exact for lossless `.mzarc` on the public dataset
- full release gating is not fully green because the decode regression check still fails against the `v0.1.1` baseline

That distinction matters. `v0.1.5` is a solid research snapshot, not a claim that every planned `v0.2.0` exit criterion is finished.

## Quick Start

Python is managed with `uv`. The repo carries its own Zig toolchain.

```bash
export ZIG="$PWD/zig-x86_64-linux-0.16.0-dev.2905+5d71e3051/zig"
uv sync
$ZIG build
$ZIG build test
```

Convert mzML to the internal dump, then encode and decode `.mzarc`:

```bash
uv run python tools/mzml_dump.py data/PXD075509/15HCD_1.mzML -o data/PXD075509/15HCD_1.bin
./zig-out/bin/mzarc encode data/PXD075509/15HCD_1.bin -o data/PXD075509/15HCD_1.lossless.mzarc
./zig-out/bin/mzarc decode data/PXD075509/15HCD_1.lossless.mzarc -o data/PXD075509/15HCD_1.roundtrip.bin
./zig-out/bin/mzarc inspect data/PXD075509/15HCD_1.lossless.mzarc
```

Run the public benchmark:

```bash
uv run python tools/benchmark_v1.py data/PXD075509/15HCD_1.mzML --build --repeats 3 --external-baselines all --public-dir benchmark
```

Refresh only the `.mzarc` numbers and regenerate the public report/plots without rerunning unchanged external baselines:

```bash
uv run python tools/benchmark_v1.py data/PXD075509/15HCD_1.mzML --build --repeats 3 --public-dir benchmark --mzarc-only
```

If you want the full release gate rather than just the core tests, run:

```bash
$ZIG build ci
```

At the moment that command is expected to fail on the decode-regression threshold, not on basic correctness.

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

The next substantive work is already clear from the current results:

1. reduce decode cost in the m/z entropy path so the regression gate can close
2. revisit SIMD FOR unpack as a real throughput lever rather than an observation-only note
3. bring back additional size wins only when they survive a speed tradeoff on real data
4. defer cross-spectrum delta until it is validated on a dataset where overlap actually supports it
5. add downstream search-impact measurements before presenting lossy mode as more than a numerical experiment

## References

- [benchmark/report.md](benchmark/report.md)
- [benchmark/report.json](benchmark/report.json)
- [benchmark/entropy_analysis.txt](benchmark/entropy_analysis.txt)
- [benchmark/cross_spectrum_analysis.txt](benchmark/cross_spectrum_analysis.txt)
- [benchmark/intensity_entropy_analysis.txt](benchmark/intensity_entropy_analysis.txt)

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
