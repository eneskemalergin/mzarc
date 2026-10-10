<!-- markdownlint-disable MD024 -->

# Reference compression benchmark

This report measures one mzML file three ways: lossless compression of its Dump V1 spectra, lossless compression of the original document, and the mzarc lossy profiles. Compare methods only within one section, because the inputs and validation contracts differ.

## Key findings

- **Dump V1:** `mzarc lossless` writes 14.46 MiB (46.99% of the input), 8.22% smaller than the smallest byte-exact peer, `xz -6 -T1` (15.76 MiB).
  Encode: 214.86 MiB/s, rank 2 of 8 rows; the fastest single-threaded peer is `zstd -3 --single-thread` at 129.80 MiB/s and the fastest peer overall is `zstd -3 -T4 [P]` at 345.06 MiB/s. Decode: 162.05 MiB/s, rank 6 of 8; the fastest is `zstd -3 --single-thread` at 427.85 MiB/s. Peak RSS: 8.68 MiB encode and 6.87 MiB decode; the lowest peers are `gzip -6` (1.90 MiB) and `gzip -6` (1.62 MiB).
- **Original mzML:** `mzarc exact` writes 24.00 MiB (31.77% of the input), 2.62% larger than the smallest byte-exact peer, `xz -6 -T1` (23.39 MiB). `MScompress -t4 [P]` writes 21.62 MiB but is validated as Dump V1 exact.
  Encode: 110.07 MiB/s, rank 6 of 10 rows; the fastest single-threaded peer is `zstd -3 --single-thread` at 325.75 MiB/s and the fastest peer overall is `zstd -3 -T4 [P]` at 814.41 MiB/s. Decode: 492.00 MiB/s, rank 3 of 10; the fastest is `zstd -3 --single-thread` at 909.99 MiB/s. Peak RSS: 1.04 MiB encode and 1.04 MiB decode; the lowest peers are `gzip -6` (1.82 MiB) and `gzip -6` (1.63 MiB).
- **Lossy:** the mzML lossy archive is 20.10% of the original document, 36.75% smaller than the exact archive; the Dump V1 lossy archive is 41.14% of its input, 12.45% smaller than the lossless archive. Largest observed errors: m/z 0.000001000000 Da and log1p intensity 0.000642643 (mzML), m/z 0.000001000000 Da and log1p intensity 0.000644625 (Dump V1), against a format-wide log1p limit of 0.005415332.

## Run context

- Source: `<data root>/PXD075509/15HCD_1.mzML`
- Source shape: 9001 spectra; 2668458 peaks; 917 MS1 and 8084 MS2 spectra
- Measured: 2026-10-10T09:05:35-07:00
- Host: AMD Ryzen 9 3950X 16-Core Processor; Linux 7.2.8-200.fc44.x86_64 x86_64 GNU/Linux
- CPU frequency governor: schedutil
- Load average (1, 5, 15 min): 3.73 4.43 4.92 before the build, 7.33 7.10 6.08 after the last measurement
- mzarc build: stripped ReleaseFast, single-threaded
- Sampling: 5 measurements per operation after one warmup
- Parallel rows: 4 workers, marked `[P]`; direction-specific behavior remains in the tables
- Execution: each operation is measured independently; files are reused after untimed validation and one warmup
- Timing: median wall time with its interquartile range (IQR); throughput is uncompressed input bytes divided by the median
- Peak RSS: median zebrac direct-child RSS
- Spread: 10 of 40 operations have an IQR above 5% of their median (largest: `zstd -3 -T4 [P]` encode 35.8%, `pigz -6 -p4 [P]` encode 17.7%, `mzarc exact` encode 10.1%); compare those timings only after a repeat run

## Input size context

| Representation                      |    Bytes |   MiB | Representation / original mzML |
| ----------------------------------- | -------: | ----: | -----------------------------: |
| Original mzML                       | 79221306 | 75.55 |                        100.00% |
| mzarc exact archive of the document | 25170444 | 24.00 |                         31.77% |
| mzarc lossy archive of the document | 15921390 | 15.18 |                         20.10% |
| Dump V1 retained fields             | 32273524 | 30.78 |                         40.74% |
| mzarc lossless archive of Dump V1   | 15165670 | 14.46 |                         19.14% |
| mzarc lossy archive of Dump V1      | 13277057 | 12.66 |                         16.76% |

