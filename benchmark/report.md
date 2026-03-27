# Benchmark Report: 15HCD_1

- mzML input: data/PXD075509/15HCD_1.mzML
- private workdir: data/PXD075509/benchmarks/15HCD_1
- public output dir: benchmark
- repeats: 3
- selected lossy intensity quantization: q=16384

## Story

The flat dump is smaller than mzML because it strips almost all interchange overhead: XML structure, controlled-vocabulary markup, base64 wrapping, and general-purpose metadata that this prototype does not need for codec bring-up. That makes the dump a useful internal floor, not a format competitor by itself.

This benchmark focuses on two things that matter right now: whether the current `.mzv1` path buys meaningful size reduction over the interchange format, and whether encode and decode stay fast and stable across repeated runs.

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
| mzv1 lossless | 21213320 | 20.23 MiB | 26.78% | 65.73% |
| mzv1 lossy | 14461329 | 13.79 MiB | 18.25% | 44.81% |
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

Lossless `.mzv1` is already materially smaller than mzML on this sample, and it slightly beats `gzip` on the dump baseline while still trailing `zstd` on the dump. The selected lossy mode gives a controlled next step down in size without the catastrophic saturation behavior that the earlier intensity quantizer had.

## Byte Composition

| artifact | structural bytes | spectrum metadata | m/z stream | intensity stream | total |
| --- | ---: | ---: | ---: | ---: | ---: |
| mzv1 lossless | 0.04 MiB (0.18%) | 0.15 MiB (0.75%) | 9.86 MiB (48.75%) | 10.18 MiB (50.32%) | 20.23 MiB |
| mzv1 lossy q=16384 | 0.04 MiB (0.27%) | 0.15 MiB (1.10%) | 9.17 MiB (66.46%) | 4.44 MiB (32.17%) | 13.79 MiB |

The lossless byte breakdown shows whether the size regression is real payload or container overhead. On this run, the intensity stream is the largest component at 10.18 MiB, which keeps the diagnosis grounded in actual encoded bytes rather than guesswork.

## Performance Overview

![Throughput Overview](plots/performance_overview.png)

| artifact | direction | status | throughput | mean time | throughput basis | source format | notes |
| --- | --- | --- | ---: | ---: | --- | --- | --- |
| gzip dump | compression | measured | 18.79 MiB/s | 1.6381s | input | dump |  |
| gzip dump | decompression | measured | 150.1 MiB/s | 0.20505s | output | gzip dump |  |
| zstd dump | compression | measured | 163.9 MiB/s | 0.18779s | input | dump |  |
| zstd dump | decompression | measured | 577.8 MiB/s | 0.053267s | output | zstd dump |  |
| bzip2 dump | compression | measured | 11.7 MiB/s | 2.6315s | input | dump |  |
| bzip2 dump | decompression | measured | 21.16 MiB/s | 1.4545s | output | bzip2 dump |  |
| lz4 dump | compression | measured | 397.2 MiB/s | 0.077484s | input | dump |  |
| lz4 dump | decompression | measured | 562.1 MiB/s | 0.054756s | output | lz4 dump |  |
| xz dump | compression | measured | 2.587 MiB/s | 11.896s | input | dump |  |
| xz dump | decompression | measured | 62.42 MiB/s | 0.49306s | output | xz dump |  |
| gzip mzML | compression | measured | 49.31 MiB/s | 1.5322s | input | mzML |  |
| gzip mzML | decompression | measured | 213.6 MiB/s | 0.35363s | output | gzip mzML |  |
| zstd mzML | compression | measured | 439.6 MiB/s | 0.17186s | input | mzML |  |
| zstd mzML | decompression | measured | 1317 MiB/s | 0.057354s | output | zstd mzML |  |
| bzip2 mzML | compression | measured | 10.64 MiB/s | 7.1036s | input | mzML |  |
| bzip2 mzML | decompression | measured | 30.9 MiB/s | 2.4447s | output | bzip2 mzML |  |
| lz4 mzML | compression | measured | 775.8 MiB/s | 0.097386s | input | mzML |  |
| lz4 mzML | decompression | measured | 852.9 MiB/s | 0.088584s | output | lz4 mzML |  |
| xz mzML | compression | measured | 14.27 MiB/s | 5.2951s | input | mzML |  |
| xz mzML | decompression | measured | 209.8 MiB/s | 0.3601s | output | xz mzML |  |
| mzv1 lossless | compression | measured | 160.9 MiB/s | 0.19129s | input | dump |  |
| mzv1 lossless | decompression | measured | 205.4 MiB/s | 0.14986s | output | mzv1 lossless |  |
| mzv1 lossy q=16384 | compression | measured | 126.1 MiB/s | 0.24416s | input | dump |  |
| mzv1 lossy q=16384 | decompression | measured | 160.7 MiB/s | 0.19147s | output | mzv1 lossy q=16384 |  |
| mzMLb | compression | measured | 3.423 MiB/s | 22.071s | input | mzML |  |
| mzMLb | decompression | measured | 6.396 MiB/s | 4.8122s | output | mzMLb |  |
| MS-Numpress in mzML | compression | measured | 3.398 MiB/s | 22.233s | input | mzML |  |
| MS-Numpress in mzML | decompression | measured | 4.939 MiB/s | 6.2323s | output | MS-Numpress in mzML |  |
| MScompress | compression | measured | 105.6 MiB/s | 0.71553s | input | mzML |  |
| MScompress | decompression | measured | 4.212 MiB/s | 7.3075s | output | MScompress |  |
| MScompress threaded | compression | measured | 582.7 MiB/s | 0.12965s | input | mzML |  |
| MScompress threaded | decompression | measured | 5.946 MiB/s | 5.176s | output | MScompress threaded |  |

