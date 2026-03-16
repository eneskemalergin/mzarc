from __future__ import annotations

from benchmark_core import format_bytes, format_interval, format_percent


FUTURE_BASELINES = [
    {
        "name": "mspack",
        "core_idea": "Dedicated mass-spectrometry compressor for mzML and mzXML with both lossless and lossy modes and explicit decode support.",
        "why_it_matters": "It is a direct codec-style baseline rather than a general container baseline, so it is much closer to mzarc on design intent.",
        "source": "fhanau/mspack",
    },
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
        "name": "mz5",
        "core_idea": "Re-encodes the mzML ontology on top of HDF5, uses binary datasets, compression-friendly layout, and delta mass storage.",
        "why_it_matters": "The published paper reports roughly 54% of mzML size and materially faster linear read and write, so it is a useful open-format systems baseline.",
        "source": "PMCID: PMC3270111",
    },
    {
        "name": "mzMLb",
        "core_idea": "Keeps standards-compliant mzML metadata while moving bulk numeric arrays into HDF5 for better speed and storage efficiency.",
        "why_it_matters": "It is a direct standard-preserving answer to the same problem mzarc is addressing: less storage and faster access without giving up open-format interoperability.",
        "source": "PMID: 32864978",
    },
    {
        "name": "Aird",
        "core_idea": "A computation-oriented format designed around higher compression ratio and lower decoding time, with related StackZDPD work on fast spectral encoding.",
        "why_it_matters": "It is a strong modern comparison point because its stated goals overlap almost exactly with mzarc: practical compression and decode speed for analysis workflows.",
        "source": "PMID: 35021987; PMID: 35354909",
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
    lossless = report["fidelity"]["mzv1_lossless"]
    lossy = report["fidelity"]["mzv1_lossy"]
    selected_quant = report["selected_lossy_intensity_quant"]
    external_baselines = report.get("external_baselines", [])
    performance_rows = report.get("performance_rows", [])
    fidelity_metrics = report.get("fidelity_metrics", [])
    search_impact_rows = report.get("search_impact_rows", [])
    fidelity_rows = report.get(
        "fidelity_rows",
        [
            {"artifact": "mzv1 lossless", "data": lossless},
            {"artifact": f"mzv1 lossy q={selected_quant}", "data": lossy},
        ],
    )

    lines: list[str] = []
    lines.append(f"# Benchmark Report: {report['sample_name']}")
    lines.append("")
    lines.append(f"- mzML input: {report['paths']['mzml']}")
    lines.append(f"- private workdir: {report['paths']['private_workdir']}")
    lines.append(f"- public output dir: {report['paths']['public_dir']}")
    lines.append(f"- repeats: {report['repeats']}")
    lines.append(f"- selected lossy intensity quantization: q={selected_quant}")
    lines.append("")
    lines.append("## Story")
    lines.append("")
    lines.append("The flat dump is smaller than mzML because it strips almost all interchange overhead: XML structure, controlled-vocabulary markup, base64 wrapping, and general-purpose metadata that this prototype does not need for codec bring-up. That makes the dump a useful internal floor, not a format competitor by itself.")
    lines.append("")
    lines.append("This benchmark focuses on two things that matter right now: whether the current `.mzv1` path buys meaningful size reduction over the interchange format, and whether encode and decode stay fast and stable across repeated runs.")
    lines.append("")
    lines.append("## Coverage Overview")
    lines.append("")
    lines.append(f"![Benchmark Coverage by Artifact](plots/{report['plots']['metric_coverage']})")
    lines.append("")
    benchmarked_external = [item["name"] for item in external_baselines if item["status"] == "benchmarked"]
    if benchmarked_external:
        lines.append(f"External formats that actually ran end-to-end in this benchmark: {', '.join(benchmarked_external)}.")
    else:
        lines.append("No external formats ran end-to-end in this benchmark.")
    lines.append("")
    lines.append("## Dataset")
    lines.append("")
    lines.append(f"- spectra: {dataset['spectra']}")
    lines.append(f"- total peaks: {dataset['total_peaks']}")
    lines.append(f"- ms1 spectra: {dataset['ms1_spectra']}")
    lines.append(f"- ms2 spectra: {dataset['ms2_spectra']}")
    lines.append("")
    lines.append("## Size Comparison")
    lines.append("")
    lines.append(f"![Artifact Size Comparison](plots/{report['plots']['size_comparison']})")
    lines.append("")
    lines.append("| artifact | bytes | size | vs mzML | vs dump |")
    lines.append("| --- | ---: | ---: | ---: | ---: |")
    mzml_bytes = report["sizes"]["mzML"]["bytes"]
    dump_bytes = report["sizes"]["dump"]["bytes"]
    for artifact, item in report["sizes"].items():
        lines.append(
            f"| {artifact} | {item['bytes']} | {format_bytes(item['bytes'])} | {(item['bytes'] / mzml_bytes) * 100:.2f}% | {(item['bytes'] / dump_bytes) * 100:.2f}% |"
        )
    lines.append("")
    lines.append("Lossless `.mzv1` is already materially smaller than mzML on this sample, and it slightly beats `gzip` on the dump baseline while still trailing `zstd` on the dump. The selected lossy mode gives a controlled next step down in size without the catastrophic saturation behavior that the earlier intensity quantizer had.")
    lines.append("")
    lines.append("## Performance Overview")
    lines.append("")
    lines.append(f"![Throughput Overview](plots/{report['plots']['performance_overview']})")
    lines.append("")
    lines.append("| artifact | direction | status | throughput | mean time | throughput basis | source format | notes |")
    lines.append("| --- | --- | --- | ---: | ---: | --- | --- | --- |")
    for item in performance_rows:
        lines.append(
            f"| {item['artifact']} | {item['direction']} | {item['status']} | {_format_optional_number(item['throughput_mib_s'], precision=4, suffix=' MiB/s')} | {_format_optional_number(item['mean_seconds'], precision=5, suffix='s')} | {item['throughput_basis'] or 'n/a'} | {item['source_format'] or 'n/a'} | {item['notes'] or ''} |"
        )
    lines.append("")
    lines.append("## Timing Variability")
    lines.append("")
    lines.append(f"![Timing Variability Across Runs](plots/{report['plots']['timing_intervals']})")
    lines.append("")
    lines.append(f"The chart above uses all {report['repeats']} runs per operation. Gray dots are individual runs. Black points show the mean with a two-sided 95% confidence interval for the mean.")
    lines.append("")
    lines.append("| operation | mean ± sd | median | 95% CI of mean | min | max | throughput | basis |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |")
    for item in report["timings"]:
        throughput = "n/a" if item["throughput_mib_s"] is None else f"{item['throughput_mib_s']:.2f} MiB/s"
        lines.append(
            "| "
            f"{item['name']} | "
            f"{item['mean_seconds']:.4f}s ± {item['stdev_seconds']:.4f}s | "
            f"{item['median_seconds']:.4f}s | "
            f"{format_interval(item['ci95_low_seconds'], item['ci95_high_seconds'])} | "
            f"{item['min_seconds']:.4f}s | "
            f"{item['max_seconds']:.4f}s | "
            f"{throughput} | "
            f"{item.get('throughput_basis', 'n/a')} |"
        )
    lines.append("")
    lines.append("## External Baselines")
    lines.append("")
    if external_baselines:
        lines.append("| baseline | status | size | encode | decode | notes |")
        lines.append("| --- | --- | ---: | --- | --- | --- |")
        for item in external_baselines:
            size = "n/a" if item["artifact_bytes"] is None else format_bytes(item["artifact_bytes"])
            encode_op = item["encode_operation"] or "n/a"
            decode_op = item["decode_operation"] or "n/a"
            notes = item["reason"] or ""
            lines.append(
                f"| {item['name']} | {item['status']} | {size} | {encode_op} | {decode_op} | {notes} |"
            )
    else:
        lines.append("No external baselines were requested for this run.")
    lines.append("")
    lines.append("## Data Fidelity")
    lines.append("")
    lines.append(f"![Data Fidelity Overview](plots/{report['plots']['fidelity_overview']})")
    lines.append("")
    lines.append("| artifact | status | global order | max abs m/z | mean abs intensity | max abs intensity | p95 rel intensity | notes |")
    lines.append("| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |")
    for item in fidelity_metrics:
        lines.append(
            f"| {item['artifact']} | {item['status']} | {str(item['global_order_preserved']).lower() if item['global_order_preserved'] is not None else 'n/a'} | {_format_optional_number(item['max_abs_mz_error'], precision=9)} | {_format_optional_number(item['mean_abs_intensity_error'], precision=9)} | {_format_optional_number(item['max_abs_intensity_error'], precision=9)} | {_format_optional_percent(item['p95_rel_intensity_error_pct'])} | {item['notes'] or ''} |"
        )
    lines.append("")
    lines.append("## Fidelity Summary")
    lines.append("")
    lines.append("| artifact | global order | ms1 order | ms2 order | mean abs mz | max abs mz | mean abs intensity | rmse intensity | p95 rel intensity | p99 rel intensity | mean abs log1p intensity |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for row in fidelity_rows:
        artifact_name = row["artifact"]
        item = row["data"]
        lines.append(
            f"| {artifact_name} | {str(item['global_order_preserved']).lower()} | {str(item['ms1_relative_order_preserved']).lower()} | {str(item['ms2_relative_order_preserved']).lower()} | {item['mz_abs']['mean']:.9g} | {item['mz_abs']['max']:.9g} | {item['intensity_abs']['mean']:.9g} | {item['intensity_abs']['rmse']:.9g} | {format_percent(item['intensity_rel']['p95'])} | {format_percent(item['intensity_rel']['p99'])} | {item['intensity_log1p_abs']['mean']:.9g} |"
        )
    lines.append("")
    exact_artifacts = [
        f"`{item['artifact']}`"
        for item in fidelity_metrics
        if item.get("status") == "measured"
        and item.get("global_order_preserved") is True
        and float(item.get("max_abs_mz_error") or 0.0) == 0.0
        and float(item.get("max_abs_intensity_error") or 0.0) == 0.0
    ]
    exact_summary = _join_with_and(exact_artifacts)
    lines.append(
        f"On the current run, {exact_summary} round-trip exactly. `mzv1 lossless` is intensity-exact but still carries the expected fixed-point m/z quantization, and `mzv1 lossy` adds the configured intensity quantization on top of that. Global order is still not preserved for `mzv1` because MS1 and MS2 are written as separate streams."
    )
    lines.append("")
    lines.append("## Lossy Sweep")
    lines.append("")
    lines.append(f"![Lossy Tradeoff](plots/{report['plots']['lossy_tradeoff']})")
    lines.append("")
    lines.append("| q | bytes | size | p95 rel intensity err | p99 rel intensity err | mean rel intensity err |")
    lines.append("| ---: | ---: | ---: | ---: | ---: | ---: |")
    for item in report["lossy_sweep"]:
        rel = item["fidelity"]["intensity_rel"]
        lines.append(
            f"| {item['intensity_quant']} | {item['bytes']} | {format_bytes(item['bytes'])} | {format_percent(rel['p95'])} | {format_percent(rel['p99'])} | {format_percent(rel['mean'])} |"
        )
    lines.append("")
    lines.append("The selected `q` stays user-controlled. Higher `q` means more preserved log-intensity precision and usually a larger file; lower `q` buys size at the cost of broader relative error tails.")
    lines.append("")
    lines.append(f"![Relative Intensity Error Quantiles](plots/{report['plots']['intensity_relative_quantiles']})")
    lines.append("")
    lines.append("## Search Impact")
    lines.append("")
    lines.append("| artifact | status | peptide ID difference | peptide ID change | FDR change | notes |")
    lines.append("| --- | --- | ---: | ---: | ---: | --- |")
    for item in search_impact_rows:
        lines.append(
            f"| {item['artifact']} | {item['status']} | {_format_optional_number(item['peptide_identification_difference'], precision=0)} | {_format_optional_percent(item['peptide_identification_pct_change'])} | {_format_optional_percent(item['fdr_change_pct_points'])} | {item['notes'] or ''} |"
        )
    lines.append("")
    measured_search_rows = [item for item in search_impact_rows if item["status"] == "measured"]
    if measured_search_rows:
        lines.append("Measured search-impact rows were supplied externally for this run.")
    else:
        lines.append("Search-impact metrics are not measured by the current benchmark pipeline yet. They remain listed here so the report does not imply numerical equivalence where no downstream search experiment has actually been run.")
    lines.append("")
    lines.append("## How The Error Numbers Are Computed")
    lines.append("")
    lines.append("The reported means are computed over every matched peak after round-trip decode. They are not inferred from min and max.")
    lines.append("")
    lines.append("- Mean absolute error: average absolute per-peak error.")
    lines.append("- RMSE: square root of the average squared per-peak error.")
    lines.append("- Relative intensity error: absolute error divided by the original intensity, evaluated only on strictly positive peaks.")
    lines.append("- log1p intensity error: absolute error after applying `log1p`, which keeps the metric useful across large dynamic range.")
    lines.append("")
    lines.append("## Future Comparison Candidates")
    lines.append("")
    benchmarked_names = {item["name"] for item in external_baselines if item["status"] != "unavailable"}
    remaining_candidates = [
        item for item in report["comparison_candidates"] if item["name"] not in benchmarked_names
    ]
    if remaining_candidates:
        lines.append("These are the remaining or still-blocked comparison candidates after the current benchmark run.")
        lines.append("")
        lines.append("| candidate | core idea | why test it next | source |")
        lines.append("| --- | --- | --- | --- |")
        for item in remaining_candidates:
            lines.append(
                f"| {item['name']} | {item['core_idea']} | {item['why_it_matters']} | {item['source']} |"
            )
        lines.append("")
    else:
        lines.append("All named comparison candidates are wired into the current benchmark run in some form.")
        lines.append("")
    return "\n".join(lines)