The document archives restore the whole mzML file: exactly, or with only spectrum m/z and intensity values changed within their bounds. The Dump V1 archives restore only the spectrum fields Dump V1 keeps.

## mzML ingest

Converting the original mzML to Dump V1 with `mzarc dump`. Its output is checked byte for byte against the dump every Dump V1 row starts from.

| Step         | Output bytes | Median (ms) | IQR (ms) | mzML MiB/s | Peak RSS (MiB) |
| ------------ | -----------: | ----------: | -------: | ---------: | -------------: |
| `mzarc dump` |     32273524 |     445.216 |   10.319 |     169.70 |           1.04 |

## Dump V1 round trip

Comparison input: Dump V1, 30.78 MiB (32273524 bytes).

![Dump V1 round trip summary](dump-summary.svg)

### Artifact

| Method                  | Threads (encode / decode) | Validation | Artifact bytes | Artifact / Dump V1 |
| ----------------------- | ------------------------- | ---------- | -------------: | -----------------: |
| mzarc lossless          | single / single           | byte exact |       15165670 |             46.99% |
| gzip -6                 | single / single           | byte exact |       20780851 |             64.39% |
| pigz -6 -p1             | single / single           | byte exact |       20707631 |             64.16% |
| pigz -6 -p4 [P]         | fixed-4 / fixed-4 helpers | byte exact |       20707632 |             64.16% |
| zstd -3 --single-thread | single / single           | byte exact |       18710563 |             57.97% |
| zstd -3 -T4 [P]         | fixed-4 / single          | byte exact |       18659882 |             57.82% |
| xz -6 -T1               | single / single           | byte exact |       16524524 |             51.20% |
| xz -6 -T4 [P]           | fixed-4 / fixed-4         | byte exact |       16535444 |             51.24% |

### Encode

| Method                  | Median (ms) | IQR (ms) | IQR / median |  MiB/s | Peak RSS (MiB) |
| ----------------------- | ----------: | -------: | -----------: | -----: | -------------: |
| mzarc lossless          |     143.248 |    1.175 |         0.8% | 214.86 |           8.68 |
| gzip -6                 |    1576.862 |    9.727 |         0.6% |  19.52 |           1.90 |
| pigz -6 -p1             |    1360.605 |   23.759 |         1.7% |  22.62 |           2.85 |
| pigz -6 -p4 [P]         |     366.212 |    8.070 |         2.2% |  84.05 |           4.85 |
| zstd -3 --single-thread |     237.118 |   15.746 |         6.6% | 129.80 |           5.44 |
| zstd -3 -T4 [P]         |      89.197 |   31.964 |        35.8% | 345.06 |          54.19 |
| xz -6 -T1               |   16852.000 |  851.716 |         5.1% |   1.83 |          93.91 |
| xz -6 -T4 [P]           |   13268.435 |  209.321 |         1.6% |   2.32 |         218.10 |

### Decode

| Method                  | Median (ms) | IQR (ms) | IQR / median |  MiB/s | Peak RSS (MiB) |
| ----------------------- | ----------: | -------: | -----------: | -----: | -------------: |
| mzarc lossless          |     189.926 |    7.601 |         4.0% | 162.05 |           6.87 |
| gzip -6                 |     139.223 |    1.928 |         1.4% | 221.07 |           1.62 |
| pigz -6 -p1             |     140.088 |    4.432 |         3.2% | 219.71 |           2.16 |
| pigz -6 -p4 [P]         |     133.014 |    1.118 |         0.8% | 231.39 |           2.17 |
| zstd -3 --single-thread |      71.937 |    2.863 |         4.0% | 427.85 |           4.64 |
| zstd -3 -T4 [P]         |      73.887 |    2.131 |         2.9% | 416.56 |           4.64 |
| xz -6 -T1               |     646.581 |    5.983 |         0.9% |  47.60 |          10.09 |
| xz -6 -T4 [P]           |     509.485 |    6.404 |         1.3% |  60.41 |          59.42 |

## Original mzML round trip

Comparison input: original mzML, 75.55 MiB (79221306 bytes).

![Original mzML round trip summary](mzml-summary.svg)

### Artifact

