# Benchmark Report: 15HCD_1

- mzML input: data/PXD075509/15HCD_1.mzML
- private workdir: data/PXD075509/benchmarks/15HCD_1
- public output dir: benchmark
- repeats: n/a
- selected lossy intensity quantization: q=16384

## Story

mzarc is a domain-specific MS codec: it reads mass spectrometry spectra, strips the mzML interchange overhead, and applies a pipeline of delta coding, frame-of-reference packing, and rANS entropy coding tuned to the statistical structure of m/z and intensity arrays. The benchmarks are organised into three groups. MS-domain codecs (mzarc, mzMLb, MScompress, MS-Numpress) all understand spectrum structure. Generic-on-mzML rows show what you get by applying a general-purpose compressor to the standard XML interchange format. Generic-on-dump rows are an internal reference floor: the same compressors applied to the stripped binary dump, which removes XML and base64 overhead but is not a viable interchange format on its own.

External MS-domain formats that ran end-to-end in this benchmark: mzMLb, MS-Numpress in mzML, MScompress, MScompress (1T).

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
| gzip dump | 20780851 | 19.82 MiB | 26.23% | 64.39% |
| zstd dump | 18720327 | 17.85 MiB | 23.63% | 58.01% |
| bzip2 dump | 19719837 | 18.81 MiB | 24.89% | 61.10% |
| lz4 dump | 26038757 | 24.83 MiB | 32.87% | 80.68% |
| xz dump | 16535444 | 15.77 MiB | 20.87% | 51.24% |
| gzip mzML | 25465391 | 24.29 MiB | 32.14% | 78.90% |
| zstd mzML | 24770559 | 23.62 MiB | 31.27% | 76.75% |
| bzip2 mzML | 24720971 | 23.58 MiB | 31.20% | 76.60% |
| lz4 mzML | 34826833 | 33.21 MiB | 43.96% | 107.91% |
| xz mzML | 24536980 | 23.40 MiB | 30.97% | 76.03% |
| mzarc lossless | 16016009 | 15.27 MiB | 20.22% | 49.63% |
| mzarc lossy q=16384 | 13233307 | 12.62 MiB | 16.70% | 41.00% |
| pigz dump | 20731776 | 19.77 MiB | 26.17% | 64.24% |
| pigz mzML | 25395942 | 24.22 MiB | 32.06% | 78.69% |
| zstd mt dump | 18720327 | 17.85 MiB | 23.63% | 58.01% |
| zstd mt mzML | 24770559 | 23.62 MiB | 31.27% | 76.75% |
| mzMLb | 17038178 | 16.25 MiB | 21.51% | 52.79% |
| MS-Numpress in mzML | 69905308 | 66.67 MiB | 88.24% | 216.60% |
| MScompress | 22579410 | 21.53 MiB | 28.50% | 69.96% |
| MScompress (1T) | 22679622 | 21.63 MiB | 28.63% | 70.27% |

Lossless `.mzarc` is already materially smaller than mzML on this sample, and it slightly beats `gzip` on the dump baseline while still trailing `zstd` on the dump. The selected lossy mode gives a controlled next step down in size without the catastrophic saturation behavior that the earlier intensity quantizer had.

## Byte Composition

| artifact | structural bytes | spectrum metadata | m/z stream | intensity stream | total |
| --- | ---: | ---: | ---: | ---: | ---: |
| mzarc lossless | 0.04 MiB (0.24%) | 0.15 MiB (1.00%) | 6.81 MiB (44.61%) | 8.27 MiB (54.15%) | 15.27 MiB |
| mzarc lossy q=16384 | 0.04 MiB (0.29%) | 0.15 MiB (1.20%) | 7.99 MiB (63.35%) | 4.44 MiB (35.15%) | 12.62 MiB |

The lossless byte breakdown shows whether the size regression is real payload or container overhead. On this run, the intensity stream is the largest component at 8.27 MiB, which keeps the diagnosis grounded in actual encoded bytes rather than guesswork.

