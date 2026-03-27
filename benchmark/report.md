# Benchmark Report: 15HCD_1

- mzML input: data/PXD075509/15HCD_1.mzML
- private workdir: data/PXD075509/benchmarks/15HCD_1
- public output dir: benchmark
- repeats: 10
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
| mzv1 lossless | 24172914 | 23.05 MiB |  30.51% |  74.90% |
| mzv1 lossy    | 14481953 | 13.81 MiB |  18.28% |  44.87% |
| gzip dump     | 20780851 | 19.82 MiB |  26.23% |  64.39% |
| zstd dump     | 18720327 | 17.85 MiB |  23.63% |  58.01% |
| gzip mzML     | 25465391 | 24.29 MiB |  32.14% |  78.90% |
| zstd mzML     | 24770559 | 23.62 MiB |  31.27% |  76.75% |
| mzMLb         | 17038178 | 16.25 MiB |  21.51% |  52.79% |

Lossless `.mzv1` is already materially smaller than mzML on this sample, and it slightly beats `gzip` on the dump baseline while still trailing `zstd` on the dump. The selected lossy mode gives a controlled next step down in size without the catastrophic saturation behavior that the earlier intensity quantizer had.

## Byte Composition

| artifact           | structural bytes | spectrum metadata |         m/z stream |   intensity stream |     total |
| ------------------ | ---------------: | ----------------: | -----------------: | -----------------: | --------: |
| mzv1 lossless      | 0.04 MiB (0.16%) |  0.17 MiB (0.74%) | 12.66 MiB (54.94%) | 10.18 MiB (44.16%) | 23.05 MiB |
| mzv1 lossy q=16384 | 0.04 MiB (0.27%) |  0.17 MiB (1.24%) |  9.17 MiB (66.37%) |  4.44 MiB (32.12%) | 13.81 MiB |

The lossless byte breakdown shows whether the size regression is real payload or container overhead. On this run, the m/z stream is the largest component at 12.66 MiB, which keeps the diagnosis grounded in actual encoded bytes rather than guesswork.

## Performance Overview

![Throughput Overview](plots/performance_overview.png)

| artifact           | direction     | status   |  throughput | mean time | throughput basis | source format      | notes |
| ------------------ | ------------- | -------- | ----------: | --------: | ---------------- | ------------------ | ----- |
| gzip dump          | compression   | measured | 18.73 MiB/s |    1.643s | input            | dump               |       |
| gzip dump          | decompression | measured | 150.6 MiB/s |  0.20431s | output           | gzip dump          |       |
| zstd dump          | compression   | measured | 167.7 MiB/s |  0.18354s | input            | dump               |       |
| zstd dump          | decompression | measured | 566.5 MiB/s |  0.05433s | output           | zstd dump          |       |
| gzip mzML          | compression   | measured | 48.98 MiB/s |   1.5424s | input            | mzML               |       |
| gzip mzML          | decompression | measured | 212.9 MiB/s |  0.35479s | output           | gzip mzML          |       |
| zstd mzML          | compression   | measured | 434.9 MiB/s |  0.17372s | input            | mzML               |       |
| zstd mzML          | decompression | measured | 966.9 MiB/s |  0.07814s | output           | zstd mzML          |       |
| mzv1 lossless      | compression   | measured | 142.9 MiB/s |  0.21533s | input            | dump               |       |
| mzv1 lossless      | decompression | measured | 189.3 MiB/s |   0.1626s | output           | mzv1 lossless      |       |
| mzv1 lossy q=16384 | compression   | measured | 126.1 MiB/s |  0.24409s | input            | dump               |       |
| mzv1 lossy q=16384 | decompression | measured |   163 MiB/s |  0.18879s | output           | mzv1 lossy q=16384 |       |
| mzMLb              | compression   | measured | 3.413 MiB/s |   22.133s | input            | mzML               |       |
| mzMLb              | decompression | measured | 6.328 MiB/s |   4.8635s | output           | mzMLb              |       |

## Timing Variability

![Timing Variability Across Runs](plots/timing_intervals.png)

The chart above uses all 10 runs per operation. Gray dots are individual runs. Black points show the mean with a two-sided 95% confidence interval for the mean.

