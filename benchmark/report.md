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

| artifact            |    bytes |      size | vs mzML | vs dump |
| ------------------- | -------: | --------: | ------: | ------: |
| mzML                | 79221306 | 75.55 MiB | 100.00% | 245.47% |
| dump                | 32273524 | 30.78 MiB |  40.74% | 100.00% |
| mzarc lossless      | 16016009 | 15.27 MiB |  20.22% |  49.63% |
| mzarc lossy         | 13340333 | 12.72 MiB |  16.84% |  41.34% |
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
| mzarc lossy q=16384 | 0.04 MiB (0.29%) |  0.15 MiB (1.19%) | 8.10 MiB (63.64%) | 4.44 MiB (34.87%) | 12.72 MiB |

The lossless byte breakdown shows whether the size regression is real payload or container overhead. On this run, the intensity stream is the largest component at 8.27 MiB, which keeps the diagnosis grounded in actual encoded bytes rather than guesswork.

## Performance Overview

![Throughput Overview](plots/performance_overview.png)

| artifact            | direction     | status   |  throughput | mean time | throughput basis | source format       | notes |
| ------------------- | ------------- | -------- | ----------: | --------: | ---------------- | ------------------- | ----- |
| gzip dump           | compression   | measured | 18.64 MiB/s |   1.6514s | input            | dump                |       |
| gzip dump           | decompression | measured |   149 MiB/s |   0.2066s | output           | gzip dump           |       |
| zstd dump           | compression   | measured | 166.1 MiB/s |  0.18535s | input            | dump                |       |
| zstd dump           | decompression | measured | 574.9 MiB/s | 0.053535s | output           | zstd dump           |       |
| bzip2 dump          | compression   | measured | 11.35 MiB/s |   2.7108s | input            | dump                |       |
| bzip2 dump          | decompression | measured | 20.95 MiB/s |    1.469s | output           | bzip2 dump          |       |
| lz4 dump            | compression   | measured | 393.7 MiB/s |  0.07817s | input            | dump                |       |
| lz4 dump            | decompression | measured | 540.9 MiB/s | 0.056899s | output           | lz4 dump            |       |
| xz dump             | compression   | measured | 2.404 MiB/s |   12.802s | input            | dump                |       |
| xz dump             | decompression | measured | 61.72 MiB/s |  0.49869s | output           | xz dump             |       |
| gzip mzML           | compression   | measured | 49.12 MiB/s |    1.538s | input            | mzML                |       |
| gzip mzML           | decompression | measured |   210 MiB/s |  0.35978s | output           | gzip mzML           |       |
| zstd mzML           | compression   | measured | 423.2 MiB/s |  0.17852s | input            | mzML                |       |
| zstd mzML           | decompression | measured |  1307 MiB/s | 0.057809s | output           | zstd mzML           |       |
| bzip2 mzML          | compression   | measured | 10.67 MiB/s |   7.0787s | input            | mzML                |       |
| bzip2 mzML          | decompression | measured | 30.54 MiB/s |   2.4742s | output           | bzip2 mzML          |       |
| lz4 mzML            | compression   | measured | 764.4 MiB/s | 0.098841s | input            | mzML                |       |
| lz4 mzML            | decompression | measured | 828.1 MiB/s | 0.091232s | output           | lz4 mzML            |       |
| xz mzML             | compression   | measured |  13.4 MiB/s |   5.6378s | input            | mzML                |       |
| xz mzML             | decompression | measured | 206.1 MiB/s |   0.3665s | output           | xz mzML             |       |
| mzarc lossless      | compression   | measured |  94.7 MiB/s |  0.32499s | input            | dump                |       |
| mzarc lossless      | decompression | measured | 148.4 MiB/s |  0.20739s | output           | mzarc lossless      |       |
| mzarc lossy q=16384 | compression   | measured | 86.36 MiB/s |  0.35638s | input            | dump                |       |
| mzarc lossy q=16384 | decompression | measured | 130.1 MiB/s |  0.23659s | output           | mzarc lossy q=16384 |       |
| mzMLb               | compression   | measured | 3.352 MiB/s |   22.541s | input            | mzML                |       |
| mzMLb               | decompression | measured | 6.265 MiB/s |   4.9129s | output           | mzMLb               |       |
| MS-Numpress in mzML | compression   | measured | 3.328 MiB/s |   22.703s | input            | mzML                |       |
| MS-Numpress in mzML | decompression | measured | 4.869 MiB/s |    6.321s | output           | MS-Numpress in mzML |       |
| MScompress          | compression   | measured | 103.9 MiB/s |   0.7271s | input            | mzML                |       |
| MScompress          | decompression | measured | 4.219 MiB/s |   7.2949s | output           | MScompress          |       |
| MScompress threaded | compression   | measured | 586.5 MiB/s |  0.12882s | input            | mzML                |       |
| MScompress threaded | decompression | measured |  5.87 MiB/s |   5.2437s | output           | MScompress threaded |       |