## Performance Overview

![Throughput Overview](plots/performance_overview.png)

| artifact | category | direction | status | throughput | median time | samples | source format | notes |
| --- | --- | --- | --- | ---: | ---: | ---: | --- | --- |
| gzip dump | Generic (on dump) | compression | measured | 12.03 MiB/s | 1.6468s | 3 | dump |  |
| gzip dump | Generic (on dump) | decompression | measured | 141.5 MiB/s | 0.21751s | 14 | gzip dump |  |
| zstd dump | Generic (on dump) | compression | measured | 92.86 MiB/s | 0.19227s | 16 | dump |  |
| zstd dump | Generic (on dump) | decompression | measured | 478.7 MiB/s | 0.064289s | 46 | zstd dump |  |
| bzip2 dump | Generic (on dump) | compression | measured | 7.075 MiB/s | 2.6583s | 3 | dump |  |
| bzip2 dump | Generic (on dump) | decompression | measured | 20.69 MiB/s | 1.4873s | 3 | bzip2 dump |  |
| lz4 dump | Generic (on dump) | compression | measured | 294.8 MiB/s | 0.084246s | 36 | dump |  |
| lz4 dump | Generic (on dump) | decompression | measured | 452.9 MiB/s | 0.067966s | 44 | lz4 dump |  |
| xz dump | Generic (on dump) | compression | measured | 1.374 MiB/s | 11.48s | 3 | dump |  |
| xz dump | Generic (on dump) | decompression | measured | 60.09 MiB/s | 0.51221s | 6 | xz dump |  |
| gzip mzML | Generic (on mzML) | compression | measured | 15.85 MiB/s | 1.5327s | 3 | mzML |  |
| gzip mzML | Generic (on mzML) | decompression | measured | 202.5 MiB/s | 0.37301s | 9 | gzip mzML |  |
| zstd mzML | Generic (on mzML) | compression | measured | 136.9 MiB/s | 0.17262s | 18 | mzML |  |
| zstd mzML | Generic (on mzML) | decompression | measured | 965 MiB/s | 0.078291s | 39 | zstd mzML |  |
| bzip2 mzML | Generic (on mzML) | compression | measured | 3.422 MiB/s | 6.8891s | 3 | mzML |  |
| bzip2 mzML | Generic (on mzML) | decompression | measured | 30.3 MiB/s | 2.4937s | 3 | bzip2 mzML |  |
| lz4 mzML | Generic (on mzML) | compression | measured | 313.7 MiB/s | 0.10586s | 29 | mzML |  |
| lz4 mzML | Generic (on mzML) | decompression | measured | 684.6 MiB/s | 0.11036s | 28 | lz4 mzML |  |
| xz mzML | Generic (on mzML) | compression | measured | 4.431 MiB/s | 5.2816s | 3 | mzML |  |
| xz mzML | Generic (on mzML) | decompression | measured | 194.6 MiB/s | 0.3882s | 8 | xz mzML |  |
| mzarc lossless | MS-domain codec | compression | measured | 51.92 MiB/s | 0.29417s | 11 | dump |  |
| mzarc lossless | MS-domain codec | decompression | measured | 155.4 MiB/s | 0.19801s | 16 | mzarc lossless |  |
| mzarc lossy q=16384 | MS-domain codec | compression | measured | 31.89 MiB/s | 0.39569s | 8 | dump |  |
| mzarc lossy q=16384 | MS-domain codec | decompression | measured | 139.4 MiB/s | 0.22072s | 14 | mzarc lossy q=16384 |  |
| pigz dump | Parallel (multi-thread) | compression | measured | 232.2 MiB/s | 0.085155s | 36 | dump |  |
| pigz dump | Parallel (multi-thread) | decompression | measured | 242.7 MiB/s | 0.1268s | 24 | pigz dump |  |
| pigz mzML | Parallel (multi-thread) | compression | measured | 234.9 MiB/s | 0.10309s | 29 | mzML |  |
| pigz mzML | Parallel (multi-thread) | decompression | measured | 428.8 MiB/s | 0.17619s | 18 | pigz mzML |  |
| zstd mt dump | Parallel (multi-thread) | compression | measured | 234.2 MiB/s | 0.076226s | 39 | dump |  |
| zstd mt dump | Parallel (multi-thread) | decompression | measured | 481.9 MiB/s | 0.063867s | 47 | zstd mt dump |  |
| zstd mt mzML | Parallel (multi-thread) | compression | measured | 302.2 MiB/s | 0.078177s | 39 | mzML |  |
| zstd mt mzML | Parallel (multi-thread) | decompression | measured | 842.1 MiB/s | 0.089717s | 31 | zstd mt mzML |  |
| mzMLb | MS-domain codec | compression | measured | 0.6856 MiB/s | 23.701s | 3 | mzML |  |
| mzMLb | MS-domain codec | decompression | measured | 5.791 MiB/s | 5.3152s | 3 | mzMLb |  |
| MS-Numpress in mzML | MS-domain codec | compression | measured | 2.755 MiB/s | 24.2s | 3 | mzML |  |
| MS-Numpress in mzML | MS-domain codec | decompression | measured | 4.803 MiB/s | 6.4076s | 3 | MS-Numpress in mzML |  |
| MScompress | MS-domain codec | compression | measured | 75.47 MiB/s | 0.28532s | 11 | mzML |  |
| MScompress | MS-domain codec | decompression | measured | 5.63 MiB/s | 5.4666s | 3 | MScompress |  |
| MScompress (1T) | MS-domain codec | compression | measured | 25.22 MiB/s | 0.85753s | 4 | mzML |  |
| MScompress (1T) | MS-domain codec | decompression | measured | 4.259 MiB/s | 7.226s | 3 | MScompress (1T) |  |

