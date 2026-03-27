# Benchmark Report: 15HCD_1

- mzML input: data/PXD075509/15HCD_1.mzML
- private workdir: data/PXD075509/benchmarks/15HCD_1
- public output dir: benchmark
- repeats: 3
- selected lossy intensity quantization: q=16384

## Story

The flat dump is smaller than mzML because it strips almost all interchange overhead: XML structure, controlled-vocabulary markup, base64 wrapping, and general-purpose metadata that this prototype does not need for codec bring-up. That makes the dump a useful internal floor, not a format competitor by itself.

This benchmark focuses on two things that matter right now: whether the current `.mzv1` path buys meaningful size reduction over the interchange format, and whether encode and decode stay fast and stable across repeated runs.

External formats that actually ran end-to-end in this benchmark: mzMLb, MS-Numpress in mzML, MScompress.

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
| mzv1 lossless | 21233944 | 20.25 MiB | 26.80% | 65.79% |
| mzv1 lossy | 14481953 | 13.81 MiB | 18.28% | 44.87% |
| gzip dump | 20780851 | 19.82 MiB | 26.23% | 64.39% |
| zstd dump | 18720327 | 17.85 MiB | 23.63% | 58.01% |
| gzip mzML | 25465391 | 24.29 MiB | 32.14% | 78.90% |
| zstd mzML | 24770559 | 23.62 MiB | 31.27% | 76.75% |
| bzip2 dump | 19719837 | 18.81 MiB | 24.89% | 61.10% |
| lz4 dump | 26038757 | 24.83 MiB | 32.87% | 80.68% |
| xz dump | 16535444 | 15.77 MiB | 20.87% | 51.24% |
| bzip2 mzML | 24720971 | 23.58 MiB | 31.20% | 76.60% |
| lz4 mzML | 34826833 | 33.21 MiB | 43.96% | 107.91% |
| xz mzML | 24536980 | 23.40 MiB | 30.97% | 76.03% |
| mzMLb | 17038178 | 16.25 MiB | 21.51% | 52.79% |
| MS-Numpress in mzML | 69905308 | 66.67 MiB | 88.24% | 216.60% |
| MScompress | 22679622 | 21.63 MiB | 28.63% | 70.27% |

Lossless `.mzv1` is already materially smaller than mzML on this sample, and it slightly beats `gzip` on the dump baseline while still trailing `zstd` on the dump. The selected lossy mode gives a controlled next step down in size without the catastrophic saturation behavior that the earlier intensity quantizer had.

## Byte Composition

| artifact | structural bytes | spectrum metadata | m/z stream | intensity stream | total |
| --- | ---: | ---: | ---: | ---: | ---: |
| mzv1 lossless | 0.04 MiB (0.18%) | 0.17 MiB (0.85%) | 9.86 MiB (48.70%) | 10.18 MiB (50.27%) | 20.25 MiB |
| mzv1 lossy q=16384 | 0.04 MiB (0.27%) | 0.17 MiB (1.24%) | 9.17 MiB (66.37%) | 4.44 MiB (32.12%) | 13.81 MiB |

The lossless byte breakdown shows whether the size regression is real payload or container overhead. On this run, the intensity stream is the largest component at 10.18 MiB, which keeps the diagnosis grounded in actual encoded bytes rather than guesswork.

## Performance Overview

![Throughput Overview](plots/performance_overview.png)

