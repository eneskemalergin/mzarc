#!/usr/bin/env bash
# tools/smoke_test.sh -- Fast correctness check using the frozen test fixture.
#
# Usage:
#   tools/smoke_test.sh [OPTIONS]
#
# Options:
#   --fixture FILE   binary dump to test (default: test/fixtures/frozen.bin)
#   --mzarc BIN      mzarc binary (default: zig-out/bin/mzarc)
#
# Checks performed (completes in <5 s):
#   1. Adversarial roundtrip: all test/adversarial/*.bin via mzarc validate-adversarial
#   2. Lossless encode -> decode -> binary validate on frozen fixture
#   3. Lossy encode -> decode -> binary validate on frozen fixture
#
# Exits 0 on pass, 1 on any failure.  Cleans up temp files on exit.

set -euo pipefail
cd "$(dirname "$0")/.."

FIXTURE="test/fixtures/frozen.bin"
MZARC="zig-out/bin/mzarc"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fixture) FIXTURE="$2"; shift 2 ;;
        --mzarc)   MZARC="$2";   shift 2 ;;
        --help|-h)
            grep '^#' "$0" | head -14 | sed 's/^# \{0,2\}//'
            exit 0 ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)  break ;;
    esac
done

[[ -f "$MZARC" ]]   || { echo "ERROR: mzarc not found: $MZARC" >&2; exit 1; }
[[ -f "$FIXTURE" ]] || { echo "ERROR: fixture not found: $FIXTURE" >&2; exit 1; }

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

log() { echo "[smoke] $*" >&2; }

# --------------------------------------------------------------------------- #
# 1. adversarial roundtrip                                                    #
# --------------------------------------------------------------------------- #
if [[ -d "test/adversarial" ]]; then
    log "adversarial roundtrip..."
    "$MZARC" validate-adversarial test/adversarial/
    log "adversarial: PASS"
fi

# --------------------------------------------------------------------------- #
# 2. lossless roundtrip                                                       #
# --------------------------------------------------------------------------- #
LOSSLESS="$TMPDIR/smoke.lossless.mzarc"
LOSSLESS_RT="$TMPDIR/smoke.lossless.rt.bin"

log "lossless encode..."
"$MZARC" encode "$FIXTURE" -o "$LOSSLESS" >/dev/null

log "lossless decode..."
"$MZARC" decode "$LOSSLESS" -o "$LOSSLESS_RT" >/dev/null

log "lossless validate..."
"$MZARC" validate "$FIXTURE" "$LOSSLESS_RT" --mode=lossless
log "lossless: PASS"

# --------------------------------------------------------------------------- #
# 3. lossy roundtrip                                                          #
# --------------------------------------------------------------------------- #
LOSSY="$TMPDIR/smoke.lossy.mzarc"
LOSSY_RT="$TMPDIR/smoke.lossy.rt.bin"

log "lossy encode..."
"$MZARC" encode "$FIXTURE" -o "$LOSSY" --lossy >/dev/null

log "lossy decode..."
"$MZARC" decode "$LOSSY" -o "$LOSSY_RT" >/dev/null

log "lossy validate..."
"$MZARC" validate "$FIXTURE" "$LOSSY_RT" --mode=lossy
log "lossy: PASS"

log "All smoke tests passed."