## Memory and CPU Metrics

zebrac collects Linux perf counters for each command across all samples in the measurement window. All values are medians. IPC (instructions per cycle) measures compute density: higher means the CPU is doing useful work rather than stalling on cache misses. Cache miss rate = cache_misses / cache_references; lower is better. Branch misses indicate prediction failures; a high count relative to instructions suggests data-dependent branching that limits pipelining.

![Peak RSS Comparison](plots/memory_footprint.png)

![Hardware Algorithm Efficiency](plots/hardware_efficiency.png)

| operation | wall time (med) | peak RSS (med) | instructions | IPC | cache misses | cache miss rate | cpu cycles | branch misses | n |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| mzml dump | 4.918s | 76.7 MiB | 3.17e+10 | 1.79 | 4.08e+08 | 16.571% | 1.769e+10 | 1.088e+08 | 3 |
| dump -> gzip dump | 1.647s | 1.9 MiB | 9.86e+09 | 1.65 | 7.1e+05 | 0.397% | 5.981e+09 | 5.318e+07 | 3 |
| gzip dump -> dump | 0.2175s | 1.6 MiB | 1.26e+09 | 1.82 | 1.55e+05 | 4.571% | 6.891e+08 | 4.921e+06 | 14 |
| dump -> zstd dump | 0.1923s | 45.2 MiB | 1.35e+09 | 2.15 | 3.56e+07 | 39.343% | 6.258e+08 | 2.034e+06 | 16 |
| zstd dump -> dump | 0.06429s | 6.4 MiB | 5.22e+08 | 2.86 | 9.62e+05 | 10.619% | 1.823e+08 | 5.807e+05 | 46 |
| dump -> bzip2 dump | 2.658s | 7.6 MiB | 1.91e+10 | 1.98 | 9.63e+07 | 27.126% | 9.612e+09 | 9.703e+07 | 3 |
| bzip2 dump -> dump | 1.487s | 4.9 MiB | 6.85e+09 | 1.33 | 3.67e+07 | 41.506% | 5.156e+09 | 6.188e+07 | 3 |
| dump -> lz4 dump | 0.08425s | 8.6 MiB | 5.96e+08 | 2.74 | 7.78e+04 | 0.366% | 2.175e+08 | 1.138e+06 | 36 |
| lz4 dump -> dump | 0.06797s | 8.6 MiB | 1.8e+08 | 1.5 | 3.1e+05 | 4.694% | 1.197e+08 | 4.96e+04 | 44 |
| dump -> xz dump | 11.48s | 218.5 MiB | 5.08e+10 | 0.986 | 4.22e+08 | 34.277% | 5.154e+10 | 4.053e+08 | 3 |
| xz dump -> dump | 0.5122s | 59.8 MiB | 4.5e+09 | 2.04 | 1.34e+06 | 13.705% | 2.204e+09 | 2.034e+07 | 6 |
| mzML -> gzip mzML | 1.533s | 1.9 MiB | 8.83e+09 | 1.59 | 8.2e+05 | 0.222% | 5.552e+09 | 6.862e+07 | 3 |
| gzip mzML -> mzML | 0.373s | 1.6 MiB | 1.89e+09 | 1.62 | 2.33e+05 | 3.496% | 1.167e+09 | 4.486e+06 | 9 |
| mzML -> zstd mzML | 0.1726s | 42.9 MiB | 1.15e+09 | 1.92 | 3.64e+07 | 38.789% | 6e+08 | 3.507e+06 | 18 |
| zstd mzML -> mzML | 0.07829s | 6.4 MiB | 4.67e+08 | 2.34 | 1.81e+06 | 11.893% | 1.997e+08 | 5.536e+05 | 39 |
| mzML -> bzip2 mzML | 6.889s | 7.6 MiB | 5.65e+10 | 2.25 | 3.67e+08 | 22.376% | 2.51e+10 | 2.527e+08 | 3 |
| bzip2 mzML -> mzML | 2.494s | 4.9 MiB | 9.49e+09 | 1.12 | 7.88e+07 | 41.691% | 8.487e+09 | 8.799e+07 | 3 |
| mzML -> lz4 mzML | 0.1059s | 7.8 MiB | 4.93e+08 | 1.78 | 2.25e+05 | 0.694% | 2.77e+08 | 2.784e+06 | 29 |
| lz4 mzML -> mzML | 0.1104s | 8.1 MiB | 2.27e+08 | 1.48 | 6.36e+05 | 4.619% | 1.537e+08 | 5.958e+05 | 28 |
| mzML -> xz mzML | 5.282s | 426.7 MiB | 6.27e+10 | 1.23 | 2.8e+08 | 31.589% | 5.117e+10 | 4.751e+08 | 3 |
| xz mzML -> mzML | 0.3882s | 117.0 MiB | 7.2e+09 | 2.31 | 1.93e+06 | 10.998% | 3.122e+09 | 2.033e+07 | 8 |
| dump -> mzarc lossless | 0.2942s | 89.5 MiB | 1.36e+09 | 1.79 | 6.01e+05 | 3.582% | 7.599e+08 | 3.166e+06 | 11 |
| mzarc lossless -> dump | 0.198s | 79.4 MiB | 9.25e+08 | 1.87 | 2.38e+05 | 3.188% | 4.945e+08 | 3.105e+06 | 16 |
| dump -> mzarc lossy q=16384 | 0.3957s | 79.8 MiB | 2.31e+09 | 2.01 | 5.62e+05 | 3.349% | 1.15e+09 | 3.086e+06 | 8 |
| mzarc lossy q=16384 -> dump | 0.2207s | 76.8 MiB | 1.17e+09 | 2 | 2.3e+05 | 3.244% | 5.884e+08 | 1.824e+06 | 14 |
| dump -> pigz dump | 0.08516s | 20.4 MiB | 9.49e+09 | 1.34 | 6.88e+06 | 2.506% | 7.108e+09 | 6.254e+07 | 36 |
| pigz dump -> dump | 0.1268s | 1.9 MiB | 8.13e+08 | 1.61 | 6.18e+05 | 10.897% | 5.058e+08 | 5.721e+06 | 24 |
| mzML -> pigz mzML | 0.1031s | 19.6 MiB | 8.36e+09 | 1.25 | 9.12e+06 | 1.931% | 6.674e+09 | 8.287e+07 | 29 |
| pigz mzML -> mzML | 0.1762s | 1.9 MiB | 1.3e+09 | 1.69 | 1.45e+06 | 12.246% | 7.722e+08 | 4.442e+06 | 18 |
| dump -> zstd mt dump | 0.07623s | 57.0 MiB | 1.35e+09 | 2.12 | 3.57e+07 | 39.629% | 6.345e+08 | 2.065e+06 | 39 |
| zstd mt dump -> dump | 0.06387s | 6.4 MiB | 5.22e+08 | 2.86 | 9.64e+05 | 10.639% | 1.823e+08 | 5.812e+05 | 47 |
| mzML -> zstd mt mzML | 0.07818s | 98.2 MiB | 1.15e+09 | 1.86 | 3.61e+07 | 39.504% | 6.22e+08 | 3.616e+06 | 39 |
| zstd mt mzML -> mzML | 0.08972s | 6.4 MiB | 4.67e+08 | 2.34 | 1.8e+06 | 11.877% | 1.996e+08 | 5.529e+05 | 31 |
| mzML -> mzMLb | 23.7s | 335.5 MiB | 1.41e+11 | 1.72 | 2.2e+09 | 15.653% | 8.196e+10 | 5.263e+08 | 3 |
| mzMLb -> dump | 5.315s | 182.1 MiB | 3.39e+10 | 1.81 | 4.33e+08 | 16.074% | 1.876e+10 | 1.035e+08 | 3 |
| mzML -> MS-Numpress in mzML | 24.2s | 152.8 MiB | 1.37e+11 | 1.66 | 2.48e+09 | 17.625% | 8.244e+10 | 5.495e+08 | 3 |
| MS-Numpress in mzML -> dump | 6.408s | 114.9 MiB | 3.98e+10 | 1.75 | 6.13e+08 | 20.371% | 2.271e+10 | 1.342e+08 | 3 |
| mzML -> MScompress | 0.2853s | 359.8 MiB | 4.91e+09 | 1.53 | 6.08e+07 | 30.588% | 3.198e+09 | 2.419e+07 | 11 |
| MScompress -> dump | 5.467s | 302.3 MiB | 4.55e+10 | 1.74 | 4.34e+08 | 16.485% | 2.617e+10 | 1.85e+08 | 3 |
| mzML -> MScompress (1T) | 0.8575s | 290.1 MiB | 4.89e+09 | 1.78 | 6.67e+07 | 30.999% | 2.749e+09 | 2.343e+07 | 4 |
| MScompress (1T) -> dump | 7.226s | 282.1 MiB | 4.55e+10 | 1.78 | 4.21e+08 | 16.096% | 2.559e+10 | 1.812e+08 | 3 |

