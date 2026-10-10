<!-- markdownlint-disable MD024 -->

# Reference compression benchmark

This report compares lossless compression of one mzML-derived Dump V1 input and the original mzML document. Compare methods only within the same input section because the inputs and validation contracts differ.

## Key findings

- mzarc produces a 14.46 MiB artifact from the Dump V1 input (46.99% of input), 8.22% smaller than the next-smallest single-threaded byte-exact row, xz `-6 -T1`.
- mzarc is the fastest single-threaded Dump V1 encoder at 221.72 MiB/s. The fixed-4 zstd row leads overall encode at 363.31 MiB/s. zstd records 438.53 MiB/s decode for the single-thread artifact and 423.11 MiB/s for the fixed-4 artifact; both decode operations are single-threaded.
- mzarc peak RSS is 8.71 MiB for encode and 6.52 MiB for decode on this file. gzip records the lowest values in the Dump V1 table at 1.85 MiB and 1.62 MiB.
- On original mzML, MScompress `-t4` writes the smallest artifact at 28.62% but is validated as Dump V1 exact. xz `-6 -T1` is the smallest document-byte-exact row at 30.96%. The fixed-4 zstd row records 813.67 MiB/s encode; its single-threaded decode records 867.92 MiB/s.

## Run context

- Source: `<data root>/PXD075509/15HCD_1.mzML`
- Source shape: 9001 spectra; 2668458 peaks; 917 MS1 and 8084 MS2 spectra
- Measured: 2026-10-10T05:09:47-07:00
- Host: AMD Ryzen 9 3950X 16-Core Processor; Linux 7.2.8-200.fc44.x86_64 x86_64 GNU/Linux
- mzarc build: stripped ReleaseFast, single-threaded
- Sampling: 5 measurements per operation after one warmup
- Parallel rows: 4 workers, marked `[P]`; direction-specific behavior remains in the tables
- Execution: each operation is measured independently; files are reused after untimed validation and one warmup
- Throughput: uncompressed input bytes divided by mean wall time
- Peak RSS: median zebrac direct-child RSS

## Input size context

| Representation          |    Bytes |   MiB | Representation / original mzML |
| ----------------------- | -------: | ----: | -----------------------------: |
| Original mzML           | 79221306 | 75.55 |                        100.00% |
| Dump V1 retained fields | 32273524 | 30.78 |                         40.74% |
| mzarc lossless          | 15165670 | 14.46 |                         19.14% |

The mzarc percentage against original mzML describes the current mzML-to-Dump-V1-to-mzarc storage path. mzarc reads Dump V1 and does not reproduce the original mzML document.

## Dump V1 round trip

Comparison input: Dump V1, 30.78 MiB (32273524 bytes).

![Dump V1 round trip summary](dump-summary.svg)

### Artifact

| Method                  | Threads (encode / decode) | Validation | Artifact bytes | Artifact / Dump V1 |
| ----------------------- | ------------------------- | ---------- | -------------: | -----------------: |
| mzarc lossless          | single / single           | byte exact |       15165670 |             46.99% |
| gzip -6                 | single / single           | byte exact |       20780851 |             64.39% |
| pigz -6 -p1             | single / single           | byte exact |       20707631 |             64.16% |
| pigz -6 -p4 [P]         | fixed-4 / fixed-4 helpers | byte exact |       20707622 |             64.16% |
| zstd -3 --single-thread | single / single           | byte exact |       18710563 |             57.97% |
| zstd -3 -T4 [P]         | fixed-4 / single          | byte exact |       18659882 |             57.82% |
| xz -6 -T1               | single / single           | byte exact |       16524524 |             51.20% |
| xz -6 -T4 [P]           | fixed-4 / fixed-4         | byte exact |       16535444 |             51.24% |

### Encode

| Method                  |      Mean ± SD (ms) |  MiB/s | Peak RSS (MiB) |
| ----------------------- | ------------------: | -----: | -------------: |
| mzarc lossless          |     138.819 ± 3.551 | 221.72 |           8.71 |
| gzip -6                 |    1577.683 ± 5.320 |  19.51 |           1.85 |
| pigz -6 -p1             |    1345.227 ± 4.325 |  22.88 |           2.85 |
| pigz -6 -p4 [P]         |     356.258 ± 7.556 |  86.39 |           4.98 |
| zstd -3 --single-thread |    236.077 ± 10.448 | 130.37 |           5.64 |
| zstd -3 -T4 [P]         |      84.716 ± 6.383 | 363.31 |          54.18 |
| xz -6 -T1               | 16351.090 ± 331.230 |   1.88 |          94.16 |
| xz -6 -T4 [P]           | 13982.210 ± 681.364 |   2.20 |         218.14 |

### Decode

| Method                  |  Mean ± SD (ms) |  MiB/s | Peak RSS (MiB) |
| ----------------------- | --------------: | -----: | -------------: |
| mzarc lossless          | 191.755 ± 8.909 | 160.51 |           6.52 |
| gzip -6                 | 138.417 ± 0.858 | 222.36 |           1.62 |
| pigz -6 -p1             | 139.526 ± 1.837 | 220.59 |           2.16 |
| pigz -6 -p4 [P]         | 132.867 ± 1.406 | 231.65 |           2.10 |
| zstd -3 --single-thread |  70.186 ± 1.243 | 438.53 |           4.64 |
| zstd -3 -T4 [P]         |  72.744 ± 1.007 | 423.11 |           4.64 |
| xz -6 -T1               | 643.515 ± 4.170 |  47.83 |          10.10 |
| xz -6 -T4 [P]           | 522.805 ± 6.733 |  58.87 |          59.52 |

