<p align="center">
    <strong>LOGO PENDING</strong><br />
    <sub>Artwork will be added after the prototype shape settles.</sub>
</p>

<h1 align="center">mzarc</h1>

<p align="center">
    Feasibility-first compression prototype for mzML-derived mass spectrometry spectra.
</p>

<p align="center">
    Current target: <strong>v0.0.1</strong>
</p>

<p align="center">
    <a href="#current-state"><img src="https://img.shields.io/badge/version-v0.0.1-0f766e?style=for-the-badge" alt="Version v0.0.1" /></a>
    <a href="#development"><img src="https://img.shields.io/badge/zig-0.16.0--dev-f7a41d?style=for-the-badge" alt="Zig 0.16.0 dev" /></a>
    <a href="#development"><img src="https://img.shields.io/badge/python-3.12-3776AB?style=for-the-badge" alt="Python 3.12" /></a>
    <a href="#current-state"><img src="https://img.shields.io/badge/status-prototype-orange?style=for-the-badge" alt="Prototype status" /></a>
    <a href="#development"><img src="https://img.shields.io/badge/tests-passing-2ea44f?style=for-the-badge" alt="Tests passing" /></a>
</p>

---

## What This Repository Is

`mzarc` is a small, build-first experiment around one question:

Can we take real spectra from mzML, move them into a simple binary handoff format, and then prove that a domain-specific scalar codec is worth continuing?

That is the current scope. This repository is not trying to be the final mass spectrometry container yet. It is trying to produce clean evidence.

Right now the pipeline is intentionally narrow:

`mzML -> Python dump tool -> flat binary dump -> Zig scalar transforms -> V1 block prototype`

The point of this shape is to keep XML parsing and codec work separate. Python handles mzML ingestion once. Zig handles the actual transform and decode work repeatedly.

---

## Current State

This repository is at `v0.0.1`.

What exists today:

- real mzML ingestion through `pyteomics`
- flat binary dump generation in `tools/mzml_dump.py`
- dump inspection in `tools/inspect_dump.py`
- Zig dump reader and writer in `src/binary_reader.zig`
- scalar m/z quantization in `src/quantize.zig`
- scalar intra-spectrum delta coding in `src/delta.zig`
- scalar frame-of-reference bit-packing in `src/bitpack.zig`
- first composed block encoder and decoder in `src/block_v1.zig`
- a minimal CLI entry point in `src/main.zig` with `dump-inspect`
- unit tests for each implemented layer

What this means in practice:

- the repo can read real mzML data
- the repo can turn it into a repeatable binary fixture format
- the Zig prototype can already exercise the transform stack on real spectral data
- the block layer is no longer hypothetical

What is still deliberately unfinished:

- exact m/z losslessness inside the current container
- preservation of original global scan order across MS1 and MS2
- SIMD and the more ambitious format work from later phases

---

## What v0.0.1 Is Proving

This version is trying to prove four things:

1. mzML ingestion does not need to be written in Zig for the prototype to move forward.
2. A boring binary handoff format is enough to isolate codec work from XML overhead.
3. The first scalar transform chain can be implemented, tested, and composed cleanly.
4. The project can stay honest by shipping working slices instead of speculative format design.

This is why the repository currently looks smaller and more concrete than the early design documents.

---

## What Is Implemented Right Now

### Python ingress

- `tools/mzml_dump.py` reads mzML with `pyteomics`, normalizes arrays, and writes a flat dump format.
- `tools/inspect_dump.py` validates the dump and reports counts and peak statistics.

### Zig prototype core

- `src/binary_reader.zig` reads and writes the dump format.
- `src/quantize.zig` handles m/z fixed-point conversion and lossy log-intensity quantization.
- `src/delta.zig` handles intra-spectrum delta encode and decode.
- `src/bitpack.zig` handles scalar frame-of-reference packing and unpacking.
- `src/block_v1.zig` composes the above into a real block encoder and decoder with CRC32 validation.
- `src/codec_v1.zig` stores `.mzv1` files with block streams for MS1 and MS2 and supports encode, decode, and inspect operations.

### Benchmarking