## Zebrac Statistics

All internal operations are timed by zebrac, which runs each command repeatedly over a fixed duration window using Linux perf counters. Reported wall times are medians across all samples in the window. CI 95% bounds are bootstrap confidence intervals on the median, synthesised from a log-normal distribution fitted to zebrac's summary statistics.

| operation | median | stddev | CI 95% lo | CI 95% hi | IQR | min | max | n |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| mzml dump | 4.918s | 0.01393s | 4.9s | 4.927s | 0.02745s | 4.9s | 4.927s | 3 |
| dump -> gzip dump | 1.647s | 0.0005949s | 1.647s | 1.648s | 0.001138s | 1.647s | 1.648s | 3 |
| gzip dump -> dump | 0.2175s | 0.002998s | 0.2167s | 0.2203s | 0.003803s | 0.2138s | 0.2252s | 14 |
| dump -> zstd dump | 0.1923s | 0.001845s | 0.1905s | 0.1923s | 0.001673s | 0.1862s | 0.1932s | 16 |
| zstd dump -> dump | 0.06429s | 0.003141s | 0.06466s | 0.06717s | 0.005916s | 0.06022s | 0.07175s | 46 |
| dump -> bzip2 dump | 2.658s | 0.02309s | 2.645s | 2.69s | 0.04484s | 2.645s | 2.69s | 3 |
| bzip2 dump -> dump | 1.487s | 0.009946s | 1.483s | 1.502s | 0.01885s | 1.483s | 1.502s | 3 |
| dump -> lz4 dump | 0.08425s | 0.001394s | 0.0843s | 0.08516s | 0.000548s | 0.08084s | 0.08864s | 36 |
| lz4 dump -> dump | 0.06797s | 0.003892s | 0.06771s | 0.06958s | 0.002498s | 0.06297s | 0.08815s | 44 |
| dump -> xz dump | 11.48s | 0.09075s | 11.45s | 11.62s | 0.1713s | 11.45s | 11.62s | 3 |
| xz dump -> dump | 0.5122s | 0.003576s | 0.5087s | 0.513s | 0.007438s | 0.5053s | 0.5155s | 6 |
| mzML -> gzip mzML | 1.533s | 0.003374s | 1.531s | 1.538s | 0.006377s | 1.531s | 1.538s | 3 |
| gzip mzML -> mzML | 0.373s | 0.004181s | 0.3707s | 0.3781s | 0.007775s | 0.3684s | 0.3808s | 9 |
| mzML -> zstd mzML | 0.1726s | 0.001172s | 0.1722s | 0.1736s | 0.001339s | 0.1714s | 0.1759s | 18 |
| zstd mzML -> mzML | 0.07829s | 0.003923s | 0.0773s | 0.07952s | 0.003051s | 0.07527s | 0.09894s | 39 |
| mzML -> bzip2 mzML | 6.889s | 0.00369s | 6.886s | 6.894s | 0.007319s | 6.886s | 6.894s | 3 |
| bzip2 mzML -> mzML | 2.494s | 0.06364s | 2.493s | 2.604s | 0.1106s | 2.493s | 2.604s | 3 |
| mzML -> lz4 mzML | 0.1059s | 0.003533s | 0.1043s | 0.1082s | 0.004642s | 0.1019s | 0.1181s | 29 |
| lz4 mzML -> mzML | 0.1104s | 0.002411s | 0.1097s | 0.1118s | 0.002249s | 0.1074s | 0.1165s | 28 |
| mzML -> xz mzML | 5.282s | 0.08613s | 5.137s | 5.29s | 0.1532s | 5.137s | 5.29s | 3 |
| xz mzML -> mzML | 0.3882s | 0.00451s | 0.3836s | 0.3914s | 0.006651s | 0.383s | 0.3957s | 8 |
| dump -> mzarc lossless | 0.2942s | 0.001574s | 0.2937s | 0.2955s | 0.003142s | 0.2926s | 0.2978s | 11 |
| mzarc lossless -> dump | 0.198s | 0.001434s | 0.1975s | 0.1989s | 0.001742s | 0.1968s | 0.2021s | 16 |
| dump -> mzarc lossy q=16384 | 0.3957s | 0.0006242s | 0.3953s | 0.3964s | 0.0008753s | 0.395s | 0.3971s | 8 |
| mzarc lossy q=16384 -> dump | 0.2207s | 0.001554s | 0.2199s | 0.2217s | 0.001166s | 0.218s | 0.2244s | 14 |
| dump -> pigz dump | 0.08516s | 0.002599s | 0.08488s | 0.08649s | 0.002354s | 0.08031s | 0.09676s | 36 |
| pigz dump -> dump | 0.1268s | 0.002099s | 0.125s | 0.127s | 0.000652s | 0.1172s | 0.1283s | 24 |
| mzML -> pigz mzML | 0.1031s | 0.01406s | 0.09615s | 0.1116s | 0.01024s | 0.09202s | 0.1683s | 29 |
| pigz mzML -> mzML | 0.1762s | 0.008234s | 0.1715s | 0.1815s | 0.003065s | 0.1565s | 0.2028s | 18 |
| dump -> zstd mt dump | 0.07623s | 0.005009s | 0.07555s | 0.07837s | 0.001959s | 0.07214s | 0.0995s | 39 |
| zstd mt dump -> dump | 0.06387s | 0.003105s | 0.06318s | 0.06549s | 0.001756s | 0.05355s | 0.07354s | 47 |
| mzML -> zstd mt mzML | 0.07818s | 0.001976s | 0.07761s | 0.07873s | 0.003655s | 0.07558s | 0.08281s | 39 |
| zstd mt mzML -> mzML | 0.08972s | 0.02388s | 0.08682s | 0.1036s | 0.04719s | 0.05813s | 0.1415s | 31 |
| mzML -> mzMLb | 23.7s | 0.04895s | 23.64s | 23.74s | 0.09681s | 23.64s | 23.74s | 3 |
| mzMLb -> dump | 5.315s | 0.004061s | 5.314s | 5.322s | 0.007515s | 5.314s | 5.322s | 3 |
| mzML -> MS-Numpress in mzML | 24.2s | 0.2537s | 23.9s | 24.41s | 0.5047s | 23.9s | 24.41s | 3 |
| MS-Numpress in mzML -> dump | 6.408s | 0.06376s | 6.374s | 6.497s | 0.1234s | 6.374s | 6.497s | 3 |
| mzML -> MScompress | 0.2853s | 0.003996s | 0.2838s | 0.2885s | 0.007373s | 0.2808s | 0.2941s | 11 |
| MScompress -> dump | 5.467s | 0.0119s | 5.446s | 5.467s | 0.02079s | 5.446s | 5.467s | 3 |
| mzML -> MScompress (1T) | 0.8575s | 0.01328s | 0.8662s | 0.8733s | 0.02659s | 0.8561s | 0.8833s | 4 |
| MScompress (1T) -> dump | 7.226s | 0.004333s | 7.224s | 7.233s | 0.008213s | 7.224s | 7.233s | 3 |

