from __future__ import annotations

import contextlib
import io
import importlib.util
import os
import shlex
import warnings
from dataclasses import asdict
from pathlib import Path

from benchmark_core import (
    Spectrum,
    TimingResult,
    compare_dumps,
    read_dump,
    run_dump_mzml_quietly,
    run_timed_callable,
    run_timed_path_command,
)
from mzml_dump import dump_mzmlb

DEFAULT_EXTERNAL_BASELINES = ("mzmlb", "mscompress")

DISPLAY_NAMES = {
    "mzmlb": "mzMLb",
    "ms-numpress": "MS-Numpress in mzML",
    "mscompress": "MScompress",
}

OUTPUT_SUFFIXES = {
    "mzmlb": ".mzMLb",
    "ms-numpress": ".numpress.mzML",
    "mscompress": ".msz",
}

def parse_external_baselines(value: str | None) -> tuple[str, ...]:
    if value is None:
        return DEFAULT_EXTERNAL_BASELINES

    normalized = value.strip().lower()
    if normalized in {"", "all"}:
        return DEFAULT_EXTERNAL_BASELINES
    if normalized in {"none", "off"}:
        return ()

    alias_map = {
        "mzmlb": "mzmlb",
        "ms-numpress": "ms-numpress",
        "ms_numpress": "ms-numpress",
        "numpress": "ms-numpress",
        "mscompress": "mscompress",
        "msz": "mscompress",
    }

    items: list[str] = []
    for raw_item in value.split(","):
        item = raw_item.strip().lower()
        if not item:
            continue
        if item not in alias_map:
            raise ValueError(f"Unknown external baseline: {raw_item}")
        canonical = alias_map[item]
        if canonical not in items:
            items.append(canonical)
    return tuple(items)

def builtin_numpress_available() -> tuple[bool, str | None]:
    if importlib.util.find_spec("pynumpress") is not None:
        return True, None
    return (
        False,
        "psims and pyteomics can use MS-Numpress, but the required `pynumpress` backend is not available in this environment. The upstream PyMSNumpress package currently fails to build on Python 3.12 here.",
    )

def builtin_mscompress_available() -> tuple[bool, str | None]:
    if importlib.util.find_spec("mscompress") is not None:
        return True, None
    return False, "MScompress Python package is not installed in the active benchmark environment."

def estimate_external_steps(
    requested: tuple[str, ...],
    repeats: int,
    *,
    numpress_command_template: str | None = None,
    numpress_to_dump_command_template: str | None = None,
    mscompress_command_template: str | None = None,
    mscompress_to_dump_command_template: str | None = None,
    mscompress_benchmark_threaded: bool = False,
) -> int:
    steps = 0
    builtin_numpress_ok, _ = builtin_numpress_available()

    if "mzmlb" in requested:
        steps += repeats * 2 + 1

    if "ms-numpress" in requested:
        if numpress_command_template is not None:
            steps += repeats
            if numpress_to_dump_command_template is not None:
                steps += repeats + 1
        elif builtin_numpress_ok:
            steps += repeats * 2 + 1
        else:
            steps += 1

    if "mscompress" in requested:
        builtin_mscompress_ok, _ = builtin_mscompress_available()
        if mscompress_command_template is not None:
            steps += repeats
            if mscompress_to_dump_command_template is not None:
                steps += repeats + 1
        elif builtin_mscompress_ok:
            steps += repeats * 2 + 1
            if mscompress_benchmark_threaded:
                steps += repeats * 2 + 1
        else:
            steps += 1

    return steps

def _dump_mzmlb_quietly(input_path: Path, output_path: Path) -> None:
    with contextlib.redirect_stdout(io.StringIO()):
        dump_mzmlb(input_path, output_path)


def convert_mzml_to_mzmlb(input_path: Path, output_path: Path, *, h5_compression: str) -> None:
    from psims.document import ReferentialIntegrityWarning
    from psims.transform.mzml import MzMLToMzMLb
    from uuid import uuid4

    temp_output_path = output_path.with_name(f"{output_path.name}.{uuid4().hex}.tmp")
    transformer = MzMLToMzMLb(str(input_path), str(temp_output_path), h5_compression=h5_compression)
    transformer.log = lambda *args, **kwargs: None
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", ReferentialIntegrityWarning)
            transformer.write()
    finally:
        writer = getattr(transformer, "writer", None)
        if writer is not None:
            writer.close()
    temp_output_path.replace(output_path)


