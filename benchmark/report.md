# Benchmark Report: 15HCD_1

- mzML input: data/PXD075509/15HCD_1.mzML
- private workdir: data/PXD075509/benchmarks/15HCD_1
- public output dir: benchmark
- repeats: 10
- selected lossy intensity quantization: q=16384

## Story

The flat dump is smaller than mzML because it strips almost all interchange overhead: XML structure, controlled-vocabulary markup, base64 wrapping, and general-purpose metadata that this prototype does not need for codec bring-up. That makes the dump a useful internal floor, not a format competitor by itself.

This benchmark focuses on two things that matter right now: whether the current `.mzarc` path buys meaningful size reduction over the interchange format, and whether encode and decode stay fast and stable across repeated runs.

External formats that actually ran end-to-end in this benchmark: mzMLb, MS-Numpress in mzML, MScompress, MScompress threaded.

## Dataset

- spectra: 9001
- total peaks: 2668458
- ms1 spectra: 917
- ms2 spectra: 8084

## Size Comparison

![Artifact Size Comparison](plots/size_comparison.png)

| artifact            |    bytes |      size | vs mzML | vs dump |
| ------------------- | -------: | --------: | ------: | ------: |
| mzML                | 79221306 | 75.55 MiB | 100.00% | 245.47% |
| dump                | 32273524 | 30.78 MiB |  40.74% | 100.00% |
| mzarc lossless      | 16016009 | 15.27 MiB |  20.22% |  49.63% |
| mzarc lossy         | 13233307 | 12.62 MiB |  16.70% |  41.00% |
| gzip dump           | 20780851 | 19.82 MiB |  26.23% |  64.39% |
| zstd dump           | 18720327 | 17.85 MiB |  23.63% |  58.01% |
| gzip mzML           | 25465391 | 24.29 MiB |  32.14% |  78.90% |
| zstd mzML           | 24770559 | 23.62 MiB |  31.27% |  76.75% |
| bzip2 dump          | 19719837 | 18.81 MiB |  24.89% |  61.10% |
| lz4 dump            | 26038757 | 24.83 MiB |  32.87% |  80.68% |
| xz dump             | 16535444 | 15.77 MiB |  20.87% |  51.24% |
| bzip2 mzML          | 24720971 | 23.58 MiB |  31.20% |  76.60% |
| lz4 mzML            | 34826833 | 33.21 MiB |  43.96% | 107.91% |
| xz mzML             | 24536980 | 23.40 MiB |  30.97% |  76.03% |
| mzMLb               | 17038178 | 16.25 MiB |  21.51% |  52.79% |
| MS-Numpress in mzML | 69905308 | 66.67 MiB |  88.24% | 216.60% |
| MScompress          | 22679622 | 21.63 MiB |  28.63% |  70.27% |
| MScompress threaded | 22579410 | 21.53 MiB |  28.50% |  69.96% |

Lossless `.mzarc` is already materially smaller than mzML on this sample, and it slightly beats `gzip` on the dump baseline while still trailing `zstd` on the dump. The selected lossy mode gives a controlled next step down in size without the catastrophic saturation behavior that the earlier intensity quantizer had.

## Byte Composition

| artifact            | structural bytes | spectrum metadata |        m/z stream |  intensity stream |     total |
| ------------------- | ---------------: | ----------------: | ----------------: | ----------------: | --------: |
| mzarc lossless      | 0.04 MiB (0.24%) |  0.15 MiB (1.00%) | 6.81 MiB (44.61%) | 8.27 MiB (54.15%) | 15.27 MiB |
| mzarc lossy q=16384 | 0.04 MiB (0.29%) |  0.15 MiB (1.20%) | 7.99 MiB (63.35%) | 4.44 MiB (35.15%) | 12.62 MiB |

The lossless byte breakdown shows whether the size regression is real payload or container overhead. On this run, the intensity stream is the largest component at 8.27 MiB, which keeps the diagnosis grounded in actual encoded bytes rather than guesswork.

