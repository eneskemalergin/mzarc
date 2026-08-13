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

scratch=$(mktemp -d "${TMPDIR:-/tmp}/mzarc-smoke.XXXXXX")
cleanup() {
    rm -rf -- "$scratch"
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

run_quiet 'help' "$mzarc" --help
run_quiet 'adversarial lossless round trips' "$mzarc" validate-adversarial "$adversarial"
round_trip lossless
round_trip lossy --lossy