def convert_mzml_to_numpress_mzml(input_path: Path, output_path: Path) -> None:
    from psims.document import ReferentialIntegrityWarning
    from psims.mzml.binary_encoding import (
        COMPRESSION_NONE,
        COMPRESSION_NUMPRESS_LINEAR_PREDICTION,
        COMPRESSION_NUMPRESS_POSITIVE_INTEGER,
        COMPRESSION_NUMPRESS_SHORT_LOGGED_FLOAT,
    )
    from psims.transform.mzml import MzMLTransformer

    class MzMLToNumpressMzML(MzMLTransformer):
        def format_spectrum(self, spectrum):
            spec_data = super().format_spectrum(spectrum)
            spec_data["compression"] = {
                "m/z array": COMPRESSION_NUMPRESS_LINEAR_PREDICTION,
                "intensity array": COMPRESSION_NUMPRESS_SHORT_LOGGED_FLOAT,
                "charge array": COMPRESSION_NUMPRESS_POSITIVE_INTEGER,
            }
            return spec_data

        def format_chromatogram(self, chromatogram):
            chrom_data = super().format_chromatogram(chromatogram)
            compression = chrom_data.get("compression")
            if compression is None:
                compression = {}
            if isinstance(compression, dict):
                compression.setdefault("time array", COMPRESSION_NONE)
                compression.setdefault("intensity array", COMPRESSION_NUMPRESS_SHORT_LOGGED_FLOAT)
            chrom_data["compression"] = compression
            return chrom_data

    transformer = MzMLToNumpressMzML(str(input_path), str(output_path))
    transformer.log = lambda *args, **kwargs: None
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", ReferentialIntegrityWarning)
        transformer.write()


def convert_mzml_to_mscompress(input_path: Path, output_path: Path, *, threads: int = 1) -> None:
    import mscompress

    mzml = mscompress.read(str(input_path))
    if threads is not None:
        mzml.arguments.threads = threads
    mzml.compress(str(output_path))


def convert_mscompress_to_dump(input_path: Path, output_path: Path, *, threads: int = 1) -> None:
    import mscompress

    roundtrip_mzml = output_path.with_suffix(".mscompress.roundtrip.mzML")
    artifact = mscompress.read(str(input_path))
    if threads is not None:
        artifact.arguments.threads = threads
    artifact.decompress(str(roundtrip_mzml))
    run_dump_mzml_quietly(roundtrip_mzml, output_path)


def _benchmark_callable_baseline(
    *,
    records: list[dict[str, object]],
    sizes: dict[str, dict[str, object]],
    timings: list[TimingResult],
    display_name: str,
    input_path: Path,
    artifact_path: Path,
    roundtrip_path: Path,
    reference_dump: list[Spectrum],
    dump_bytes: int,
    repeats: int,
    repo_relative_path,
    progress,
    encode_callable,
    decode_callable,
    reason: str,
) -> None:
    encode_timing = run_timed_callable(
        f"mzML -> {display_name}",
        encode_callable,
        repeats=repeats,
        input_bytes=input_path.stat().st_size,
        progress_callback=progress.callback(f"mzML -> {display_name}"),
    )
    decode_timing = run_timed_callable(
        f"{display_name} -> dump",
        decode_callable,
        repeats=repeats,
        input_bytes=artifact_path.stat().st_size,
        output_bytes=dump_bytes,
        progress_callback=progress.callback(f"{display_name} -> dump"),
    )
    fidelity = asdict(compare_dumps(display_name, reference_dump, read_dump(roundtrip_path)))
    progress.step(f"compare {display_name} fidelity")
    records.append(
        {
            "name": display_name,
            "status": "benchmarked",
            "reason": reason,
            "artifact_path": repo_relative_path(artifact_path),
            "artifact_bytes": artifact_path.stat().st_size,
            "encode_operation": encode_timing.name,
            "decode_operation": decode_timing.name,
            "fidelity": fidelity,
        }
    )
    sizes[display_name] = {"path": repo_relative_path(artifact_path), "bytes": artifact_path.stat().st_size}
    timings.extend([encode_timing, decode_timing])


def _format_template_command(template: str, input_path: Path, output_path: Path) -> list[str]:
    values = {
        "input": str(input_path),
        "output": str(output_path),
        "input_rel": os.path.relpath(input_path, Path.cwd()),
        "output_rel": os.path.relpath(output_path, Path.cwd()),
    }
    return shlex.split(template.format(**values))


def _record_unavailable(records: list[dict[str, object]], progress, name: str, reason: str) -> None:
    progress.step(f"{name} unavailable")
    records.append(
        {
            "name": name,
            "status": "unavailable",
            "reason": reason,
            "artifact_path": None,
            "artifact_bytes": None,
            "encode_operation": None,
            "decode_operation": None,
            "fidelity": None,
        }
    )


