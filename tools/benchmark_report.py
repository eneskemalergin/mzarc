from __future__ import annotations

from benchmark_core import format_bytes, format_percent


def _fmt(value: object, *, precision: int = 4, suffix: str = "") -> str:
    """Format an optional numeric value; returns 'n/a' for None."""
    if value is None:
        return "n/a"
    number = float(value)
    if number == 0.0:
        return f"0{suffix}"
    if precision <= 0:
        return f"{int(round(number))}{suffix}"
    return f"{number:.{precision}g}{suffix}"


def _pct(value: object, *, precision: int = 3) -> str:
    """Format a value that is already in percent units (0-100 scale)."""
    if value is None:
        return "n/a"
    return f"{float(value):.{precision}f}%"


def render_markdown(report: dict) -> str:
    dataset              = report["dataset"]
    selected_quant       = report["selected_lossy_intensity_quant"]
    external_baselines   = report.get("external_baselines", [])
    performance_rows     = report.get("performance_rows", [])
    fidelity_metrics     = report.get("fidelity_metrics", [])
    fidelity_rows        = report.get("fidelity_rows", [])
    codec_byte_breakdown = report.get("codec_byte_breakdown", {})
    memory_metric_rows   = report.get("memory_metric_rows", [])
    stat_comparisons     = report.get("stat_comparisons", [])

    mzml_bytes           = report["sizes"]["mzML"]["bytes"]
    dump_bytes           = report["sizes"]["dump"]["bytes"]
    benchmarked_external = [b["name"] for b in external_baselines if b["status"] == "measured"]

    lines: list[str] = []
    line = lines.append

    def blank() -> None:
        if not lines or lines[-1] != "":
            lines.append("")

    def section(title: str, *, level: int = 2) -> None:
        blank()
        line(f"{'#' * level} {title}")
        blank()

    def paragraph(text: str) -> None:
        line(text)
        blank()

    def image(alt: str, path: str) -> None:
        line(f"![{alt}]({path})")
        blank()

    def table(
        headers: list[str],
        rows: list[list[str]],
        alignments: list[str] | None = None,
    ) -> None:
        alignments = alignments or ["left"] * len(headers)
        markers = {"left": "---", "right": "---:", "center": ":---:"}
        line("| " + " | ".join(headers) + " |")
        line("| " + " | ".join(markers.get(a, "---") for a in alignments) + " |")
        for row in rows:
            line("| " + " | ".join(row) + " |")
        blank()

    # ---------------------------------------------------------------------- #
    # Header                                                                   #
    # ---------------------------------------------------------------------- #
    line(f"# Benchmark Report: {report['sample_name']}")
    blank()
    line(
        f"**Dataset:** `{report['paths']['mzml']}`  |  "
        f"{dataset['spectra']:,} spectra "
        f"({dataset['ms1_spectra']:,} MS1 / {dataset['ms2_spectra']:,} MS2)  |  "
        f"{dataset['total_peaks']:,} total peaks  |  "
        f"lossy q={selected_quant}"
    )
    blank()
    paragraph(
        "mzarc is a domain-specific MS codec: it strips mzML interchange overhead "
        "and applies delta coding, frame-of-reference packing, and rANS entropy coding "
        "tuned to the statistical structure of m/z and intensity arrays. "
        "Three comparison groups are used: MS-domain codecs (mzarc, mzMLb, MScompress, "
        "MS-Numpress) that understand spectrum structure; generic compressors applied to "
        "the mzML XML interchange format; and generic compressors applied to the stripped "
        "binary dump (a lower-bound reference that is not a viable interchange format)."
    )

    # ---------------------------------------------------------------------- #
    # Key Results                                                              #
    # ---------------------------------------------------------------------- #
    section("Key Results")

    # Lookup encode/decode throughput keyed by artifact name.
    perf: dict[str, dict[str, float | None]] = {}
    for row in performance_rows:
        art = row["artifact"]
        if art not in perf:
            perf[art] = {"compress": None, "decompress": None}
        if row["direction"] == "compression" and row.get("throughput_mib_s") is not None:
            perf[art]["compress"] = float(row["throughput_mib_s"])
        elif row["direction"] == "decompression" and row.get("throughput_mib_s") is not None:
            perf[art]["decompress"] = float(row["throughput_mib_s"])

    def _is_exact(artifact: str) -> str:
        for item in fidelity_metrics:
            if item["artifact"] == artifact:
                return (
                    "exact"
                    if float(item.get("max_abs_mz_error") or 0) == 0
                    and float(item.get("max_abs_intensity_error") or 0) == 0
                    else "lossy"
                )
        return "n/a"

    ms_codecs = [
        "mzarc lossless",
        f"mzarc lossy q={selected_quant}",
        "mzMLb",
        "MScompress",
        "MScompress (1T)",
        "MS-Numpress in mzML",
    ]
    table(
        ["codec", "size", "vs mzML", "encode MiB/s", "decode MiB/s", "fidelity"],
        [
            [
                art,
                format_bytes(report["sizes"][art]["bytes"]) if art in report["sizes"] else "n/a",
                f"{report['sizes'][art]['bytes'] / mzml_bytes * 100:.1f}%"
                if art in report["sizes"]
                else "n/a",
                _fmt((perf.get(art) or {}).get("compress"), precision=4),
                _fmt((perf.get(art) or {}).get("decompress"), precision=4),
                _is_exact(art),
            ]
            for art in ms_codecs
            if art in report["sizes"] or art in perf
        ],
        ["left", "right", "right", "right", "right", "left"],
    )

    # Generic baseline context.
    best_dump_entry = min(
        (
            (k, v)
            for k, v in report["sizes"].items()
            if "dump" in k.lower() and k not in {"dump", "mzML"}
        ),
        key=lambda kv: kv[1]["bytes"],
        default=None,
    )
    mzarc_lossless_bytes = report["sizes"].get("mzarc lossless", {}).get("bytes")
    if best_dump_entry and mzarc_lossless_bytes:
        best_name, best_val = best_dump_entry
        delta_pct = (best_val["bytes"] - mzarc_lossless_bytes) / best_val["bytes"] * 100
        paragraph(
            f"Best single-thread generic size on the binary dump: "
            f"`{best_name}` at {format_bytes(best_val['bytes'])} "
            f"({best_val['bytes'] / mzml_bytes * 100:.1f}% of mzML). "
            f"mzarc lossless is {delta_pct:.1f}% smaller."
        )

    if benchmarked_external:
        paragraph(
            f"External MS-domain codecs benchmarked in this run: {', '.join(benchmarked_external)}."
        )

    # ---------------------------------------------------------------------- #
    # Size Comparison                                                          #
    # ---------------------------------------------------------------------- #
    section("Size Comparison")
    image("Artifact Size Comparison", f"plots/{report['plots']['size_comparison']}")
    table(
        ["artifact", "size", "vs mzML", "vs dump"],
        [
            [
                artifact,
                format_bytes(item["bytes"]),
                f"{item['bytes'] / mzml_bytes * 100:.2f}%",
                f"{item['bytes'] / dump_bytes * 100:.2f}%",
            ]
            for artifact, item in report["sizes"].items()
        ],
        ["left", "right", "right", "right"],
    )

    if codec_byte_breakdown:
        section("Internal Byte Breakdown", level=3)
        table(
            ["artifact", "structural", "spectrum metadata", "m/z stream", "intensity stream", "total"],
            [
                [
                    artifact,
                    *[
                        f"{format_bytes(n)} ({n / data['total_bytes'] * 100:.1f}%)"
                        for n in [
                            data["file_header_bytes"] + data["global_order_bytes"] + data["block_header_bytes"],
                            data["scan_id_bytes"] + data["rt_bytes"] + data["precursor_bytes"] + data["peak_count_bytes"],
                            data["mz_metadata_bytes"] + data["mz_payload_bytes"],
                            data["intensity_metadata_bytes"] + data["intensity_payload_bytes"],
                        ]
                    ],
                    format_bytes(data["total_bytes"]),
                ]
                for artifact, data in codec_byte_breakdown.items()
            ],
            ["left", "right", "right", "right", "right", "right"],
        )

    # ---------------------------------------------------------------------- #
    # Throughput                                                               #
    # ---------------------------------------------------------------------- #
    section("Throughput")
    image("Throughput Overview", f"plots/{report['plots']['performance_overview']}")
    table(
        ["artifact", "category", "direction", "throughput", "median", "n"],
        [
            [
                item["artifact"],
                item.get("category_label") or "",
                item["direction"],
                _fmt(item["throughput_mib_s"], precision=4, suffix=" MiB/s"),
                _fmt(item["median_seconds"], precision=4, suffix="s"),
                str(item["sample_count"]) if item.get("sample_count") else "n/a",
            ]
            for item in performance_rows
            if item.get("status") == "measured"
        ],
        ["left", "left", "left", "right", "right", "right"],
    )

    # ---------------------------------------------------------------------- #
    # Memory and CPU                                                           #
    # ---------------------------------------------------------------------- #
    if memory_metric_rows:
        section("Memory and CPU")
        paragraph(
            "All values are zebrac medians from Linux perf counters. "
            "IPC = instructions / cycle (higher = more compute-efficient). "
            "Cache miss rate = cache_misses / cache_references (lower = better data locality)."
        )
        if "memory_footprint" in report.get("plots", {}):
            image("Peak RSS", f"plots/{report['plots']['memory_footprint']}")
        if "hardware_efficiency" in report.get("plots", {}):
            image("Hardware Algorithm Efficiency", f"plots/{report['plots']['hardware_efficiency']}")
        table(
            ["operation", "wall time", "peak RSS", "instructions", "IPC", "cache miss rate", "n"],
            [
                [
                    row["operation"],
                    _fmt(row["wall_time_median_seconds"], precision=4, suffix="s"),
                    f"{row['peak_rss_median_mib']:.1f} MiB",
                    f"{row['instructions_median']:.3g}",
                    _fmt(row.get("ipc"), precision=3),
                    _pct(
                        row["cache_miss_rate"] * 100
                        if row.get("cache_miss_rate") is not None
                        else None
                    ),
                    str(row["sample_count"]),
                ]
                for row in memory_metric_rows
            ],
            ["left", "right", "right", "right", "right", "right", "right"],
        )

    # ---------------------------------------------------------------------- #
    # Statistical Comparisons                                                  #
    # ---------------------------------------------------------------------- #
    rows_with_ratio = [c for c in stat_comparisons if c.get("speed_ratio") is not None]
    if rows_with_ratio:
        section("Statistical Comparisons")
        paragraph(
            "Mann-Whitney U tests on log-normal samples drawn from zebrac summary statistics. "
            "Speed ratio = mzarc time / baseline time; ratio < 1 means mzarc is faster. "
            "p < 0.05 is significant."
        )
        if "stat_comparisons" in report.get("plots", {}):
            image("Speed Ratio: mzarc vs Baselines", f"plots/{report['plots']['stat_comparisons']}")
        table(
            ["operation A", "operation B", "speed ratio", "p-value", "significant"],
            [
                [
                    str(c.get("name_a", c.get("operation_a", ""))),
                    str(c.get("name_b", c.get("operation_b", ""))),
                    _fmt(c.get("speed_ratio"), precision=3),
                    _fmt(c.get("p_value"), precision=4),
                    "yes" if c.get("significant") else "no",
                ]
                for c in rows_with_ratio
            ],
            ["left", "left", "right", "right", "left"],
        )

    # ---------------------------------------------------------------------- #
    # Data Fidelity                                                            #
    # ---------------------------------------------------------------------- #
    section("Data Fidelity")
    image("Data Fidelity Overview", f"plots/{report['plots']['fidelity_overview']}")

    # p99 from fidelity_rows is a raw fraction; format_percent handles it.
    p99_by_artifact: dict[str, float] = {
        row["artifact"]: float(row["data"]["intensity_rel"]["p99"])
        for row in fidelity_rows
        if row["data"].get("intensity_rel", {}).get("p99") is not None
    }

    table(
        ["artifact", "exact", "global order", "max ppm m/z", "p95 rel intensity", "p99 rel intensity"],
        [
            [
                item["artifact"],
                "yes"
                if (
                    float(item.get("max_abs_mz_error") or 0) == 0
                    and float(item.get("max_abs_intensity_error") or 0) == 0
                )
                else "no",
                str(item["global_order_preserved"]).lower()
                if item["global_order_preserved"] is not None
                else "n/a",
                _fmt(item.get("max_ppm_mz_error"), precision=5),
                _pct(item["p95_rel_intensity_error_pct"]),
                format_percent(p99_by_artifact[item["artifact"]])
                if item["artifact"] in p99_by_artifact
                else "n/a",
            ]
            for item in fidelity_metrics
        ],
        ["left", "left", "left", "right", "right", "right"],
    )

    # Narrative summary.
    exact_artifacts = [
        f"`{item['artifact']}`"
        for item in fidelity_metrics
        if float(item.get("max_abs_mz_error") or 0) == 0
        and float(item.get("max_abs_intensity_error") or 0) == 0
    ]
    lossless_row = next(
        (r["data"] for r in fidelity_rows if r["artifact"] == "mzarc lossless"), None
    )
    lossy_row = next(
        (r["data"] for r in fidelity_rows if str(r["artifact"]).startswith("mzarc lossy q=")),
        None,
    )
    parts: list[str] = []
    if exact_artifacts:
        exact_list = (
            ", ".join(exact_artifacts[:-1]) + " and " + exact_artifacts[-1]
            if len(exact_artifacts) > 1
            else exact_artifacts[0]
        )
        parts.append(f"{exact_list} round-trip exactly.")
    if lossless_row is not None and (
        float(lossless_row["mz_abs"]["max"]) == 0
        and float(lossless_row["intensity_abs"]["max"]) == 0
        and lossless_row["global_order_preserved"]
    ):
        parts.append("`mzarc lossless` is numerically exact and preserves global scan order.")
    if lossy_row is not None:
        p95_str = format_percent(lossy_row["intensity_rel"]["p95"])
        if lossy_row["global_order_preserved"]:
            parts.append(
                f"`mzarc lossy` preserves scan order; p95 relative intensity error is {p95_str}."
            )
        else:
            parts.append(
                f"`mzarc lossy` p95 relative intensity error is {p95_str}, "
                f"but does not preserve global scan order."
            )
    if parts:
        paragraph(" ".join(parts))

    # ---------------------------------------------------------------------- #
    # Lossy Quantization Sweep                                                 #
    # ---------------------------------------------------------------------- #
    section("Lossy Quantization Sweep")
    image("Lossy Tradeoff", f"plots/{report['plots']['lossy_tradeoff']}")
    table(
        ["q", "size", "vs mzML", "p95 rel intensity err", "p99 rel intensity err", "mean"],
        [
            [
                str(item["intensity_quant"]),
                format_bytes(item["bytes"]),
                f"{item['bytes'] / mzml_bytes * 100:.1f}%",
                format_percent(item["fidelity"]["intensity_rel"]["p95"]),
                format_percent(item["fidelity"]["intensity_rel"]["p99"]),
                format_percent(item["fidelity"]["intensity_rel"]["mean"]),
            ]
            for item in report["lossy_sweep"]
        ],
        ["right", "right", "right", "right", "right", "right"],
    )
    selected_p95 = next(
        (
            format_percent(item["fidelity"]["intensity_rel"]["p95"])
            for item in report["lossy_sweep"]
            if item["intensity_quant"] == selected_quant
        ),
        "n/a",
    )
    paragraph(
        f"Higher q = more preserved log-intensity precision at the cost of a larger file. "
        f"Selected q={selected_quant} gives p95 relative intensity error of {selected_p95}. "
        f"Relative error = abs(delta) / original, evaluated over strictly positive peaks after round-trip decode."
    )
    image(
        "Relative Intensity Error Quantiles",
        f"plots/{report['plots']['intensity_relative_quantiles']}",
    )

    return "\n".join(lines).rstrip() + "\n"