## Timing Variability

![Timing Variability Across Runs](plots/timing_intervals.png)

The chart above uses all 3 runs per operation. Gray dots are individual runs. Black points show the mean with a two-sided 95% confidence interval for the mean.

| operation                   |          mean ± sd |   median |       95% CI of mean |      min |      max |    throughput | basis  |
| --------------------------- | -----------------: | -------: | -------------------: | -------: | -------: | ------------: | ------ |
| mzML -> dump                |  4.5883s ± 0.0145s |  4.5809s |   [4.5522s, 4.6243s] |  4.5789s |  4.6049s |   16.47 MiB/s | input  |
| dump -> gzip dump           |  1.6514s ± 0.0046s |  1.6512s |   [1.6398s, 1.6629s] |  1.6468s |  1.6561s |   18.64 MiB/s | input  |
| gzip dump -> dump           |  0.2066s ± 0.0041s |  0.2057s |   [0.1964s, 0.2168s] |  0.2030s |  0.2111s |  148.98 MiB/s | output |
| dump -> zstd dump           |  0.1854s ± 0.0002s |  0.1853s |   [0.1850s, 0.1857s] |  0.1853s |  0.1855s |  166.05 MiB/s | input  |
| zstd dump -> dump           |  0.0535s ± 0.0014s |  0.0533s |   [0.0500s, 0.0571s] |  0.0522s |  0.0550s |  574.92 MiB/s | output |
| dump -> bzip2 dump          |  2.7108s ± 0.0043s |  2.7119s |   [2.7002s, 2.7215s] |  2.7061s |  2.7145s |   11.35 MiB/s | input  |
| bzip2 dump -> dump          |  1.4690s ± 0.0139s |  1.4613s |   [1.4344s, 1.5036s] |  1.4606s |  1.4851s |   20.95 MiB/s | output |
| dump -> lz4 dump            |  0.0782s ± 0.0004s |  0.0781s |   [0.0773s, 0.0791s] |  0.0779s |  0.0786s |  393.74 MiB/s | input  |
| lz4 dump -> dump            |  0.0569s ± 0.0024s |  0.0556s |   [0.0510s, 0.0628s] |  0.0555s |  0.0596s |  540.93 MiB/s | output |
| dump -> xz dump             | 12.8020s ± 0.1949s | 12.6907s | [12.3176s, 13.2863s] | 12.6881s | 13.0271s |    2.40 MiB/s | input  |
| xz dump -> dump             |  0.4987s ± 0.0034s |  0.4980s |   [0.4903s, 0.5071s] |  0.4957s |  0.5024s |   61.72 MiB/s | output |
| mzML -> gzip mzML           |  1.5380s ± 0.0046s |  1.5384s |   [1.5267s, 1.5494s] |  1.5333s |  1.5424s |   49.12 MiB/s | input  |
| gzip mzML -> mzML           |  0.3598s ± 0.0071s |  0.3636s |   [0.3421s, 0.3774s] |  0.3516s |  0.3642s |  209.99 MiB/s | output |
| mzML -> zstd mzML           |  0.1785s ± 0.0049s |  0.1806s |   [0.1663s, 0.1907s] |  0.1729s |  0.1820s |  423.20 MiB/s | input  |
| zstd mzML -> mzML           |  0.0578s ± 0.0001s |  0.0578s |   [0.0576s, 0.0580s] |  0.0577s |  0.0579s | 1306.91 MiB/s | output |
| mzML -> bzip2 mzML          |  7.0787s ± 0.0109s |  7.0818s |   [7.0516s, 7.1058s] |  7.0666s |  7.0878s |   10.67 MiB/s | input  |
| bzip2 mzML -> mzML          |  2.4742s ± 0.0248s |  2.4740s |   [2.4126s, 2.5359s] |  2.4495s |  2.4992s |   30.54 MiB/s | output |
| mzML -> lz4 mzML            |  0.0988s ± 0.0013s |  0.0985s |   [0.0956s, 0.1020s] |  0.0978s |  0.1003s |  764.37 MiB/s | input  |
| lz4 mzML -> mzML            |  0.0912s ± 0.0050s |  0.0896s |   [0.0789s, 0.1036s] |  0.0873s |  0.0968s |  828.12 MiB/s | output |
| mzML -> xz mzML             |  5.6378s ± 0.1095s |  5.6176s |   [5.3657s, 5.9098s] |  5.5397s |  5.7559s |   13.40 MiB/s | input  |
| xz mzML -> mzML             |  0.3665s ± 0.0065s |  0.3633s |   [0.3504s, 0.3826s] |  0.3623s |  0.3740s |  206.14 MiB/s | output |
| dump -> mzarc lossless      |  0.3250s ± 0.0015s |  0.3243s |   [0.3213s, 0.3287s] |  0.3240s |  0.3267s |   94.70 MiB/s | input  |
| mzarc lossless -> dump      |  0.2074s ± 0.0014s |  0.2077s |   [0.2039s, 0.2109s] |  0.2059s |  0.2086s |  148.41 MiB/s | output |
| dump -> mzarc lossy q=16384 |  0.3564s ± 0.0018s |  0.3558s |   [0.3519s, 0.3609s] |  0.3549s |  0.3584s |   86.36 MiB/s | input  |
| mzarc lossy q=16384 -> dump |  0.2366s ± 0.0017s |  0.2370s |   [0.2324s, 0.2408s] |  0.2347s |  0.2380s |  130.09 MiB/s | output |
| mzML -> mzMLb               | 22.5415s ± 1.1111s | 21.9691s | [19.7811s, 25.3018s] | 21.8332s | 23.8221s |    3.35 MiB/s | input  |
| mzMLb -> dump               |  4.9129s ± 0.0475s |  4.8975s |   [4.7948s, 5.0309s] |  4.8749s |  4.9661s |    6.26 MiB/s | output |
| mzML -> MS-Numpress in mzML | 22.7030s ± 0.4710s | 22.5056s | [21.5329s, 23.8732s] | 22.3628s | 23.2406s |    3.33 MiB/s | input  |
| MS-Numpress in mzML -> dump |  6.3210s ± 0.0960s |  6.3166s |   [6.0825s, 6.5594s] |  6.2272s |  6.4191s |    4.87 MiB/s | output |
| mzML -> MScompress          |  0.7271s ± 0.0062s |  0.7241s |   [0.7117s, 0.7425s] |  0.7230s |  0.7342s |  103.91 MiB/s | input  |
| MScompress -> dump          |  7.2949s ± 0.1435s |  7.2389s |   [6.9384s, 7.6514s] |  7.1878s |  7.4580s |    4.22 MiB/s | output |
| mzML -> MScompress threaded |  0.1288s ± 0.0031s |  0.1282s |   [0.1210s, 0.1366s] |  0.1260s |  0.1322s |  586.51 MiB/s | input  |
| MScompress threaded -> dump |  5.2437s ± 0.0732s |  5.2140s |   [5.0619s, 5.4256s] |  5.1900s |  5.3271s |    5.87 MiB/s | output |

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
| mzarc lossless      |         true |      true |      true |              0 |              0 |          0 |                  0 |              0 |            0.000% |            0.000% |                        0 |
| mzarc lossy q=16384 |         true |      true |      true | 5.00068204e-07 | 1.00000011e-06 | 0.00746008 |         173.700907 |     2607.53484 |            0.055% |            0.059% |           0.000284144487 |
| mzMLb               |         true |      true |      true |              0 |              0 |          0 |                  0 |              0 |            0.000% |            0.000% |                        0 |
| MS-Numpress in mzML |         true |      true |      true | 4.70575714e-08 | 2.37443714e-07 | 0.00140354 |         41.5276661 |     690.149717 |            0.012% |            0.014% |           5.85200344e-05 |
| MScompress          |         true |      true |      true |              0 |              0 |          0 |                  0 |              0 |            0.000% |            0.000% |                        0 |
| MScompress threaded |         true |      true |      true |              0 |              0 |          0 |                  0 |              0 |            0.000% |            0.000% |                        0 |

On the current run, `lz4 dump`, `gzip dump`, `zstd dump`, `bzip2 dump`, `xz dump`, `mzarc lossless`, `mzMLb`, `MScompress`, and `MScompress threaded` round-trip exactly. `mzarc lossless` round-trips exactly, including m/z values and original scan order. `mzarc lossy` preserves original scan order while keeping m/z and intensity error within the current quantization bounds.

## Lossy Sweep

![Lossy Tradeoff](plots/lossy_tradeoff.png)

|     q |    bytes |      size | p95 rel intensity err | p99 rel intensity err | mean rel intensity err |
| ----: | -------: | --------: | --------------------: | --------------------: | ---------------------: |
|   256 | 10827157 | 10.33 MiB |                3.499% |                3.813% |                 1.820% |
|  1024 | 12006101 | 11.45 MiB |                0.874% |                0.950% |                 0.455% |
|  4096 | 12673210 | 12.09 MiB |                0.218% |                0.238% |                 0.114% |
| 16384 | 13340333 | 12.72 MiB |                0.055% |                0.059% |                 0.028% |

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