| artifact | direction | status | throughput | mean time | throughput basis | source format | notes |
| --- | --- | --- | ---: | ---: | --- | --- | --- |
| gzip dump | compression | measured | 18.42 MiB/s | 1.6712s | input | dump |  |
| gzip dump | decompression | measured | 142.3 MiB/s | 0.21624s | output | gzip dump |  |
| zstd dump | compression | measured | 162.6 MiB/s | 0.18929s | input | dump |  |
| zstd dump | decompression | measured | 552.5 MiB/s | 0.055703s | output | zstd dump |  |
| bzip2 dump | compression | measured | 11.24 MiB/s | 2.7374s | input | dump |  |
| bzip2 dump | decompression | measured | 20.84 MiB/s | 1.4765s | output | bzip2 dump |  |
| lz4 dump | compression | measured | 380.2 MiB/s | 0.080964s | input | dump |  |
| lz4 dump | decompression | measured | 555 MiB/s | 0.055454s | output | lz4 dump |  |
| xz dump | compression | measured | 2.491 MiB/s | 12.356s | input | dump |  |
| xz dump | decompression | measured | 61.85 MiB/s | 0.49759s | output | xz dump |  |
| gzip mzML | compression | measured | 48.76 MiB/s | 1.5495s | input | mzML |  |
| gzip mzML | decompression | measured | 212 MiB/s | 0.35639s | output | gzip mzML |  |
| zstd mzML | compression | measured | 430.3 MiB/s | 0.17558s | input | mzML |  |
| zstd mzML | decompression | measured | 1288 MiB/s | 0.058655s | output | zstd mzML |  |
| bzip2 mzML | compression | measured | 10.65 MiB/s | 7.0939s | input | mzML |  |
| bzip2 mzML | decompression | measured | 30.67 MiB/s | 2.4634s | output | bzip2 mzML |  |
| lz4 mzML | compression | measured | 754 MiB/s | 0.1002s | input | mzML |  |
| lz4 mzML | decompression | measured | 832.2 MiB/s | 0.090782s | output | lz4 mzML |  |
| xz mzML | compression | measured | 13.33 MiB/s | 5.6697s | input | mzML |  |
| xz mzML | decompression | measured | 208.5 MiB/s | 0.36238s | output | xz mzML |  |
| mzv1 lossless | compression | measured | 158.2 MiB/s | 0.1945s | input | dump |  |
| mzv1 lossless | decompression | measured | 202.2 MiB/s | 0.15222s | output | mzv1 lossless |  |
| mzv1 lossy q=16384 | compression | measured | 123.5 MiB/s | 0.24913s | input | dump |  |
| mzv1 lossy q=16384 | decompression | measured | 161.8 MiB/s | 0.19024s | output | mzv1 lossy q=16384 |  |
| mzMLb | compression | measured | 3.352 MiB/s | 22.537s | input | mzML |  |
| mzMLb | decompression | measured | 6.259 MiB/s | 4.9178s | output | mzMLb |  |
| MS-Numpress in mzML | compression | measured | 3.223 MiB/s | 23.442s | input | mzML |  |
| MS-Numpress in mzML | decompression | measured | 4.87 MiB/s | 6.3201s | output | MS-Numpress in mzML |  |
| MScompress | compression | measured | 104.7 MiB/s | 0.72145s | input | mzML |  |
| MScompress | decompression | measured | 4.139 MiB/s | 7.437s | output | MScompress |  |

## Timing Variability

![Timing Variability Across Runs](plots/timing_intervals.png)

The chart above uses all 3 runs per operation. Gray dots are individual runs. Black points show the mean with a two-sided 95% confidence interval for the mean.