## Performance Overview

![Throughput Overview](plots/performance_overview.png)

| artifact            | direction     | status   |  throughput | median time | timing source | source format | notes               |
| ------------------- | ------------- | -------- | ----------: | ----------: | ------------- | ------------- | ------------------- |
| gzip dump           | compression   | measured | 18.79 MiB/s |     1.6383s | python-timer  | input         | dump                |
| gzip dump           | decompression | measured | 149.7 MiB/s |    0.20665s | python-timer  | output        | gzip dump           |
| zstd dump           | compression   | measured | 165.9 MiB/s |    0.18578s | python-timer  | input         | dump                |
| zstd dump           | decompression | measured | 583.9 MiB/s |   0.052744s | python-timer  | output        | zstd dump           |
| bzip2 dump          | compression   | measured | 11.65 MiB/s |     2.6323s | python-timer  | input         | dump                |
| bzip2 dump          | decompression | measured |  21.2 MiB/s |     1.4522s | python-timer  | output        | bzip2 dump          |
| lz4 dump            | compression   | measured | 400.5 MiB/s |   0.076379s | python-timer  | input         | dump                |
| lz4 dump            | decompression | measured | 561.8 MiB/s |   0.054544s | python-timer  | output        | lz4 dump            |
| xz dump             | compression   | measured | 2.619 MiB/s |      11.75s | python-timer  | input         | dump                |
| xz dump             | decompression | measured | 62.33 MiB/s |    0.49175s | python-timer  | output        | xz dump             |
| gzip mzML           | compression   | measured | 49.34 MiB/s |     1.5222s | python-timer  | input         | mzML                |
| gzip mzML           | decompression | measured | 213.2 MiB/s |    0.35424s | python-timer  | output        | gzip mzML           |
| zstd mzML           | compression   | measured | 439.9 MiB/s |    0.17003s | python-timer  | input         | mzML                |
| zstd mzML           | decompression | measured |  1309 MiB/s |   0.057513s | python-timer  | output        | zstd mzML           |
| bzip2 mzML          | compression   | measured | 10.96 MiB/s |     6.8983s | python-timer  | input         | mzML                |
| bzip2 mzML          | decompression | measured | 30.99 MiB/s |     2.4379s | python-timer  | output        | bzip2 mzML          |
| lz4 mzML            | compression   | measured | 777.1 MiB/s |   0.096374s | python-timer  | input         | mzML                |
| lz4 mzML            | decompression | measured | 888.2 MiB/s |   0.085051s | python-timer  | output        | lz4 mzML            |
| xz mzML             | compression   | measured | 13.97 MiB/s |     5.2801s | python-timer  | input         | mzML                |
| xz mzML             | decompression | measured | 208.4 MiB/s |    0.36203s | python-timer  | output        | xz mzML             |
| mzarc lossless      | compression   | measured | 101.2 MiB/s |    0.30417s | zebrac        | input         | dump                |
| mzarc lossless      | decompression | measured | 146.3 MiB/s |    0.21036s | zebrac        | output        | mzarc lossless      |
| mzarc lossy q=16384 | compression   | measured | 76.75 MiB/s |    0.40102s | zebrac        | input         | dump                |
| mzarc lossy q=16384 | decompression | measured | 135.1 MiB/s |    0.22785s | zebrac        | output        | mzarc lossy q=16384 |
| mzMLb               | compression   | measured | 3.385 MiB/s |     21.657s | python-timer  | input         | mzML                |
| mzMLb               | decompression | measured | 6.354 MiB/s |     4.8362s | python-timer  | output        | mzMLb               |
| MS-Numpress in mzML | compression   | measured | 3.335 MiB/s |     22.598s | python-timer  | input         | mzML                |
| MS-Numpress in mzML | decompression | measured | 4.909 MiB/s |     6.2725s | python-timer  | output        | MS-Numpress in mzML |
| MScompress          | compression   | measured | 104.8 MiB/s |    0.71574s | python-timer  | input         | mzML                |
| MScompress          | decompression | measured | 4.258 MiB/s |     7.1133s | python-timer  | output        | MScompress          |
| MScompress threaded | compression   | measured | 597.1 MiB/s |    0.12649s | python-timer  | input         | mzML                |
| MScompress threaded | decompression | measured | 5.981 MiB/s |     5.1319s | python-timer  | output        | MScompress threaded |