| operation                  |          mean ± sd |   median |       95% CI of mean |      min |      max |   throughput | basis  |
| -------------------------- | -----------------: | -------: | -------------------: | -------: | -------: | -----------: | ------ |
| mzML -> dump               |  4.7050s ± 0.0391s |  4.6968s |   [4.6770s, 4.7330s] |  4.6644s |  4.7814s |  16.06 MiB/s | input  |
| dump -> gzip dump          |  1.6430s ± 0.0066s |  1.6415s |   [1.6382s, 1.6477s] |  1.6332s |  1.6579s |  18.73 MiB/s | input  |
| gzip dump -> dump          |  0.2043s ± 0.0019s |  0.2034s |   [0.2030s, 0.2057s] |  0.2032s |  0.2083s | 150.64 MiB/s | output |
| dump -> zstd dump          |  0.1835s ± 0.0028s |  0.1832s |   [0.1815s, 0.1856s] |  0.1795s |  0.1891s | 167.70 MiB/s | input  |
| zstd dump -> dump          |  0.0543s ± 0.0027s |  0.0531s |   [0.0524s, 0.0562s] |  0.0527s |  0.0595s | 566.51 MiB/s | output |
| mzML -> gzip mzML          |  1.5424s ± 0.0306s |  1.5317s |   [1.5205s, 1.5643s] |  1.5222s |  1.6208s |  48.98 MiB/s | input  |
| gzip mzML -> mzML          |  0.3548s ± 0.0027s |  0.3537s |   [0.3529s, 0.3567s] |  0.3533s |  0.3618s | 212.94 MiB/s | output |
| mzML -> zstd mzML          |  0.1737s ± 0.0042s |  0.1734s |   [0.1707s, 0.1767s] |  0.1670s |  0.1804s | 434.89 MiB/s | input  |
| zstd mzML -> mzML          |  0.0781s ± 0.0651s |  0.0576s |   [0.0316s, 0.1247s] |  0.0573s |  0.2634s | 966.87 MiB/s | output |
| dump -> mzv1 lossless      |  0.2153s ± 0.0040s |  0.2142s |   [0.2125s, 0.2182s] |  0.2112s |  0.2231s | 142.94 MiB/s | input  |
| mzv1 lossless -> dump      |  0.1626s ± 0.0022s |  0.1620s |   [0.1610s, 0.1642s] |  0.1607s |  0.1674s | 189.29 MiB/s | output |
| dump -> mzv1 lossy q=16384 |  0.2441s ± 0.0046s |  0.2424s |   [0.2408s, 0.2474s] |  0.2406s |  0.2554s | 126.09 MiB/s | input  |
| mzv1 lossy q=16384 -> dump |  0.1888s ± 0.0042s |  0.1878s |   [0.1858s, 0.1918s] |  0.1850s |  0.1992s | 163.03 MiB/s | output |
| mzML -> mzMLb              | 22.1332s ± 0.8628s | 21.8978s | [21.5160s, 22.7504s] | 21.4528s | 24.5198s |   3.41 MiB/s | input  |
| mzMLb -> dump              |  4.8635s ± 0.0347s |  4.8687s |   [4.8386s, 4.8883s] |  4.7905s |  4.9153s |   6.33 MiB/s | output |

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
| mzv1 lossless      | measured |         true | 4.99994712e-10 | 3.90576e-06 |                  0 |                 0 |            0.000% |       |
| mzv1 lossy q=16384 | measured |         true | 1.00000011e-06 |  0.00746008 |         173.700907 |            537856 |            0.055% |       |
| mzMLb              | measured |         true |              0 |           0 |                  0 |                 0 |            0.000% |       |

## Fidelity Summary

| artifact           | global order | ms1 order | ms2 order |    mean abs mz |     max abs mz |  max ppm mz | mean abs intensity | rmse intensity | p95 rel intensity | p99 rel intensity | mean abs log1p intensity |
| ------------------ | -----------: | --------: | --------: | -------------: | -------------: | ----------: | -----------------: | -------------: | ----------------: | ----------------: | -----------------------: |
| gzip dump          |         true |      true |      true |              0 |              0 |           0 |                  0 |              0 |            0.000% |            0.000% |                        0 |
| zstd dump          |         true |      true |      true |              0 |              0 |           0 |                  0 |              0 |            0.000% |            0.000% |                        0 |
| mzv1 lossless      |         true |      true |      true | 2.50042291e-10 | 4.99994712e-10 | 3.90576e-06 |                  0 |              0 |            0.000% |            0.000% |                        0 |
| mzv1 lossy q=16384 |         true |      true |      true | 5.00068204e-07 | 1.00000011e-06 |  0.00746008 |         173.700907 |     2607.53484 |            0.055% |            0.059% |           0.000284144487 |
| mzMLb              |         true |      true |      true |              0 |              0 |           0 |                  0 |              0 |            0.000% |            0.000% |                        0 |

On the current run, `gzip dump`, `zstd dump`, and `mzMLb` round-trip exactly. `mzv1 lossless` still carries measurable round-trip error and needs more work before it can be treated as exact. `mzv1 lossy` preserves original scan order while keeping m/z and intensity error within the current quantization bounds.

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
| mzv1 lossless      | not-measured |                   n/a |               n/a |        n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra.                                                                  |
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
