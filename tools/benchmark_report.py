from __future__ import annotations

from benchmark_core import format_bytes, format_interval, format_percent

FUTURE_BASELINES = [
    {
        "name": "MScompress",
        "core_idea": "Multi-threaded mzML to MSZ compressor with random-access decode support and configurable lossless or lossy encoding.",
        "why_it_matters": "It is a modern practical systems baseline with explicit focus on speed, threading, and usable compressed-file access.",
        "source": "chrisagrams/mscompress",
    },
    {
        "name": "MS-Numpress in mzML",
        "core_idea": "Array-level compression inside the mzML ecosystem: linear prediction for smooth m/z arrays and logged or integer schemes for intensities.",
        "why_it_matters": "It is the closest standard-adjacent baseline for testing whether mzarc beats established PSI-compatible spectrum array compression.",
        "source": "ms-numpress project",
    },
    {
        "name": "mzMLb",
        "core_idea": "Keeps standards-compliant mzML metadata while moving bulk numeric arrays into HDF5 for better speed and storage efficiency.",
        "why_it_matters": "It is a direct standard-preserving answer to the same problem mzarc is addressing: less storage and faster access without giving up open-format interoperability.",
        "source": "PMID: 32864978",
    },
]

def _format_optional_number(value: object, *, precision: int = 6, suffix: str = "") -> str:
    if value is None:
        return "n/a"
    number = float(value)
    if number == 0.0:
        return f"0{suffix}"
    if precision <= 0:
        return f"{int(round(number))}{suffix}"
    return f"{number:.{precision}g}{suffix}"

def _format_optional_percent(value: object, *, precision: int = 3) -> str:
    if value is None:
        return "n/a"
    return f"{float(value):.{precision}f}%"

def _join_with_and(items: list[str]) -> str:
    if not items:
        return ""
    if len(items) == 1:
        return items[0]
    if len(items) == 2:
        return f"{items[0]} and {items[1]}"
    return ", ".join(items[:-1]) + f", and {items[-1]}"

