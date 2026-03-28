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
| mzarc lossless      | 19802353 | 18.88 MiB |  25.00% |  61.36% |
| mzarc lossy         | 14461329 | 13.79 MiB |  18.25% |  44.81% |
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
| mzarc lossless      | 0.04 MiB (0.20%) |  0.15 MiB (0.80%) | 9.86 MiB (52.22%) | 8.83 MiB (46.78%) | 18.88 MiB |
| mzarc lossy q=16384 | 0.04 MiB (0.27%) |  0.15 MiB (1.10%) | 9.17 MiB (66.46%) | 4.44 MiB (32.17%) | 13.79 MiB |

The lossless byte breakdown shows whether the size regression is real payload or container overhead. On this run, the m/z stream is the largest component at 9.86 MiB, which keeps the diagnosis grounded in actual encoded bytes rather than guesswork.

## Performance Overview

![Throughput Overview](plots/performance_overview.png)

| artifact            | direction     | status   |  throughput | mean time | throughput basis | source format       | notes |
| ------------------- | ------------- | -------- | ----------: | --------: | ---------------- | ------------------- | ----- |
| gzip dump           | compression   | measured | 18.52 MiB/s |   1.6623s | input            | dump                |       |
| gzip dump           | decompression | measured |   148 MiB/s |  0.20794s | output           | gzip dump           |       |
| zstd dump           | compression   | measured | 166.2 MiB/s |  0.18521s | input            | dump                |       |
| zstd dump           | decompression | measured | 568.9 MiB/s | 0.054097s | output           | zstd dump           |       |
| bzip2 dump          | compression   | measured | 11.34 MiB/s |   2.7131s | input            | dump                |       |
| bzip2 dump          | decompression | measured | 20.92 MiB/s |   1.4709s | output           | bzip2 dump          |       |
| lz4 dump            | compression   | measured | 391.1 MiB/s | 0.078692s | input            | dump                |       |
| lz4 dump            | decompression | measured | 557.9 MiB/s | 0.055168s | output           | lz4 dump            |       |
| xz dump             | compression   | measured | 2.408 MiB/s |    12.78s | input            | dump                |       |
| xz dump             | decompression | measured | 60.92 MiB/s |  0.50526s | output           | xz dump             |       |
| gzip mzML           | compression   | measured | 48.84 MiB/s |   1.5468s | input            | mzML                |       |
| gzip mzML           | decompression | measured | 212.2 MiB/s |    0.356s | output           | gzip mzML           |       |
| zstd mzML           | compression   | measured | 439.8 MiB/s |  0.17179s | input            | mzML                |       |
| zstd mzML           | decompression | measured |  1253 MiB/s | 0.060303s | output           | zstd mzML           |       |
| bzip2 mzML          | compression   | measured | 10.75 MiB/s |    7.031s | input            | mzML                |       |
| bzip2 mzML          | decompression | measured | 30.45 MiB/s |   2.4808s | output           | bzip2 mzML          |       |
| lz4 mzML            | compression   | measured | 763.1 MiB/s |  0.09901s | input            | mzML                |       |
| lz4 mzML            | decompression | measured | 851.6 MiB/s |  0.08872s | output           | lz4 mzML            |       |
| xz mzML             | compression   | measured | 13.33 MiB/s |   5.6694s | input            | mzML                |       |
| xz mzML             | decompression | measured | 205.9 MiB/s |  0.36686s | output           | xz mzML             |       |
| mzarc lossless      | compression   | measured | 136.7 MiB/s |  0.22514s | input            | dump                |       |
| mzarc lossless      | decompression | measured | 200.1 MiB/s |  0.15385s | output           | mzarc lossless      |       |
| mzarc lossy q=16384 | compression   | measured | 126.2 MiB/s |  0.24385s | input            | dump                |       |
| mzarc lossy q=16384 | decompression | measured | 157.2 MiB/s |   0.1958s | output           | mzarc lossy q=16384 |       |
| mzMLb               | compression   | measured | 3.317 MiB/s |   22.776s | input            | mzML                |       |
| mzMLb               | decompression | measured | 6.251 MiB/s |   4.9235s | output           | mzMLb               |       |
| MS-Numpress in mzML | compression   | measured | 3.256 MiB/s |   23.202s | input            | mzML                |       |
| MS-Numpress in mzML | decompression | measured | 4.844 MiB/s |   6.3538s | output           | MS-Numpress in mzML |       |
| MScompress          | compression   | measured | 106.9 MiB/s |  0.70642s | input            | mzML                |       |
| MScompress          | decompression | measured | 4.196 MiB/s |   7.3351s | output           | MScompress          |       |
| MScompress threaded | compression   | measured | 592.3 MiB/s |  0.12756s | input            | mzML                |       |
| MScompress threaded | decompression | measured |  5.85 MiB/s |   5.2615s | output           | MScompress threaded |       |