| Method                  | Threads (encode / decode) | Validation    | Artifact bytes | Artifact / original mzML |
| ----------------------- | ------------------------- | ------------- | -------------: | -----------------------: |
| mzarc exact             | single / single           | byte exact    |       25170444 |                   31.77% |
| gzip -6                 | single / single           | byte exact    |       25465391 |                   32.14% |
| pigz -6 -p1             | single / single           | byte exact    |       25247634 |                   31.87% |
| pigz -6 -p4 [P]         | fixed-4 / fixed-4 helpers | byte exact    |       25247634 |                   31.87% |
| zstd -3 --single-thread | single / single           | byte exact    |       24773401 |                   31.27% |
| zstd -3 -T4 [P]         | fixed-4 / single          | byte exact    |       24761059 |                   31.26% |
| xz -6 -T1               | single / single           | byte exact    |       24527740 |                   30.96% |
| xz -6 -T4 [P]           | fixed-4 / fixed-4         | byte exact    |       24536980 |                   30.97% |
| MScompress -t1          | single / single           | Dump V1 exact |       22679622 |                   28.63% |
| MScompress -t4 [P]      | fixed-4 / fixed-4         | Dump V1 exact |       22670580 |                   28.62% |

### Encode

| Method                  | Median (ms) | IQR (ms) | IQR / median |  MiB/s | Peak RSS (MiB) |
| ----------------------- | ----------: | -------: | -----------: | -----: | -------------: |
| mzarc exact             |     686.374 |   69.404 |        10.1% | 110.07 |           1.04 |
| gzip -6                 |    1301.338 |   26.862 |         2.1% |  58.06 |           1.82 |
| pigz -6 -p1             |     667.380 |   59.517 |         8.9% | 113.21 |           2.84 |
| pigz -6 -p4 [P]         |     191.462 |   33.835 |        17.7% | 394.60 |           4.66 |
| zstd -3 --single-thread |     231.929 |    9.567 |         4.1% | 325.75 |           5.39 |
| zstd -3 -T4 [P]         |      92.768 |    6.537 |         7.0% | 814.41 |          74.95 |
| xz -6 -T1               |   16144.040 |  704.087 |         4.4% |   4.68 |          93.91 |
| xz -6 -T4 [P]           |    6098.549 |  534.513 |         8.8% |  12.39 |         426.39 |
| MScompress -t1          |     915.886 |   25.829 |         2.8% |  82.49 |         253.64 |
| MScompress -t4 [P]      |     378.941 |   34.761 |         9.2% | 199.38 |         271.93 |

### Decode

| Method                  | Median (ms) | IQR (ms) | IQR / median |  MiB/s | Peak RSS (MiB) |
| ----------------------- | ----------: | -------: | -----------: | -----: | -------------: |
| mzarc exact             |     153.560 |    0.793 |         0.5% | 492.00 |           1.04 |
| gzip -6                 |     180.532 |    6.077 |         3.4% | 418.49 |           1.63 |
| pigz -6 -p1             |     173.556 |    3.285 |         1.9% | 435.31 |           2.16 |
| pigz -6 -p4 [P]         |     155.869 |    2.738 |         1.8% | 484.71 |           2.16 |
| zstd -3 --single-thread |      83.025 |    2.323 |         2.8% | 909.99 |           4.68 |
| zstd -3 -T4 [P]         |      86.180 |    1.886 |         2.2% | 876.67 |           4.68 |
| xz -6 -T1               |     954.097 |   27.684 |         2.9% |  79.19 |          10.09 |
| xz -6 -T4 [P]           |     378.785 |   20.370 |         5.4% | 199.46 |         116.39 |
| MScompress -t1          |    5795.234 |   42.807 |         0.7% |  13.04 |         255.86 |
| MScompress -t4 [P]      |    2053.692 |   25.414 |         1.2% |  36.79 |         213.76 |

## Lossy archives

### Artifact

| Method                      | Threads (encode / decode) | Validation           | Artifact bytes | Artifact / its input |
| --------------------------- | ------------------------- | -------------------- | -------------: | -------------------: |
| mzarc lossy (Dump V1 input) | single / single           | Dump V1 lossy bounds |       13277057 |               41.14% |
| mzarc lossy (mzML input)    | single / single           | mzML lossy bounds    |       15921390 |               20.10% |

### Encode

