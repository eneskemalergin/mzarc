#!/usr/bin/env python3
"""Assemble manifest.json from benchmark.sh output.

Called at the end of benchmark.sh.  Reads file sizes from the generated
intermediate files and writes a structured manifest used by collect_report.py
and fidelity_check.py.

Usage (internal, called by benchmark.sh):
    python3 tools/write_manifest.py \\
        --mzml <path> --sample <name> --workdir <dir> \\
        --raw-dir <dir> --output-dir <dir> \\
        --duration <ms> --quant <N> --lossy-sweep <csv>
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))

from benchmark_core import repo_relative_path  # noqa: E402


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--mzml",       required=True, type=Path)
    p.add_argument("--sample",     required=True)
    p.add_argument("--workdir",    required=True, type=Path)
    p.add_argument("--raw-dir",    required=True, type=Path)
    p.add_argument("--output-dir", required=True, type=Path)
    p.add_argument("--duration",   required=True, type=int)
    p.add_argument("--quant",      required=True, type=int)
    p.add_argument("--lossy-sweep", required=True)
    return p.parse_args()


def _size(path: Path) -> int:
    return path.stat().st_size if path.exists() else 0


def _rel(path: Path) -> str:
    return repo_relative_path(path.resolve())


def _op(
    name: str,
    group: str,
    direction: str,
    fmt: str,
    artifact: str,
    inp: Path,
    out: Path,
    rt: Path | None,
    slug: str,
    raw: Path,
) -> dict[str, object]:
    return {
        "name": name,
        "group": group,
        "direction": direction,
        "format": fmt,
        "artifact": artifact,
        "input_path": _rel(inp),
        "output_path": _rel(out),
        "roundtrip_path": (_rel(rt) if (rt is not None and rt.exists()) else None),
        "input_bytes": _size(inp),
        "output_bytes": _size(out),
        "zebrac_json": _rel(raw / f"{slug}.json"),
    }


def main() -> None:
    args = parse_args()
    mzml = args.mzml.resolve()
    wd = args.workdir.resolve()
    raw = args.raw_dir.resolve()
    s = args.sample
    q = args.quant
    sweep_levels = sorted({int(x.strip()) for x in args.lossy_sweep.split(",")})

    dump       = wd / f"{s}.bin"
    mzml_bytes = _size(mzml)
    dump_bytes = _size(dump)

    # Dump-level codec paths
    def dp(ext: str) -> Path:
        return wd / f"{s}.bin.{ext}"

    def dr(tag: str) -> Path:
        return wd / f"{s}.{tag}.roundtrip.bin"

    gzip_dump   = dp("gz");    gzip_dump_rt  = dr("gzip")
    zstd_dump   = dp("zst");   zstd_dump_rt  = dr("zstd")
    bzip2_dump  = dp("bz2");   bzip2_dump_rt = dr("bzip2")
    lz4_dump    = dp("lz4");   lz4_dump_rt   = dr("lz4")
    xz_dump     = dp("xz");    xz_dump_rt    = dr("xz")

    # mzML-level codec paths
    def mp(ext: str) -> Path:
        return wd / f"{s}.mzML.{ext}"

    gzip_mzml  = mp("gz")
    zstd_mzml  = mp("zst")
    bzip2_mzml = mp("bz2")
    lz4_mzml   = mp("lz4")
    xz_mzml    = mp("xz")

    mzarc_lossless    = wd / f"{s}.lossless.mzarc"
    mzarc_lossless_rt = wd / f"{s}.lossless.roundtrip.bin"
    mzarc_lossy       = wd / f"{s}.lossy.q{q}.mzarc"
    mzarc_lossy_rt    = wd / f"{s}.lossy.q{q}.roundtrip.bin"

    def o(name, group, direction, fmt, artifact, inp, out, rt, slug):
        return _op(name, group, direction, fmt, artifact, inp, out, rt, slug, raw)

    operations: list[dict[str, object]] = [
        # mzML dump (Python wrapped in zebrac)
        o("mzml dump",        "mzml", "encode", "dump",      "dump",      mzml, dump, None, "mzml_dump"),
        # dump-level codecs
        o("dump -> gzip dump",  "dump_codec", "encode", "gzip dump",  "gzip dump",  dump,       gzip_dump,    None,        "gzip_dump_encode"),
        o("gzip dump -> dump",  "dump_codec", "decode", "gzip dump",  "gzip dump",  gzip_dump,  gzip_dump_rt, gzip_dump_rt, "gzip_dump_decode"),
        o("dump -> zstd dump",  "dump_codec", "encode", "zstd dump",  "zstd dump",  dump,       zstd_dump,    None,        "zstd_dump_encode"),
        o("zstd dump -> dump",  "dump_codec", "decode", "zstd dump",  "zstd dump",  zstd_dump,  zstd_dump_rt, zstd_dump_rt, "zstd_dump_decode"),
        o("dump -> bzip2 dump", "dump_codec", "encode", "bzip2 dump", "bzip2 dump", dump,       bzip2_dump,   None,        "bzip2_dump_encode"),
        o("bzip2 dump -> dump", "dump_codec", "decode", "bzip2 dump", "bzip2 dump", bzip2_dump, bzip2_dump_rt, bzip2_dump_rt, "bzip2_dump_decode"),
        o("dump -> lz4 dump",   "dump_codec", "encode", "lz4 dump",   "lz4 dump",   dump,       lz4_dump,     None,        "lz4_dump_encode"),
        o("lz4 dump -> dump",   "dump_codec", "decode", "lz4 dump",   "lz4 dump",   lz4_dump,   lz4_dump_rt,  lz4_dump_rt,  "lz4_dump_decode"),
        o("dump -> xz dump",    "dump_codec", "encode", "xz dump",    "xz dump",    dump,       xz_dump,      None,        "xz_dump_encode"),
        o("xz dump -> dump",    "dump_codec", "decode", "xz dump",    "xz dump",    xz_dump,    xz_dump_rt,   xz_dump_rt,   "xz_dump_decode"),
        # mzML-level codecs (no roundtrip dump, timing only)
        o("mzML -> gzip mzML",  "mzml_codec", "encode", "gzip mzML",  "gzip mzML",  mzml,      gzip_mzml,  None, "gzip_mzml_encode"),
        o("gzip mzML -> mzML",  "mzml_codec", "decode", "gzip mzML",  "gzip mzML",  gzip_mzml, wd / f"{s}.gzip_mzml.roundtrip.mzML",  None, "gzip_mzml_decode"),
        o("mzML -> zstd mzML",  "mzml_codec", "encode", "zstd mzML",  "zstd mzML",  mzml,      zstd_mzml,  None, "zstd_mzml_encode"),
        o("zstd mzML -> mzML",  "mzml_codec", "decode", "zstd mzML",  "zstd mzML",  zstd_mzml, wd / f"{s}.zstd_mzml.roundtrip.mzML",  None, "zstd_mzml_decode"),
        o("mzML -> bzip2 mzML", "mzml_codec", "encode", "bzip2 mzML", "bzip2 mzML", mzml,      bzip2_mzml, None, "bzip2_mzml_encode"),
        o("bzip2 mzML -> mzML", "mzml_codec", "decode", "bzip2 mzML", "bzip2 mzML", bzip2_mzml, wd / f"{s}.bzip2_mzml.roundtrip.mzML", None, "bzip2_mzml_decode"),
        o("mzML -> lz4 mzML",   "mzml_codec", "encode", "lz4 mzML",   "lz4 mzML",   mzml,      lz4_mzml,   None, "lz4_mzml_encode"),
        o("lz4 mzML -> mzML",   "mzml_codec", "decode", "lz4 mzML",   "lz4 mzML",   lz4_mzml,  wd / f"{s}.lz4_mzml.roundtrip.mzML",   None, "lz4_mzml_decode"),
        o("mzML -> xz mzML",    "mzml_codec", "encode", "xz mzML",    "xz mzML",    mzml,      xz_mzml,    None, "xz_mzml_encode"),
        o("xz mzML -> mzML",    "mzml_codec", "decode", "xz mzML",    "xz mzML",    xz_mzml,   wd / f"{s}.xz_mzml.roundtrip.mzML",    None, "xz_mzml_decode"),
        # mzarc
        o("dump -> mzarc lossless",          "mzarc", "encode", "mzarc lossless",        "mzarc lossless",        dump,            mzarc_lossless,    None,             "mzarc_lossless_encode"),
        o("mzarc lossless -> dump",          "mzarc", "decode", "mzarc lossless",        "mzarc lossless",        mzarc_lossless,  mzarc_lossless_rt, mzarc_lossless_rt, "mzarc_lossless_decode"),
        o(f"dump -> mzarc lossy q={q}",      "mzarc", "encode", f"mzarc lossy q={q}",   f"mzarc lossy q={q}",   dump,            mzarc_lossy,       None,             "mzarc_lossy_encode"),
        o(f"mzarc lossy q={q} -> dump",      "mzarc", "decode", f"mzarc lossy q={q}",   f"mzarc lossy q={q}",   mzarc_lossy,     mzarc_lossy_rt,    mzarc_lossy_rt,   "mzarc_lossy_decode"),
    ]

    sizes: dict[str, object] = {
        "mzML":        {"path": _rel(mzml),      "bytes": mzml_bytes},
        "dump":        {"path": _rel(dump),       "bytes": dump_bytes},
        "gzip dump":   {"path": _rel(gzip_dump),  "bytes": _size(gzip_dump)},
        "zstd dump":   {"path": _rel(zstd_dump),  "bytes": _size(zstd_dump)},
        "bzip2 dump":  {"path": _rel(bzip2_dump), "bytes": _size(bzip2_dump)},
        "lz4 dump":    {"path": _rel(lz4_dump),   "bytes": _size(lz4_dump)},
        "xz dump":     {"path": _rel(xz_dump),    "bytes": _size(xz_dump)},
        "gzip mzML":   {"path": _rel(gzip_mzml),  "bytes": _size(gzip_mzml)},
        "zstd mzML":   {"path": _rel(zstd_mzml),  "bytes": _size(zstd_mzml)},
        "bzip2 mzML":  {"path": _rel(bzip2_mzml), "bytes": _size(bzip2_mzml)},
        "lz4 mzML":    {"path": _rel(lz4_mzml),   "bytes": _size(lz4_mzml)},
        "xz mzML":     {"path": _rel(xz_mzml),    "bytes": _size(xz_mzml)},
        "mzarc lossless":      {"path": _rel(mzarc_lossless), "bytes": _size(mzarc_lossless)},
        f"mzarc lossy q={q}":  {"path": _rel(mzarc_lossy),    "bytes": _size(mzarc_lossy)},
    }

    lossy_sweep_rows: list[dict[str, object]] = []
    for ql in sweep_levels:
        sp = wd / f"{s}.lossy.q{ql}.mzarc"
        b = _size(sp)
        lossy_sweep_rows.append({
            "intensity_quant": ql,
            "path": _rel(sp),
            "bytes": b,
            "size_mib": b / (1024 * 1024),
        })

    # External baselines: auto-detect if artifacts and zebrac JSONs exist.
    _ext_candidates = [
        ("mzMLb",               wd / f"{s}.mzMLb",          wd / f"{s}.mzmlb.roundtrip.bin",       "mzmlb"),
        ("MS-Numpress in mzML", wd / f"{s}.numpress.mzML",  wd / f"{s}.numpress.roundtrip.bin",    "numpress"),
        ("MScompress",          wd / f"{s}.msz",            wd / f"{s}.mscompress.roundtrip.bin",  "mscompress"),
    ]
    for ext_name, ext_art, ext_rt, ext_slug in _ext_candidates:
        if not ext_art.exists():
            continue
        enc_json = raw / f"{ext_slug}_encode.json"
        dec_json = raw / f"{ext_slug}_decode.json"
        if not enc_json.exists():
            continue
        operations.append(_op(
            f"mzML -> {ext_name}", "external", "encode", ext_name, ext_name,
            mzml, ext_art, None, f"{ext_slug}_encode", raw,
        ))
        if dec_json.exists() and ext_rt.exists():
            operations.append(_op(
                f"{ext_name} -> dump", "external", "decode", ext_name, ext_name,
                ext_art, ext_rt, ext_rt, f"{ext_slug}_decode", raw,
            ))
        sizes[ext_name] = {"path": _rel(ext_art), "bytes": _size(ext_art)}

    manifest: dict[str, object] = {
        "schema_version": 1,
        "sample": s,
        "mzml_path": _rel(mzml),
        "dump_path": _rel(dump),
        "workdir": str(os.path.relpath(wd, REPO_ROOT)),
        "raw_dir": str(os.path.relpath(raw, REPO_ROOT)),
        "zebrac_duration_ms": args.duration,
        "selected_lossy_quant": q,
        "lossy_sweep": sweep_levels,
        "operations": operations,
        "sizes": sizes,
        "lossy_sweep_rows": lossy_sweep_rows,
    }

    out_path = raw / "manifest.json"
    out_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"Wrote {os.path.relpath(out_path, REPO_ROOT)}", flush=True)


if __name__ == "__main__":
    main()
