<!-- markdownlint-disable MD024 -->

# Reference compression benchmark

This report measures one mzML file three ways: lossless compression of its Dump V1 spectra, lossless compression of the original document, and the mzarc lossy profiles. Compare methods only within one section, because the inputs and validation contracts differ.

## Key findings

- **Dump V1:** `mzarc lossless` writes 14.46 MiB (46.99% of the input), 8.22% smaller than the smallest byte-exact peer, `xz -6 -T1` (15.76 MiB).
  Encode: 217.96 MiB/s, rank 2 of 8 rows; the fastest single-threaded peer is `zstd -3 --single-thread` at 108.97 MiB/s and the fastest peer overall is `zstd -3 -T4 [P]` at 256.84 MiB/s. Decode: 154.74 MiB/s, rank 6 of 8; the fastest is `zstd -3 --single-thread` at 370.46 MiB/s. Peak RSS: 8.72 MiB encode and 6.80 MiB decode; the lowest peers are `gzip -6` (1.90 MiB) and `gzip -6` (1.61 MiB).
- **Original mzML:** `mzarc exact` writes 24.00 MiB (31.77% of the input), 2.62% larger than the smallest byte-exact peer, `xz -6 -T1` (23.39 MiB). `MScompress -t4 [P]` writes 21.62 MiB but is validated as Dump V1 exact.
  Encode: 93.09 MiB/s, rank 6 of 10 rows; the fastest single-threaded peer is `zstd -3 --single-thread` at 266.82 MiB/s and the fastest peer overall is `zstd -3 -T4 [P]` at 665.50 MiB/s. Decode: 422.28 MiB/s, rank 3 of 10; the fastest is `zstd -3 -T4 [P]` at 747.70 MiB/s. Peak RSS: 1.02 MiB encode and 1.27 MiB decode; the lowest peers are `gzip -6` (1.86 MiB) and `gzip -6` (1.65 MiB).
- **Lossy:** the mzML lossy archive is 20.10% of the original document, 36.75% smaller than the exact archive; the Dump V1 lossy archive is 41.14% of its input, 12.45% smaller than the lossless archive. Largest observed errors: m/z 0.000000000000 Da and log1p intensity 0.000642643 (mzML), m/z 0.000001000000 Da and log1p intensity 0.000644625 (Dump V1), against a format-wide log1p limit of 0.005415332.

## Run context

- Source: `<data root>/PXD075509/15HCD_1.mzML`
- Source shape: 9001 spectra; 2668458 peaks; 917 MS1 and 8084 MS2 spectra
- Measured: 2026-11-03T14:00:11-07:00
- Host: AMD Ryzen 9 3950X 16-Core Processor; Linux 7.2.14-200.fc44.x86_64 x86_64 GNU/Linux
- CPU frequency governor: schedutil
- Load average (1, 5, 15 min): 17.21 23.34 20.13 before the build, 20.88 20.09 20.38 after the last measurement
- mzarc build: stripped ReleaseFast, single-threaded
- Sampling: 5 measurements per operation after one warmup
- Parallel rows: 4 workers, marked `[P]`; direction-specific behavior remains in the tables
- Execution: each operation is measured independently; files are reused after untimed validation and one warmup
- Timing: median wall time with its interquartile range (IQR); throughput is uncompressed input bytes divided by the median
- Peak RSS: median zebrac direct-child RSS
- Spread: 31 of 40 operations have an IQR above 5% of their median (largest: `zstd -3 --single-thread` encode 64.7%, `zstd -3 -T4 [P]` encode 64.5%, `xz -6 -T4 [P]` decode 41.5%); compare those timings only after a repeat run

## Input size context

| Representation                      |    Bytes |   MiB | Representation / original mzML |
| ----------------------------------- | -------: | ----: | -----------------------------: |
| Original mzML                       | 79221306 | 75.55 |                        100.00% |
| mzarc exact archive of the document | 25170444 | 24.00 |                         31.77% |
| mzarc lossy archive of the document | 15921538 | 15.18 |                         20.10% |
| Dump V1 retained fields             | 32273524 | 30.78 |                         40.74% |
| mzarc lossless archive of Dump V1   | 15165670 | 14.46 |                         19.14% |
| mzarc lossy archive of Dump V1      | 13277057 | 12.66 |                         16.76% |

