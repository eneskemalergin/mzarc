#!/usr/bin/env python3
"""Generate deterministic adversarial binary dump corpus into test/adversarial/.

Each file exercises one codec edge case. All files use the same flat RawSpectrum
dump format as inspect_dump.py / slice_fixture.py so they feed directly into
`mzarc encode`.

Files generated (test/adversarial/<name>.bin):
  empty.bin                 100 spectra, 0 peaks each
  single_peak.bin           100 spectra, 1 peak each; m/z uniform across 50–6000
  constant_mz.bin           100 spectra, all peaks at the same m/z per spectrum
  full_range.bin            100 spectra, exactly 2 peaks: m/z 50.0 and 6000.0
  zero_intensity.bin        100 spectra mixing zero-intensity peaks with normal ones
  near_min_intensity.bin    100 spectra, intensity = 1e-38 (near f32 minimum positive)
  near_max_intensity.bin    100 spectra, intensity = 1e+37 (near f32 maximum; avoid inf)
  mz_zero.bin               100 spectra, one peak at m/z = 0.0
  dense.bin                 100 spectra, 5,000 peaks each
  identical_block.bin       128 byte-for-byte identical spectra
  random_block.bin          128 spectra with fully random m/z and intensity

Usage:
    uv run python tools/gen_adversarial.py [--output-dir test/adversarial]
"""

from __future__ import annotations

import argparse
import dataclasses
import random
import struct
from pathlib import Path

RECORD_HEADER = struct.Struct("<IfB3xdI4x")  # scan_id u32, rt f32, ms_level u8, pad3, precursor_mz f64, peak_count u32, pad4


@dataclasses.dataclass
class Spectrum:
    scan_id: int
    rt_seconds: float
    ms_level: int
    precursor_mz: float
    mz: list[float]
    intensity: list[float]

    @property
    def peak_count(self) -> int:
        return len(self.mz)


