from __future__ import annotations

import json
from pathlib import Path


SEARCH_IMPACT_NOT_MEASURED = (
    "Requires downstream peptide identification and FDR measurements on the original and round-tripped spectra."
)


def comparison_artifact_order(selected_quant: int, external_baselines: list[dict[str, object]]) -> list[str]:
    names = [
        "gzip dump",
        "zstd dump",
        "mzv1 lossless",
        f"mzv1 lossy q={selected_quant}",
    ]
    for item in external_baselines:
        name = str(item["name"])
        if name not in names:
            names.append(name)
    return names


def load_search_impact(path: Path | None) -> dict[str, dict[str, object]]:
    if path is None:
        return {}

    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("Search impact JSON must be an object keyed by artifact name")

    rows: dict[str, dict[str, object]] = {}
    for artifact, value in payload.items():
        if not isinstance(artifact, str):
            raise ValueError("Search impact artifact names must be strings")
        if not isinstance(value, dict):
            raise ValueError(f"Search impact entry for {artifact} must be an object")

        rows[artifact] = {
            "peptide_identification_difference": value.get("peptide_identification_difference"),
            "peptide_identification_pct_change": value.get("peptide_identification_pct_change"),
            "fdr_change_pct_points": value.get("fdr_change_pct_points"),
            "notes": value.get("notes"),
            "source": value.get("source"),
        }
    return rows


def build_performance_rows(
    timings: list[dict[str, object]],
    *,
    selected_quant: int,
    external_baselines: list[dict[str, object]],
) -> list[dict[str, object]]:
    timing_by_name = {str(item["name"]): item for item in timings}
    rows: list[dict[str, object]] = []

    def add_row(
        artifact: str,
        direction: str,
        operation: str | None,
        *,
        source_format: str | None,
        status: str,
        notes: str | None = None,
    ) -> None:
        item = timing_by_name.get(operation or "") if operation is not None else None
        rows.append(
            {
                "artifact": artifact,
                "direction": direction,
                "operation": operation,
                "source_format": source_format,
                "status": status,
                "throughput_mib_s": None if item is None else item["throughput_mib_s"],
                "throughput_input_mib_s": None if item is None else item.get("throughput_input_mib_s"),
                "throughput_output_mib_s": None if item is None else item.get("throughput_output_mib_s"),
                "throughput_basis": None if item is None else item.get("throughput_basis"),
                "mean_seconds": None if item is None else item["mean_seconds"],
                "notes": notes,
            }
        )

    internal_rows = [
        ("gzip dump", "compression", "dump -> gzip dump", "dump"),
        ("gzip dump", "decompression", "gzip dump -> dump", "gzip dump"),
        ("zstd dump", "compression", "dump -> zstd dump", "dump"),
        ("zstd dump", "decompression", "zstd dump -> dump", "zstd dump"),
        ("mzv1 lossless", "compression", "dump -> mzv1 lossless", "dump"),
        ("mzv1 lossless", "decompression", "mzv1 lossless -> dump", "mzv1 lossless"),
        (f"mzv1 lossy q={selected_quant}", "compression", f"dump -> mzv1 lossy q={selected_quant}", "dump"),
        (f"mzv1 lossy q={selected_quant}", "decompression", f"mzv1 lossy q={selected_quant} -> dump", f"mzv1 lossy q={selected_quant}"),
    ]
    for artifact, direction, operation, source_format in internal_rows:
        add_row(artifact, direction, operation, source_format=source_format, status="measured")

    for item in external_baselines:
        artifact = str(item["name"])
        encode_operation = item.get("encode_operation")
        decode_operation = item.get("decode_operation")
        reason = item.get("reason")

        if encode_operation is not None:
            source_format = str(encode_operation).split(" -> ", 1)[0]
            add_row(artifact, "compression", str(encode_operation), source_format=source_format, status="measured")
        else:
            add_row(artifact, "compression", None, source_format=None, status=str(item["status"]), notes=None if reason is None else str(reason))

        if decode_operation is not None:
            source_format = str(decode_operation).split(" -> ", 1)[0]
            add_row(artifact, "decompression", str(decode_operation), source_format=source_format, status="measured")
        else:
            add_row(artifact, "decompression", None, source_format=None, status=str(item["status"]), notes=None if reason is None else str(reason))

    return rows


