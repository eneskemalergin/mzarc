# test/fixtures/

Frozen validation fixtures used by `zig build ci` and `zig build check-fixture`.

## frozen.bin

A deterministically sliced 1,000-spectrum subset of the PXD075509 `15HCD_1.bin` Dump V1 (then under the repository's `data/`, now in `~/Github/data/mzml/PXD075509/`). The original generator is no longer retained; the frozen bytes and narrow integrity check are the current contract.

### Composition constraints

| Constraint                       | Required      | Actual |
| -------------------------------- | ------------- | ------ |
| Total spectra                    | exactly 1,000 | 1,000  |
| MS1 spectra                      | >= 100        | 110    |
| MS2 spectra                      | >= 800        | 890    |
| Distinct isolation windows (MS2) | >= 3          | 430    |
| Sparse spectra (< 5 peaks)       | >= 10         | 10     |
| Dense spectra (> 1,000 peaks)    | >= 5          | 46     |
| Empty spectra (0 peaks)          | >= 1          | 1      |

Sparse and empty spectra are fabricated deterministically (`random.seed(42)`) because
the source dump (min 16 peaks/spectrum) contains no such spectra naturally.

### dump-inspect summary (`mzarc dump-inspect`)

```text
file: test/fixtures/frozen.bin
spectra: 1000
total peaks: 202806
ms1 count: 110
ms2 count: 890
zero intensity peaks: 0
min peaks per spectrum: 0
median peaks per spectrum: 66.5
max peaks per spectrum: 2339
```

### SHA-256

```sha
9d5a10167356db7afaa4e6c43832a7ea75a53e84dc74e679a881d5d8cf7cb2c6
```

`zig build check-fixture` re-hashes `frozen.bin` at build time (`sha256sum`, or `shasum -a 256` on macOS) and fails if the digest does not match.

## small.mzML and small.bin

`small.mzML` is a hand-written 7,758-byte mzML document for `mzarc dump`. It has four spectra and one chromatogram, and covers:

- retention time in minutes and in seconds, and a spectrum without one;
- f64 and f32 arrays, zlib and uncompressed;
- array terms given directly and through referenceable parameter groups;
- an MS2 precursor, and an MS2 spectrum without one;
- unsorted m/z with a tie, which must sort stably;
- an ID without `scan=` (falls back to the index) and an ID whose first `scan=` has no digits;
- an empty spectrum and a chromatogram, which the dump skips.

`small.bin` is the expected 220-byte Dump V1. It was produced on 2026-10-10 by `tools/mzml_dump.py` (Pyteomics 5.0.1), independently of the Zig converter, and stays the frozen expectation after the Python converter is removed. `tools/smoke_test.sh` compares `mzarc dump` output with it byte for byte, and checks that a dump of the fixture cut at byte 4,000 fails without replacing an existing destination.

## Adversarial corpus (test/adversarial/)

The files were generated deterministically with seed 42. The original generator is no longer retained.
All files use the same flat `RawSpectrum` dump format and feed directly into `mzarc encode`.
`mzarc validate-adversarial test/adversarial/` round-trips every file in-memory.

| File                       | Spectra | Peaks/spectrum | Purpose                                                                                    |
| -------------------------- | ------- | -------------- | ------------------------------------------------------------------------------------------ |
| `empty.bin`                | 100     | 0              | Empty spectra; exercises zero-peak path                                                    |
| `single_peak.bin`          | 100     | 1              | One-peak spectra; minimal delta array                                                      |
| `constant_mz.bin`          | 100     | 10             | All peaks at same m/z; FOR range = 0                                                       |
| `full_range.bin`           | 100     | 2              | Peaks at m/z 50 and 6000; maximum FOR range                                                |
| `zero_intensity.bin`       | 100     | 10             | Zero-intensity peaks mixed with normal ones                                                |
| `near_min_intensity.bin`   | 100     | 10             | Intensity approx 1e-38 (near f32 minimum positive normal)                                  |
| `near_max_intensity.bin`   | 100     | 10             | Intensity approx 1e+37 (near f32 maximum; avoids inf)                                      |
| `mz_zero.bin`              | 100     | 5              | One peak at m/z 0.0                                                                        |
| `dense.bin`                | 100     | 5,000          | Large spectra; multi-block encoding at scale                                               |
| `identical_block.bin`      | 128     | 50             | One full block of identical spectra; zero residuals                                        |
| `random_block.bin`         | 128     | 20-80          | Fully random m/z+intensity; worst-case residuals                                           |
| `split_exp_narrow.bin`     | 100     | 20             | Intensities in one decade (2^16..2^17); exponent FOR bit-width = 1                         |
| `split_exp_degenerate.bin` | 100     | 5              | All intensities identical; exponent FOR bit-width = 0, exercises zero-length payload path  |

Total corpus: 13 files, ~5.99 MiB. All files pass `validate-adversarial` lossless round-trip.