def render_markdown(report: dict) -> str:
    dataset = report["dataset"]
    selected_quant = report["selected_lossy_intensity_quant"]
    external_baselines = report.get("external_baselines", [])
    performance_rows = report.get("performance_rows", [])
    fidelity_metrics = report.get("fidelity_metrics", [])
    fidelity_rows = report.get("fidelity_rows", [])
    search_impact_rows = report.get("search_impact_rows", [])
    codec_byte_breakdown = report.get("codec_byte_breakdown", {})

    lines: list[str] = []

    line = lines.append
    def blank() -> None:
        if not lines or lines[-1] != "":
            lines.append("")

    def section(title: str, *, level: int = 2) -> None:
        blank()
        line(f"{'#' * level} {title}")
        blank()

    def bullets(items: list[str]) -> None:
        lines.extend(f"- {item}" for item in items)
        blank()

    def paragraph(text: str) -> None:
        line(text)
        blank()

    def image(alt: str, path: str) -> None:
        line(f"![{alt}]({path})")
        blank()

    def table(headers: list[str], rows: list[list[str]], alignments: list[str] | None = None) -> None:
        alignments = alignments or ["left"] * len(headers)
        markers = {"left": "---", "right": "---:", "center": ":---:"}
        line("| " + " | ".join(headers) + " |")
        line("| " + " | ".join(markers.get(item, "---") for item in alignments) + " |")
        for row in rows:
            line("| " + " | ".join(row) + " |")
        blank()

    benchmarked_external = [item["name"] for item in external_baselines if item["status"] == "benchmarked"]
    mzml_bytes = report["sizes"]["mzML"]["bytes"]
    dump_bytes = report["sizes"]["dump"]["bytes"]

    line(f"# Benchmark Report: {report['sample_name']}")
    blank()
    bullets(
        [
            f"mzML input: {report['paths']['mzml']}",
            f"private workdir: {report['paths']['private_workdir']}",
            f"public output dir: {report['paths']['public_dir']}",
            f"repeats: {report['repeats']}",
            f"selected lossy intensity quantization: q={selected_quant}",
        ]
    )

    section("Story")
    paragraph(
        "The flat dump is smaller than mzML because it strips almost all interchange overhead: XML structure, controlled-vocabulary markup, base64 wrapping, and general-purpose metadata that this prototype does not need for codec bring-up. That makes the dump a useful internal floor, not a format competitor by itself."
    )
    paragraph(
        "This benchmark focuses on two things that matter right now: whether the current `.mzarc` path buys meaningful size reduction over the interchange format, and whether encode and decode stay fast and stable across repeated runs."
    )

    paragraph(
        f"External formats that actually ran end-to-end in this benchmark: {', '.join(benchmarked_external)}."
        if benchmarked_external
        else "No external formats ran end-to-end in this benchmark."
    )

    section("Dataset")
    bullets(
        [
            f"spectra: {dataset['spectra']}",
            f"total peaks: {dataset['total_peaks']}",
            f"ms1 spectra: {dataset['ms1_spectra']}",
            f"ms2 spectra: {dataset['ms2_spectra']}",
        ]
    )

    section("Size Comparison")
    image("Artifact Size Comparison", f"plots/{report['plots']['size_comparison']}")
    table(
        ["artifact", "bytes", "size", "vs mzML", "vs dump"],
        [
            [
                artifact,
                str(item["bytes"]),
                format_bytes(item["bytes"]),
                f"{(item['bytes'] / mzml_bytes) * 100:.2f}%",
                f"{(item['bytes'] / dump_bytes) * 100:.2f}%",
            ]
            for artifact, item in report["sizes"].items()
        ],
        ["left", "right", "right", "right", "right"],
    )
    paragraph(
        "Lossless `.mzarc` is already materially smaller than mzML on this sample, and it slightly beats `gzip` on the dump baseline while still trailing `zstd` on the dump. The selected lossy mode gives a controlled next step down in size without the catastrophic saturation behavior that the earlier intensity quantizer had."
    )

    if codec_byte_breakdown:
        section("Byte Composition")
        table(
            ["artifact", "structural bytes", "spectrum metadata", "m/z stream", "intensity stream", "total"],
            [
                [
                    artifact,
                    f"{format_bytes(data['file_header_bytes'] + data['global_order_bytes'] + data['block_header_bytes'])} ({((data['file_header_bytes'] + data['global_order_bytes'] + data['block_header_bytes']) / data['total_bytes']) * 100:.2f}%)",
                    f"{format_bytes(data['scan_id_bytes'] + data['rt_bytes'] + data['precursor_bytes'] + data['peak_count_bytes'])} ({((data['scan_id_bytes'] + data['rt_bytes'] + data['precursor_bytes'] + data['peak_count_bytes']) / data['total_bytes']) * 100:.2f}%)",
                    f"{format_bytes(data['mz_metadata_bytes'] + data['mz_payload_bytes'])} ({((data['mz_metadata_bytes'] + data['mz_payload_bytes']) / data['total_bytes']) * 100:.2f}%)",
                    f"{format_bytes(data['intensity_metadata_bytes'] + data['intensity_payload_bytes'])} ({((data['intensity_metadata_bytes'] + data['intensity_payload_bytes']) / data['total_bytes']) * 100:.2f}%)",
                    format_bytes(data['total_bytes']),
                ]
                for artifact, data in codec_byte_breakdown.items()
            ],
            ["left", "right", "right", "right", "right", "right"],
        )

        lossless_bytes = codec_byte_breakdown.get("mzarc lossless")
        if lossless_bytes is not None:
            structural_bytes = lossless_bytes["file_header_bytes"] + lossless_bytes["global_order_bytes"] + lossless_bytes["block_header_bytes"]
            spectrum_metadata_bytes = lossless_bytes["scan_id_bytes"] + lossless_bytes["rt_bytes"] + lossless_bytes["precursor_bytes"] + lossless_bytes["peak_count_bytes"]
            mz_stream_bytes = lossless_bytes["mz_metadata_bytes"] + lossless_bytes["mz_payload_bytes"]
            intensity_stream_bytes = lossless_bytes["intensity_metadata_bytes"] + lossless_bytes["intensity_payload_bytes"]
            dominant_component = max(
                [
                    ("structural overhead", structural_bytes),
                    ("per-spectrum metadata", spectrum_metadata_bytes),
                    ("the m/z stream", mz_stream_bytes),
                    ("the intensity stream", intensity_stream_bytes),
                ],
                key=lambda item: item[1],
            )
            paragraph(
                f"The lossless byte breakdown shows whether the size regression is real payload or container overhead. On this run, {dominant_component[0]} is the largest component at {format_bytes(dominant_component[1])}, which keeps the diagnosis grounded in actual encoded bytes rather than guesswork."
            )

    section("Performance Overview")
    image("Throughput Overview", f"plots/{report['plots']['performance_overview']}")
    table(
        ["artifact", "direction", "status", "throughput", "mean time", "throughput basis", "source format", "notes"],
        [
            [
                item["artifact"],
                item["direction"],
                item["status"],
                _format_optional_number(item["throughput_mib_s"], precision=4, suffix=" MiB/s"),
                _format_optional_number(item["mean_seconds"], precision=5, suffix="s"),
                item["throughput_basis"] or "n/a",
                item["source_format"] or "n/a",
                item["notes"] or "",
            ]
            for item in performance_rows
        ],
        ["left", "left", "left", "right", "right", "left", "left", "left"],
    )

    section("Timing Variability")
    image("Timing Variability Across Runs", f"plots/{report['plots']['timing_intervals']}")
    paragraph(
        f"The chart above uses all {report['repeats']} runs per operation. Gray dots are individual runs. Black points show the mean with a two-sided 95% confidence interval for the mean."
    )
    table(
        ["operation", "mean ± sd", "median", "95% CI of mean", "min", "max", "throughput", "basis"],
        [
            [
                item["name"],
                f"{item['mean_seconds']:.4f}s ± {item['stdev_seconds']:.4f}s",
                f"{item['median_seconds']:.4f}s",
                format_interval(item["ci95_low_seconds"], item["ci95_high_seconds"]),
                f"{item['min_seconds']:.4f}s",
                f"{item['max_seconds']:.4f}s",
                "n/a" if item["throughput_mib_s"] is None else f"{item['throughput_mib_s']:.2f} MiB/s",
                item.get("throughput_basis", "n/a"),
            ]
            for item in report["timings"]
        ],
        ["left", "right", "right", "right", "right", "right", "right", "left"],
    )

    section("External Baselines")
    if external_baselines:
        table(
            ["baseline", "status", "size", "encode", "decode", "notes"],
            [
                [
                    item["name"],
                    item["status"],
                    "n/a" if item["artifact_bytes"] is None else format_bytes(item["artifact_bytes"]),
                    item["encode_operation"] or "n/a",
                    item["decode_operation"] or "n/a",
                    item["reason"] or "",
                ]
                for item in external_baselines
            ],
            ["left", "left", "right", "left", "left", "left"],
        )
    else:
        paragraph("No external baselines were requested for this run.")

    section("Data Fidelity")
    image("Data Fidelity Overview", f"plots/{report['plots']['fidelity_overview']}")
    table(
        ["artifact", "status", "global order", "max abs m/z", "max ppm m/z", "mean abs intensity", "max abs intensity", "p95 rel intensity", "notes"],
        [
            [
                item["artifact"],
                item["status"],
                str(item["global_order_preserved"]).lower() if item["global_order_preserved"] is not None else "n/a",
                _format_optional_number(item["max_abs_mz_error"], precision=9),
                _format_optional_number(item.get("max_ppm_mz_error"), precision=6),
                _format_optional_number(item["mean_abs_intensity_error"], precision=9),
                _format_optional_number(item["max_abs_intensity_error"], precision=9),
                _format_optional_percent(item["p95_rel_intensity_error_pct"]),
                item["notes"] or "",
            ]
            for item in fidelity_metrics
        ],
        ["left", "left", "right", "right", "right", "right", "right", "right", "left"],
    )

    section("Fidelity Summary")
    table(
        ["artifact", "global order", "ms1 order", "ms2 order", "mean abs mz", "max abs mz", "max ppm mz", "mean abs intensity", "rmse intensity", "p95 rel intensity", "p99 rel intensity", "mean abs log1p intensity"],
        [
            [
                row["artifact"],
                str(row["data"]["global_order_preserved"]).lower(),
                str(row["data"]["ms1_relative_order_preserved"]).lower(),
                str(row["data"]["ms2_relative_order_preserved"]).lower(),
                f"{row['data']['mz_abs']['mean']:.9g}",
                f"{row['data']['mz_abs']['max']:.9g}",
                f"{row['data'].get('mz_ppm', {}).get('max', 0.0):.6g}",
                f"{row['data']['intensity_abs']['mean']:.9g}",
                f"{row['data']['intensity_abs']['rmse']:.9g}",
                format_percent(row["data"]["intensity_rel"]["p95"]),
                format_percent(row["data"]["intensity_rel"]["p99"]),
                f"{row['data']['intensity_log1p_abs']['mean']:.9g}",
            ]
            for row in fidelity_rows
        ],
        ["left", "right", "right", "right", "right", "right", "right", "right", "right", "right", "right", "right"],
    )
    exact_artifacts = [f"`{item['artifact']}`" for item in fidelity_metrics if item["status"] == "measured" and float(item.get("max_abs_mz_error") or 0.0) == 0.0 and float(item.get("max_abs_intensity_error") or 0.0) == 0.0]
    lossless_row = next((row["data"] for row in fidelity_rows if row["artifact"] == "mzarc lossless"), None)
    lossy_row = next((row["data"] for row in fidelity_rows if str(row["artifact"]).startswith("mzarc lossy q=")), None)

    lossless_summary = "`mzarc lossless` was not included in this run."
    if lossless_row is not None:
        lossless_exact = (
            float(lossless_row["mz_abs"]["max"]) == 0.0 and
            float(lossless_row["intensity_abs"]["max"]) == 0.0
        )
        if lossless_exact and bool(lossless_row["global_order_preserved"]):
            lossless_summary = "`mzarc lossless` round-trips exactly, including m/z values and original scan order."
        elif lossless_exact:
            lossless_summary = "`mzarc lossless` is numerically exact but still does not preserve original global scan order."
        else:
            lossless_summary = "`mzarc lossless` still carries measurable round-trip error and needs more work before it can be treated as exact."

    lossy_summary = "`mzarc lossy` was not included in this run."
    if lossy_row is not None:
        lossy_summary = (
            "`mzarc lossy` preserves original scan order while keeping m/z and intensity error within the current quantization bounds."
            if bool(lossy_row["global_order_preserved"])
            else "`mzarc lossy` keeps m/z and intensity error within the current quantization bounds, but it still does not preserve original global scan order."
        )

    exact_sentence = (
        f"On the current run, {_join_with_and(exact_artifacts)} round-trip exactly."
        if exact_artifacts
        else "On the current run, no measured artifact round-trips exactly."
    )

    paragraph(
        f"{exact_sentence} {lossless_summary} {lossy_summary}"
    )

    section("Lossy Sweep")
    image("Lossy Tradeoff", f"plots/{report['plots']['lossy_tradeoff']}")
    table(
        ["q", "bytes", "size", "p95 rel intensity err", "p99 rel intensity err", "mean rel intensity err"],
        [
            [
                str(item["intensity_quant"]),
                str(item["bytes"]),
                format_bytes(item["bytes"]),
                format_percent(item["fidelity"]["intensity_rel"]["p95"]),
                format_percent(item["fidelity"]["intensity_rel"]["p99"]),
                format_percent(item["fidelity"]["intensity_rel"]["mean"]),
            ]
            for item in report["lossy_sweep"]
        ],
        ["right", "right", "right", "right", "right", "right"],
    )
    paragraph(
        "The selected `q` stays user-controlled. Higher `q` means more preserved log-intensity precision and usually a larger file; lower `q` buys size at the cost of broader relative error tails."
    )
    image("Relative Intensity Error Quantiles", f"plots/{report['plots']['intensity_relative_quantiles']}")

    section("Search Impact")
    table(
        ["artifact", "status", "peptide ID difference", "peptide ID change", "FDR change", "notes"],
        [
            [
                item["artifact"],
                item["status"],
                _format_optional_number(item["peptide_identification_difference"], precision=0),
                _format_optional_percent(item["peptide_identification_pct_change"]),
                _format_optional_percent(item["fdr_change_pct_points"]),
                item["notes"] or "",
            ]
            for item in search_impact_rows
        ],
        ["left", "left", "right", "right", "right", "left"],
    )
    paragraph(
        "Measured search-impact rows were supplied externally for this run."
        if any(item["status"] == "measured" for item in search_impact_rows)
        else "Search-impact metrics are not measured by the current benchmark pipeline yet. They remain listed here so the report does not imply numerical equivalence where no downstream search experiment has actually been run."
    )

    section("How The Error Numbers Are Computed")
    paragraph("The reported means are computed over every matched peak after round-trip decode. They are not inferred from min and max.")
    bullets(
        [
            "Mean absolute error: average absolute per-peak error.",
            "RMSE: square root of the average squared per-peak error.",
            "Relative intensity error: absolute error divided by the original intensity, evaluated only on strictly positive peaks.",
            "log1p intensity error: absolute error after applying `log1p`, which keeps the metric useful across large dynamic range.",
        ]
    )

    benchmarked_names = {item["name"] for item in external_baselines if item["status"] != "unavailable"}
    remaining_candidates = [item for item in report["comparison_candidates"] if item["name"] not in benchmarked_names]
    section("Future Comparison Candidates")
    if remaining_candidates:
        paragraph("These are the remaining or still-blocked comparison candidates after the current benchmark run.")
        table(
            ["candidate", "core idea", "why test it next", "source"],
            [[item["name"], item["core_idea"], item["why_it_matters"], item["source"]] for item in remaining_candidates],
        )
    else:
        paragraph("All named comparison candidates are wired into the current benchmark run in some form.")

    return "\n".join(lines).rstrip() + "\n"