## Memory and CPU Metrics

The following metrics were collected by zebrac, which runs each command repeatedly over a fixed duration window using Linux perf counters. Reported values are medians across all samples in the window. Peak RSS is the highest resident set size observed for that process. Instructions and cache misses are per-run hardware counter readings.

![Peak RSS Comparison](plots/memory_footprint.png)

| operation                   | wall time (median) | peak RSS (median) | peak RSS (min) | instructions (median) | cache misses (median) | samples |
| --------------------------- | -----------------: | ----------------: | -------------: | --------------------: | --------------------: | ------: |
| dump -> mzarc lossless      |            0.3042s |          89.5 MiB |       89.4 MiB |              1.36e+09 |              5.52e+05 |       4 |
| mzarc lossless -> dump      |            0.2104s |          79.4 MiB |       79.2 MiB |              9.25e+08 |              2.16e+05 |       5 |
| dump -> mzarc lossy q=16384 |             0.401s |          79.6 MiB |       79.6 MiB |              2.31e+09 |              5.05e+05 |       3 |
| mzarc lossy q=16384 -> dump |            0.2278s |          76.7 MiB |       76.5 MiB |              1.17e+09 |              1.94e+05 |       5 |

## Zebrac Statistics

All internal operations are timed by zebrac, which runs each command repeatedly over a fixed duration window using Linux perf counters. Reported wall times are medians across all samples in the window. These replace the old Python-timer runs.

| operation                   | wall time (median) | wall time (stddev) |     min |     max | samples |
| --------------------------- | -----------------: | -----------------: | ------: | ------: | ------: |
| dump -> mzarc lossless      |            0.3042s |          0.003685s | 0.2968s |  0.305s |       4 |
| mzarc lossless -> dump      |            0.2104s |          0.004176s |  0.207s | 0.2166s |       5 |
| dump -> mzarc lossy q=16384 |             0.401s |          0.001189s | 0.4008s |  0.403s |       3 |
| mzarc lossy q=16384 -> dump |            0.2278s |          0.004058s | 0.2216s | 0.2313s |       5 |

## Timing Validation

Wall-time medians from zebrac and hyperfine are compared for each shared operation. Agreement is defined as |zebrac - hyperfine| / hyperfine ≤ 10%. Agreement confirms that zebrac's richer metrics (RSS, instructions, cache misses) are collected under conditions consistent with an independent wall-time reference.

![Zebrac vs Hyperfine Wall Time](plots/timing_validation.png)

| operation                   | zebrac median | hyperfine median | diff % | agrees | zebrac samples | hyperfine runs |
| --------------------------- | ------------: | ---------------: | -----: | ------ | -------------: | -------------: |
| dump -> mzarc lossless      |       0.3042s |          0.3013s |  0.95% | yes    |              4 |              5 |
| mzarc lossless -> dump      |       0.2104s |          0.2049s |  2.67% | yes    |              5 |              5 |
| dump -> mzarc lossy q=16384 |       0.4010s |          0.4026s |  0.38% | yes    |              3 |              5 |
| mzarc lossy q=16384 -> dump |       0.2278s |          0.2272s |  0.26% | yes    |              5 |              5 |

## External Baselines

