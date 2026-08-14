<!-- markdownlint-disable MD024 -->

# Reference compression benchmark

This report compares lossless compression of one mzML-derived Dump V1 input and the original mzML document. Compare methods only within the same input section because the inputs and validation contracts differ.

## Key findings

- mzarc produces a 14.46 MiB artifact from the Dump V1 input (46.99% of input), 8.22% smaller than the next-smallest single-threaded byte-exact row, xz `-6 -T1`.
- mzarc is the fastest single-threaded Dump V1 encoder at 226.51 MiB/s. The fixed-4 zstd row leads overall encode at 348.43 MiB/s. zstd records 451.98 MiB/s decode for the single-thread artifact and 445.50 MiB/s for the fixed-4 artifact; both decode operations are single-threaded.
- mzarc peak RSS is 8.52 MiB for encode and 6.33 MiB for decode on this file. gzip records the lowest values in the Dump V1 table at 1.85 MiB and 1.60 MiB.
- On original mzML, MScompress `-t4` writes the smallest artifact at 28.62% but is validated as Dump V1 exact. xz `-6 -T1` is the smallest document-byte-exact row at 30.96%. The fixed-4 zstd row records 970.85 MiB/s encode; its single-threaded decode records 810.95 MiB/s.

## Run context

- Source: `data/PXD075509/15HCD_1.mzML`
- Source shape: 9001 spectra; 2668458 peaks; 917 MS1 and 8084 MS2 spectra
- Measured: 2026-08-15T02:49:24-07:00
- Host: AMD Ryzen 9 3950X 16-Core Processor; Linux 7.0.11-76070011-generic x86_64 GNU/Linux
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
| pigz -6 -p1             | single / single           | byte exact |       20731776 |             64.24% |
| pigz -6 -p4 [P]         | fixed-4 / fixed-4 helpers | byte exact |       20731776 |             64.24% |
| zstd -3 --single-thread | single / single           | byte exact |       18721502 |             58.01% |
| zstd -3 -T4 [P]         | fixed-4 / single          | byte exact |       18720327 |             58.01% |
| xz -6 -T1               | single / single           | byte exact |       16524524 |             51.20% |
| xz -6 -T4 [P]           | fixed-4 / fixed-4         | byte exact |       16535444 |             51.24% |

### Encode

| Method                  |      Mean ± SD (ms) |  MiB/s | Peak RSS (MiB) |
| ----------------------- | ------------------: | -----: | -------------: |
| mzarc lossless          |     135.881 ± 3.553 | 226.51 |           8.52 |
| gzip -6                 |    1670.748 ± 8.828 |  18.42 |           1.85 |
| pigz -6 -p1             |    1666.610 ± 8.860 |  18.47 |           2.39 |
| pigz -6 -p4 [P]         |     431.578 ± 7.141 |  71.32 |           4.40 |
| zstd -3 --single-thread |     231.869 ± 7.943 | 132.74 |           5.75 |
| zstd -3 -T4 [P]         |      88.336 ± 8.344 | 348.43 |          54.68 |
| xz -6 -T1               | 17148.455 ± 160.174 |   1.79 |          94.87 |
| xz -6 -T4 [P]           | 13307.703 ± 360.831 |   2.31 |         217.65 |

### Decode

| Method                  |  Mean ± SD (ms) |  MiB/s | Peak RSS (MiB) |
| ----------------------- | --------------: | -----: | -------------: |
| mzarc lossless          | 125.413 ± 2.171 | 245.42 |           6.33 |
| gzip -6                 | 207.737 ± 2.883 | 148.16 |           1.60 |
| pigz -6 -p1             | 157.408 ± 2.292 | 195.53 |           1.90 |
| pigz -6 -p4 [P]         | 130.950 ± 5.178 | 235.04 |           1.95 |
| zstd -3 --single-thread |  68.096 ± 1.103 | 451.98 |           4.97 |
| zstd -3 -T4 [P]         |  69.088 ± 1.479 | 445.50 |           4.94 |
| xz -6 -T1               | 638.643 ± 8.404 |  48.19 |           9.93 |
| xz -6 -T4 [P]           | 509.993 ± 7.699 |  60.35 |          59.81 |

## Original mzML round trip

Comparison input: original mzML, 75.55 MiB (79221306 bytes).

