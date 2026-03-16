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
| mzv1 lossless | 20467802 | 19.52 MiB | 25.84% | 63.42% |
| mzv1 lossy | 13778826 | 13.14 MiB | 17.39% | 42.69% |
| gzip dump | 20780851 | 19.82 MiB | 26.23% | 64.39% |
| zstd dump | 18720327 | 17.85 MiB | 23.63% | 58.01% |
| mzMLb | 17038178 | 16.25 MiB | 21.51% | 52.79% |
| MScompress | 22679622 | 21.63 MiB | 28.63% | 70.27% |
| MScompress threaded | 22579410 | 21.53 MiB | 28.50% | 69.96% |

Lossless `.mzv1` is already materially smaller than mzML on this sample, and it slightly beats `gzip` on the dump baseline while still trailing `zstd` on the dump. The selected lossy mode gives a controlled next step down in size without the catastrophic saturation behavior that the earlier intensity quantizer had.

## Performance Overview

![Throughput Overview](plots/performance_overview.png)

| artifact | direction | status | throughput | mean time | throughput basis | source format | notes |
| --- | --- | --- | ---: | ---: | --- | --- | --- |
| gzip dump | compression | measured | 18.69 MiB/s | 1.6467s | input | dump |  |
| gzip dump | decompression | measured | 152.6 MiB/s | 0.20166s | output | gzip dump |  |
| zstd dump | compression | measured | 166.3 MiB/s | 0.18512s | input | dump |  |
| zstd dump | decompression | measured | 574 MiB/s | 0.05362s | output | zstd dump |  |
| mzv1 lossless | compression | measured | 58.4 MiB/s | 0.527s | input | dump |  |
| mzv1 lossless | decompression | measured | 68.81 MiB/s | 0.44731s | output | mzv1 lossless |  |
| mzv1 lossy q=4096 | compression | measured | 32.93 MiB/s | 0.93467s | input | dump |  |
| mzv1 lossy q=4096 | decompression | measured | 53.43 MiB/s | 0.57605s | output | mzv1 lossy q=4096 |  |
| mzMLb | compression | measured | 3.387 MiB/s | 22.309s | input | mzML |  |
| mzMLb | decompression | measured | 6.311 MiB/s | 4.877s | output | mzMLb |  |
| MScompress | compression | measured | 105.5 MiB/s | 0.71622s | input | mzML |  |
| MScompress | decompression | measured | 4.295 MiB/s | 7.1654s | output | MScompress |  |
| MScompress threaded | compression | measured | 599.3 MiB/s | 0.12606s | input | mzML |  |
| MScompress threaded | decompression | measured | 6.278 MiB/s | 4.9028s | output | MScompress threaded |  |

## Timing Variability

![Timing Variability Across Runs](plots/timing_intervals.png)

The chart above uses all 10 runs per operation. Gray dots are individual runs. Black points show the mean with a two-sided 95% confidence interval for the mean.

