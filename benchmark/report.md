# Benchmark Report: 15HCD_1

- mzML input: data/PXD075509/15HCD_1.mzML
- private workdir: data/PXD075509/benchmarks/15HCD_1
- public output dir: benchmark
- repeats: 3
- selected lossy intensity quantization: q=16384

## Story

The flat dump is smaller than mzML because it strips almost all interchange overhead: XML structure, controlled-vocabulary markup, base64 wrapping, and general-purpose metadata that this prototype does not need for codec bring-up. That makes the dump a useful internal floor, not a format competitor by itself.

This benchmark focuses on two things that matter right now: whether the current `.mzv1` path buys meaningful size reduction over the interchange format, and whether encode and decode stay fast and stable across repeated runs.

External formats that actually ran end-to-end in this benchmark: mzMLb.

## Dataset

- spectra: 9001
- total peaks: 2668458
- ms1 spectra: 917
- ms2 spectra: 8084

## Size Comparison

![Artifact Size Comparison](plots/size_comparison.png)

| artifact      |    bytes |      size | vs mzML | vs dump |
| ------------- | -------: | --------: | ------: | ------: |
| mzML          | 79221306 | 75.55 MiB | 100.00% | 245.47% |
| dump          | 32273524 | 30.78 MiB |  40.74% | 100.00% |
| mzv1 lossless | 21233944 | 20.25 MiB |  26.80% |  65.79% |
| mzv1 lossy    | 14481953 | 13.81 MiB |  18.28% |  44.87% |
| gzip dump     | 20780851 | 19.82 MiB |  26.23% |  64.39% |
| zstd dump     | 18720327 | 17.85 MiB |  23.63% |  58.01% |
| gzip mzML     | 25465391 | 24.29 MiB |  32.14% |  78.90% |
| zstd mzML     | 24770559 | 23.62 MiB |  31.27% |  76.75% |
| mzMLb         | 17038178 | 16.25 MiB |  21.51% |  52.79% |

Lossless `.mzv1` is already materially smaller than mzML on this sample, and it slightly beats `gzip` on the dump baseline while still trailing `zstd` on the dump. The selected lossy mode gives a controlled next step down in size without the catastrophic saturation behavior that the earlier intensity quantizer had.

## Byte Composition

| artifact           | structural bytes | spectrum metadata |        m/z stream |   intensity stream |     total |
| ------------------ | ---------------: | ----------------: | ----------------: | -----------------: | --------: |
| mzv1 lossless      | 0.04 MiB (0.18%) |  0.17 MiB (0.85%) | 9.86 MiB (48.70%) | 10.18 MiB (50.27%) | 20.25 MiB |
| mzv1 lossy q=16384 | 0.04 MiB (0.27%) |  0.17 MiB (1.24%) | 9.17 MiB (66.37%) |  4.44 MiB (32.12%) | 13.81 MiB |

The lossless byte breakdown shows whether the size regression is real payload or container overhead. On this run, the intensity stream is the largest component at 10.18 MiB, which keeps the diagnosis grounded in actual encoded bytes rather than guesswork.

## Performance Overview

![Throughput Overview](plots/performance_overview.png)

| artifact           | direction     | status   |  throughput | mean time | throughput basis | source format      | notes |
| ------------------ | ------------- | -------- | ----------: | --------: | ---------------- | ------------------ | ----- |
| gzip dump          | compression   | measured | 18.61 MiB/s |    1.654s | input            | dump               |       |
| gzip dump          | decompression | measured | 149.6 MiB/s |  0.20579s | output           | gzip dump          |       |
| zstd dump          | compression   | measured | 164.8 MiB/s |  0.18673s | input            | dump               |       |
| zstd dump          | decompression | measured | 578.1 MiB/s | 0.053242s | output           | zstd dump          |       |
| gzip mzML          | compression   | measured | 49.27 MiB/s |   1.5333s | input            | mzML               |       |
| gzip mzML          | decompression | measured | 212.8 MiB/s |  0.35503s | output           | gzip mzML          |       |
| zstd mzML          | compression   | measured | 428.3 MiB/s |  0.17641s | input            | mzML               |       |
| zstd mzML          | decompression | measured |  1255 MiB/s | 0.060206s | output           | zstd mzML          |       |
| mzv1 lossless      | compression   | measured | 157.2 MiB/s |   0.1958s | input            | dump               |       |
| mzv1 lossless      | decompression | measured | 194.2 MiB/s |  0.15849s | output           | mzv1 lossless      |       |
| mzv1 lossy q=16384 | compression   | measured | 125.1 MiB/s |  0.24593s | input            | dump               |       |
| mzv1 lossy q=16384 | decompression | measured | 164.9 MiB/s |  0.18662s | output           | mzv1 lossy q=16384 |       |
| mzMLb              | compression   | measured | 3.377 MiB/s |   22.373s | input            | mzML               |       |
| mzMLb              | decompression | measured | 6.336 MiB/s |   4.8574s | output           | mzMLb              |       |