| baseline            | status      |      size | encode                      | decode                      | notes                                                                                        |
| ------------------- | ----------- | --------: | --------------------------- | --------------------------- | -------------------------------------------------------------------------------------------- |
| mzMLb               | benchmarked | 16.25 MiB | mzML -> mzMLb               | mzMLb -> dump               | Converted with psims MzMLToMzMLb using HDF5 compression `blosc:zstd`.                        |
| MS-Numpress in mzML | benchmarked | 66.67 MiB | mzML -> MS-Numpress in mzML | MS-Numpress in mzML -> dump | Converted with psims and per-array MS-Numpress compression settings.                         |
| MScompress          | benchmarked | 21.63 MiB | mzML -> MScompress          | MScompress -> dump          | Converted with the MScompress Python package using 1 thread for single-thread comparability. |
| MScompress threaded | benchmarked | 21.53 MiB | mzML -> MScompress threaded | MScompress threaded -> dump | Converted with the MScompress Python package using its default thread setting.               |

## Data Fidelity

![Data Fidelity Overview](plots/fidelity_overview.png)

| artifact            | status   | global order |    max abs m/z | max ppm m/z | mean abs intensity | max abs intensity | p95 rel intensity | notes |
| ------------------- | -------- | -----------: | -------------: | ----------: | -----------------: | ----------------: | ----------------: | ----- |
| lz4 dump            | measured |         true |              0 |           0 |                  0 |                 0 |            0.000% |       |
| gzip dump           | measured |         true |              0 |           0 |                  0 |                 0 |            0.000% |       |
| zstd dump           | measured |         true |              0 |           0 |                  0 |                 0 |            0.000% |       |
| bzip2 dump          | measured |         true |              0 |           0 |                  0 |                 0 |            0.000% |       |
| xz dump             | measured |         true |              0 |           0 |                  0 |                 0 |            0.000% |       |
| mzarc lossless      | measured |         true |              0 |           0 |                  0 |                 0 |            0.000% |       |
| mzarc lossy q=16384 | measured |         true | 1.00000011e-06 |  0.00746008 |         173.700907 |            537856 |            0.055% |       |
| mzMLb               | measured |         true |              0 |           0 |                  0 |                 0 |            0.000% |       |
| MS-Numpress in mzML | measured |         true | 2.37443714e-07 |  0.00140354 |         41.5276661 |            191744 |            0.012% |       |
| MScompress          | measured |         true |              0 |           0 |                  0 |                 0 |            0.000% |       |
| MScompress threaded | measured |         true |              0 |           0 |                  0 |                 0 |            0.000% |       |

## Fidelity Summary

| artifact            | global order | ms1 order | ms2 order |    mean abs mz |     max abs mz | max ppm mz | mean abs intensity | rmse intensity | p95 rel intensity | p99 rel intensity | mean abs log1p intensity |
| ------------------- | -----------: | --------: | --------: | -------------: | -------------: | ---------: | -----------------: | -------------: | ----------------: | ----------------: | -----------------------: |
| gzip dump           |         true |      true |      true |              0 |              0 |          0 |                  0 |              0 |            0.000% |            0.000% |                        0 |
| zstd dump           |         true |      true |      true |              0 |              0 |          0 |                  0 |              0 |            0.000% |            0.000% |                        0 |
| bzip2 dump          |         true |      true |      true |              0 |              0 |          0 |                  0 |              0 |            0.000% |            0.000% |                        0 |
| lz4 dump            |         true |      true |      true |              0 |              0 |          0 |                  0 |              0 |            0.000% |            0.000% |                        0 |
| xz dump             |         true |      true |      true |              0 |              0 |          0 |                  0 |              0 |            0.000% |            0.000% |                        0 |
| mzMLb               |         true |      true |      true |              0 |              0 |          0 |                  0 |              0 |            0.000% |            0.000% |                        0 |
| MS-Numpress in mzML |         true |      true |      true | 4.70575714e-08 | 2.37443714e-07 | 0.00140354 |         41.5276661 |     690.149717 |            0.012% |            0.014% |           5.85200344e-05 |
| MScompress          |         true |      true |      true |              0 |              0 |          0 |                  0 |              0 |            0.000% |            0.000% |                        0 |
| MScompress threaded |         true |      true |      true |              0 |              0 |          0 |                  0 |              0 |            0.000% |            0.000% |                        0 |
| mzarc lossless      |         true |      true |      true |              0 |              0 |          0 |                  0 |              0 |            0.000% |            0.000% |                        0 |
| mzarc lossy q=16384 |         true |      true |      true | 5.00068204e-07 | 1.00000011e-06 | 0.00746008 |         173.700907 |     2607.53484 |            0.055% |            0.059% |           0.000284144487 |