| operation | mean ± sd | median | 95% CI of mean | min | max | throughput | basis |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| mzML -> dump | 4.5946s ± 0.0358s | 4.5902s | [4.5689s, 4.6202s] | 4.5477s | 4.6603s | 16.44 MiB/s | input |
| dump -> gzip dump | 1.6467s ± 0.0040s | 1.6455s | [1.6439s, 1.6496s] | 1.6427s | 1.6556s | 18.69 MiB/s | input |
| gzip dump -> dump | 0.2017s ± 0.0010s | 0.2016s | [0.2010s, 0.2023s] | 0.2007s | 0.2042s | 152.62 MiB/s | output |
| dump -> zstd dump | 0.1851s ± 0.0038s | 0.1837s | [0.1824s, 0.1879s] | 0.1813s | 0.1928s | 166.26 MiB/s | input |
| zstd dump -> dump | 0.0536s ± 0.0005s | 0.0536s | [0.0533s, 0.0540s] | 0.0530s | 0.0548s | 574.01 MiB/s | output |
| dump -> mzv1 lossless | 0.5270s ± 0.0576s | 0.5102s | [0.4858s, 0.5682s] | 0.5029s | 0.6907s | 58.40 MiB/s | input |
| mzv1 lossless -> dump | 0.4473s ± 0.0042s | 0.4479s | [0.4443s, 0.4503s] | 0.4409s | 0.4539s | 68.81 MiB/s | output |
| dump -> mzv1 lossy q=4096 | 0.9347s ± 0.0083s | 0.9347s | [0.9288s, 0.9406s] | 0.9245s | 0.9472s | 32.93 MiB/s | input |
| mzv1 lossy q=4096 -> dump | 0.5760s ± 0.0072s | 0.5766s | [0.5709s, 0.5812s] | 0.5667s | 0.5856s | 53.43 MiB/s | output |
| mzML -> mzMLb | 22.3086s ± 0.5009s | 22.1453s | [21.9503s, 22.6669s] | 21.8202s | 23.6509s | 3.39 MiB/s | input |
| mzMLb -> dump | 4.8770s ± 0.0989s | 4.8511s | [4.8063s, 4.9477s] | 4.7773s | 5.1226s | 6.31 MiB/s | output |
| mzML -> MScompress | 0.7162s ± 0.0057s | 0.7161s | [0.7121s, 0.7203s] | 0.7072s | 0.7275s | 105.49 MiB/s | input |
| MScompress -> dump | 7.1654s ± 0.0997s | 7.1860s | [7.0941s, 7.2367s] | 6.9067s | 7.2788s | 4.30 MiB/s | output |
| mzML -> MScompress threaded | 0.1261s ± 0.0041s | 0.1255s | [0.1231s, 0.1290s] | 0.1206s | 0.1321s | 599.32 MiB/s | input |
| MScompress threaded -> dump | 4.9028s ± 0.0551s | 4.8939s | [4.8634s, 4.9422s] | 4.8368s | 4.9922s | 6.28 MiB/s | output |

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
| mzv1 lossless | measured | false | 1.00000011e-06 | 0 | 0 | 0.000% |  |
| mzv1 lossy q=4096 | measured | false | 1.00000011e-06 | 695.252613 | 3177472 | 0.218% |  |
| mzMLb | measured | true | 0 | 0 | 0 | 0.000% |  |
| MScompress | measured | true | 0 | 0 | 0 | 0.000% |  |
| MScompress threaded | measured | true | 0 | 0 | 0 | 0.000% |  |

## Fidelity Summary

| artifact | global order | ms1 order | ms2 order | mean abs mz | max abs mz | mean abs intensity | rmse intensity | p95 rel intensity | p99 rel intensity | mean abs log1p intensity |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| gzip dump | true | true | true | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| zstd dump | true | true | true | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| mzv1 lossless | false | true | true | 5.00068204e-07 | 1.00000011e-06 | 0 | 0 | 0.000% | 0.000% | 0 |
| mzv1 lossy q=4096 | false | true | true | 5.00068204e-07 | 1.00000011e-06 | 695.252613 | 10758.6615 | 0.218% | 0.238% | 0.00113669413 |
| mzMLb | true | true | true | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| MScompress | true | true | true | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| MScompress threaded | true | true | true | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |

On the current run, `gzip dump`, `zstd dump`, `mzMLb`, `MScompress`, and `MScompress threaded` round-trip exactly. `mzv1 lossless` is intensity-exact but still carries the expected fixed-point m/z quantization, and `mzv1 lossy` adds the configured intensity quantization on top of that. Global order is still not preserved for `mzv1` because MS1 and MS2 are written as separate streams.

## Lossy Sweep

![Lossy Tradeoff](plots/lossy_tradeoff.png)

| q | bytes | size | p95 rel intensity err | p99 rel intensity err | mean rel intensity err |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 256 | 12444574 | 11.87 MiB | 3.499% | 3.813% | 1.820% |
| 1024 | 13111717 | 12.50 MiB | 0.874% | 0.950% | 0.455% |
| 4096 | 13778826 | 13.14 MiB | 0.218% | 0.238% | 0.114% |
| 16384 | 14445949 | 13.78 MiB | 0.055% | 0.059% | 0.028% |

The selected `q` stays user-controlled. Higher `q` means more preserved log-intensity precision and usually a larger file; lower `q` buys size at the cost of broader relative error tails.

![Relative Intensity Error Quantiles](plots/intensity_relative_quantiles.png)

## Search Impact

| artifact | status | peptide ID difference | peptide ID change | FDR change | notes |
| --- | --- | ---: | ---: | ---: | --- |
| gzip dump | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| zstd dump | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| mzv1 lossless | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. |
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