The document archives restore the whole mzML file: exactly, or with only spectrum m/z and intensity values changed within their bounds. The Dump V1 archives restore only the spectrum fields Dump V1 keeps.

## mzML ingest

Converting the original mzML to Dump V1 with `mzarc dump`. Its output is checked byte for byte against the dump every Dump V1 row starts from.

| Step         | Output bytes | Median (ms) | IQR (ms) | mzML MiB/s | Peak RSS (MiB) |
| ------------ | -----------: | ----------: | -------: | ---------: | -------------: |
| `mzarc dump` |     32273524 |     445.086 |   17.559 |     169.75 |           1.02 |

## Inspection and validation

The commands that check and describe the lossless Dump V1 round trip, on the files the Dump V1 comparison validated: `validate` compares the input dump with its decoded copy (input bytes count both), `dump-inspect` reads the input dump, and `inspect` checks every block of the lossless archive. Each reads one record or one block at a time.

| Command                          | Input bytes | Median (ms) | IQR (ms) | Input MiB/s | Peak RSS (MiB) |
| -------------------------------- | ----------: | ----------: | -------: | ----------: | -------------: |
| `mzarc validate --mode=lossless` |    64547048 |      28.634 |    0.633 |     2149.75 |           0.90 |
| `mzarc dump-inspect`             |    32273524 |       6.899 |    0.940 |     4461.19 |           0.90 |
| `mzarc inspect`                  |    15165670 |      73.503 |   11.629 |      196.77 |           6.43 |

## Dump V1 round trip

Comparison input: Dump V1, 30.78 MiB (32273524 bytes).

![Dump V1 round trip summary](dump-summary.svg)

### Artifact

| Method                  | Threads (encode / decode) | Validation | Artifact bytes | Artifact / Dump V1 |
| ----------------------- | ------------------------- | ---------- | -------------: | -----------------: |
| mzarc lossless          | single / single           | byte exact |       15165670 |             46.99% |
| gzip -6                 | single / single           | byte exact |       20780851 |             64.39% |
| pigz -6 -p1             | single / single           | byte exact |       20707631 |             64.16% |
| pigz -6 -p4 [P]         | fixed-4 / fixed-4 helpers | byte exact |       20707626 |             64.16% |
| zstd -3 --single-thread | single / single           | byte exact |       18710563 |             57.97% |
| zstd -3 -T4 [P]         | fixed-4 / single          | byte exact |       18659882 |             57.82% |
| xz -6 -T1               | single / single           | byte exact |       16524524 |             51.20% |
| xz -6 -T4 [P]           | fixed-4 / fixed-4         | byte exact |       16535444 |             51.24% |

### Encode

| Method                  | Median (ms) | IQR (ms) | IQR / median |  MiB/s | Peak RSS (MiB) |
| ----------------------- | ----------: | -------: | -----------: | -----: | -------------: |
| mzarc lossless          |     141.210 |    8.448 |         6.0% | 217.96 |           8.72 |
| gzip -6                 |    1809.301 |  148.359 |         8.2% |  17.01 |           1.90 |
| pigz -6 -p1             |    1415.434 |  127.397 |         9.0% |  21.74 |           2.92 |
| pigz -6 -p4 [P]         |     397.686 |   42.713 |        10.7% |  77.39 |           5.10 |
| zstd -3 --single-thread |     282.445 |  182.746 |        64.7% | 108.97 |           5.64 |
| zstd -3 -T4 [P]         |     119.835 |   13.564 |        11.3% | 256.84 |          54.44 |
| xz -6 -T1               |   26978.865 | 2257.108 |         8.4% |   1.14 |          94.35 |
| xz -6 -T4 [P]           |   20509.420 | 2367.939 |        11.5% |   1.50 |         217.35 |

### Decode

