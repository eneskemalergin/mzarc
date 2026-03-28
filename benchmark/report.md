# Benchmark Report: 15HCD_1

- mzML input: data/PXD075509/15HCD_1.mzML
- private workdir: data/PXD075509/benchmarks/15HCD_1
- public output dir: benchmark
- repeats: 3
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

| artifact | bytes | size | vs mzML | vs dump |
| --- | ---: | ---: | ---: | ---: |
| mzML | 79221306 | 75.55 MiB | 100.00% | 245.47% |
| dump | 32273524 | 30.78 MiB | 40.74% | 100.00% |
| mzarc lossless | 16016009 | 15.27 MiB | 20.22% | 49.63% |
| mzarc lossy | 13233307 | 12.62 MiB | 16.70% | 41.00% |
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
| MScompress threaded | 22579410 | 21.53 MiB | 28.50% | 69.96% |

Lossless `.mzarc` is already materially smaller than mzML on this sample, and it slightly beats `gzip` on the dump baseline while still trailing `zstd` on the dump. The selected lossy mode gives a controlled next step down in size without the catastrophic saturation behavior that the earlier intensity quantizer had.

## Byte Composition

| artifact | structural bytes | spectrum metadata | m/z stream | intensity stream | total |
| --- | ---: | ---: | ---: | ---: | ---: |
| mzarc lossless | 0.04 MiB (0.24%) | 0.15 MiB (1.00%) | 6.81 MiB (44.61%) | 8.27 MiB (54.15%) | 15.27 MiB |
| mzarc lossy q=16384 | 0.04 MiB (0.29%) | 0.15 MiB (1.20%) | 7.99 MiB (63.35%) | 4.44 MiB (35.15%) | 12.62 MiB |

The lossless byte breakdown shows whether the size regression is real payload or container overhead. On this run, the intensity stream is the largest component at 8.27 MiB, which keeps the diagnosis grounded in actual encoded bytes rather than guesswork.

## Performance Overview

![Throughput Overview](plots/performance_overview.png)

| artifact | direction | status | throughput | mean time | throughput basis | source format | notes |
| --- | --- | --- | ---: | ---: | --- | --- | --- |
| gzip dump | compression | measured | 18.79 MiB/s | 1.6376s | input | dump |  |
| gzip dump | decompression | measured | 149.7 MiB/s | 0.20556s | output | gzip dump |  |
| zstd dump | compression | measured | 165.9 MiB/s | 0.18555s | input | dump |  |
| zstd dump | decompression | measured | 583.9 MiB/s | 0.052709s | output | zstd dump |  |
| bzip2 dump | compression | measured | 11.65 MiB/s | 2.6412s | input | dump |  |
| bzip2 dump | decompression | measured | 21.2 MiB/s | 1.4517s | output | bzip2 dump |  |
| lz4 dump | compression | measured | 400.5 MiB/s | 0.076846s | input | dump |  |
| lz4 dump | decompression | measured | 561.8 MiB/s | 0.054786s | output | lz4 dump |  |
| xz dump | compression | measured | 2.619 MiB/s | 11.753s | input | dump |  |
| xz dump | decompression | measured | 62.33 MiB/s | 0.49381s | output | xz dump |  |
| gzip mzML | compression | measured | 49.34 MiB/s | 1.5314s | input | mzML |  |
| gzip mzML | decompression | measured | 213.2 MiB/s | 0.35431s | output | gzip mzML |  |
| zstd mzML | compression | measured | 439.9 MiB/s | 0.17173s | input | mzML |  |
| zstd mzML | decompression | measured | 1309 MiB/s | 0.057702s | output | zstd mzML |  |
| bzip2 mzML | compression | measured | 10.96 MiB/s | 6.8912s | input | mzML |  |
| bzip2 mzML | decompression | measured | 30.99 MiB/s | 2.4378s | output | bzip2 mzML |  |
| lz4 mzML | compression | measured | 777.1 MiB/s | 0.097221s | input | mzML |  |
| lz4 mzML | decompression | measured | 888.2 MiB/s | 0.085064s | output | lz4 mzML |  |
| xz mzML | compression | measured | 13.97 MiB/s | 5.4079s | input | mzML |  |
| xz mzML | decompression | measured | 208.4 MiB/s | 0.36254s | output | xz mzML |  |
| mzarc lossless | compression | measured | 95.88 MiB/s | 0.32102s | input | dump |  |
| mzarc lossless | decompression | measured | 151.5 MiB/s | 0.20311s | output | mzarc lossless |  |
| mzarc lossy q=16384 | compression | measured | 72.4 MiB/s | 0.42514s | input | dump |  |
| mzarc lossy q=16384 | decompression | measured | 130.4 MiB/s | 0.23602s | output | mzarc lossy q=16384 |  |
| mzMLb | compression | measured | 3.385 MiB/s | 22.321s | input | mzML |  |
| mzMLb | decompression | measured | 6.354 MiB/s | 4.8443s | output | mzMLb |  |
| MS-Numpress in mzML | compression | measured | 3.335 MiB/s | 22.652s | input | mzML |  |
| MS-Numpress in mzML | decompression | measured | 4.909 MiB/s | 6.2702s | output | MS-Numpress in mzML |  |
| MScompress | compression | measured | 104.8 MiB/s | 0.72111s | input | mzML |  |
| MScompress | decompression | measured | 4.258 MiB/s | 7.2276s | output | MScompress |  |
| MScompress threaded | compression | measured | 597.1 MiB/s | 0.12653s | input | mzML |  |
| MScompress threaded | decompression | measured | 5.981 MiB/s | 5.1459s | output | MScompress threaded |  |

