# Local tools

`mzml_dump.py` creates the one Dump V1 input used by the dump comparison. `benchmark.sh` measures that dump and the original mzML as separate inputs.

The generic compressors come from `PATH`. The mass-spectrometry MScompress CLI must come from `tools/bin/mscompress-msz`; the command named `mscompress` on some Linux systems is an unrelated Microsoft compression utility.

Build the native MScompress 1.0.16 CLI with:

```bash
bash tools/build_mscompress.sh
```

The script checks out the pinned upstream commit under ignored `tmp/tools/`, runs the upstream CMake tests, and installs a stripped local binary under ignored `tools/bin/`. Its build and runtime do not use Python. Git, CMake, a C compiler, and network access for the first checkout are required.

MScompress 1.0.16 does not include a project-level license file in its tagged source, and GitHub does not identify a repository license. Keep the binary local. Do not commit or redistribute it from this repository unless the upstream licensing terms are clarified.

Run the local comparison with:

```bash
bash tools/benchmark.sh data/PXD075509/15HCD_1.mzML
```

The reference report uses five measured samples after one warmup. Parallel rows use four workers and are marked `[P]`. Use `--help` for the output, worker, and sample controls.

Files under `data/examples/` are parser sanity inputs. They require `--sanity`, which labels the report as a wiring check and omits figures. Their measurements are not benchmark results.

The benchmark report contains two input sections:

- one Dump V1 input compressed by mzarc, gzip, pigz, zstd, and xz;
- the original mzML compressed by gzip, pigz, zstd, xz, and MScompress.

Generic compressors must reproduce the exact input bytes. MScompress must reproduce the exact Dump V1 spectrum fields; it may rewrite the mzML document representation.

Each percentage column names its denominator. Compare methods within a section, not across the Dump V1 and original mzML sections. Each section keeps the complete results in separate artifact, encode, and decode tables. If `gnuplot` is available, the report also includes one SVG summary for each input. The figures compare artifact size, throughput, and peak RSS. Plotting does not use Python.
