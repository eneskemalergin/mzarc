from __future__ import annotations

from benchmark_core import format_bytes, format_interval, format_percent


FUTURE_BASELINES = [
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


def render_markdown(report: dict) -> str:
    dataset = report["dataset"]
    lossless = report["fidelity"]["mzv1_lossless"]
    lossy = report["fidelity"]["mzv1_lossy"]
    selected_quant = report["selected_lossy_intensity_quant"]

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
    lines.append("## Timing Variability")
    lines.append("")
    lines.append(f"![Timing Variability Across Runs](plots/{report['plots']['timing_intervals']})")
    lines.append("")
    lines.append(f"The chart above uses all {report['repeats']} runs per operation. Gray dots are individual runs. Black points show the mean with a two-sided 95% confidence interval for the mean.")
    lines.append("")
    lines.append("| operation | mean ± sd | median | 95% CI of mean | min | max | throughput |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
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
            f"{throughput} |"
        )
    lines.append("")
    lines.append("## Fidelity Summary")
    lines.append("")
    lines.append("| artifact | global order | ms1 order | ms2 order | mean abs mz | max abs mz | mean abs intensity | rmse intensity | p95 rel intensity | p99 rel intensity | mean abs log1p intensity |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for artifact_name, item in (("mzv1 lossless", lossless), (f"mzv1 lossy q={selected_quant}", lossy)):
        lines.append(
            f"| {artifact_name} | {str(item['global_order_preserved']).lower()} | {str(item['ms1_relative_order_preserved']).lower()} | {str(item['ms2_relative_order_preserved']).lower()} | {item['mz_abs']['mean']:.9g} | {item['mz_abs']['max']:.9g} | {item['intensity_abs']['mean']:.9g} | {item['intensity_abs']['rmse']:.9g} | {format_percent(item['intensity_rel']['p95'])} | {format_percent(item['intensity_rel']['p99'])} | {item['intensity_log1p_abs']['mean']:.9g} |"
        )
    lines.append("")
    lines.append("The current so-called lossless path is still not truly lossless for m/z, because the container stores fixed-point m/z values. It is intensity-exact on this sample. Global order is still not preserved because MS1 and MS2 are written as separate streams.")
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
    lines.append("These are not benchmarked here yet, but they are the most relevant external baselines to add next if we want a real proteomics-compression comparison instead of only internal baselines.")
    lines.append("")
    lines.append("| candidate | core idea | why test it next | source |")
    lines.append("| --- | --- | --- | --- |")
    for item in report["comparison_candidates"]:
        lines.append(
            f"| {item['name']} | {item['core_idea']} | {item['why_it_matters']} | {item['source']} |"
        )
    lines.append("")
    return "\n".join(lines)