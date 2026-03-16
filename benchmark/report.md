# Benchmark Report: 15HCD_1

- mzML input: data/PXD075509/15HCD_1.mzML
- private workdir: data/PXD075509/benchmarks/15HCD_1
- public output dir: benchmark
- repeats: 10
- selected lossy intensity quantization: q=4096

## Story

The flat dump is smaller than mzML because it strips almost all interchange overhead: XML structure, controlled-vocabulary markup, base64 wrapping, and general-purpose metadata that this prototype does not need for codec bring-up. That makes the dump a useful internal floor, not a format competitor by itself.

This benchmark focuses on two things that matter right now: whether the current `.mzv1` path buys meaningful size reduction over the interchange format, and whether encode and decode stay fast and stable across repeated runs.

## Dataset

- spectra: 9001
- total peaks: 2668458
- ms1 spectra: 917
- ms2 spectra: 8084

## Size Comparison

![Artifact Size Comparison](plots/size_comparison.png)

| artifact | bytes | size | vs mzML | vs dump |
| --- | ---: | ---: | ---: | ---: |
| mzML | 79221306 | 75.55 MiB | 100.00% | 245.47% |
| dump | 32273524 | 30.78 MiB | 40.74% | 100.00% |
| mzv1 lossless | 20467802 | 19.52 MiB | 25.84% | 63.42% |
| mzv1 lossy | 13778826 | 13.14 MiB | 17.39% | 42.69% |
| gzip dump | 20780851 | 19.82 MiB | 26.23% | 64.39% |
| zstd dump | 18720327 | 17.85 MiB | 23.63% | 58.01% |

Lossless `.mzv1` is already materially smaller than mzML on this sample, and it slightly beats `gzip` on the dump baseline while still trailing `zstd` on the dump. The selected lossy mode gives a controlled next step down in size without the catastrophic saturation behavior that the earlier intensity quantizer had.

## Timing Variability

![Timing Variability Across Runs](plots/timing_intervals.png)

The chart above uses all 10 runs per operation. Gray dots are individual runs. Black points show the mean with a two-sided 95% confidence interval for the mean.

| operation | mean ± sd | median | 95% CI of mean | min | max | throughput |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| mzML -> dump | 4.6199s ± 0.0603s | 4.6077s | [4.5768s, 4.6630s] | 4.5533s | 4.7160s | 16.35 MiB/s |
| dump -> gzip dump | 1.6610s ± 0.0129s | 1.6611s | [1.6518s, 1.6702s] | 1.6455s | 1.6896s | 18.53 MiB/s |
| gzip dump -> dump | 0.2036s ± 0.0005s | 0.2034s | [0.2032s, 0.2039s] | 0.2028s | 0.2048s | 97.36 MiB/s |
| dump -> zstd dump | 0.1857s ± 0.0024s | 0.1853s | [0.1840s, 0.1874s] | 0.1833s | 0.1906s | 165.73 MiB/s |
| zstd dump -> dump | 0.0532s ± 0.0003s | 0.0532s | [0.0530s, 0.0534s] | 0.0527s | 0.0539s | 335.54 MiB/s |
| dump -> mzv1 lossless | 0.7521s ± 0.0078s | 0.7495s | [0.7465s, 0.7577s] | 0.7421s | 0.7685s | 40.92 MiB/s |
| mzv1 lossless -> dump | 0.7832s ± 0.0033s | 0.7827s | [0.7808s, 0.7856s] | 0.7795s | 0.7896s | 24.92 MiB/s |
| dump -> mzv1 lossy q=4096 | 1.1657s ± 0.0108s | 1.1636s | [1.1580s, 1.1735s] | 1.1526s | 1.1934s | 26.40 MiB/s |
| mzv1 lossy q=4096 -> dump | 0.8638s ± 0.0086s | 0.8620s | [0.8577s, 0.8700s] | 0.8545s | 0.8811s | 15.21 MiB/s |

## Fidelity Summary

| artifact | global order | ms1 order | ms2 order | mean abs mz | max abs mz | mean abs intensity | rmse intensity | p95 rel intensity | p99 rel intensity | mean abs log1p intensity |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| mzv1 lossless | false | true | true | 5.00068204e-07 | 1.00000011e-06 | 0 | 0 | 0.000% | 0.000% | 0 |
| mzv1 lossy q=4096 | false | true | true | 5.00068204e-07 | 1.00000011e-06 | 695.252613 | 10758.6615 | 0.218% | 0.238% | 0.00113669413 |

The current so-called lossless path is still not truly lossless for m/z, because the container stores fixed-point m/z values. It is intensity-exact on this sample. Global order is still not preserved because MS1 and MS2 are written as separate streams.

## Lossy Sweep

![Lossy Tradeoff](plots/lossy_tradeoff.png)

| q | bytes | size | p95 rel intensity err | p99 rel intensity err | mean rel intensity err |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 256 | 12444574 | 11.87 MiB | 3.499% | 3.813% | 1.820% |
| 1024 | 13111717 | 12.50 MiB | 0.874% | 0.950% | 0.455% |
| 4096 | 13778826 | 13.14 MiB | 0.218% | 0.238% | 0.114% |
| 16384 | 14445949 | 13.78 MiB | 0.055% | 0.059% | 0.028% |

The selected `q` stays user-controlled. Higher `q` means more preserved log-intensity precision and usually a larger file; lower `q` buys size at the cost of broader relative error tails.

![Relative Intensity Error Quantiles](plots/intensity_relative_quantiles.png)

## How The Error Numbers Are Computed

The reported means are computed over every matched peak after round-trip decode. They are not inferred from min and max.

- Mean absolute error: average absolute per-peak error.
- RMSE: square root of the average squared per-peak error.
- Relative intensity error: absolute error divided by the original intensity, evaluated only on strictly positive peaks.
- log1p intensity error: absolute error after applying `log1p`, which keeps the metric useful across large dynamic range.

## Future Comparison Candidates

These are not benchmarked here yet, but they are the most relevant external baselines to add next if we want a real proteomics-compression comparison instead of only internal baselines.

| candidate | core idea | why test it next | source |
| --- | --- | --- | --- |
| MS-Numpress in mzML | Array-level compression inside the mzML ecosystem: linear prediction for smooth m/z arrays and logged or integer schemes for intensities. | It is the closest standard-adjacent baseline for testing whether mzarc beats established PSI-compatible spectrum array compression. | ms-numpress project |
| mz5 | Re-encodes the mzML ontology on top of HDF5, uses binary datasets, compression-friendly layout, and delta mass storage. | The published paper reports roughly 54% of mzML size and materially faster linear read and write, so it is a useful open-format systems baseline. | PMCID: PMC3270111 |
| mzMLb | Keeps standards-compliant mzML metadata while moving bulk numeric arrays into HDF5 for better speed and storage efficiency. | It is a direct standard-preserving answer to the same problem mzarc is addressing: less storage and faster access without giving up open-format interoperability. | PMID: 32864978 |
| Aird | A computation-oriented format designed around higher compression ratio and lower decoding time, with related StackZDPD work on fast spectral encoding. | It is a strong modern comparison point because its stated goals overlap almost exactly with mzarc: practical compression and decode speed for analysis workflows. | PMID: 35021987; PMID: 35354909 |