## Timing Variability

![Timing Variability Across Runs](plots/timing_intervals.png)

The chart above uses all 3 runs per operation. Gray dots are individual runs. Black points show the mean with a two-sided 95% confidence interval for the mean.

| operation | mean ± sd | median | 95% CI of mean | min | max | throughput | basis |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| mzML -> dump | 4.5897s ± 0.0592s | 4.5652s | [4.4426s, 4.7368s] | 4.5467s | 4.6572s | 16.46 MiB/s | input |
| dump -> gzip dump | 1.6376s ± 0.0023s | 1.6383s | [1.6320s, 1.6433s] | 1.6351s | 1.6395s | 18.79 MiB/s | input |
| gzip dump -> dump | 0.2056s ± 0.0021s | 0.2066s | [0.2004s, 0.2107s] | 0.2032s | 0.2069s | 149.73 MiB/s | output |
| dump -> zstd dump | 0.1855s ± 0.0009s | 0.1858s | [0.1834s, 0.1877s] | 0.1846s | 0.1863s | 165.88 MiB/s | input |
| zstd dump -> dump | 0.0527s ± 0.0001s | 0.0527s | [0.0524s, 0.0530s] | 0.0526s | 0.0528s | 583.93 MiB/s | output |
| dump -> bzip2 dump | 2.6412s ± 0.0204s | 2.6323s | [2.5905s, 2.6920s] | 2.6268s | 2.6646s | 11.65 MiB/s | input |
| bzip2 dump -> dump | 1.4517s ± 0.0019s | 1.4522s | [1.4470s, 1.4565s] | 1.4496s | 1.4534s | 21.20 MiB/s | output |
| dump -> lz4 dump | 0.0768s ± 0.0008s | 0.0764s | [0.0748s, 0.0789s] | 0.0764s | 0.0778s | 400.52 MiB/s | input |
| lz4 dump -> dump | 0.0548s ± 0.0010s | 0.0545s | [0.0522s, 0.0573s] | 0.0539s | 0.0559s | 561.79 MiB/s | output |
| dump -> xz dump | 11.7528s ± 0.1162s | 11.7499s | [11.4642s, 12.0414s] | 11.6381s | 11.8703s | 2.62 MiB/s | input |
| xz dump -> dump | 0.4938s ± 0.0049s | 0.4917s | [0.4816s, 0.5061s] | 0.4902s | 0.4994s | 62.33 MiB/s | output |
| mzML -> gzip mzML | 1.5314s ± 0.0160s | 1.5222s | [1.4917s, 1.5710s] | 1.5221s | 1.5498s | 49.34 MiB/s | input |
| gzip mzML -> mzML | 0.3543s ± 0.0011s | 0.3542s | [0.3516s, 0.3571s] | 0.3532s | 0.3555s | 213.23 MiB/s | output |
| mzML -> zstd mzML | 0.1717s ± 0.0034s | 0.1700s | [0.1634s, 0.1801s] | 0.1696s | 0.1756s | 439.94 MiB/s | input |
| zstd mzML -> mzML | 0.0577s ± 0.0005s | 0.0575s | [0.0565s, 0.0589s] | 0.0573s | 0.0582s | 1309.34 MiB/s | output |
| mzML -> bzip2 mzML | 6.8912s ± 0.0139s | 6.8983s | [6.8566s, 6.9258s] | 6.8752s | 6.9001s | 10.96 MiB/s | input |
| bzip2 mzML -> mzML | 2.4378s ± 0.0006s | 2.4379s | [2.4362s, 2.4394s] | 2.4371s | 2.4383s | 30.99 MiB/s | output |
| mzML -> lz4 mzML | 0.0972s ± 0.0016s | 0.0964s | [0.0933s, 0.1012s] | 0.0962s | 0.0990s | 777.11 MiB/s | input |
| lz4 mzML -> mzML | 0.0851s ± 0.0002s | 0.0851s | [0.0846s, 0.0855s] | 0.0849s | 0.0852s | 888.18 MiB/s | output |
| mzML -> xz mzML | 5.4079s ± 0.2375s | 5.2801s | [4.8179s, 5.9978s] | 5.2616s | 5.6819s | 13.97 MiB/s | input |
| xz mzML -> mzML | 0.3625s ± 0.0047s | 0.3620s | [0.3509s, 0.3742s] | 0.3581s | 0.3674s | 208.39 MiB/s | output |
| mzML -> mzMLb | 22.3208s ± 1.1547s | 21.6572s | [19.4523s, 25.1894s] | 21.6512s | 23.6541s | 3.38 MiB/s | input |
| mzMLb -> dump | 4.8443s ± 0.0309s | 4.8362s | [4.7675s, 4.9210s] | 4.8182s | 4.8784s | 6.35 MiB/s | output |
| mzML -> MS-Numpress in mzML | 22.6521s ± 0.1860s | 22.5985s | [22.1899s, 23.1142s] | 22.4987s | 22.8590s | 3.34 MiB/s | input |
| MS-Numpress in mzML -> dump | 6.2702s ± 0.0260s | 6.2725s | [6.2057s, 6.3348s] | 6.2432s | 6.2950s | 4.91 MiB/s | output |
| mzML -> MScompress | 0.7211s ± 0.0121s | 0.7157s | [0.6910s, 0.7512s] | 0.7126s | 0.7350s | 104.77 MiB/s | input |
| MScompress -> dump | 7.2276s ± 0.2569s | 7.1133s | [6.5894s, 7.8658s] | 7.0477s | 7.5218s | 4.26 MiB/s | output |
| mzML -> MScompress threaded | 0.1265s ± 0.0016s | 0.1265s | [0.1226s, 0.1305s] | 0.1250s | 0.1281s | 597.13 MiB/s | input |
| MScompress threaded -> dump | 5.1459s ± 0.0422s | 5.1319s | [5.0411s, 5.2506s] | 5.1125s | 5.1933s | 5.98 MiB/s | output |
| dump -> mzarc lossless | 0.3210s ± 0.0024s | 0.3214s | [0.3150s, 0.3270s] | 0.3184s | 0.3232s | 95.88 MiB/s | input |
| mzarc lossless -> dump | 0.2031s ± 0.0014s | 0.2026s | [0.1996s, 0.2066s] | 0.2020s | 0.2047s | 151.53 MiB/s | output |
| dump -> mzarc lossy q=16384 | 0.4251s ± 0.0046s | 0.4252s | [0.4137s, 0.4366s] | 0.4205s | 0.4297s | 72.40 MiB/s | input |
| mzarc lossy q=16384 -> dump | 0.2360s ± 0.0023s | 0.2350s | [0.2303s, 0.2418s] | 0.2344s | 0.2387s | 130.41 MiB/s | output |