## Timing Variability

![Timing Variability Across Runs](plots/timing_intervals.png)

The chart above uses all 3 runs per operation. Gray dots are individual runs. Black points show the mean with a two-sided 95% confidence interval for the mean.

| operation                   |          mean ± sd |   median |       95% CI of mean |      min |      max |    throughput | basis  |
| --------------------------- | -----------------: | -------: | -------------------: | -------: | -------: | ------------: | ------ |
| mzML -> dump                |  4.6344s ± 0.0401s |  4.6409s |   [4.5349s, 4.7340s] |  4.5915s |  4.6708s |   16.30 MiB/s | input  |
| dump -> gzip dump           |  1.6623s ± 0.0121s |  1.6565s |   [1.6323s, 1.6924s] |  1.6543s |  1.6762s |   18.52 MiB/s | input  |
| gzip dump -> dump           |  0.2079s ± 0.0073s |  0.2048s |   [0.1899s, 0.2260s] |  0.2028s |  0.2162s |  148.02 MiB/s | output |
| dump -> zstd dump           |  0.1852s ± 0.0014s |  0.1855s |   [0.1818s, 0.1886s] |  0.1837s |  0.1864s |  166.18 MiB/s | input  |
| zstd dump -> dump           |  0.0541s ± 0.0006s |  0.0540s |   [0.0527s, 0.0555s] |  0.0536s |  0.0547s |  568.95 MiB/s | output |
| dump -> bzip2 dump          |  2.7131s ± 0.0243s |  2.7072s |   [2.6527s, 2.7736s] |  2.6923s |  2.7399s |   11.34 MiB/s | input  |
| bzip2 dump -> dump          |  1.4709s ± 0.0117s |  1.4684s |   [1.4419s, 1.5000s] |  1.4607s |  1.4837s |   20.92 MiB/s | output |
| dump -> lz4 dump            |  0.0787s ± 0.0002s |  0.0787s |   [0.0783s, 0.0791s] |  0.0785s |  0.0788s |  391.13 MiB/s | input  |
| lz4 dump -> dump            |  0.0552s ± 0.0008s |  0.0549s |   [0.0532s, 0.0571s] |  0.0546s |  0.0561s |  557.91 MiB/s | output |
| dump -> xz dump             | 12.7803s ± 0.2250s | 12.8874s | [12.2214s, 13.3392s] | 12.5218s | 12.9317s |    2.41 MiB/s | input  |
| xz dump -> dump             |  0.5053s ± 0.0077s |  0.5019s |   [0.4862s, 0.5243s] |  0.4999s |  0.5140s |   60.92 MiB/s | output |
| mzML -> gzip mzML           |  1.5468s ± 0.0073s |  1.5456s |   [1.5286s, 1.5650s] |  1.5401s |  1.5546s |   48.84 MiB/s | input  |
| gzip mzML -> mzML           |  0.3560s ± 0.0016s |  0.3556s |   [0.3521s, 0.3599s] |  0.3547s |  0.3577s |  212.23 MiB/s | output |
| mzML -> zstd mzML           |  0.1718s ± 0.0013s |  0.1711s |   [0.1685s, 0.1750s] |  0.1709s |  0.1733s |  439.80 MiB/s | input  |
| zstd mzML -> mzML           |  0.0603s ± 0.0021s |  0.0595s |   [0.0550s, 0.0656s] |  0.0587s |  0.0627s | 1252.86 MiB/s | output |
| mzML -> bzip2 mzML          |  7.0310s ± 0.0418s |  7.0524s |   [6.9271s, 7.1349s] |  6.9828s |  7.0577s |   10.75 MiB/s | input  |
| bzip2 mzML -> mzML          |  2.4808s ± 0.0119s |  2.4761s |   [2.4511s, 2.5105s] |  2.4719s |  2.4944s |   30.45 MiB/s | output |
| mzML -> lz4 mzML            |  0.0990s ± 0.0006s |  0.0991s |   [0.0976s, 0.1004s] |  0.0984s |  0.0995s |  763.07 MiB/s | input  |
| lz4 mzML -> mzML            |  0.0887s ± 0.0018s |  0.0894s |   [0.0842s, 0.0933s] |  0.0866s |  0.0901s |  851.58 MiB/s | output |
| mzML -> xz mzML             |  5.6694s ± 0.0392s |  5.6880s |   [5.5721s, 5.7667s] |  5.6244s |  5.6957s |   13.33 MiB/s | input  |
| xz mzML -> mzML             |  0.3669s ± 0.0076s |  0.3657s |   [0.3479s, 0.3858s] |  0.3599s |  0.3750s |  205.94 MiB/s | output |
| dump -> mzarc lossless      |  0.2251s ± 0.0014s |  0.2259s |   [0.2216s, 0.2286s] |  0.2235s |  0.2260s |  136.71 MiB/s | input  |
| mzarc lossless -> dump      |  0.1538s ± 0.0009s |  0.1535s |   [0.1516s, 0.1561s] |  0.1532s |  0.1549s |  200.06 MiB/s | output |
| dump -> mzarc lossy q=16384 |  0.2439s ± 0.0011s |  0.2440s |   [0.2410s, 0.2467s] |  0.2427s |  0.2449s |  126.22 MiB/s | input  |
| mzarc lossy q=16384 -> dump |  0.1958s ± 0.0026s |  0.1944s |   [0.1894s, 0.2022s] |  0.1942s |  0.1988s |  157.20 MiB/s | output |
| mzML -> mzMLb               | 22.7763s ± 1.0926s | 22.2469s | [20.0620s, 25.4906s] | 22.0494s | 24.0328s |    3.32 MiB/s | input  |
| mzMLb -> dump               |  4.9235s ± 0.0212s |  4.9165s |   [4.8709s, 4.9762s] |  4.9068s |  4.9474s |    6.25 MiB/s | output |
| mzML -> MS-Numpress in mzML | 23.2022s ± 0.2521s | 23.3173s | [22.5759s, 23.8285s] | 22.9131s | 23.3762s |    3.26 MiB/s | input  |
| MS-Numpress in mzML -> dump |  6.3538s ± 0.0090s |  6.3587s |   [6.3314s, 6.3763s] |  6.3434s |  6.3594s |    4.84 MiB/s | output |
| mzML -> MScompress          |  0.7064s ± 0.0039s |  0.7085s |   [0.6968s, 0.7160s] |  0.7020s |  0.7088s |  106.95 MiB/s | input  |
| MScompress -> dump          |  7.3351s ± 0.2192s |  7.2375s |   [6.7906s, 7.8797s] |  7.1818s |  7.5862s |    4.20 MiB/s | output |
| mzML -> MScompress threaded |  0.1276s ± 0.0029s |  0.1262s |   [0.1204s, 0.1347s] |  0.1256s |  0.1309s |  592.28 MiB/s | input  |
| MScompress threaded -> dump |  5.2615s ± 0.0287s |  5.2719s |   [5.1901s, 5.3329s] |  5.2291s |  5.2836s |    5.85 MiB/s | output |

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
|   256 | 12459954 | 11.88 MiB |                3.499% |                3.813% |                 1.820% |
|  1024 | 13127097 | 12.52 MiB |                0.874% |                0.950% |                 0.455% |
|  4096 | 13794206 | 13.16 MiB |                0.218% |                0.238% |                 0.114% |
| 16384 | 14461329 | 13.79 MiB |                0.055% |                0.059% |                 0.028% |

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