| operation | mean ± sd | median | 95% CI of mean | min | max | throughput | basis |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| mzML -> dump | 4.7007s ± 0.0282s | 4.7020s | [4.6307s, 4.7708s] | 4.6719s | 4.7282s | 16.07 MiB/s | input |
| dump -> gzip dump | 1.6712s ± 0.0295s | 1.6800s | [1.5979s, 1.7445s] | 1.6383s | 1.6953s | 18.42 MiB/s | input |
| gzip dump -> dump | 0.2162s ± 0.0100s | 0.2118s | [0.1915s, 0.2410s] | 0.2093s | 0.2276s | 142.34 MiB/s | output |
| dump -> zstd dump | 0.1893s ± 0.0050s | 0.1872s | [0.1769s, 0.2017s] | 0.1857s | 0.1950s | 162.60 MiB/s | input |
| zstd dump -> dump | 0.0557s ± 0.0040s | 0.0545s | [0.0458s, 0.0656s] | 0.0525s | 0.0601s | 552.54 MiB/s | output |
| dump -> bzip2 dump | 2.7374s ± 0.0483s | 2.7301s | [2.6175s, 2.8574s] | 2.6933s | 2.7890s | 11.24 MiB/s | input |
| bzip2 dump -> dump | 1.4765s ± 0.0074s | 1.4761s | [1.4581s, 1.4950s] | 1.4694s | 1.4842s | 20.84 MiB/s | output |
| dump -> lz4 dump | 0.0810s ± 0.0027s | 0.0798s | [0.0742s, 0.0878s] | 0.0790s | 0.0841s | 380.15 MiB/s | input |
| lz4 dump -> dump | 0.0555s ± 0.0004s | 0.0554s | [0.0545s, 0.0564s] | 0.0551s | 0.0559s | 555.03 MiB/s | output |
| dump -> xz dump | 12.3564s ± 0.0930s | 12.3436s | [12.1252s, 12.5875s] | 12.2704s | 12.4551s | 2.49 MiB/s | input |
| xz dump -> dump | 0.4976s ± 0.0029s | 0.4988s | [0.4904s, 0.5048s] | 0.4943s | 0.4997s | 61.85 MiB/s | output |
| mzML -> gzip mzML | 1.5495s ± 0.0097s | 1.5480s | [1.5254s, 1.5737s] | 1.5406s | 1.5599s | 48.76 MiB/s | input |
| gzip mzML -> mzML | 0.3564s ± 0.0027s | 0.3569s | [0.3496s, 0.3631s] | 0.3535s | 0.3588s | 211.99 MiB/s | output |
| mzML -> zstd mzML | 0.1756s ± 0.0017s | 0.1750s | [0.1714s, 0.1798s] | 0.1742s | 0.1775s | 430.29 MiB/s | input |
| zstd mzML -> mzML | 0.0587s ± 0.0001s | 0.0587s | [0.0583s, 0.0590s] | 0.0585s | 0.0587s | 1288.07 MiB/s | output |
| mzML -> bzip2 mzML | 7.0939s ± 0.0527s | 7.1062s | [6.9629s, 7.2249s] | 7.0361s | 7.1394s | 10.65 MiB/s | input |
| bzip2 mzML -> mzML | 2.4634s ± 0.0079s | 2.4666s | [2.4438s, 2.4830s] | 2.4544s | 2.4692s | 30.67 MiB/s | output |
| mzML -> lz4 mzML | 0.1002s ± 0.0011s | 0.1007s | [0.0974s, 0.1030s] | 0.0989s | 0.1010s | 753.98 MiB/s | input |
| lz4 mzML -> mzML | 0.0908s ± 0.0017s | 0.0909s | [0.0867s, 0.0949s] | 0.0891s | 0.0924s | 832.23 MiB/s | output |
| mzML -> xz mzML | 5.6697s ± 0.0693s | 5.6868s | [5.4976s, 5.8418s] | 5.5935s | 5.7288s | 13.33 MiB/s | input |
| xz mzML -> mzML | 0.3624s ± 0.0011s | 0.3619s | [0.3598s, 0.3650s] | 0.3616s | 0.3636s | 208.48 MiB/s | output |
| dump -> mzv1 lossless | 0.1945s ± 0.0012s | 0.1947s | [0.1915s, 0.1975s] | 0.1932s | 0.1956s | 158.24 MiB/s | input |
| mzv1 lossless -> dump | 0.1522s ± 0.0008s | 0.1518s | [0.1503s, 0.1541s] | 0.1518s | 0.1531s | 202.20 MiB/s | output |
| dump -> mzv1 lossy q=16384 | 0.2491s ± 0.0037s | 0.2511s | [0.2399s, 0.2584s] | 0.2449s | 0.2515s | 123.54 MiB/s | input |
| mzv1 lossy q=16384 -> dump | 0.1902s ± 0.0048s | 0.1884s | [0.1784s, 0.2021s] | 0.1866s | 0.1957s | 161.79 MiB/s | output |
| mzML -> mzMLb | 22.5373s ± 1.1615s | 21.9881s | [19.6516s, 25.4230s] | 21.7522s | 23.8716s | 3.35 MiB/s | input |
| mzMLb -> dump | 4.9178s ± 0.0623s | 4.9218s | [4.7630s, 5.0725s] | 4.8536s | 4.9780s | 6.26 MiB/s | output |
| mzML -> MS-Numpress in mzML | 23.4415s ± 0.2929s | 23.3342s | [22.7139s, 24.1692s] | 23.2174s | 23.7729s | 3.22 MiB/s | input |
| MS-Numpress in mzML -> dump | 6.3201s ± 0.0358s | 6.3222s | [6.2311s, 6.4091s] | 6.2832s | 6.3548s | 4.87 MiB/s | output |
| mzML -> MScompress | 0.7215s ± 0.0080s | 0.7172s | [0.7017s, 0.7412s] | 0.7165s | 0.7306s | 104.72 MiB/s | input |
| MScompress -> dump | 7.4370s ± 0.1930s | 7.4332s | [6.9575s, 7.9166s] | 7.2460s | 7.6320s | 4.14 MiB/s | output |