def build_fidelity_metric_rows(
    fidelity_rows: list[dict[str, object]],
    *,
    selected_quant: int,
    external_baselines: list[dict[str, object]],
) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    seen: set[str] = set()

    for row in fidelity_rows:
        artifact = str(row["artifact"])
        item = row["data"]
        rows.append(
            {
                "artifact": artifact,
                "status": "measured",
                "global_order_preserved": item["global_order_preserved"],
                "ms1_relative_order_preserved": item["ms1_relative_order_preserved"],
                "ms2_relative_order_preserved": item["ms2_relative_order_preserved"],
                "max_abs_mz_error": item["mz_abs"]["max"],
                "mean_abs_mz_error": item["mz_abs"]["mean"],
                "mean_abs_intensity_error": item["intensity_abs"]["mean"],
                "max_abs_intensity_error": item["intensity_abs"]["max"],
                "rmse_intensity_error": item["intensity_abs"]["rmse"],
                "p95_rel_intensity_error_pct": item["intensity_rel"]["p95"] * 100.0,
                "p99_rel_intensity_error_pct": item["intensity_rel"]["p99"] * 100.0,
                "mean_abs_log1p_intensity_error": item["intensity_log1p_abs"]["mean"],
                "notes": None,
            }
        )
        seen.add(artifact)

    for item in external_baselines:
        artifact = str(item["name"])
        if artifact in seen:
            continue
        rows.append(
            {
                "artifact": artifact,
                "status": str(item["status"]),
                "global_order_preserved": None,
                "ms1_relative_order_preserved": None,
                "ms2_relative_order_preserved": None,
                "max_abs_mz_error": None,
                "mean_abs_mz_error": None,
                "mean_abs_intensity_error": None,
                "max_abs_intensity_error": None,
                "rmse_intensity_error": None,
                "p95_rel_intensity_error_pct": None,
                "p99_rel_intensity_error_pct": None,
                "mean_abs_log1p_intensity_error": None,
                "notes": item.get("reason"),
            }
        )

    order = comparison_artifact_order(selected_quant, external_baselines)
    order_index = {name: idx for idx, name in enumerate(order)}
    rows.sort(key=lambda row: order_index.get(str(row["artifact"]), len(order_index)))
    return rows


def _search_impact_aliases(artifact: str) -> list[str]:
    aliases = [artifact]
    lower = artifact.lower()
    if lower.startswith("mzv1 lossy q="):
        aliases.append("mzv1 lossy")
    if artifact == "MS-Numpress in mzML":
        aliases.extend(["MS-Numpress", "ms-numpress", "numpress"])
    if artifact == "mzMLb":
        aliases.append("mzmlb")
    return aliases


def build_search_impact_rows(
    *,
    selected_quant: int,
    external_baselines: list[dict[str, object]],
    search_impact_data: dict[str, dict[str, object]],
    fidelity_metric_rows: list[dict[str, object]],
) -> list[dict[str, object]]:
    fidelity_by_artifact = {str(item["artifact"]): item for item in fidelity_metric_rows}
    external_by_artifact = {str(item["name"]): item for item in external_baselines}
    rows: list[dict[str, object]] = []

    for artifact in comparison_artifact_order(selected_quant, external_baselines):
        metrics = None
        for alias in _search_impact_aliases(artifact):
            if alias in search_impact_data:
                metrics = search_impact_data[alias]
                break

        if metrics is not None:
            rows.append(
                {
                    "artifact": artifact,
                    "status": "measured",
                    "peptide_identification_difference": metrics.get("peptide_identification_difference"),
                    "peptide_identification_pct_change": metrics.get("peptide_identification_pct_change"),
                    "fdr_change_pct_points": metrics.get("fdr_change_pct_points"),
                    "notes": metrics.get("notes"),
                    "source": metrics.get("source"),
                }
            )
            continue

        external_item = external_by_artifact.get(artifact)
        if external_item is not None and str(external_item["status"]) == "unavailable":
            rows.append(
                {
                    "artifact": artifact,
                    "status": "unavailable",
                    "peptide_identification_difference": None,
                    "peptide_identification_pct_change": None,
                    "fdr_change_pct_points": None,
                    "notes": external_item.get("reason"),
                    "source": None,
                }
            )
            continue

        notes = SEARCH_IMPACT_NOT_MEASURED
        fidelity_item = fidelity_by_artifact.get(artifact)
        if fidelity_item is not None and fidelity_item["status"] == "measured":
            max_mz_error = fidelity_item["max_abs_mz_error"]
            mean_intensity_error = fidelity_item["mean_abs_intensity_error"]
            if max_mz_error == 0.0 and mean_intensity_error == 0.0:
                notes += " Dump round-trip was numerically exact on the current comparison."

        rows.append(
            {
                "artifact": artifact,
                "status": "not-measured",
                "peptide_identification_difference": None,
                "peptide_identification_pct_change": None,
                "fdr_change_pct_points": None,
                "notes": notes,
                "source": None,
            }
        )

    return rows