## Original mzML round trip

Comparison input: original mzML, 75.55 MiB (79221306 bytes).

![Original mzML round trip summary](mzml-summary.svg)

### Artifact

| Method                  | Threads (encode / decode) | Validation    | Artifact bytes | Artifact / original mzML |
| ----------------------- | ------------------------- | ------------- | -------------: | -----------------------: |
| gzip -6                 | single / single           | byte exact    |       25465391 |                   32.14% |
| pigz -6 -p1             | single / single           | byte exact    |       25247634 |                   31.87% |
| pigz -6 -p4 [P]         | fixed-4 / fixed-4 helpers | byte exact    |       25247637 |                   31.87% |
| zstd -3 --single-thread | single / single           | byte exact    |       24773401 |                   31.27% |
| zstd -3 -T4 [P]         | fixed-4 / single          | byte exact    |       24761059 |                   31.26% |
| xz -6 -T1               | single / single           | byte exact    |       24527740 |                   30.96% |
| xz -6 -T4 [P]           | fixed-4 / fixed-4         | byte exact    |       24536980 |                   30.97% |
| MScompress -t1          | single / single           | Dump V1 exact |       22679622 |                   28.63% |
| MScompress -t4 [P]      | fixed-4 / fixed-4         | Dump V1 exact |       22670580 |                   28.62% |

### Encode

| Method                  |      Mean ± SD (ms) |  MiB/s | Peak RSS (MiB) |
| ----------------------- | ------------------: | -----: | -------------: |
| gzip -6                 |    1296.320 ± 5.135 |  58.28 |           1.87 |
| pigz -6 -p1             |     673.893 ± 4.170 | 112.11 |           2.97 |
| pigz -6 -p4 [P]         |     197.297 ± 8.777 | 382.93 |           4.67 |
| zstd -3 --single-thread |     231.382 ± 2.837 | 326.52 |           5.39 |
| zstd -3 -T4 [P]         |      92.852 ± 4.670 | 813.67 |          74.64 |
| xz -6 -T1               | 15927.644 ± 310.909 |   4.74 |          94.17 |
| xz -6 -T4 [P]           |  5863.070 ± 158.546 |  12.89 |         426.60 |
| MScompress -t1          |     918.459 ± 6.302 |  82.26 |         254.36 |
| MScompress -t4 [P]      |    378.867 ± 13.703 | 199.41 |         271.93 |

### Decode

| Method                  |    Mean ± SD (ms) |  MiB/s | Peak RSS (MiB) |
| ----------------------- | ----------------: | -----: | -------------: |
| gzip -6                 |   183.016 ± 3.899 | 412.81 |           1.60 |
| pigz -6 -p1             |   174.040 ± 1.529 | 434.10 |           2.16 |
| pigz -6 -p4 [P]         |   153.528 ± 0.895 | 492.10 |           2.16 |
| zstd -3 --single-thread |    84.556 ± 0.955 | 893.51 |           4.69 |
| zstd -3 -T4 [P]         |    87.049 ± 2.234 | 867.92 |           4.69 |
| xz -6 -T1               |  929.020 ± 10.823 |  81.32 |           9.85 |
| xz -6 -T4 [P]           |  391.056 ± 14.872 | 193.20 |         116.75 |
| MScompress -t1          | 5830.040 ± 28.969 |  12.96 |         255.95 |
| MScompress -t4 [P]      | 2159.739 ± 38.859 |  34.98 |         214.33 |

## Validation boundaries

- mzarc, gzip, pigz, zstd, and xz reproduce their Dump V1 input byte for byte.
- gzip, pigz, zstd, and xz reproduce the original mzML document byte for byte.
- MScompress reproduces the fields retained by Dump V1 here, not necessarily the original document bytes. Its decoded mzML is converted through the same Dump V1 converter and compared byte for byte with the source dump.

## Limits

- This report covers one file and one acquisition shape. It does not establish performance or RSS behavior across the broader corpus.
- mzarc currently starts from Dump V1. The original mzML section therefore has no mzarc row.
- The runner does not clear filesystem caches, randomize operation order, isolate CPUs, or control system load and CPU frequency.
- Wall time and RSS are measurements from one host, not portable guarantees.

## Tool versions

- mzarc: `v0.3.0` at `7921148`
- Build: Zig `0.16.0`; stripped ReleaseFast; single-threaded
- Ingest: `mzarc dump` on zmz `a44765e`
- Measurement: `zebrac 0.6.2`
- Compression peers: `gzip 1.14`; `pigz 2.8`; `zstd 1.5.7`; `xz 5.8.2`; `MScompress 1.0.16`
- Report generation: `jq-1.8.1`; `gnuplot 6.0.3 patchlevel 3`

## Machine-readable rows

The full-precision Dump V1 rows are retained in [dump.tsv](dump.tsv) for direct local comparisons. The reader-facing tables above are rounded.

Column order: method, thread class, validation, artifact bytes, artifact percentage, encode mean ms, encode SD ms, encode MiB/s, encode RSS MiB, decode mean ms, decode SD ms, decode MiB/s, and decode RSS MiB.
