#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: tools/smoke_test.sh [options]

Options:
  --fixture FILE   Dump V1 fixture (default: test/fixtures/frozen.bin).
  --mzarc FILE     mzarc binary (default: zig-out/bin/mzarc).
  -h, --help       Show this help.
EOF
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture="$repo_root/test/fixtures/frozen.bin"
mzarc="$repo_root/zig-out/bin/mzarc"
adversarial="$repo_root/test/adversarial"
mzml_fixture="$repo_root/test/fixtures/small.mzML"
mzml_expected="$repo_root/test/fixtures/small.bin"

while (($#)); do
    case "$1" in
        --fixture)
            fixture=${2:?missing file after --fixture}
            shift 2
            ;;
        --mzarc)
            mzarc=${2:?missing file after --mzarc}
            shift 2
            ;;
        -h|--help)
            usage
            exit
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ ! -x "$mzarc" ]]; then
    echo "error: mzarc executable not found: $mzarc" >&2
    exit 1
fi
if [[ ! -f "$fixture" ]]; then
    echo "error: fixture not found: $fixture" >&2
    exit 1
fi
if [[ ! -d "$adversarial" ]]; then
    echo "error: adversarial corpus not found: $adversarial" >&2
    exit 1
fi
if [[ ! -f "$mzml_fixture" || ! -f "$mzml_expected" ]]; then
    echo "error: mzML fixture not found: $mzml_fixture" >&2
    exit 1
fi

