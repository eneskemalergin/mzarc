#!/usr/bin/env bash
# tools/validate.sh -- Fidelity and regression validation for mzarc.
#
# Usage:
#   tools/validate.sh [OPTIONS]
#
# Options:
#   --manifest FILE    manifest.json from benchmark.sh (default: benchmark/raw/manifest.json)
#   --baseline FILE    baseline JSON for regression check (default: benchmark/baseline_v0.1.1.json)
#   --output FILE      where to write fidelity.json (default: benchmark/raw/fidelity.json)
#
# Checks performed:
#   0a. Adversarial roundtrip: all test/adversarial/*.bin files via mzarc validate-adversarial
#   0b. Binary-exact validate: lossless and lossy roundtrips via mzarc validate
#   1.  Round-trip fidelity: decoded files vs original dump (via fidelity_check.py)
#   2.  Regression: compare current report.json vs baseline (via check_regression.py)

set -euo pipefail
cd "$(dirname "$0")/.."

MANIFEST="benchmark/raw/manifest.json"
BASELINE="benchmark/baseline_v0.1.1.json"
FIDELITY_OUT="benchmark/raw/fidelity.json"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --manifest) MANIFEST="$2";     shift 2 ;;
        --baseline) BASELINE="$2";     shift 2 ;;
        --output)   FIDELITY_OUT="$2"; shift 2 ;;
        --help|-h)
            grep '^#' "$0" | head -12 | sed 's/^# \{0,2\}//'
            exit 0 ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)  break ;;
    esac
done

if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: manifest not found: $MANIFEST" >&2
    echo "Run tools/benchmark.sh first." >&2
    exit 1
fi

MZARC="zig-out/bin/mzarc"

# --------------------------------------------------------------------------- #
# 0a. adversarial roundtrip (Zig, <1 s, no manifest needed)                  #
# --------------------------------------------------------------------------- #
if [[ -f "$MZARC" ]] && [[ -d "test/adversarial" ]]; then
    echo "[validate] Adversarial roundtrip check..." >&2
    "$MZARC" validate-adversarial test/adversarial/
    echo "[validate] Adversarial check passed." >&2
fi

# --------------------------------------------------------------------------- #
# 0b. Binary-exact validate: lossless and lossy roundtrips                   #
# --------------------------------------------------------------------------- #
if [[ -f "$MZARC" ]]; then
    _PATHS=$(python3 - "$MANIFEST" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1]))
dump = m["dump_path"]
ops  = m["operations"]
lossless_rt = next((o["roundtrip_path"] for o in ops
                    if o.get("roundtrip_path") and "lossless" in o.get("artifact", "")), "")
lossy_rt    = next((o["roundtrip_path"] for o in ops
                    if o.get("roundtrip_path") and "lossy"    in o.get("artifact", "")), "")
print(dump)
print(lossless_rt)
print(lossy_rt)
PYEOF
    )
    _DUMP=$(echo "$_PATHS"        | sed -n '1p')
    _LOSSLESS_RT=$(echo "$_PATHS" | sed -n '2p')
    _LOSSY_RT=$(echo "$_PATHS"    | sed -n '3p')

    if [[ -f "$_DUMP" ]] && [[ -n "$_LOSSLESS_RT" ]] && [[ -f "$_LOSSLESS_RT" ]]; then
        echo "[validate] Binary lossless validate..." >&2
        "$MZARC" validate "$_DUMP" "$_LOSSLESS_RT" --mode=lossless
        echo "[validate] Lossless binary check passed." >&2
    fi

    if [[ -f "$_DUMP" ]] && [[ -n "$_LOSSY_RT" ]] && [[ -f "$_LOSSY_RT" ]]; then
        echo "[validate] Binary lossy validate..." >&2
        "$MZARC" validate "$_DUMP" "$_LOSSY_RT" --mode=lossy
        echo "[validate] Lossy binary check passed." >&2
    fi
fi

# --------------------------------------------------------------------------- #
# 1. fidelity checks                                                          #
# --------------------------------------------------------------------------- #
echo "[validate] Running fidelity checks..." >&2
python3 tools/fidelity_check.py "$MANIFEST" --output "$FIDELITY_OUT"
echo "[validate] Fidelity results: $FIDELITY_OUT" >&2

# --------------------------------------------------------------------------- #
# 2. regression check (skipped when no baseline is present)                  #
# --------------------------------------------------------------------------- #
if [[ -f "$BASELINE" ]] && [[ -f "benchmark/report.json" ]]; then
    echo "[validate] Checking regression vs $BASELINE..." >&2
    if python3 tools/check_regression.py; then
        echo "[validate] Regression check passed." >&2
    else
        echo "[validate] REGRESSION DETECTED -- see output above." >&2
        exit 1
    fi
else
    echo "[validate] No baseline or report found, skipping regression check." >&2
fi

echo "[validate] All checks passed." >&2