## Statistical Comparisons

Mann-Whitney U tests compare mzarc lossless encode wall-time distributions against each general-purpose codec baseline. Wilcoxon signed-rank test compares mzarc encode vs decode. Distributions are synthesised from zebrac summary statistics via log-normal sampling (log-normal is appropriate for execution-time data). p-values below 0.05 are considered significant.

![Speed Ratio: mzarc vs Baselines](plots/stat_comparisons.png)

| operation A | operation B | type | speed ratio | p-value | significant |
| --- | --- | --- | ---: | ---: | --- |
| dump -> mzarc lossless | dump -> gzip dump | encode_vs_baseline | 0.178 | 0.005495 | yes |
| dump -> mzarc lossless | dump -> zstd dump | encode_vs_baseline | 1.54 | 1.576e-05 | yes |
| dump -> mzarc lossless | mzarc lossless -> dump | encode_vs_decode | n/a | 1.135e-83 | yes |

## External Baselines

| baseline | status | size | encode | decode | notes |
| --- | --- | ---: | --- | --- | --- |
| mzMLb | measured | 16.25 MiB | mzML -> mzMLb | mzMLb -> dump |  |
| MS-Numpress in mzML | measured | 66.67 MiB | mzML -> MS-Numpress in mzML | MS-Numpress in mzML -> dump |  |
| MScompress | measured | 21.53 MiB | mzML -> MScompress | MScompress -> dump |  |
| MScompress (1T) | measured | 21.63 MiB | mzML -> MScompress (1T) | MScompress (1T) -> dump |  |