- `tools/benchmark_v1.py` benchmarks mzML ingest, `.mzv1` encode and decode, size, and round-trip fidelity.
- [benchmark/report.md](benchmark/report.md) contains the current public benchmark summary and plot references.
- [benchmark/report.json](benchmark/report.json) contains the machine-readable benchmark output.
- repo-root `benchmark/` contains the pushable report and plots.
- ignored `data/.../benchmarks/...` stores generated dumps, round-trips, and encoded intermediates.

### Current benchmark snapshot

- On `data/PXD075509/15HCD_1.mzML`, lossless `.mzv1` is `19.52 MiB`, down from `75.55 MiB` for mzML and `30.78 MiB` for the internal dump.
- Selected lossy `.mzv1` at `q=4096` is `13.14 MiB`, with `0.218%` p95 relative intensity error and `0.238%` p99 relative intensity error.
- Over 10 runs, lossless encode and decode average `0.7521s` and `0.7832s`; lossy encode and decode average `1.1657s` and `0.8638s`.
- Against generic dump baselines, lossless `.mzv1` is slightly smaller than `gzip dump` (`19.82 MiB`) but still larger than `zstd dump` (`17.85 MiB`).
- The current lossless path is still not truly lossless for m/z: mean absolute m/z error is about `5.0e-7`, intensity is exact on this sample, and original global order is not yet preserved.

### Validation

- unit tests cover dump IO, quantization, delta coding, bit-packing, and block round-trips
- the current CLI can encode, decode, and inspect a real `.mzv1` file end-to-end
- the benchmark report runs repeated timings and records confidence intervals, size tradeoffs, and fidelity summaries on real mzML input

---

## What Comes Next

The next development steps are straightforward and close to the code that already exists:

1. make the current lossless path truly lossless for m/z
2. preserve original global scan order across decode
3. add a second, more representative DIA dataset once the current benchmark path is stable
4. start comparing against external proteomics-specific baselines such as Numpress, mzMLb, mz5, or Aird

After that, the project will be in a position to make stronger claims about whether the format direction is worth continuing.

---

## Repository Layout

```text
mzarc/
├── build.zig
├── build.zig.zon
├── benchmark/
│   ├── report.json
│   ├── report.md
│   └── plots/
├── pyproject.toml
├── src/
│   ├── binary_reader.zig
│   ├── bitpack.zig
│   ├── block_v1.zig
│   ├── codec_v1.zig
│   ├── delta.zig
│   ├── main.zig
│   └── quantize.zig
├── test/
│   ├── test_binary_reader.zig
│   ├── test_bitpack.zig
│   ├── test_block_v1.zig
│   ├── test_codec_v1.zig
│   ├── test_delta.zig
│   └── test_quantize.zig
└── tools/
    ├── benchmark_core.py
    ├── benchmark_plotting.py
    ├── benchmark_report.py
    ├── benchmark_v1.py
    ├── inspect_dump.py
    └── mzml_dump.py
```

This tree is intentionally small. More files should only appear when the next working slice demands them.

---

## Development

Python is managed with `uv`, pinned to Python `3.12`.

The Zig toolchain is repo-local and should be used explicitly:

```bash
export ZIG="$PWD/zig-x86_64-linux-0.16.0-dev.2905+5d71e3051/zig"
uv sync
$ZIG build test
$ZIG build
```

Current working commands:

```bash
uv run python tools/mzml_dump.py data/PXD075509/15HCD_1.mzML -o data/PXD075509/15HCD_1.bin
uv run python tools/inspect_dump.py data/PXD075509/15HCD_1.bin
./zig-out/bin/mzarc dump-inspect data/PXD075509/15HCD_1.bin
./zig-out/bin/mzarc encode-v1 data/PXD075509/15HCD_1.bin -o data/PXD075509/15HCD_1.lossless.mzv1
./zig-out/bin/mzarc decode-v1 data/PXD075509/15HCD_1.lossless.mzv1 -o data/PXD075509/15HCD_1.roundtrip.bin
uv run python tools/benchmark_v1.py data/PXD075509/15HCD_1.mzML
```

The important rule for this stage is simple: every new step should leave behind a runnable command and a testable artifact.

---

## License

MIT. See [LICENSE](LICENSE) for details.

---

<br />

<p align="center">
    <em>
        Ions drift to ground<br />
        Folded into bit-packed frames—<br />
        The machine breathes light.
    </em>
</p>
