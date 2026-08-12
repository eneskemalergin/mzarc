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

round_trip() {
    local mode=$1
    shift
    local archive="$scratch/$mode.mzarc"
    local decoded="$scratch/$mode.bin"

    run_quiet "$mode encode" "$mzarc" encode "$fixture" -o "$archive" "$@"
    run_quiet "$mode decode" "$mzarc" decode "$archive" -o "$decoded"
    run_quiet "$mode validation" "$mzarc" validate "$fixture" "$decoded" "--mode=$mode"
}

run_quiet 'adversarial lossless round trips' "$mzarc" validate-adversarial "$adversarial"
round_trip lossless
round_trip lossy --lossy