def write_dump(path: Path, spectra: list[Spectrum]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as fh:
        for s in spectra:
            fh.write(RECORD_HEADER.pack(s.scan_id, s.rt_seconds, s.ms_level, s.precursor_mz, s.peak_count))
            for m in s.mz:
                fh.write(struct.pack("<d", m))
            for v in s.intensity:
                fh.write(struct.pack("<f", v))


def _ms1(scan_id: int, rt: float, peak_count: int, mz: list[float], intensity: list[float]) -> Spectrum:
    return Spectrum(scan_id=scan_id, rt_seconds=rt, ms_level=1, precursor_mz=0.0, mz=mz, intensity=intensity)


def _ms2(scan_id: int, rt: float, precursor_mz: float, mz: list[float], intensity: list[float]) -> Spectrum:
    return Spectrum(scan_id=scan_id, rt_seconds=rt, ms_level=2, precursor_mz=precursor_mz, mz=mz, intensity=intensity)


# ---------------------------------------------------------------------------
# Individual corpus generators
# ---------------------------------------------------------------------------

def gen_empty(rng: random.Random) -> list[Spectrum]:
    """100 spectra with 0 peaks each."""
    spectra = []
    for i in range(100):
        spectra.append(_ms2(scan_id=i + 1, rt=float(i) * 0.1, precursor_mz=500.0, mz=[], intensity=[]))
    return spectra


def gen_single_peak(rng: random.Random) -> list[Spectrum]:
    """100 spectra with 1 peak each; m/z uniform across 50–6000."""
    spectra = []
    for i in range(100):
        mz_val = 50.0 + (6000.0 - 50.0) * i / 99.0
        spectra.append(_ms2(scan_id=i + 1, rt=float(i) * 0.1, precursor_mz=500.0,
                            mz=[mz_val], intensity=[10000.0]))
    return spectra


def gen_constant_mz(rng: random.Random) -> list[Spectrum]:
    """100 spectra; all 10 peaks in each spectrum share the same m/z value."""
    spectra = []
    for i in range(100):
        mz_val = 100.0 + float(i) * 20.0   # different constant per spectrum
        mz = [mz_val] * 10
        intensity = [float(rng.randint(1000, 50000)) for _ in range(10)]
        spectra.append(_ms2(scan_id=i + 1, rt=float(i) * 0.1, precursor_mz=500.0,
                            mz=mz, intensity=intensity))
    return spectra


def gen_full_range(rng: random.Random) -> list[Spectrum]:
    """100 spectra with exactly 2 peaks: m/z 50.0 and m/z 6000.0."""
    spectra = []
    for i in range(100):
        spectra.append(_ms2(scan_id=i + 1, rt=float(i) * 0.1, precursor_mz=3025.0,
                            mz=[50.0, 6000.0], intensity=[5000.0, 5000.0]))
    return spectra


def gen_zero_intensity(rng: random.Random) -> list[Spectrum]:
    """100 spectra mixing zero-intensity peaks with normal ones (10 peaks each)."""
    spectra = []
    for i in range(100):
        mz = sorted(50.0 + rng.random() * 5950.0 for _ in range(10))
        intensity = [0.0 if j % 3 == 0 else float(rng.randint(1000, 50000)) for j in range(10)]
        spectra.append(_ms2(scan_id=i + 1, rt=float(i) * 0.1, precursor_mz=500.0,
                            mz=mz, intensity=intensity))
    return spectra


def gen_near_min_intensity(rng: random.Random) -> list[Spectrum]:
    """100 spectra with intensity = 1e-38 (near f32 minimum positive normal)."""
    spectra = []
    for i in range(100):
        mz = sorted(100.0 + rng.random() * 1000.0 for _ in range(10))
        intensity = [1e-38] * 10
        spectra.append(_ms2(scan_id=i + 1, rt=float(i) * 0.1, precursor_mz=500.0,
                            mz=mz, intensity=intensity))
    return spectra


def gen_near_max_intensity(rng: random.Random) -> list[Spectrum]:
    """100 spectra with intensity = 1e+37 (near f32 maximum; avoids inf)."""
    spectra = []
    for i in range(100):
        mz = sorted(100.0 + rng.random() * 1000.0 for _ in range(10))
        intensity = [1e37] * 10
        spectra.append(_ms2(scan_id=i + 1, rt=float(i) * 0.1, precursor_mz=500.0,
                            mz=mz, intensity=intensity))
    return spectra


def gen_mz_zero(rng: random.Random) -> list[Spectrum]:
    """100 spectra, one peak at m/z = 0.0 plus 4 normal peaks."""
    spectra = []
    for i in range(100):
        extra = sorted(100.0 + rng.random() * 1000.0 for _ in range(4))
        mz = [0.0] + extra   # 0.0 is already sorted first
        intensity = [float(rng.randint(1000, 50000)) for _ in range(5)]
        spectra.append(_ms2(scan_id=i + 1, rt=float(i) * 0.1, precursor_mz=500.0,
                            mz=mz, intensity=intensity))
    return spectra


def gen_dense(rng: random.Random) -> list[Spectrum]:
    """100 spectra with 5,000 peaks each (6 MiB total)."""
    spectra = []
    for i in range(100):
        mz = sorted(50.0 + rng.random() * 5950.0 for _ in range(5000))
        intensity = [float(rng.randint(100, 100000)) for _ in range(5000)]
        spectra.append(_ms2(scan_id=i + 1, rt=float(i) * 0.1, precursor_mz=500.0,
                            mz=mz, intensity=intensity))
    return spectra


def gen_identical_block(rng: random.Random) -> list[Spectrum]:
    """128 byte-for-byte identical spectra (one full block).

    Tests cross-spectrum delta: residuals should be all-zero, yielding
    maximum compression gain.  Same scan_id/rt/precursor_mz per spectrum
    to make them truly identical at the Zig struct level.
    """
    # One template spectrum
    mz = sorted(100.0 + rng.random() * 900.0 for _ in range(50))
    intensity = [float(rng.randint(1000, 50000)) for _ in range(50)]
    spectra = []
    for i in range(128):
        spectra.append(_ms2(scan_id=i + 1, rt=0.0, precursor_mz=500.0,
                            mz=list(mz), intensity=list(intensity)))
    return spectra


def gen_random_block(rng: random.Random) -> list[Spectrum]:
    """128 spectra with fully random m/z and intensity.

    Tests cross-spectrum delta with worst-case residuals (no correlation
    between consecutive spectra).  Each spectrum has a different peak count
    to also stress alignment logic.
    """
    spectra = []
    for i in range(128):
        n = rng.randint(20, 80)
        mz = sorted(50.0 + rng.random() * 5950.0 for _ in range(n))
        intensity = [float(rng.randint(100, 100000)) for _ in range(n)]
        spectra.append(_ms2(scan_id=i + 1, rt=float(i) * 0.1, precursor_mz=500.0,
                            mz=mz, intensity=intensity))
    return spectra


def gen_split_exp_narrow(rng: random.Random) -> list[Spectrum]:
    """100 spectra, intensities all in [1e4, 9.9e4] (one decade).

    Exponent range = 1 (biased exponents 143-144 only), FOR bit width = 1.
    split_bytes = 13 + ceil(1*N/8) + 3*N vs raw_bytes = 4*N.
    For N=20 peaks: split=13+3+60=76 vs raw=80 → split wins.
    Tests that flag_split_exponent is set AND round-trip is bit-exact.
    """
    spectra = []
    # Force exact f32 values whose biased exponent is 143 (2^16) or 144 (2^17)
    # to guarantee exponent range = 1 deterministically (no rng drift).
    low_vals  = [65536.0,  32768.0 * 1.5, 65536.0 * 1.25, 65536.0 * 1.75,
                 32768.0 * 1.1, 65536.0 * 1.125, 32768.0 * 1.875, 65536.0 * 1.0625,
                 32768.0 * 1.25, 65536.0 * 1.5,  # mix of exp 143 and 144
                 32768.0 * 1.75, 65536.0 * 1.875, 32768.0 * 1.0625, 65536.0 * 1.125,
                 32768.0 * 1.625, 65536.0 * 1.375, 32768.0 * 1.9375, 65536.0 * 1.3125,
                 32768.0 * 1.5625, 65536.0 * 1.6875]
    for i in range(100):
        mz = sorted(200.0 + j * 10.0 for j in range(20))
        intensity = [low_vals[j % len(low_vals)] for j in range(20)]
        spectra.append(_ms2(scan_id=i + 1, rt=float(i) * 0.1, precursor_mz=500.0,
                            mz=mz, intensity=intensity))
    return spectra


def gen_split_exp_degenerate(rng: random.Random) -> list[Spectrum]:
    """100 spectra mixing near-zero (1e-38) and near-max (1e+37) intensities.

    Exercises the full f32 dynamic range: biased exponents from ~1 (near-min
    positive normal, 2^-126 approx 1.2e-38) to ~250 (near-max approx 1.7e38,
    biased exp = 254).  FOR exponent bit-width = 8 (floor(log2(253)) + 1).
    split_bytes = 13 + ceil(8*40/8) + 3*40 = 13 + 40 + 120 = 173.
    raw_bytes = 4*40 = 160 → split LOSES; raw fallback ensues.

    The per-block unit test covers the split-exponent bit-width=0 path
    ("zero FOR bit-width still activates split when block is large enough").
    """
    spectra = []
    for i in range(100):
        mz = sorted(100.0 + j * 50.0 for j in range(40))
        intensity = []
        for j in range(40):
            if j % 2 == 0:
                intensity.append(1e-38)   # near-min positive normal
            else:
                intensity.append(1e+37)   # near-max (avoids inf)
        spectra.append(_ms2(scan_id=i + 1, rt=float(i) * 0.1, precursor_mz=300.0,
                            mz=mz, intensity=intensity))
    return spectra


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

CORPUS: list[tuple[str, object]] = [
    ("empty.bin", gen_empty),
    ("single_peak.bin", gen_single_peak),
    ("constant_mz.bin", gen_constant_mz),
    ("full_range.bin", gen_full_range),
    ("zero_intensity.bin", gen_zero_intensity),
    ("near_min_intensity.bin", gen_near_min_intensity),
    ("near_max_intensity.bin", gen_near_max_intensity),
    ("mz_zero.bin", gen_mz_zero),
    ("dense.bin", gen_dense),
    ("identical_block.bin", gen_identical_block),
    ("random_block.bin", gen_random_block),
    ("split_exp_narrow.bin", gen_split_exp_narrow),
    ("split_exp_degenerate.bin", gen_split_exp_degenerate),
]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output-dir", default="test/adversarial", help="Directory to write corpus files into")
    args = parser.parse_args()

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    rng = random.Random(42)
    total_bytes = 0
    for filename, generator in CORPUS:
        spectra = generator(rng)
        path = out_dir / filename
        write_dump(path, spectra)
        size = path.stat().st_size
        total_bytes += size
        print(f"  wrote {filename:30s}  {len(spectra):4d} spectra  {size:>10,} bytes")

    print(f"\ntotal: {len(CORPUS)} files, {total_bytes:,} bytes ({total_bytes / 1024 / 1024:.2f} MiB)")


if __name__ == "__main__":
    main()