scratch=$(mktemp -d "${TMPDIR:-/var/tmp}/mzarc-smoke.XXXXXX")
cleanup() {
    # The smoke checks write only plain files directly under the scratch directory.
    rm -f -- "$scratch"/*
    rmdir -- "$scratch"
}
trap cleanup EXIT

run_quiet() {
    local label=$1
    shift
    local output

    if output=$("$@" 2>&1); then
        echo "PASS $label"
        return
    fi
    printf '%s\n' "$output" >&2
    echo "FAIL $label" >&2
    return 1
}

run_lossy_validation() {
    local output

    if ! output=$(
        "$mzarc" validate "$fixture" "$scratch/lossy.bin" --mode=lossy 2>&1
    ); then
        printf '%s\n' "$output" >&2
        echo "FAIL lossy validation" >&2
        return 1
    fi
    if [[ $output != *"mz_quantized_values exact"* || $output != *"nominal half-step 0.000001000 Da plus f64 rounding"* || $output != *"intensity_log1p_max_error"* ]]; then
        printf '%s\n' "$output" >&2
        echo "FAIL lossy validation contract" >&2
        return 1
    fi
    echo "PASS lossy validation"

    cp "$scratch/lossy.bin" "$scratch/lossy-invalid.bin"
    printf '\0\0\0\0\0\0\0\0' | dd \
        of="$scratch/lossy-invalid.bin" bs=1 seek=28 count=8 conv=notrunc 2>/dev/null
    if output=$("$mzarc" validate "$fixture" "$scratch/lossy-invalid.bin" --mode=lossy 2>&1); then
        echo "FAIL lossy validation mismatch" >&2
        return 1
    fi
    if [[ $output != *"FAIL mz_quantized_values"* ]]; then
        printf '%s\n' "$output" >&2
        echo "FAIL lossy validation mismatch result" >&2
        return 1
    fi
    echo "PASS lossy validation mismatch"
}

round_trip() {
    local mode=$1
    shift
    local archive="$scratch/$mode.mzarc"
    local decoded="$scratch/$mode.bin"

    run_quiet "$mode encode" "$mzarc" encode "$fixture" -o "$archive" "$@"
    run_quiet "$mode decode" "$mzarc" decode "$archive" -o "$decoded"
    if [[ $mode == lossy ]]; then
        run_lossy_validation
        run_quiet 'lossy explicit quant validation' \
            "$mzarc" validate "$fixture" "$decoded" --mode=lossy --intensity-quant 16384
    else
        run_quiet "$mode validation" "$mzarc" validate "$fixture" "$decoded" "--mode=$mode"
    fi
}

check_mzml_dump() {
    run_quiet 'mzML dump' "$mzarc" dump "$mzml_fixture" -o "$scratch/small.bin"
    if ! cmp -s "$mzml_expected" "$scratch/small.bin"; then
        echo "FAIL mzML dump bytes" >&2
        return 1
    fi
    echo "PASS mzML dump bytes"

    # Byte 4000 is inside the second spectrum, after the dump has started writing.
    head -c 4000 "$mzml_fixture" >"$scratch/truncated.mzML"
    printf 'keep' >"$scratch/existing.bin"
    if "$mzarc" dump "$scratch/truncated.mzML" -o "$scratch/existing.bin" >/dev/null 2>&1; then
        echo "FAIL truncated mzML dump accepted" >&2
        return 1
    fi
    if [[ $(<"$scratch/existing.bin") != keep ]]; then
        echo "FAIL failed mzML dump replaced its destination" >&2
        return 1
    fi
    echo "PASS truncated mzML dump keeps destination"
}

# One spectrum of zero-valued peaks; $2 is the m/z width in bytes (8 for f64, 4 for f32).
peak_limit_mzml() {
    local peaks=$1 mz_width=$2 mz_term mz_text intensity_text
    mz_term='MS:1000523" name="64-bit float'
    if ((mz_width == 4)); then mz_term='MS:1000521" name="32-bit float'; fi
    mz_text=$(head -c $((peaks * mz_width)) /dev/zero | base64 | tr -d '\n')
    intensity_text=$(head -c $((peaks * 4)) /dev/zero | base64 | tr -d '\n')
    printf '<?xml version="1.0" encoding="utf-8"?>\n<mzML xmlns="http://psi.hupo.org/ms/mzml" version="1.1.0"><run id="r"><spectrumList count="1"><spectrum index="0" id="scan=1" defaultArrayLength="%d"><cvParam cvRef="MS" accession="MS:1000511" name="ms level" value="1"/><binaryDataArrayList count="2"><binaryDataArray encodedLength="%d"><cvParam cvRef="MS" accession="%s"/><cvParam cvRef="MS" accession="MS:1000576" name="no compression"/><cvParam cvRef="MS" accession="MS:1000514" name="m/z array"/><binary>%s</binary></binaryDataArray><binaryDataArray encodedLength="%d"><cvParam cvRef="MS" accession="MS:1000521" name="32-bit float"/><cvParam cvRef="MS" accession="MS:1000576" name="no compression"/><cvParam cvRef="MS" accession="MS:1000515" name="intensity array"/><binary>%s</binary></binaryDataArray></binaryDataArrayList></spectrum></spectrumList></run></mzML>\n' \
        "$peaks" "${#mz_text}" "$mz_term" "$mz_text" "${#intensity_text}" "$intensity_text"
}

check_mzml_dump_peak_limit() {
    local limit=524288 width
    peak_limit_mzml "$limit" 8 >"$scratch/limit.mzML"
    run_quiet 'mzML dump at the peak limit' "$mzarc" dump "$scratch/limit.mzML" -o "$scratch/limit.bin"
    if (($(wc -c <"$scratch/limit.bin") != 28 + 12 * limit)); then
        echo "FAIL mzML dump at the peak limit size" >&2
        return 1
    fi
    for width in 8 4; do
        peak_limit_mzml $((limit + 1)) "$width" >"$scratch/over.mzML"
        printf 'keep' >"$scratch/existing.bin"
        if "$mzarc" dump "$scratch/over.mzML" -o "$scratch/existing.bin" >/dev/null 2>&1; then
            echo "FAIL mzML dump accepted $((limit + 1)) peaks with $((width * 8))-bit m/z" >&2
            return 1
        fi
        if [[ $(<"$scratch/existing.bin") != keep ]]; then
            echo "FAIL over-limit mzML dump replaced its destination" >&2
            return 1
        fi
    done
    echo "PASS mzML dump rejects one peak over the limit"
}

check_dump_inspect_median() {
    local output
    output=$("$mzarc" dump-inspect "$fixture" 2>&1)
    # The frozen fixture has 1,000 spectra; the mean of the two middle peak counts is 66.5.
    if [[ $output != *"median peaks per spectrum: 66.5"* ]]; then
        printf '%s\n' "$output" >&2
        echo "FAIL dump-inspect median" >&2
        return 1
    fi
    echo "PASS dump-inspect median"
}

check_mzml_archives() {
    local source_counts output_counts output
    run_quiet 'mzML exact encode' "$mzarc" encode "$mzml_fixture" -o "$scratch/exact.mzarc"
    run_quiet 'mzML exact decode' "$mzarc" decode "$scratch/exact.mzarc" -o "$scratch/exact.mzML"
    if ! cmp -s "$mzml_fixture" "$scratch/exact.mzML"; then
        echo "FAIL mzML exact round trip bytes" >&2
        return 1
    fi
    echo "PASS mzML exact round trip bytes"

    run_quiet 'mzML lossy encode' "$mzarc" encode "$mzml_fixture" -o "$scratch/lossy-doc.mzarc" --lossy
    run_quiet 'mzML lossy decode' "$mzarc" decode "$scratch/lossy-doc.mzarc" -o "$scratch/lossy.mzML"
    source_counts=$("$mzarc" dump "$mzml_fixture" -o "$scratch/source-dump.bin" | grep -E '^(spectra|total peaks|ms1 count|ms2 count):')
    output_counts=$("$mzarc" dump "$scratch/lossy.mzML" -o "$scratch/lossy-dump.bin" | grep -E '^(spectra|total peaks|ms1 count|ms2 count):')
    if [[ $source_counts != "$output_counts" ]]; then
        echo "FAIL mzML lossy round trip counts" >&2
        return 1
    fi
    echo "PASS mzML lossy round trip counts"

    run_quiet 'mzML lossy bounds validation' \
        "$mzarc" validate "$scratch/source-dump.bin" "$scratch/lossy-dump.bin" --mode=mzml-lossy
    cp "$scratch/lossy-dump.bin" "$scratch/lossy-dump-invalid.bin"
    # Byte 28 is the first m/z of the first spectrum; zero is neither the source value nor its quantization.
    printf '\0\0\0\0\0\0\0\0' | dd \
        of="$scratch/lossy-dump-invalid.bin" bs=1 seek=28 count=8 conv=notrunc 2>/dev/null
    if "$mzarc" validate "$scratch/source-dump.bin" "$scratch/lossy-dump-invalid.bin" --mode=mzml-lossy >/dev/null 2>&1; then
        echo "FAIL mzML lossy bounds validation accepted a changed m/z" >&2
        return 1
    fi
    if "$mzarc" validate "$scratch/source-dump.bin" "$scratch/lossy-dump.bin" --mode=mzml-lossy --intensity-quant 4096 >/dev/null 2>&1; then
        echo "FAIL mzML lossy bounds validation accepted --intensity-quant" >&2
        return 1
    fi
    echo "PASS mzML lossy bounds validation rejects a changed m/z"

    output=$("$mzarc" inspect "$scratch/lossy-doc.mzarc" 2>&1)
    if [[ $output != *"kind: source document"* || $output != *"mode: lossy"* ]]; then
        printf '%s\n' "$output" >&2
        echo "FAIL mzML archive inspect" >&2
        return 1
    fi
    echo "PASS mzML archive inspect"

    if "$mzarc" encode "$mzml_fixture" -o "$scratch/rejected.mzarc" --intensity-quant 4096 >/dev/null 2>&1; then
        echo "FAIL mzML encode accepted a Dump V1 option" >&2
        return 1
    fi
    echo "PASS mzML encode rejects Dump V1 options"
}

check_inspect_json_path() {
    local quoted="$scratch/a\"b.mzarc" output escaped
    escaped=${quoted//\"/\\\"}
    run_quiet 'inspect json fixture encode' "$mzarc" encode "$fixture" -o "$quoted"
    output=$("$mzarc" inspect "$quoted" --json 2>&1)
    if [[ $output != *"\"file\": \"$escaped\""* ]]; then
        printf '%s\n' "$output" >&2
        echo "FAIL inspect json escapes the path" >&2
        return 1
    fi
    run_quiet 'inspect json mzML encode' "$mzarc" encode "$mzml_fixture" -o "$quoted"
    output=$("$mzarc" inspect "$quoted" --json 2>&1)
    if [[ $output != *"\"file\":\"$escaped\""* ]]; then
        printf '%s\n' "$output" >&2
        echo "FAIL inspect json escapes the mzML archive path" >&2
        return 1
    fi
    echo "PASS inspect json escapes the path"
}

check_output_is_input() {
    local copy="$scratch/same.mzML" archive="$scratch/same.mzarc" link="$scratch/same-link.mzML"
    cp "$mzml_fixture" "$copy"
    ln -s "$copy" "$link"
    "$mzarc" encode "$mzml_fixture" -o "$archive" >/dev/null
    cp "$archive" "$scratch/same-before.mzarc"
    local -a cases=(
        "encode|$copy|$copy|--lossy"
        "encode|$copy|$scratch/./same.mzML|"
        "encode|$copy|$link|"
        "dump|$copy|$copy|"
        "decode|$archive|$archive|"
    )
    local entry command input output flag
    for entry in "${cases[@]}"; do
        IFS='|' read -r command input output flag <<<"$entry"
        if "$mzarc" "$command" "$input" -o "$output" ${flag:+"$flag"} >/dev/null 2>&1; then
            echo "FAIL $command accepted its input as the output: $output" >&2
            return 1
        fi
    done
    if ! cmp -s "$mzml_fixture" "$copy" || ! cmp -s "$scratch/same-before.mzarc" "$archive"; then
        echo "FAIL a refused same-path command changed its input" >&2
        return 1
    fi
    echo "PASS commands refuse an output that is the input"
}

run_quiet 'help' "$mzarc" --help
check_dump_inspect_median
check_mzml_dump
check_mzml_dump_peak_limit
check_mzml_archives
check_inspect_json_path
check_output_is_input
run_quiet 'adversarial lossless round trips' "$mzarc" validate-adversarial "$adversarial"
round_trip lossless
round_trip lossy --lossy