| Method                  | Median (ms) | IQR (ms) | IQR / median |  MiB/s | Peak RSS (MiB) |
| ----------------------- | ----------: | -------: | -----------: | -----: | -------------: |
| mzarc lossless          |     198.909 |    2.275 |         1.1% | 154.74 |           6.80 |
| gzip -6                 |     146.162 |   42.565 |        29.1% | 210.58 |           1.61 |
| pigz -6 -p1             |     150.433 |    6.017 |         4.0% | 204.60 |           2.15 |
| pigz -6 -p4 [P]         |     150.382 |   25.487 |        16.9% | 204.67 |           2.17 |
| zstd -3 --single-thread |      83.083 |   15.515 |        18.7% | 370.46 |           4.68 |
| zstd -3 -T4 [P]         |      93.664 |   17.351 |        18.5% | 328.60 |           4.64 |
| xz -6 -T1               |     711.571 |   24.338 |         3.4% |  43.25 |          10.10 |
| xz -6 -T4 [P]           |     600.768 |  249.360 |        41.5% |  51.23 |          59.73 |

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
| mzarc exact             |     811.578 |   36.846 |         4.5% |  93.09 |           1.02 |
| gzip -6                 |    1462.069 |   95.447 |         6.5% |  51.67 |           1.86 |
| pigz -6 -p1             |     768.118 |   26.917 |         3.5% |  98.36 |           2.90 |
| pigz -6 -p4 [P]         |     241.711 |   56.714 |        23.5% | 312.57 |           4.85 |
| zstd -3 --single-thread |     283.151 |   28.743 |        10.2% | 266.82 |           5.62 |
| zstd -3 -T4 [P]         |     113.525 |   73.268 |        64.5% | 665.50 |          74.88 |
| xz -6 -T1               |   18290.879 | 2063.389 |        11.3% |   4.13 |          94.14 |
| xz -6 -T4 [P]           |    6890.275 | 1050.133 |        15.2% |  10.96 |         425.91 |
| MScompress -t1          |     935.898 |   23.070 |         2.5% |  80.73 |         254.18 |
| MScompress -t4 [P]      |     428.221 |   35.731 |         8.3% | 176.43 |         271.39 |

### Decode

| Method                  | Median (ms) | IQR (ms) | IQR / median |  MiB/s | Peak RSS (MiB) |
| ----------------------- | ----------: | -------: | -----------: | -----: | -------------: |
| mzarc exact             |     178.914 |   24.461 |        13.7% | 422.28 |           1.27 |
| gzip -6                 |     201.631 |    7.732 |         3.8% | 374.70 |           1.65 |
| pigz -6 -p1             |     199.685 |   10.390 |         5.2% | 378.35 |           2.10 |
| pigz -6 -p4 [P]         |     232.102 |   44.742 |        19.3% | 325.51 |           2.16 |
| zstd -3 --single-thread |     104.766 |   10.137 |         9.7% | 721.15 |           4.69 |
| zstd -3 -T4 [P]         |     101.044 |   13.659 |        13.5% | 747.70 |           4.69 |
| xz -6 -T1               |     941.991 |   17.403 |         1.8% |  80.20 |          10.09 |
| xz -6 -T4 [P]           |     409.244 |   21.869 |         5.3% | 184.61 |         116.66 |
| MScompress -t1          |    5947.631 |  319.394 |         5.4% |  12.70 |         256.04 |
| MScompress -t4 [P]      |    2181.291 |  227.830 |        10.4% |  34.64 |         214.16 |

## Lossy archives

### Artifact

| Method                      | Threads (encode / decode) | Validation           | Artifact bytes | Artifact / its input |
| --------------------------- | ------------------------- | -------------------- | -------------: | -------------------: |
| mzarc lossy (Dump V1 input) | single / single           | Dump V1 lossy bounds |       13277057 |               41.14% |
| mzarc lossy (mzML input)    | single / single           | mzML lossy bounds    |       15921538 |               20.10% |

### Encode

| Method                      | Median (ms) | IQR (ms) | IQR / median |  MiB/s | Peak RSS (MiB) |
| --------------------------- | ----------: | -------: | -----------: | -----: | -------------: |
| mzarc lossy (Dump V1 input) |     220.612 |   13.040 |         5.9% | 139.51 |           9.43 |
| mzarc lossy (mzML input)    |    1461.025 |   85.834 |         5.9% |  51.71 |           2.32 |