def _benchmark_template_baseline(
    *,
    records: list[dict[str, object]],
    sizes: dict[str, dict[str, object]],
    timings: list[TimingResult],
    display_name: str,
    input_path: Path,
    artifact_path: Path,
    reference_dump: list[Spectrum],
    dump_bytes: int,
    repeats: int,
    repo_relative_path,
    progress,
    encode_template: str,
    decode_template: str | None,
) -> None:
    encode_command = _format_template_command(encode_template, input_path, artifact_path)
    encode_timing = run_timed_path_command(
        f"mzML -> {display_name}",
        encode_command,
        repeats=repeats,
        output_path=artifact_path,
        input_bytes=input_path.stat().st_size,
        progress_callback=progress.callback(f"mzML -> {display_name}"),
    )
    timings.append(encode_timing)

    record = {
        "name": display_name,
        "status": "encode-only",
        "reason": None,
        "artifact_path": repo_relative_path(artifact_path),
        "artifact_bytes": artifact_path.stat().st_size,
        "encode_operation": encode_timing.name,
        "decode_operation": None,
        "fidelity": None,
    }
    sizes[display_name] = {"path": repo_relative_path(artifact_path), "bytes": artifact_path.stat().st_size}

    if decode_template is not None:
        dump_path = artifact_path.with_suffix(artifact_path.suffix + ".roundtrip.bin")
        decode_command = _format_template_command(decode_template, artifact_path, dump_path)
        decode_timing = run_timed_path_command(
            f"{display_name} -> dump",
            decode_command,
            repeats=repeats,
            output_path=dump_path,
            input_bytes=artifact_path.stat().st_size,
            output_bytes=dump_bytes,
            progress_callback=progress.callback(f"{display_name} -> dump"),
        )
        timings.append(decode_timing)
        fidelity = asdict(compare_dumps(display_name, reference_dump, read_dump(dump_path)))
        progress.step(f"compare {display_name} fidelity")
        record["status"] = "benchmarked"
        record["decode_operation"] = decode_timing.name
        record["fidelity"] = fidelity
    else:
        record["reason"] = "Only encode and size were measured because no dump-conversion command template was provided."

    records.append(record)