## Data Fidelity

![Data Fidelity Overview](plots/fidelity_overview.png)

| artifact | status | global order | max abs m/z | max ppm m/z | mean abs intensity | max abs intensity | p95 rel intensity | notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| mzarc lossless | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| mzarc lossy q=16384 | measured | true | 1.00000011e-06 | 0.00746008 | 173.700907 | 537856 | 0.055% |  |
| mzMLb | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| MScompress | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| MScompress (1T) | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| MS-Numpress in mzML | measured | true | 2.37443714e-07 | 0.00140354 | 41.5276661 | 191744 | 0.012% |  |
| gzip dump | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| zstd dump | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| bzip2 dump | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| lz4 dump | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| xz dump | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| pigz dump | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |
| zstd mt dump | measured | true | 0 | 0 | 0 | 0 | 0.000% |  |

## Fidelity Summary

| artifact | global order | ms1 order | ms2 order | mean abs mz | max abs mz | max ppm mz | mean abs intensity | rmse intensity | p95 rel intensity | p99 rel intensity | mean abs log1p intensity |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| gzip dump | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| zstd dump | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| bzip2 dump | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| lz4 dump | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| xz dump | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| mzarc lossless | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| mzarc lossy q=16384 | true | true | true | 5.00068204e-07 | 1.00000011e-06 | 0.00746008 | 173.700907 | 2607.53484 | 0.055% | 0.059% | 0.000284144487 |
| pigz dump | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| zstd mt dump | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| mzMLb | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| MS-Numpress in mzML | true | true | true | 4.70575714e-08 | 2.37443714e-07 | 0.00140354 | 41.5276661 | 690.149717 | 0.012% | 0.014% | 5.85200344e-05 |
| MScompress | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |
| MScompress (1T) | true | true | true | 0 | 0 | 0 | 0 | 0 | 0.000% | 0.000% | 0 |