## Timing Variability

![Timing Variability Across Runs](plots/timing_intervals.png)

The chart above uses all 3 runs per operation. Gray dots are individual runs. Black points show the mean with a two-sided 95% confidence interval for the mean.

| operation | mean ± sd | median | 95% CI of mean | min | max | throughput | basis |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| mzML -> dump | 4.6115s ± 0.0226s | 4.5986s | [4.5554s, 4.6675s] | 4.5983s | 4.6375s | 16.38 MiB/s | input |
| dump -> gzip dump | 1.6381s ± 0.0039s | 1.6374s | [1.6285s, 1.6477s] | 1.6346s | 1.6422s | 18.79 MiB/s | input |
| gzip dump -> dump | 0.2050s ± 0.0008s | 0.2051s | [0.2031s, 0.2070s] | 0.2042s | 0.2058s | 150.11 MiB/s | output |
| dump -> zstd dump | 0.1878s ± 0.0062s | 0.1870s | [0.1724s, 0.2032s] | 0.1820s | 0.1943s | 163.90 MiB/s | input |
| zstd dump -> dump | 0.0533s ± 0.0003s | 0.0533s | [0.0525s, 0.0541s] | 0.0529s | 0.0536s | 577.81 MiB/s | output |
| dump -> bzip2 dump | 2.6315s ± 0.0021s | 2.6326s | [2.6262s, 2.6368s] | 2.6290s | 2.6328s | 11.70 MiB/s | input |
| bzip2 dump -> dump | 1.4545s ± 0.0041s | 1.4528s | [1.4444s, 1.4646s] | 1.4515s | 1.4591s | 21.16 MiB/s | output |
| dump -> lz4 dump | 0.0775s ± 0.0011s | 0.0773s | [0.0749s, 0.0801s] | 0.0765s | 0.0786s | 397.22 MiB/s | input |
| lz4 dump -> dump | 0.0548s ± 0.0010s | 0.0542s | [0.0524s, 0.0571s] | 0.0542s | 0.0559s | 562.10 MiB/s | output |
| dump -> xz dump | 11.8962s ± 0.4096s | 11.6862s | [10.8786s, 12.9138s] | 11.6342s | 12.3682s | 2.59 MiB/s | input |
| xz dump -> dump | 0.4931s ± 0.0027s | 0.4943s | [0.4864s, 0.4997s] | 0.4900s | 0.4949s | 62.42 MiB/s | output |
| mzML -> gzip mzML | 1.5322s ± 0.0135s | 1.5277s | [1.4987s, 1.5657s] | 1.5216s | 1.5474s | 49.31 MiB/s | input |
| gzip mzML -> mzML | 0.3536s ± 0.0001s | 0.3537s | [0.3533s, 0.3540s] | 0.3535s | 0.3538s | 213.64 MiB/s | output |
| mzML -> zstd mzML | 0.1719s ± 0.0033s | 0.1717s | [0.1636s, 0.1801s] | 0.1686s | 0.1753s | 439.60 MiB/s | input |
| zstd mzML -> mzML | 0.0574s ± 0.0001s | 0.0573s | [0.0572s, 0.0575s] | 0.0573s | 0.0574s | 1317.29 MiB/s | output |
| mzML -> bzip2 mzML | 7.1036s ± 0.2093s | 7.0578s | [6.5837s, 7.6234s] | 6.9210s | 7.3319s | 10.64 MiB/s | input |
| bzip2 mzML -> mzML | 2.4447s ± 0.0032s | 2.4444s | [2.4368s, 2.4527s] | 2.4417s | 2.4481s | 30.90 MiB/s | output |
| mzML -> lz4 mzML | 0.0974s ± 0.0012s | 0.0971s | [0.0944s, 0.1003s] | 0.0963s | 0.0987s | 775.79 MiB/s | input |
| lz4 mzML -> mzML | 0.0886s ± 0.0035s | 0.0869s | [0.0800s, 0.0972s] | 0.0862s | 0.0926s | 852.88 MiB/s | output |
| mzML -> xz mzML | 5.2951s ± 0.2087s | 5.2241s | [4.7767s, 5.8136s] | 5.1313s | 5.5301s | 14.27 MiB/s | input |
| xz mzML -> mzML | 0.3601s ± 0.0014s | 0.3595s | [0.3567s, 0.3635s] | 0.3591s | 0.3617s | 209.81 MiB/s | output |
| dump -> mzv1 lossless | 0.1913s ± 0.0015s | 0.1905s | [0.1876s, 0.1949s] | 0.1904s | 0.1930s | 160.90 MiB/s | input |
| mzv1 lossless -> dump | 0.1499s ± 0.0008s | 0.1498s | [0.1479s, 0.1518s] | 0.1491s | 0.1507s | 205.38 MiB/s | output |
| dump -> mzv1 lossy q=16384 | 0.2442s ± 0.0043s | 0.2427s | [0.2334s, 0.2549s] | 0.2407s | 0.2490s | 126.06 MiB/s | input |
| mzv1 lossy q=16384 -> dump | 0.1915s ± 0.0108s | 0.1853s | [0.1646s, 0.2184s] | 0.1852s | 0.2040s | 160.75 MiB/s | output |
| mzML -> mzMLb | 22.0711s ± 1.1492s | 21.5149s | [19.2161s, 24.9261s] | 21.3058s | 23.3925s | 3.42 MiB/s | input |
| mzMLb -> dump | 4.8122s ± 0.0314s | 4.8088s | [4.7341s, 4.8902s] | 4.7826s | 4.8452s | 6.40 MiB/s | output |
| mzML -> MS-Numpress in mzML | 22.2327s ± 0.3087s | 22.0762s | [21.4658s, 22.9997s] | 22.0336s | 22.5883s | 3.40 MiB/s | input |
| MS-Numpress in mzML -> dump | 6.2323s ± 0.0250s | 6.2426s | [6.1703s, 6.2944s] | 6.2039s | 6.2505s | 4.94 MiB/s | output |
| mzML -> MScompress | 0.7155s ± 0.0071s | 0.7152s | [0.6978s, 0.7333s] | 0.7085s | 0.7228s | 105.59 MiB/s | input |
| MScompress -> dump | 7.3075s ± 0.1792s | 7.2347s | [6.8622s, 7.7528s] | 7.1761s | 7.5117s | 4.21 MiB/s | output |
| mzML -> MScompress threaded | 0.1297s ± 0.0030s | 0.1298s | [0.1221s, 0.1372s] | 0.1265s | 0.1326s | 582.72 MiB/s | input |
| MScompress threaded -> dump | 5.1760s ± 0.0092s | 5.1715s | [5.1531s, 5.1989s] | 5.1699s | 5.1866s | 5.95 MiB/s | output |

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
| mzv1 lossless | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| mzv1 lossy q=16384 | measured | true | 1.00000011e-06 | 0.00746008 | 173.700907 | 537856 | 0.055% |  |
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
| mzv1 lossless | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| mzv1 lossy q=16384 | true | true | true | 5.00068204e-07 | 1.00000011e-06 | 0.00746008 | 173.700907 | 2607.53484 | 0.055% | 0.059% | 0.000284144487 |
| mzMLb | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| MS-Numpress in mzML | true | true | true | 4.70575714e-08 | 2.37443714e-07 | 0.00140354 | 41.5276661 | 690.149717 | 0.012% | 0.014% | 5.85200344e-05 |
| MScompress | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| MScompress threaded | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |

On the current run, `lz4 dump`, `gzip dump`, `zstd dump`, `bzip2 dump`, `xz dump`, `mzv1 lossless`, `mzMLb`, `MScompress`, and `MScompress threaded` round-trip exactly. `mzv1 lossless` round-trips exactly, including m/z values and original scan order. `mzv1 lossy` preserves original scan order while keeping m/z and intensity error within the current quantization bounds.

## Lossy Sweep

![Lossy Tradeoff](plots/lossy_tradeoff.png)

| q | bytes | size | p95 rel intensity err | p99 rel intensity err | mean rel intensity err |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 256 | 12459954 | 11.88 MiB | 3.499% | 3.813% | 1.820% |
| 1024 | 13127097 | 12.52 MiB | 0.874% | 0.950% | 0.455% |
| 4096 | 13794206 | 13.16 MiB | 0.218% | 0.238% | 0.114% |
| 16384 | 14461329 | 13.79 MiB | 0.055% | 0.059% | 0.028% |

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