## Timing Variability

![Timing Variability Across Runs](plots/timing_intervals.png)

The chart above uses all 3 runs per operation. Gray dots are individual runs. Black points show the mean with a two-sided 95% confidence interval for the mean.

| operation                  |          mean ± sd |   median |       95% CI of mean |      min |      max |    throughput | basis  |
| -------------------------- | -----------------: | -------: | -------------------: | -------: | -------: | ------------: | ------ |
| mzML -> dump               |  4.6217s ± 0.0246s |  4.6263s |   [4.5607s, 4.6827s] |  4.5952s |  4.6436s |   16.35 MiB/s | input  |
| dump -> gzip dump          |  1.6540s ± 0.0080s |  1.6513s |   [1.6341s, 1.6740s] |  1.6478s |  1.6631s |   18.61 MiB/s | input  |
| gzip dump -> dump          |  0.2058s ± 0.0019s |  0.2049s |   [0.2011s, 0.2105s] |  0.2045s |  0.2080s |  149.56 MiB/s | output |
| dump -> zstd dump          |  0.1867s ± 0.0032s |  0.1862s |   [0.1788s, 0.1947s] |  0.1838s |  0.1902s |  164.83 MiB/s | input  |
| zstd dump -> dump          |  0.0532s ± 0.0007s |  0.0529s |   [0.0515s, 0.0550s] |  0.0527s |  0.0541s |  578.08 MiB/s | output |
| mzML -> gzip mzML          |  1.5333s ± 0.0078s |  1.5321s |   [1.5138s, 1.5527s] |  1.5261s |  1.5416s |   49.27 MiB/s | input  |
| gzip mzML -> mzML          |  0.3550s ± 0.0003s |  0.3549s |   [0.3544s, 0.3557s] |  0.3549s |  0.3553s |  212.80 MiB/s | output |
| mzML -> zstd mzML          |  0.1764s ± 0.0080s |  0.1719s |   [0.1566s, 0.1962s] |  0.1718s |  0.1856s |  428.26 MiB/s | input  |
| zstd mzML -> mzML          |  0.0602s ± 0.0038s |  0.0582s |   [0.0509s, 0.0695s] |  0.0579s |  0.0645s | 1254.87 MiB/s | output |
| dump -> mzv1 lossless      |  0.1958s ± 0.0022s |  0.1955s |   [0.1904s, 0.2012s] |  0.1938s |  0.1981s |  157.19 MiB/s | input  |
| mzv1 lossless -> dump      |  0.1585s ± 0.0055s |  0.1570s |   [0.1449s, 0.1720s] |  0.1540s |  0.1645s |  194.20 MiB/s | output |
| dump -> mzv1 lossy q=16384 |  0.2459s ± 0.0015s |  0.2462s |   [0.2422s, 0.2496s] |  0.2443s |  0.2473s |  125.15 MiB/s | input  |
| mzv1 lossy q=16384 -> dump |  0.1866s ± 0.0010s |  0.1867s |   [0.1841s, 0.1891s] |  0.1856s |  0.1876s |  164.93 MiB/s | output |
| mzML -> mzMLb              | 22.3730s ± 1.2475s | 21.7432s | [19.2739s, 25.4722s] | 21.5661s | 23.8099s |    3.38 MiB/s | input  |
| mzMLb -> dump              |  4.8574s ± 0.0651s |  4.8490s |   [4.6957s, 5.0191s] |  4.7969s |  4.9262s |    6.34 MiB/s | output |

## External Baselines

| baseline | status      |      size | encode        | decode        | notes                                                                 |
| -------- | ----------- | --------: | ------------- | ------------- | --------------------------------------------------------------------- |
| mzMLb    | benchmarked | 16.25 MiB | mzML -> mzMLb | mzMLb -> dump | Converted with psims MzMLToMzMLb using HDF5 compression `blosc:zstd`. |

## Data Fidelity

![Data Fidelity Overview](plots/fidelity_overview.png)

| artifact           | status   | global order |    max abs m/z | max ppm m/z | mean abs intensity | max abs intensity | p95 rel intensity | notes |
| ------------------ | -------- | -----------: | -------------: | ----------: | -----------------: | ----------------: | ----------------: | ----- |
| gzip dump          | measured |         true |              0 |           0 |                  0 |                 0 |            0.000% |       |
| zstd dump          | measured |         true |              0 |           0 |                  0 |                 0 |            0.000% |       |
| mzv1 lossless      | measured |         true |              0 |           0 |                  0 |                 0 |            0.000% |       |
| mzv1 lossy q=16384 | measured |         true | 1.00000011e-06 |  0.00746008 |         173.700907 |            537856 |            0.055% |       |
| mzMLb              | measured |         true |              0 |           0 |                  0 |                 0 |            0.000% |       |