| Method                      | Median (ms) | IQR (ms) | IQR / median |  MiB/s | Peak RSS (MiB) |
| --------------------------- | ----------: | -------: | -----------: | -----: | -------------: |
| mzarc lossy (Dump V1 input) |     207.054 |    1.971 |         1.0% | 148.65 |           9.51 |
| mzarc lossy (mzML input)    |    1404.563 |   33.499 |         2.4% |  53.79 |           2.33 |

### Decode

| Method                      | Median (ms) | IQR (ms) | IQR / median |  MiB/s | Peak RSS (MiB) |
| --------------------------- | ----------: | -------: | -----------: | -----: | -------------: |
| mzarc lossy (Dump V1 input) |     179.872 |    0.894 |         0.5% | 171.11 |           6.87 |
| mzarc lossy (mzML input)    |     892.515 |    6.997 |         0.8% |  84.65 |           1.54 |

Observed errors, from `mzarc validate` after the timed runs:

| Method                      | Arrays transformed | Max m/z error (Da) | Max log1p intensity error | Format-wide log1p limit |
| --------------------------- | -----------------: | -----------------: | ------------------------: | ----------------------: |
| mzarc lossy (Dump V1 input) |        every array |     0.000001000000 |               0.000644625 |             0.005415332 |
| mzarc lossy (mzML input)    |     18002 of 18007 |     0.000001000000 |               0.000642643 |             0.005415332 |

The mzML profile keeps an array exact when the profile cannot hold it: 32-bit m/z, unsupported compression, negative or non-finite intensity. Errors are measured over the transformed values.

## Validation boundaries

- mzarc lossless, gzip, pigz, zstd, and xz reproduce their Dump V1 input byte for byte.
- mzarc exact, gzip, pigz, zstd, and xz reproduce the original mzML document byte for byte.
- MScompress reproduces the fields retained by Dump V1 here, not necessarily the original document bytes. Its decoded mzML is converted through the same Dump V1 converter and compared byte for byte with the source dump.
- mzarc lossy (Dump V1 input) passes `mzarc validate --mode=lossy`: metadata exact, every m/z equal to its quantized value, and intensity within the format-wide log1p limit.
- mzarc lossy (mzML input) passes `mzarc validate --mode=mzml-lossy` on the Dump V1 of its decoded document: every peak is unchanged or carries the same transform within the same limit. The archive format restores every other document byte; the test suite and the release sweep check that.

## Limits

- This report covers one file and one acquisition shape. It does not establish performance or RSS behavior across the broader corpus.
- Lossy rows are not comparable with the lossless and exact rows; they trade bounded spectrum error for size.
- The runner does not clear filesystem caches, randomize operation order, isolate CPUs, or control system load and CPU frequency. The load average and spread lines above show how quiet the run was.
- Wall time and RSS are measurements from one host, not portable guarantees.

## Tool versions

- mzarc: `v0.3.0` at `9b1d0f4`
- Build: Zig `0.16.0`; stripped ReleaseFast; single-threaded
- Ingest and mzML reading: `mzarc dump` on zmz `a44765e`
- Measurement: `zebrac 0.6.2`
- Compression peers: `gzip 1.14`; `pigz 2.8`; `zstd 1.5.7`; `xz 5.8.2`; `MScompress 1.0.16`
- Report generation: `jq-1.8.1`; `gnuplot 6.0.3 patchlevel 3`

## Machine-readable rows

The full-precision rows are retained beside this report for direct local comparisons; the tables above are rounded. Every zebrac result is in `zebrac/`.

- [dump.tsv](dump.tsv), [mzml.tsv](mzml.tsv), and [lossy.tsv](lossy.tsv): method, thread class, validation, artifact bytes, artifact percentage of input, encode median ms, encode IQR ms, encode MiB/s, encode RSS MiB, decode median ms, decode IQR ms, decode MiB/s, decode RSS MiB, encode mean ms, encode SD ms, decode mean ms, decode SD ms, encode median instructions, decode median instructions, and input bytes.
- [lossy-errors.tsv](lossy-errors.tsv): method, max m/z error in Da, max log1p intensity error, the format-wide log1p limit, and the arrays transformed.
- [ingest.tsv](ingest.tsv): step, output bytes, median ms, IQR ms, mzML MiB/s, peak RSS MiB, and median instructions.