## External Baselines

| baseline | status | size | encode | decode | notes |
| --- | --- | ---: | --- | --- | --- |
| mzMLb | benchmarked | 16.25 MiB | mzML -> mzMLb | mzMLb -> dump | Converted with psims MzMLToMzMLb using HDF5 compression `blosc:zstd`. |
| MS-Numpress in mzML | benchmarked | 66.67 MiB | mzML -> MS-Numpress in mzML | MS-Numpress in mzML -> dump | Converted with psims and per-array MS-Numpress compression settings. |
| MScompress | benchmarked | 21.63 MiB | mzML -> MScompress | MScompress -> dump | Converted with the MScompress Python package using 1 thread for single-thread comparability. |
| MScompress threaded | benchmarked | 21.53 MiB | mzML -> MScompress threaded | MScompress threaded -> dump | Converted with the MScompress Python package using its default thread setting. |

## Data Fidelity

![Data Fidelity Overview](plots/fidelity_overview.png)

| artifact | status | global order | max abs m/z | max ppm m/z | mean abs intensity | max abs intensity | p95 rel intensity | notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| lz4 dump | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| gzip dump | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| zstd dump | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| bzip2 dump | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| xz dump | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| mzarc lossless | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| mzarc lossy q=16384 | measured | true | 1.00000011e-06 | 0.00746008 | 173.700907 | 537856 | 0.055% |  |
| mzMLb | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| MS-Numpress in mzML | measured | true | 2.37443714e-07 | 0.00140354 | 41.5276661 | 191744 | 0.012% |  |
| MScompress | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| MScompress threaded | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |

