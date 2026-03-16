# Benchmark Report: 15HCD_1

- mzML input: data/PXD075509/15HCD_1.mzML
- private workdir: data/PXD075509/benchmarks/15HCD_1
- public output dir: benchmark
- repeats: 10
- selected lossy intensity quantization: q=4096

## Story

The flat dump is smaller than mzML because it strips almost all interchange overhead: XML structure, controlled-vocabulary markup, base64 wrapping, and general-purpose metadata that this prototype does not need for codec bring-up. That makes the dump a useful internal floor, not a format competitor by itself.

This benchmark focuses on two things that matter right now: whether the current `.mzv1` path buys meaningful size reduction over the interchange format, and whether encode and decode stay fast and stable across repeated runs.

External formats that actually ran end-to-end in this benchmark: mzMLb, MScompress, MScompress threaded.

## Dataset

- spectra: 9001
- total peaks: 2668458
- ms1 spectra: 917
- ms2 spectra: 8084

## Size Comparison

![Artifact Size Comparison](plots/size_comparison.png)

| artifact | bytes | size | vs mzML | vs dump |
| --- | ---: | ---: | ---: | ---: |
| mzML | 79221306 | 75.55 MiB | 100.00% | 245.47% |
| dump | 32273524 | 30.78 MiB | 40.74% | 100.00% |
| mzv1 lossless | 29245109 | 27.89 MiB | 36.92% | 90.62% |
| mzv1 lossy | 13814830 | 13.17 MiB | 17.44% | 42.81% |
| gzip dump | 20780851 | 19.82 MiB | 26.23% | 64.39% |
| zstd dump | 18720327 | 17.85 MiB | 23.63% | 58.01% |
| mzMLb | 17038178 | 16.25 MiB | 21.51% | 52.79% |
| MScompress | 22679622 | 21.63 MiB | 28.63% | 70.27% |
| MScompress threaded | 22579410 | 21.53 MiB | 28.50% | 69.96% |

Lossless `.mzv1` is already materially smaller than mzML on this sample, and it slightly beats `gzip` on the dump baseline while still trailing `zstd` on the dump. The selected lossy mode gives a controlled next step down in size without the catastrophic saturation behavior that the earlier intensity quantizer had.

## Byte Composition

| artifact | structural bytes | spectrum metadata | m/z stream | intensity stream | total |
| --- | ---: | ---: | ---: | ---: | ---: |
| mzv1 lossless | 0.04 MiB (0.13%) | 0.17 MiB (0.62%) | 17.50 MiB (62.75%) | 10.18 MiB (36.50%) | 27.89 MiB |
| mzv1 lossy q=4096 | 0.04 MiB (0.28%) | 0.17 MiB (1.30%) | 9.17 MiB (69.57%) | 3.80 MiB (28.84%) | 13.17 MiB |

The lossless byte breakdown shows whether the size regression is real payload or container overhead. On this run, the m/z stream is the largest component at 17.50 MiB, which keeps the diagnosis grounded in actual encoded bytes rather than guesswork.

## Performance Overview

![Throughput Overview](plots/performance_overview.png)

| artifact | direction | status | throughput | mean time | throughput basis | source format | notes |
| --- | --- | --- | ---: | ---: | --- | --- | --- |
| gzip dump | compression | measured | 18.7 MiB/s | 1.6457s | input | dump |  |
| gzip dump | decompression | measured | 153.1 MiB/s | 0.201s | output | gzip dump |  |
| zstd dump | compression | measured | 165.1 MiB/s | 0.18646s | input | dump |  |
| zstd dump | decompression | measured | 579.7 MiB/s | 0.05309s | output | zstd dump |  |
| mzv1 lossless | compression | measured | 123.7 MiB/s | 0.24874s | input | dump |  |
| mzv1 lossless | decompression | measured | 167.2 MiB/s | 0.18409s | output | mzv1 lossless |  |
| mzv1 lossy q=4096 | compression | measured | 128.9 MiB/s | 0.2387s | input | dump |  |
| mzv1 lossy q=4096 | decompression | measured | 167.9 MiB/s | 0.18331s | output | mzv1 lossy q=4096 |  |
| mzMLb | compression | measured | 3.363 MiB/s | 22.466s | input | mzML |  |
| mzMLb | decompression | measured | 6.211 MiB/s | 4.9553s | output | mzMLb |  |
| MScompress | compression | measured | 105.6 MiB/s | 0.71551s | input | mzML |  |
| MScompress | decompression | measured | 4.252 MiB/s | 7.2393s | output | MScompress |  |
| MScompress threaded | compression | measured | 587.1 MiB/s | 0.12868s | input | mzML |  |
| MScompress threaded | decompression | measured | 6.25 MiB/s | 4.9249s | output | MScompress threaded |  |