On the current run, `mzarc lossless`, `mzMLb`, `MScompress`, `MScompress (1T)`, `gzip dump`, `zstd dump`, `bzip2 dump`, `lz4 dump`, `xz dump`, `pigz dump` and `zstd mt dump` round-trip exactly. `mzarc lossless` round-trips exactly, including m/z values and original scan order. `mzarc lossy` preserves original scan order while keeping m/z and intensity error within the current quantization bounds.

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
| mzarc lossless | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| mzarc lossy q=16384 | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. |
| mzMLb | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| MScompress | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| MScompress (1T) | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| MS-Numpress in mzML | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. |
| gzip mzML | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. |
| zstd mzML | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. |
| bzip2 mzML | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. |
| lz4 mzML | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. |
| xz mzML | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. |
| pigz mzML | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. |
| zstd mt mzML | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. |
| gzip dump | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| zstd dump | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| bzip2 dump | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| lz4 dump | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| xz dump | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| pigz dump | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |
| zstd mt dump | not-measured | n/a | n/a | n/a | Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra. Dump round-trip was numerically exact on the current comparison. |

Search-impact metrics are not measured by the current benchmark pipeline yet. They remain listed here so the report does not imply numerical equivalence where no downstream search experiment has actually been run.

## How The Error Numbers Are Computed

The reported means are computed over every matched peak after round-trip decode. They are not inferred from min and max.

- Mean absolute error: average absolute per-peak error.
- RMSE: square root of the average squared per-peak error.
- Relative intensity error: absolute error divided by the original intensity, evaluated only on strictly positive peaks.
- log1p intensity error: absolute error after applying `log1p`, which keeps the metric useful across large dynamic range.

## Future Comparison Candidates

All named comparison candidates are wired into the current benchmark run in some form.
