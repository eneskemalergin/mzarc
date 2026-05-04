#!/usr/bin/env python3
"""Thin CLI wrapper for Python-only external baseline conversions.

Called by benchmark.sh via zebrac's temp-script mechanism so each conversion
is timed under the same conditions as all other benchmark operations.

Usage:
    python3 tools/benchmark_external.py available
    python3 tools/benchmark_external.py encode mzmlb   <input.mzML>          <output.mzMLb>
    python3 tools/benchmark_external.py decode mzmlb   <input.mzMLb>         <output.bin>
    python3 tools/benchmark_external.py encode numpress <input.mzML>          <output.numpress.mzML>
    python3 tools/benchmark_external.py decode numpress <input.numpress.mzML> <output.bin>
    python3 tools/benchmark_external.py encode mscompress <input.mzML>        <output.msz>
    python3 tools/benchmark_external.py decode mscompress <input.msz>         <output.bin>

The `available` subcommand prints a space-separated list of tool keys whose
Python packages are importable, then exits 0.
"""
from __future__ import annotations

import sys
import warnings
from pathlib import Path

# Keep PYTHONPATH consistent with the rest of the tools/ scripts.
sys.path.insert(0, str(Path(__file__).resolve().parent))


# --------------------------------------------------------------------------- #
# availability checks                                                         #
# --------------------------------------------------------------------------- #

def _psims_available() -> bool:
    try:
        import psims  # noqa: F401
        return True
    except ImportError:
        return False


def _mscompress_available() -> bool:
    try:
        import mscompress  # noqa: F401
        return True
    except ImportError:
        return False


# --------------------------------------------------------------------------- #
# conversions                                                                 #
# --------------------------------------------------------------------------- #

def encode_mzmlb(input_path: Path, output_path: Path, *, h5_compression: str = "blosc:zstd") -> None:
    from uuid import uuid4
    from psims.document import ReferentialIntegrityWarning
    from psims.transform.mzml import MzMLToMzMLb

    tmp = output_path.with_name(f"{output_path.name}.{uuid4().hex}.tmp")
    transformer = MzMLToMzMLb(str(input_path), str(tmp), h5_compression=h5_compression)
    transformer.log = lambda *a, **kw: None
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", ReferentialIntegrityWarning)
            transformer.write()
    finally:
        writer = getattr(transformer, "writer", None)
        if writer is not None:
            writer.close()
    tmp.replace(output_path)


def decode_mzmlb(input_path: Path, output_path: Path) -> None:
    from mzml_dump import dump_mzmlb
    dump_mzmlb(input_path, output_path)


def encode_numpress(input_path: Path, output_path: Path) -> None:
    from psims.document import ReferentialIntegrityWarning
    from psims.mzml.binary_encoding import (
        COMPRESSION_NONE,
        COMPRESSION_NUMPRESS_LINEAR_PREDICTION,
        COMPRESSION_NUMPRESS_POSITIVE_INTEGER,
        COMPRESSION_NUMPRESS_SHORT_LOGGED_FLOAT,
    )
    from psims.transform.mzml import MzMLTransformer

    class _NumpressTransformer(MzMLTransformer):
        def format_spectrum(self, spectrum):
            d = super().format_spectrum(spectrum)
            d["compression"] = {
                "m/z array":        COMPRESSION_NUMPRESS_LINEAR_PREDICTION,
                "intensity array":  COMPRESSION_NUMPRESS_SHORT_LOGGED_FLOAT,
                "charge array":     COMPRESSION_NUMPRESS_POSITIVE_INTEGER,
            }
            return d

        def format_chromatogram(self, chromatogram):
            d = super().format_chromatogram(chromatogram)
            comp = d.get("compression") or {}
            comp.setdefault("time array",      COMPRESSION_NONE)
            comp.setdefault("intensity array", COMPRESSION_NUMPRESS_SHORT_LOGGED_FLOAT)
            d["compression"] = comp
            return d

    t = _NumpressTransformer(str(input_path), str(output_path))
    t.log = lambda *a, **kw: None
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", ReferentialIntegrityWarning)
        t.write()


def decode_numpress(input_path: Path, output_path: Path) -> None:
    from mzml_dump import main as dump_main
    import sys as _sys
    _sys.argv = ["mzml_dump.py", str(input_path), "-o", str(output_path)]
    dump_main()


def encode_mscompress(input_path: Path, output_path: Path, *, threads: int = 1) -> None:
    import mscompress
    artifact = mscompress.read(str(input_path))
    artifact.arguments.threads = threads
    artifact.compress(str(output_path))


def decode_mscompress(input_path: Path, output_path: Path, *, threads: int = 1) -> None:
    import mscompress
    from mzml_dump import main as dump_main
    import sys as _sys

    roundtrip_mzml = output_path.with_suffix(".mscompress.roundtrip.mzML")
    artifact = mscompress.read(str(input_path))
    artifact.arguments.threads = threads
    artifact.decompress(str(roundtrip_mzml))

    _sys.argv = ["mzml_dump.py", str(roundtrip_mzml), "-o", str(output_path)]
    dump_main()


# --------------------------------------------------------------------------- #
# CLI                                                                         #
# --------------------------------------------------------------------------- #

_TOOLS = {
    "mzmlb":      (_psims_available,      encode_mzmlb,      decode_mzmlb),
    "numpress":   (_psims_available,      encode_numpress,   decode_numpress),
    "mscompress": (_mscompress_available, encode_mscompress, decode_mscompress),
}


def main() -> int:
    args = sys.argv[1:]

    if not args or args[0] == "available":
        available = [key for key, (check, _, _) in _TOOLS.items() if check()]
        print(" ".join(available))
        return 0

    if len(args) < 4 or args[0] not in ("encode", "decode"):
        print(__doc__, file=sys.stderr)
        return 2

    verb, tool_key = args[0], args[1]
    input_path, output_path = Path(args[2]), Path(args[3])

    if tool_key not in _TOOLS:
        print(f"Unknown tool: {tool_key}. Must be one of: {', '.join(_TOOLS)}", file=sys.stderr)
        return 2

    check_fn, encode_fn, decode_fn = _TOOLS[tool_key]
    if not check_fn():
        print(f"{tool_key} is not available in this environment.", file=sys.stderr)
        return 1

    fn = encode_fn if verb == "encode" else decode_fn
    fn(input_path, output_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