def run_external_baselines(
    *,
    requested: tuple[str, ...],
    input_path: Path,
    sample_name: str,
    private_workdir: Path,
    reference_dump: list[Spectrum],
    dump_bytes: int,
    repeats: int,
    mzmlb_compression: str,
    repo_relative_path,
    progress,
    numpress_command_template: str | None = None,
    numpress_to_dump_command_template: str | None = None,
    mscompress_command_template: str | None = None,
    mscompress_to_dump_command_template: str | None = None,
    mscompress_benchmark_threaded: bool = False,
    mscompress_thread_count: int | None = None,
) -> dict[str, object]:
    records: list[dict[str, object]] = []
    sizes: dict[str, dict[str, object]] = {}
    timings: list[TimingResult] = []

    if "mzmlb" in requested:
        artifact_path = private_workdir / f"{sample_name}{OUTPUT_SUFFIXES['mzmlb']}"
        roundtrip_path = private_workdir / f"{sample_name}.mzmlb.roundtrip.bin"
        _benchmark_callable_baseline(
            records=records,
            sizes=sizes,
            timings=timings,
            display_name="mzMLb",
            input_path=input_path,
            artifact_path=artifact_path,
            roundtrip_path=roundtrip_path,
            reference_dump=reference_dump,
            dump_bytes=dump_bytes,
            repeats=repeats,
            repo_relative_path=repo_relative_path,
            progress=progress,
            encode_callable=lambda: convert_mzml_to_mzmlb(input_path, artifact_path, h5_compression=mzmlb_compression),
            decode_callable=lambda: _dump_mzmlb_quietly(artifact_path, roundtrip_path),
            reason=f"Converted with psims MzMLToMzMLb using HDF5 compression `{mzmlb_compression}`.",
        )

    if "ms-numpress" in requested:
        display_name = DISPLAY_NAMES["ms-numpress"]
        artifact_path = private_workdir / f"{sample_name}{OUTPUT_SUFFIXES['ms-numpress']}"
        if numpress_command_template is not None:
            _benchmark_template_baseline(
                records=records,
                sizes=sizes,
                timings=timings,
                display_name=display_name,
                input_path=input_path,
                artifact_path=artifact_path,
                reference_dump=reference_dump,
                dump_bytes=dump_bytes,
                repeats=repeats,
                repo_relative_path=repo_relative_path,
                progress=progress,
                encode_template=numpress_command_template,
                decode_template=numpress_to_dump_command_template,
            )
        else:
            numpress_ok, reason = builtin_numpress_available()
            if not numpress_ok:
                _record_unavailable(records, progress, display_name, reason or "MS-Numpress backend unavailable")
            else:
                roundtrip_path = private_workdir / f"{sample_name}.numpress.roundtrip.bin"
                _benchmark_callable_baseline(
                    records=records,
                    sizes=sizes,
                    timings=timings,
                    display_name=display_name,
                    input_path=input_path,
                    artifact_path=artifact_path,
                    roundtrip_path=roundtrip_path,
                    reference_dump=reference_dump,
                    dump_bytes=dump_bytes,
                    repeats=repeats,
                    repo_relative_path=repo_relative_path,
                    progress=progress,
                    encode_callable=lambda: convert_mzml_to_numpress_mzml(input_path, artifact_path),
                    decode_callable=lambda: run_dump_mzml_quietly(artifact_path, roundtrip_path),
                    reason="Converted with psims and per-array MS-Numpress compression settings.",
                )

    if "mscompress" in requested:
        display_name = DISPLAY_NAMES["mscompress"]
        artifact_path = private_workdir / f"{sample_name}{OUTPUT_SUFFIXES['mscompress']}"
        builtin_mscompress_ok, builtin_mscompress_reason = builtin_mscompress_available()
        if mscompress_command_template is not None:
            _benchmark_template_baseline(
                records=records,
                sizes=sizes,
                timings=timings,
                display_name=display_name,
                input_path=input_path,
                artifact_path=artifact_path,
                reference_dump=reference_dump,
                dump_bytes=dump_bytes,
                repeats=repeats,
                repo_relative_path=repo_relative_path,
                progress=progress,
                encode_template=mscompress_command_template,
                decode_template=mscompress_to_dump_command_template,
            )
        elif not builtin_mscompress_ok:
            _record_unavailable(
                records,
                progress,
                display_name,
                builtin_mscompress_reason or "MScompress is unavailable in this environment.",
            )
        else:
            _benchmark_callable_baseline(
                records=records,
                sizes=sizes,
                timings=timings,
                display_name=display_name,
                input_path=input_path,
                artifact_path=artifact_path,
                roundtrip_path=private_workdir / f"{sample_name}.mscompress.roundtrip.bin",
                reference_dump=reference_dump,
                dump_bytes=dump_bytes,
                repeats=repeats,
                repo_relative_path=repo_relative_path,
                progress=progress,
                encode_callable=lambda: convert_mzml_to_mscompress(input_path, artifact_path, threads=1),
                decode_callable=lambda: convert_mscompress_to_dump(
                    artifact_path,
                    private_workdir / f"{sample_name}.mscompress.roundtrip.bin",
                    threads=1,
                ),
                reason="Converted with the MScompress Python package using 1 thread for single-thread comparability.",
            )

            if mscompress_benchmark_threaded:
                threaded_name = (
                    f"MScompress ({mscompress_thread_count} threads)"
                    if mscompress_thread_count is not None
                    else "MScompress threaded"
                )
                threaded_suffix = (
                    f".threads{mscompress_thread_count}.msz"
                    if mscompress_thread_count is not None
                    else ".threaded.msz"
                )
                threaded_roundtrip = private_workdir / f"{sample_name}.mscompress.threaded.roundtrip.bin"
                _benchmark_callable_baseline(
                    records=records,
                    sizes=sizes,
                    timings=timings,
                    display_name=threaded_name,
                    input_path=input_path,
                    artifact_path=private_workdir / f"{sample_name}{threaded_suffix}",
                    roundtrip_path=threaded_roundtrip,
                    reference_dump=reference_dump,
                    dump_bytes=dump_bytes,
                    repeats=repeats,
                    repo_relative_path=repo_relative_path,
                    progress=progress,
                    encode_callable=lambda: convert_mzml_to_mscompress(
                        input_path,
                        private_workdir / f"{sample_name}{threaded_suffix}",
                        threads=mscompress_thread_count,
                    ),
                    decode_callable=lambda: convert_mscompress_to_dump(
                        private_workdir / f"{sample_name}{threaded_suffix}",
                        threaded_roundtrip,
                        threads=mscompress_thread_count,
                    ),
                    reason=(
                        f"Converted with the MScompress Python package using {mscompress_thread_count} threads."
                        if mscompress_thread_count is not None
                        else "Converted with the MScompress Python package using its default thread setting."
                    ),
                )

    return {"records": records, "sizes": sizes, "timings": timings}