On the current run, `lz4 dump`, `gzip dump`, `zstd dump`, `bzip2 dump`, `xz dump`, `mzarc lossless`, `mzMLb`, `MScompress`, and `MScompress threaded` round-trip exactly. `mzarc lossless` round-trips exactly, including m/z values and original scan order. `mzarc lossy` preserves original scan order while keeping m/z and intensity error within the current quantization bounds.

## Lossy Sweep

![Lossy Tradeoff](plots/lossy_tradeoff.png)

|     q |    bytes |      size | p95 rel intensity err | p99 rel intensity err | mean rel intensity err |
| ----: | -------: | --------: | --------------------: | --------------------: | ---------------------: |
|   256 | 10720131 | 10.22 MiB |                3.499% |                3.813% |                 1.820% |
|  1024 | 11899075 | 11.35 MiB |                0.874% |                0.950% |                 0.455% |
|  4096 | 12566184 | 11.98 MiB |                0.218% |                0.238% |                 0.114% |
| 16384 | 13233307 | 12.62 MiB |                0.055% |                0.059% |                 0.028% |

The selected `q` stays user-controlled. Higher `q` means more preserved log-intensity precision and usually a larger file; lower `q` buys size at the cost of broader relative error tails.

![Relative Intensity Error Quantiles](plots/intensity_relative_quantiles.png)

## Search Impact

| artifact            | status       | peptide ID difference | peptide ID change | FDR change | notes                                                                                                                                                                       |
| ------------------- | ------------ | --------------------: | ----------------: | ---------: | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| lz4 dump            | not-measured |                   n/a |               n/a |        n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| lz4 mzML            | not-measured |                   n/a |               n/a |        n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra.                                                                  |
| gzip dump           | not-measured |                   n/a |               n/a |        n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| gzip mzML           | not-measured |                   n/a |               n/a |        n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra.                                                                  |
| zstd dump           | not-measured |                   n/a |               n/a |        n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| zstd mzML           | not-measured |                   n/a |               n/a |        n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra.                                                                  |
| bzip2 dump          | not-measured |                   n/a |               n/a |        n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| bzip2 mzML          | not-measured |                   n/a |               n/a |        n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra.                                                                  |
| xz dump             | not-measured |                   n/a |               n/a |        n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| xz mzML             | not-measured |                   n/a |               n/a |        n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra.                                                                  |
| mzarc lossless      | not-measured |                   n/a |               n/a |        n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| mzarc lossy q=16384 | not-measured |                   n/a |               n/a |        n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra.                                                                  |
| mzMLb               | not-measured |                   n/a |               n/a |        n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| MS-Numpress in mzML | not-measured |                   n/a |               n/a |        n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra.                                                                  |
| MScompress          | not-measured |                   n/a |               n/a |        n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| MScompress threaded | not-measured |                   n/a |               n/a |        n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |

Search-impact metrics are not measured by the current benchmark pipeline yet. They remain listed here so the report does not imply numerical equivalence where no downstream search experiment has actually been run.

## How The Error Numbers Are Computed

The reported means are computed over every matched peak after round-trip decode. They are not inferred from min and max.

- Mean absolute error: average absolute per-peak error.
- RMSE: square root of the average squared per-peak error.
- Relative intensity error: absolute error divided by the original intensity, evaluated only on strictly positive peaks.
- log1p intensity error: absolute error after applying `log1p`, which keeps the metric useful across large dynamic range.

## Future Comparison Candidates

All named comparison candidates are wired into the current benchmark run in some form.