## Timing Variability

![Timing Variability Across Runs](plots/timing_intervals.png)

The chart above uses all 10 runs per operation. Gray dots are individual runs. Black points show the mean with a two-sided 95% confidence interval for the mean.

| operation | mean ± sd | median | 95% CI of mean | min | max | throughput | basis |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| mzML -> dump | 4.5715s ± 0.0247s | 4.5742s | [4.5538s, 4.5892s] | 4.5380s | 4.6082s | 16.53 MiB/s | input |
| dump -> gzip dump | 1.6457s ± 0.0034s | 1.6450s | [1.6432s, 1.6481s] | 1.6403s | 1.6507s | 18.70 MiB/s | input |
| gzip dump -> dump | 0.2010s ± 0.0004s | 0.2010s | [0.2007s, 0.2013s] | 0.2005s | 0.2017s | 153.13 MiB/s | output |
| dump -> zstd dump | 0.1865s ± 0.0045s | 0.1848s | [0.1832s, 0.1897s] | 0.1827s | 0.1963s | 165.07 MiB/s | input |
| zstd dump -> dump | 0.0531s ± 0.0003s | 0.0531s | [0.0529s, 0.0533s] | 0.0528s | 0.0537s | 579.75 MiB/s | output |
| dump -> mzv1 lossless | 0.2487s ± 0.0040s | 0.2482s | [0.2459s, 0.2516s] | 0.2424s | 0.2571s | 123.74 MiB/s | input |
| mzv1 lossless -> dump | 0.1841s ± 0.0028s | 0.1836s | [0.1821s, 0.1861s] | 0.1809s | 0.1902s | 167.19 MiB/s | output |
| dump -> mzv1 lossy q=4096 | 0.2387s ± 0.0023s | 0.2377s | [0.2370s, 0.2404s] | 0.2359s | 0.2425s | 128.94 MiB/s | input |
| mzv1 lossy q=4096 -> dump | 0.1833s ± 0.0012s | 0.1834s | [0.1824s, 0.1842s] | 0.1815s | 0.1854s | 167.90 MiB/s | output |
| mzML -> mzMLb | 22.4658s ± 0.6487s | 22.3030s | [22.0018s, 22.9298s] | 21.9795s | 24.0863s | 3.36 MiB/s | input |
| mzMLb -> dump | 4.9553s ± 0.1089s | 4.9463s | [4.8774s, 5.0332s] | 4.8072s | 5.1678s | 6.21 MiB/s | output |
| mzML -> MScompress | 0.7155s ± 0.0071s | 0.7158s | [0.7104s, 0.7206s] | 0.7058s | 0.7284s | 105.59 MiB/s | input |
| MScompress -> dump | 7.2393s ± 0.1330s | 7.2400s | [7.1442s, 7.3345s] | 6.9162s | 7.4213s | 4.25 MiB/s | output |
| mzML -> MScompress threaded | 0.1287s ± 0.0041s | 0.1277s | [0.1258s, 0.1316s] | 0.1241s | 0.1377s | 587.13 MiB/s | input |
| MScompress threaded -> dump | 4.9249s ± 0.0861s | 4.9025s | [4.8633s, 4.9864s] | 4.8360s | 5.0853s | 6.25 MiB/s | output |

## External Baselines

| baseline | status | size | encode | decode | notes |
| --- | --- | ---: | --- | --- | --- |
| mzMLb | benchmarked | 16.25 MiB | mzML -> mzMLb | mzMLb -> dump | Converted with psims MzMLToMzMLb using HDF5 compression `blosc:zstd`. |
| MScompress | benchmarked | 21.63 MiB | mzML -> MScompress | MScompress -> dump | Converted with the MScompress Python package using 1 thread for single-thread comparability. |
| MScompress threaded | benchmarked | 21.53 MiB | mzML -> MScompress threaded | MScompress threaded -> dump | Converted with the MScompress Python package using its default thread setting. |