### Decode

| Method                      | Median (ms) | IQR (ms) | IQR / median |  MiB/s | Peak RSS (MiB) |
| --------------------------- | ----------: | -------: | -----------: | -----: | -------------: |
| mzarc lossy (Dump V1 input) |     191.085 |   14.138 |         7.4% | 161.07 |           6.60 |
| mzarc lossy (mzML input)    |     912.790 |   31.618 |         3.5% |  82.77 |           1.52 |

Observed errors, from `mzarc validate` after the timed runs:

| Method                      | Arrays transformed | Max m/z error (Da) | Max log1p intensity error | Format-wide log1p limit |
| --------------------------- | -----------------: | -----------------: | ------------------------: | ----------------------: |
| mzarc lossy (Dump V1 input) |        every array |     0.000001000000 |               0.000644625 |             0.005415332 |
| mzarc lossy (mzML input)    |     18002 of 18007 |     0.000000000000 |               0.000642643 |             0.005415332 |

The mzML profile keeps an array exact when the profile cannot hold it: 32-bit m/z, unsupported compression, negative or non-finite intensity. A transformed f64 m/z array whose values are all f32 decodes to its source values exactly. Errors are measured over the values that changed.

## Validation boundaries

- mzarc lossless, gzip, pigz, zstd, and xz reproduce their Dump V1 input byte for byte.
- mzarc exact, gzip, pigz, zstd, and xz reproduce the original mzML document byte for byte.
- MScompress reproduces the fields retained by Dump V1 here, not necessarily the original document bytes. Its decoded mzML is converted through the same Dump V1 converter and compared byte for byte with the source dump.
- mzarc lossy (Dump V1 input) passes `mzarc validate --mode=lossy`: metadata exact, every m/z equal to its quantized value, and intensity within the format-wide log1p limit.
- mzarc lossy (mzML input) passes `mzarc validate --mode=mzml-lossy` on the Dump V1 of its decoded document: every peak is unchanged or carries the same transform within the same limit. The archive format restores every other document byte; the test suite checks that.

## Limits

- This report covers one file and one acquisition shape. It does not establish performance or RSS behavior across the broader corpus.
- Lossy rows are not comparable with the lossless and exact rows; they trade bounded spectrum error for size.
- The runner does not clear filesystem caches, randomize operation order, isolate CPUs, or control system load and CPU frequency. The load average and spread lines above show how quiet the run was.
- Wall time and RSS are measurements from one host, not portable guarantees.

## Tool versions

- mzarc: `v0.4.0` at `daef062`
- Build: Zig `0.16.0`; stripped ReleaseFast; single-threaded
- Ingest and mzML reading: `mzarc dump` on zmz `0.1.0`
- Measurement: `zebrac 0.6.2`
- Compression peers: `gzip 1.14`; `pigz 2.8`; `zstd 1.5.7`; `xz 5.8.2`; `MScompress 1.0.16`
- Report generation: `jq-1.8.1`; `gnuplot 6.0.3 patchlevel 3`

## Machine-readable rows

The full-precision rows are retained beside this report for direct local comparisons; the tables above are rounded. The zebrac results behind them stay in the run directory's `zebrac/` folder.

- [dump.tsv](dump.tsv), [mzml.tsv](mzml.tsv), and [lossy.tsv](lossy.tsv): method, thread class, validation, artifact bytes, artifact percentage of input, encode median ms, encode IQR ms, encode MiB/s, encode RSS MiB, decode median ms, decode IQR ms, decode MiB/s, decode RSS MiB, encode mean ms, encode SD ms, decode mean ms, decode SD ms, encode median instructions, decode median instructions, and input bytes.
- [lossy-errors.tsv](lossy-errors.tsv): method, max m/z error in Da, max log1p intensity error, the format-wide log1p limit, and the arrays transformed.
- [ingest.tsv](ingest.tsv): step, output bytes, median ms, IQR ms, mzML MiB/s, peak RSS MiB, and median instructions.
- [commands.tsv](commands.tsv): command, input bytes, median ms, IQR ms, input MiB/s, peak RSS MiB, and median instructions.