## Fidelity Summary

| artifact | global order | ms1 order | ms2 order | mean abs mz | max abs mz | max ppm mz | mean abs intensity | rmse intensity | p95 rel intensity | p99 rel intensity | mean abs log1p intensity |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| gzip dump | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| zstd dump | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| bzip2 dump | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| lz4 dump | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| xz dump | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| mzMLb | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| MS-Numpress in mzML | true | true | true | 4.70575714e-08 | 2.37443714e-07 | 0.00140354 | 41.5276661 | 690.149717 | 0.012% | 0.014% | 5.85200344e-05 |
| MScompress | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| MScompress threaded | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| mzarc lossless | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| mzarc lossy q=16384 | true | true | true | 5.00068204e-07 | 1.00000011e-06 | 0.00746008 | 173.700907 | 2607.53484 | 0.055% | 0.059% | 0.000284144487 |

On the current run, `lz4 dump`, `gzip dump`, `zstd dump`, `bzip2 dump`, `xz dump`, `mzarc lossless`, `mzMLb`, `MScompress`, and `MScompress threaded` round-trip exactly. `mzarc lossless` round-trips exactly, including m/z values and original scan order. `mzarc lossy` preserves original scan order while keeping m/z and intensity error within the current quantization bounds.

## Lossy Sweep

![Lossy Tradeoff](plots/lossy_tradeoff.png)

| q | bytes | size | p95 rel intensity err | p99 rel intensity err | mean rel intensity err |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 256 | 10720131 | 10.22 MiB | 3.499% | 3.813% | 1.820% |
| 1024 | 11899075 | 11.35 MiB | 0.874% | 0.950% | 0.455% |
| 4096 | 12566184 | 11.98 MiB | 0.218% | 0.238% | 0.114% |
| 16384 | 13233307 | 12.62 MiB | 0.055% | 0.059% | 0.028% |

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
| mzarc lossless | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| mzarc lossy q=16384 | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. |
| mzMLb | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| MS-Numpress in mzML | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. |
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

All named comparison candidates are wired into the current benchmark run in some form.
