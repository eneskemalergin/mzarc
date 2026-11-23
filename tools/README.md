# Local tools

`benchmark.sh` creates one Dump V1 input with `mzarc dump`, then measures that dump and the original mzML as separate inputs. It needs `zig` 0.16.0 and `zebrac` 0.6.2 on `PATH`; the report records the zmz version the build pins.

The generic compressors come from `PATH`. The mass-spectrometry MScompress CLI must come from `tools/bin/mscompress-msz`; the command named `mscompress` on some Linux systems is an unrelated Microsoft compression utility.

Build the native MScompress 1.0.16 CLI with:

```bash
bash tools/build_mscompress.sh
```

The script checks out the pinned upstream commit under ignored `tmp/tools/`, runs the upstream CMake tests, and installs a stripped local binary under ignored `tools/bin/`. Its build and runtime do not use Python. Git, CMake, a C compiler, and network access for the first checkout are required.

MScompress 1.0.16 does not include a project-level license file in its tagged source, and GitHub does not identify a repository license. Keep the binary local. Do not commit or redistribute it from this repository unless the upstream licensing terms are clarified.

Run the local comparison with:

```bash
bash tools/benchmark.sh ~/Github/data/mzml/PXD075509/15HCD_1.mzML
```

Run `bash tools/benchmark.sh --check` after changing the runner. It uses the tiny parser example from the local data root and temporary fault injection to check argument rejection, output ownership, missing tools, failed validation, malformed zebrac results, and one complete sanity report. It does not retain a benchmark run or enter CI.

The reference report uses five measured samples after one warmup. Parallel rows use four workers and are marked `[P]`. Use `--help` for the output, worker, and sample controls.

Each operation runs as one direct zebrac command. The runner requires the reported command arguments, sampling configuration, result count, failure count, wall-time unit, RSS unit, and summary sample counts to match the request. It does not use shell wrappers or zebrac's multi-command comparison display.

zebrac is Linux-only and requires access to `perf_event_open`. The runner has no macOS or permission-denied fallback and does not substitute another measurement source.

Files under `examples/` in the local data root (`~/Github/data/mzml`, or `MZARC_DATA`) are parser sanity inputs. They require `--sanity`, which labels the report as a wiring check and omits figures. Their measurements are not benchmark results.

The benchmark report contains five sections:

- one Dump V1 input compressed by mzarc, gzip, pigz, zstd, and xz;
- the original mzML compressed by mzarc's exact document archive, gzip, pigz, zstd, xz, and MScompress;
- both mzarc lossy profiles, with the largest errors `mzarc validate` observed;
- `mzarc dump` ingest from the original mzML;
- `mzarc validate`, `dump-inspect`, and `inspect` on the validated Dump V1 round trip, with their wall time and peak RSS.

mzarc's lossless and exact archives and the generic compressors must reproduce the exact input bytes. MScompress must reproduce the fields retained by Dump V1, checked by running `mzarc dump` on its decoded mzML; it may rewrite the mzML document representation. The lossy rows must pass `mzarc validate --mode=lossy` or `--mode=mzml-lossy`.

Each percentage column names its denominator. Compare methods within a section, not across the Dump V1 and original mzML sections. Each section keeps the complete results in separate artifact, encode, and decode tables. The report also records the source shape, measurement method, validation boundaries, limits, and tool versions. If `gnuplot` is available, it adds one comparison figure for each input. Each figure title names the source file and comparison-input size. Artifact percentages are labeled directly. The Dump V1 figure highlights mzarc and labels its throughput and RSS without repeating every table value. Plotting does not use Python.

The runner reads the mzarc release version from `build.zig.zon` and requires it to match the latest released entry in `CHANGELOG.md`. It queries every other tool directly. Report numbers come from the generated dump, artifacts, and zebrac summaries; the Markdown tables are aligned after generation.

Each ignored run directory retains the report, one zebrac JSON file per operation under `zebrac/`, the TSV rows (`dump.tsv`, `mzml.tsv`, `lossy.tsv`, `lossy-errors.tsv`, `ingest.tsv`, `commands.tsv`), and the figures. The accepted `benchmark/` directory tracks the report, those six TSV files, and the two SVG summaries, but not the zebrac JSON.