## External Baselines

| baseline | status | size | encode | decode | notes |
| --- | --- | ---: | --- | --- | --- |
| mzMLb | benchmarked | 16.25 MiB | mzML -> mzMLb | mzMLb -> dump | Converted with psims MzMLToMzMLb using HDF5 compression `blosc:zstd`. |
| MS-Numpress in mzML | benchmarked | 66.67 MiB | mzML -> MS-Numpress in mzML | MS-Numpress in mzML -> dump | Converted with psims and per-array MS-Numpress compression settings. |
| MScompress | benchmarked | 21.63 MiB | mzML -> MScompress | MScompress -> dump | Converted with the MScompress Python package using 1 thread for single-thread comparability. |

## Data Fidelity

![Data Fidelity Overview](plots/fidelity_overview.png)

| artifact | status | global order | max abs m/z | max ppm m/z | mean abs intensity | max abs intensity | p95 rel intensity | notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| lz4 dump | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| gzip dump | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| zstd dump | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| bzip2 dump | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| xz dump | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| mzv1 lossless | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| mzv1 lossy q=16384 | measured | true | 1.00000011e-06 | 0.00746008 | 173.700907 | 537856 | 0.055% |  |
| mzMLb | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| MS-Numpress in mzML | measured | true | 2.37443714e-07 | 0.00140354 | 41.5276661 | 191744 | 0.012% |  |
| MScompress | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |

## Fidelity Summary

| artifact | global order | ms1 order | ms2 order | mean abs mz | max abs mz | max ppm mz | mean abs intensity | rmse intensity | p95 rel intensity | p99 rel intensity | mean abs log1p intensity |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| gzip dump | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| zstd dump | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| bzip2 dump | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| lz4 dump | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| xz dump | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| mzv1 lossless | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| mzv1 lossy q=16384 | true | true | true | 5.00068204e-07 | 1.00000011e-06 | 0.00746008 | 173.700907 | 2607.53484 | 0.055% | 0.059% | 0.000284144487 |
| mzMLb | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| MS-Numpress in mzML | true | true | true | 4.70575714e-08 | 2.37443714e-07 | 0.00140354 | 41.5276661 | 690.149717 | 0.012% | 0.014% | 5.85200344e-05 |
| MScompress | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |

On the current run, `lz4 dump`, `gzip dump`, `zstd dump`, `bzip2 dump`, `xz dump`, `mzv1 lossless`, `mzMLb`, and `MScompress` round-trip exactly. `mzv1 lossless` round-trips exactly, including m/z values and original scan order. `mzv1 lossy` preserves original scan order while keeping m/z and intensity error within the current quantization bounds.

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
| lz4 dump | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| lz4 mzML | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. |
| gzip dump | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| gzip mzML | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. |
| zstd dump | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| zstd mzML | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. |
| bzip2 dump | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| bzip2 mzML | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. |
| xz dump | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| xz mzML | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. |
| mzv1 lossless | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| mzv1 lossy q=16384 | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. |
| mzMLb | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| MS-Numpress in mzML | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. |
| MScompress | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |

Search-impact metrics are not measured by the current benchmark pipeline yet. They remain listed here so the report does not imply numerical equivalence where no downstream search experiment has actually been run.

## How The Error Numbers Are Computed

The reported means are computed over every matched peak after round-trip decode. They are not inferred from min and max.

- Mean absolute error: average absolute per-peak error.
- RMSE: square root of the average squared per-peak error.
- Relative intensity error: absolute error divided by the original intensity, evaluated only on strictly positive peaks.
- log1p intensity error: absolute error after applying `log1p`, which keeps the metric useful across large dynamic range.

## Future Comparison Candidates

All named comparison candidates are wired into the current benchmark run in some form.
