#!/usr/bin/env bash
# tools/profile.sh -- Deep zebrac profiling for specific mzarc operations.
#
# Usage:
#   tools/profile.sh <mzml_file> [OPTIONS]
#
# Options:
#   --operations OP,...  comma-separated operations to profile (default: all mzarc)
#   --duration MS        zebrac window per operation in ms (default: 30000)
#   --workdir DIR        directory containing intermediate files
#   --output-dir DIR     output directory (default: benchmark)
#
# Available operations:
#   mzarc_lossless_encode, mzarc_lossless_decode,
#   mzarc_lossy_encode,    mzarc_lossy_decode,
#   mzml_dump,
#   gzip_dump_encode,      gzip_dump_decode,
#   zstd_dump_encode,      zstd_dump_decode
#
# Results land in <output-dir>/profiling/ as individual zebrac JSON files.

set -euo pipefail
cd "$(dirname "$0")/.."

DURATION=30000
OPERATIONS="mzarc_lossless_encode,mzarc_lossless_decode,mzarc_lossy_encode,mzarc_lossy_decode"
WORKDIR=""
OUTPUT_DIR="benchmark"
MZML=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration)   DURATION="$2";    shift 2 ;;
        --operations) OPERATIONS="$2";  shift 2 ;;
        --workdir)    WORKDIR="$2";     shift 2 ;;
        --output-dir) OUTPUT_DIR="$2";  shift 2 ;;
        --help|-h)
            grep '^#' "$0" | head -18 | sed 's/^# \{0,2\}//'
            exit 0 ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)  MZML="$1"; shift ;;
    esac
done

if [[ -z "$MZML" ]]; then
    echo "Usage: tools/profile.sh <mzml_file> [OPTIONS]" >&2
    exit 1
fi

SAMPLE=$(basename "$MZML" .mzML)
if [[ -z "$WORKDIR" ]]; then
    WORKDIR="$(dirname "$MZML")/benchmarks/$SAMPLE"
fi

PROF_DIR="$OUTPUT_DIR/profiling"
MZARC="zig-out/bin/mzarc"
ZEBRAC="tools/zebrac"
MANIFEST="$OUTPUT_DIR/raw/manifest.json"

if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: manifest not found: $MANIFEST" >&2
    echo "Run tools/benchmark.sh first." >&2
    exit 1
fi

mkdir -p "$PROF_DIR"

QUANT=$(python3 -c "
import json, sys
m = json.load(open(sys.argv[1]))
print(m['selected_lossy_quant'])
" "$MANIFEST")

DUMP="$WORKDIR/$SAMPLE.bin"
MZARC_LOSSLESS="$WORKDIR/$SAMPLE.lossless.mzarc"
MZARC_LOSSLESS_RT="$WORKDIR/$SAMPLE.lossless.roundtrip.bin"
MZARC_LOSSY="$WORKDIR/$SAMPLE.lossy.q${QUANT}.mzarc"
MZARC_LOSSY_RT="$WORKDIR/$SAMPLE.lossy.q${QUANT}.roundtrip.bin"

log() { echo "[profile] $*" >&2; }

IFS=',' read -ra _OPS <<< "$OPERATIONS"
for op in "${_OPS[@]}"; do
    op="${op// /}"
    case "$op" in
        mzarc_lossless_encode)
            log "$op (${DURATION}ms)"
            "$ZEBRAC" --duration "$DURATION" --json "$PROF_DIR/$op.json" \
                "$MZARC encode $DUMP -o $MZARC_LOSSLESS" ;;
        mzarc_lossless_decode)
            log "$op (${DURATION}ms)"
            "$ZEBRAC" --duration "$DURATION" --json "$PROF_DIR/$op.json" \
                "$MZARC decode $MZARC_LOSSLESS -o $MZARC_LOSSLESS_RT" ;;
        mzarc_lossy_encode)
            log "$op (${DURATION}ms)"
            "$ZEBRAC" --duration "$DURATION" --json "$PROF_DIR/$op.json" \
                "$MZARC encode $DUMP -o $MZARC_LOSSY --lossy --intensity-quant $QUANT" ;;
        mzarc_lossy_decode)
            log "$op (${DURATION}ms)"
            "$ZEBRAC" --duration "$DURATION" --json "$PROF_DIR/$op.json" \
                "$MZARC decode $MZARC_LOSSY -o $MZARC_LOSSY_RT" ;;
        mzml_dump)
            log "$op (${DURATION}ms)"
            "$ZEBRAC" --duration "$DURATION" --json "$PROF_DIR/$op.json" \
                "python3 tools/mzml_dump.py $MZML $DUMP" ;;
        gzip_dump_encode)
            log "$op (${DURATION}ms)"
            GZIP_DUMP="$WORKDIR/$SAMPLE.bin.gz"
            "$ZEBRAC" --duration "$DURATION" --json "$PROF_DIR/$op.json" \
                "gzip -n -c $DUMP > $GZIP_DUMP" ;;
        gzip_dump_decode)
            log "$op (${DURATION}ms)"
            GZIP_DUMP="$WORKDIR/$SAMPLE.bin.gz"
            GZIP_RT="$WORKDIR/$SAMPLE.gzip.roundtrip.bin"
            "$ZEBRAC" --duration "$DURATION" --json "$PROF_DIR/$op.json" \
                "gzip -d -c $GZIP_DUMP > $GZIP_RT" ;;
        zstd_dump_encode)
            log "$op (${DURATION}ms)"
            ZSTD_DUMP="$WORKDIR/$SAMPLE.bin.zst"
            "$ZEBRAC" --duration "$DURATION" --json "$PROF_DIR/$op.json" \
                "zstd -q -c $DUMP > $ZSTD_DUMP" ;;
        zstd_dump_decode)
            log "$op (${DURATION}ms)"
            ZSTD_DUMP="$WORKDIR/$SAMPLE.bin.zst"
            ZSTD_RT="$WORKDIR/$SAMPLE.zstd.roundtrip.bin"
            "$ZEBRAC" --duration "$DURATION" --json "$PROF_DIR/$op.json" \
                "zstd -q -d -c $ZSTD_DUMP > $ZSTD_RT" ;;
        *)
            log "Unknown operation: $op (skipping)" ;;
    esac
done

log "Profiling complete.  Results: $PROF_DIR/"
log "Inspect with: python3 tools/inspect_dump.py $PROF_DIR/<op>.json"