## Fidelity Summary

| artifact           | global order | ms1 order | ms2 order |    mean abs mz |     max abs mz | max ppm mz | mean abs intensity | rmse intensity | p95 rel intensity | p99 rel intensity | mean abs log1p intensity |
| ------------------ | -----------: | --------: | --------: | -------------: | -------------: | ---------: | -----------------: | -------------: | ----------------: | ----------------: | -----------------------: |
| gzip dump          |         true |      true |      true |              0 |              0 |          0 |                  0 |              0 |            0.000% |            0.000% |                        0 |
| zstd dump          |         true |      true |      true |              0 |              0 |          0 |                  0 |              0 |            0.000% |            0.000% |                        0 |
| mzv1 lossless      |         true |      true |      true |              0 |              0 |          0 |                  0 |              0 |            0.000% |            0.000% |                        0 |
| mzv1 lossy q=16384 |         true |      true |      true | 5.00068204e-07 | 1.00000011e-06 | 0.00746008 |         173.700907 |     2607.53484 |            0.055% |            0.059% |           0.000284144487 |
| mzMLb              |         true |      true |      true |              0 |              0 |          0 |                  0 |              0 |            0.000% |            0.000% |                        0 |

On the current run, `gzip dump`, `zstd dump`, `mzv1 lossless`, and `mzMLb` round-trip exactly. `mzv1 lossless` round-trips exactly, including m/z values and original scan order. `mzv1 lossy` preserves original scan order while keeping m/z and intensity error within the current quantization bounds.

## Lossy Sweep

![Lossy Tradeoff](plots/lossy_tradeoff.png)

|     q |    bytes |      size | p95 rel intensity err | p99 rel intensity err | mean rel intensity err |
| ----: | -------: | --------: | --------------------: | --------------------: | ---------------------: |
|   256 | 12480578 | 11.90 MiB |                3.499% |                3.813% |                 1.820% |
|  1024 | 13147721 | 12.54 MiB |                0.874% |                0.950% |                 0.455% |
|  4096 | 13814830 | 13.17 MiB |                0.218% |                0.238% |                 0.114% |
| 16384 | 14481953 | 13.81 MiB |                0.055% |                0.059% |                 0.028% |

The selected `q` stays user-controlled. Higher `q` means more preserved log-intensity precision and usually a larger file; lower `q` buys size at the cost of broader relative error tails.

![Relative Intensity Error Quantiles](plots/intensity_relative_quantiles.png)

## Search Impact

| artifact           | status       | peptide ID difference | peptide ID change | FDR change | notes                                                                                                                                                                       |
| ------------------ | ------------ | --------------------: | ----------------: | ---------: | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| gzip dump          | not-measured |                   n/a |               n/a |        n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| gzip mzML          | not-measured |                   n/a |               n/a |        n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra.                                                                  |
| zstd dump          | not-measured |                   n/a |               n/a |        n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| zstd mzML          | not-measured |                   n/a |               n/a |        n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra.                                                                  |
| mzv1 lossless      | not-measured |                   n/a |               n/a |        n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| mzv1 lossy q=16384 | not-measured |                   n/a |               n/a |        n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra.                                                                  |
| mzMLb              | not-measured |                   n/a |               n/a |        n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |

Search-impact metrics are not measured by the current benchmark pipeline yet. They remain listed here so the report does not imply numerical equivalence where no downstream search experiment has actually been run.

## How The Error Numbers Are Computed

The reported means are computed over every matched peak after round-trip decode. They are not inferred from min and max.

- Mean absolute error: average absolute per-peak error.
- RMSE: square root of the average squared per-peak error.
- Relative intensity error: absolute error divided by the original intensity, evaluated only on strictly positive peaks.
- log1p intensity error: absolute error after applying `log1p`, which keeps the metric useful across large dynamic range.

## Future Comparison Candidates

These are the remaining or still-blocked comparison candidates after the current benchmark run.

| candidate           | core idea                                                                                                                                 | why test it next                                                                                                                    | source                 |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | ---------------------- |
| MScompress          | Multi-threaded mzML to MSZ compressor with random-access decode support and configurable lossless or lossy encoding.                      | It is a modern practical systems baseline with explicit focus on speed, threading, and usable compressed-file access.               | chrisagrams/mscompress |
| MS-Numpress in mzML | Array-level compression inside the mzML ecosystem: linear prediction for smooth m/z arrays and logged or integer schemes for intensities. | It is the closest standard-adjacent baseline for testing whether mzarc beats established PSI-compatible spectrum array compression. | ms-numpress project    |