## Data Fidelity

![Data Fidelity Overview](plots/fidelity_overview.png)

| artifact | status | global order | max abs m/z | mean abs intensity | max abs intensity | p95 rel intensity | notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| gzip dump | measured | true | 0 | 0 | 0 | 0.000% |  |
| zstd dump | measured | true | 0 | 0 | 0 | 0.000% |  |
| mzv1 lossless | measured | true | 0 | 0 | 0 | 0.000% |  |
| mzv1 lossy q=4096 | measured | true | 1.00000011e-06 | 695.252613 | 3177472 | 0.218% |  |
| mzMLb | measured | true | 0 | 0 | 0 | 0.000% |  |
| MScompress | measured | true | 0 | 0 | 0 | 0.000% |  |
| MScompress threaded | measured | true | 0 | 0 | 0 | 0.000% |  |

## Fidelity Summary

| artifact | global order | ms1 order | ms2 order | mean abs mz | max abs mz | mean abs intensity | rmse intensity | p95 rel intensity | p99 rel intensity | mean abs log1p intensity |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| gzip dump | true | true | true | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| zstd dump | true | true | true | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| mzv1 lossless | true | true | true | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| mzv1 lossy q=4096 | true | true | true | 5.00068204e-07 | 1.00000011e-06 | 695.252613 | 10758.6615 | 0.218% | 0.238% | 0.00113669413 |
| mzMLb | true | true | true | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| MScompress | true | true | true | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| MScompress threaded | true | true | true | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |

On the current run, `gzip dump`, `zstd dump`, `mzv1 lossless`, `mzMLb`, `MScompress`, and `MScompress threaded` round-trip exactly. `mzv1 lossless` round-trips exactly, including m/z values and original scan order. `mzv1 lossy` preserves original scan order while keeping m/z and intensity error within the current quantization bounds.

## Lossy Sweep

![Lossy Tradeoff](plots/lossy_tradeoff.png)

| q | bytes | size | p95 rel intensity err | p99 rel intensity err | mean rel intensity err |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 256 | 12480578 | 11.90 MiB | 3.499% | 3.813% | 1.820% |
| 1024 | 13147721 | 12.54 MiB | 0.874% | 0.950% | 0.455% |
| 4096 | 13814830 | 13.17 MiB | 0.218% | 0.238% | 0.114% |
| 16384 | 14481953 | 13.81 MiB | 0.055% | 0.059% | 0.028% |

The selected `q` stays user-controlled. Higher `q` means more preserved log-intensity precision and usually a larger file; lower `q` buys size at the cost of broader relative error tails.

![Relative Intensity Error Quantiles](plots/intensity_relative_quantiles.png)

## Search Impact

| artifact | status | peptide ID difference | peptide ID change | FDR change | notes |
| --- | --- | ---: | ---: | ---: | --- |
| gzip dump | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| zstd dump | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| mzv1 lossless | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| mzv1 lossy q=4096 | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. |
| mzMLb | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| MScompress | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| MScompress threaded | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |

Search-impact metrics are not measured by the current benchmark pipeline yet. They remain listed here so the report does not imply numerical equivalence where no downstream search experiment has actually been run.

## How The Error Numbers Are Computed

The reported means are computed over every matched peak after round-trip decode. They are not inferred from min and max.

- Mean absolute error: average absolute per-peak error.
- RMSE: square root of the average squared per-peak error.
- Relative intensity error: absolute error divided by the original intensity, evaluated only on strictly positive peaks.
- log1p intensity error: absolute error after applying `log1p`, which keeps the metric useful across large dynamic range.

## Future Comparison Candidates

These are the remaining or still-blocked comparison candidates after the current benchmark run.

| candidate | core idea | why test it next | source |
| --- | --- | --- | --- |
| MS-Numpress in mzML | Array-level compression inside the mzML ecosystem: linear prediction for smooth m/z arrays and logged or integer schemes for intensities. | It is the closest standard-adjacent baseline for testing whether mzarc beats established PSI-compatible spectrum array compression. | ms-numpress project |