![Original mzML round trip summary](mzml-summary.svg)

### Artifact

| Method                  | Threads (encode / decode) | Validation    | Artifact bytes | Artifact / original mzML |
| ----------------------- | ------------------------- | ------------- | -------------: | -----------------------: |
| gzip -6                 | single / single           | byte exact    |       25465391 |                   32.14% |
| pigz -6 -p1             | single / single           | byte exact    |       25395942 |                   32.06% |
| pigz -6 -p4 [P]         | fixed-4 / fixed-4 helpers | byte exact    |       25395942 |                   32.06% |
| zstd -3 --single-thread | single / single           | byte exact    |       24771413 |                   31.27% |
| zstd -3 -T4 [P]         | fixed-4 / single          | byte exact    |       24770559 |                   31.27% |
| xz -6 -T1               | single / single           | byte exact    |       24527740 |                   30.96% |
| xz -6 -T4 [P]           | fixed-4 / fixed-4         | byte exact    |       24536980 |                   30.97% |
| MScompress -t1          | single / single           | Dump V1 exact |       22679622 |                   28.63% |
| MScompress -t4 [P]      | fixed-4 / fixed-4         | Dump V1 exact |       22670580 |                   28.62% |

### Encode

| Method                  |      Mean ± SD (ms) |  MiB/s | Peak RSS (MiB) |
| ----------------------- | ------------------: | -----: | -------------: |
| gzip -6                 |    1545.797 ± 4.706 |  48.88 |           1.85 |
| pigz -6 -p1             |   1491.623 ± 13.380 |  50.65 |           2.41 |
| pigz -6 -p4 [P]         |     387.707 ± 3.637 | 194.87 |           4.39 |
| zstd -3 --single-thread |     237.621 ± 5.154 | 317.95 |           5.73 |
| zstd -3 -T4 [P]         |      77.819 ± 5.358 | 970.85 |          75.19 |
| xz -6 -T1               | 16079.689 ± 205.709 |   4.70 |          94.91 |
| xz -6 -T4 [P]           |  5915.283 ± 219.877 |  12.77 |         426.89 |
| MScompress -t1          |     898.356 ± 5.415 |  84.10 |         253.34 |
| MScompress -t4 [P]      |     349.532 ± 3.372 | 216.15 |         271.78 |

### Decode

| Method                  |    Mean ± SD (ms) |  MiB/s | Peak RSS (MiB) |
| ----------------------- | ----------------: | -----: | -------------: |
| gzip -6                 |   357.336 ± 2.028 | 211.43 |           1.60 |
| pigz -6 -p1             |   253.929 ± 5.322 | 297.53 |           1.89 |
| pigz -6 -p4 [P]         |   178.039 ± 4.748 | 424.35 |           1.89 |
| zstd -3 --single-thread |    90.764 ± 0.694 | 832.40 |           4.93 |
| zstd -3 -T4 [P]         |    93.164 ± 1.144 | 810.95 |           4.96 |
| xz -6 -T1               |   921.663 ± 7.462 |  81.97 |           9.89 |
| xz -6 -T4 [P]           |   385.240 ± 2.093 | 196.12 |         116.77 |
| MScompress -t1          |  5791.410 ± 5.307 |  13.05 |         256.08 |
| MScompress -t4 [P]      | 2052.828 ± 13.212 |  36.80 |         214.69 |

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

- mzarc: `v0.3.0`
- Build: Zig `0.16.0`; stripped ReleaseFast; single-threaded
- Ingest: Python `3.12.13`; Pyteomics `5.0.1`
- Measurement: `zebrac 0.6.2`
- Compression peers: `gzip 1.10`; `pigz 2.6`; `zstd 1.5.6`; `xz 5.6.4`; `MScompress 1.0.16`
- Report generation: `jq-1.6`; `gnuplot 5.4 patchlevel 2`

## Machine-readable rows

The full-precision Dump V1 rows are retained in [dump.tsv](dump.tsv) for direct local comparisons. The reader-facing tables above are rounded.

Column order: method, thread class, validation, artifact bytes, artifact percentage, encode mean ms, encode SD ms, encode MiB/s, encode RSS MiB, decode mean ms, decode SD ms, decode MiB/s, and decode RSS MiB.
