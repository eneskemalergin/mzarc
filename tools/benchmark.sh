#!/usr/bin/env bash
# tools/benchmark.sh -- Orchestrate all timing measurements for mzarc.
#
# Usage:
#   tools/benchmark.sh <mzml_file> [OPTIONS]
#
# Options:
#   --duration MS      zebrac window per operation in ms (default: 5000)
#   --quant N          selected lossy intensity quant (default: 16384)
#   --lossy-sweep L    comma-separated quant levels (default: 256,1024,4096,16384)
#   --build            build mzarc release binary before running
#   --workdir DIR      directory for generated intermediate files
#   --output-dir DIR   directory for benchmark output (default: benchmark)
#
# Each timing measurement is written as a separate zebrac JSON file to
# <output-dir>/raw/.  After all runs, write_manifest.py assembles the
# manifest.json that collect_report.py uses to produce the final report.
#
# After benchmark.sh:
#   tools/validate.sh               # fidelity + regression checks
#   python3 tools/collect_report.py benchmark/raw/manifest.json

set -euo pipefail
cd "$(dirname "$0")/.."

# --------------------------------------------------------------------------- #
# defaults                                                                    #
# --------------------------------------------------------------------------- #
DURATION=5000
QUANT=16384
LOSSY_SWEEP="256,1024,4096,16384"
BUILD=0
WORKDIR=""
OUTPUT_DIR="benchmark"
MZML=""

# --------------------------------------------------------------------------- #
# argument parsing                                                            #
# --------------------------------------------------------------------------- #
while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration)   DURATION="$2";   shift 2 ;;
        --quant)      QUANT="$2";      shift 2 ;;
        --lossy-sweep) LOSSY_SWEEP="$2"; shift 2 ;;
        --build)      BUILD=1;         shift   ;;
        --workdir)    WORKDIR="$2";    shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --help|-h)
            grep '^#' "$0" | head -15 | sed 's/^# \{0,2\}//'
            exit 0 ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)  MZML="$1"; shift ;;
    esac
done

if [[ -z "$MZML" ]]; then
    echo "Usage: tools/benchmark.sh <mzml_file> [OPTIONS]" >&2
    exit 1
fi

SAMPLE=$(basename "$MZML" .mzML)
if [[ -z "$WORKDIR" ]]; then
    WORKDIR="$(dirname "$MZML")/benchmarks/$SAMPLE"
fi

RAW="$OUTPUT_DIR/raw"
MZARC="zig-out/bin/mzarc"
ZEBRAC="tools/zebrac"

# --------------------------------------------------------------------------- #
# optional build                                                              #
# --------------------------------------------------------------------------- #
if [[ "$BUILD" == "1" ]]; then
    echo "[benchmark] Building mzarc..." >&2
    zig_bin=$(ls zig-*/zig 2>/dev/null | head -1 || true)
    if [[ -z "$zig_bin" ]]; then
        echo "ERROR: No zig binary found in repo root" >&2; exit 1
    fi
    "$zig_bin" build --release=fast
    echo "[benchmark] Build complete." >&2
fi

# --------------------------------------------------------------------------- #
# sanity checks                                                               #
# --------------------------------------------------------------------------- #
for tool in gzip zstd bzip2 lz4 xz; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool not found in PATH" >&2; exit 1; }
done
[[ -f "$MZARC" ]] || { echo "ERROR: mzarc binary not found: $MZARC (run with --build)" >&2; exit 1; }
[[ -f "$ZEBRAC" ]] || { echo "ERROR: zebrac not found: $ZEBRAC" >&2; exit 1; }
[[ -f "$MZML" ]]  || { echo "ERROR: mzML file not found: $MZML" >&2; exit 1; }

mkdir -p "$WORKDIR" "$RAW"

# --------------------------------------------------------------------------- #
# helpers                                                                     #
# --------------------------------------------------------------------------- #
log()  { echo "[benchmark] $*" >&2; }
bench() {
    # bench <slug> <shell_command_string>
    local out="$RAW/$1.json"
    local tmp; tmp=$(mktemp /tmp/mzarc_bench_XXXXXX.sh)
    printf '#!/bin/sh\n%s\n' "$2" > "$tmp"
    chmod +x "$tmp"
    log "$1"
    "$ZEBRAC" --duration "$DURATION" --json "$out" "$tmp"
    rm -f "$tmp"
}

# --------------------------------------------------------------------------- #
# file paths                                                                  #
# --------------------------------------------------------------------------- #
DUMP="$WORKDIR/$SAMPLE.bin"

GZIP_DUMP="$WORKDIR/$SAMPLE.bin.gz"
GZIP_DUMP_RT="$WORKDIR/$SAMPLE.gzip.roundtrip.bin"
ZSTD_DUMP="$WORKDIR/$SAMPLE.bin.zst"
ZSTD_DUMP_RT="$WORKDIR/$SAMPLE.zstd.roundtrip.bin"
BZIP2_DUMP="$WORKDIR/$SAMPLE.bin.bz2"
BZIP2_DUMP_RT="$WORKDIR/$SAMPLE.bzip2.roundtrip.bin"
LZ4_DUMP="$WORKDIR/$SAMPLE.bin.lz4"
LZ4_DUMP_RT="$WORKDIR/$SAMPLE.lz4.roundtrip.bin"
XZ_DUMP="$WORKDIR/$SAMPLE.bin.xz"
XZ_DUMP_RT="$WORKDIR/$SAMPLE.xz.roundtrip.bin"

GZIP_MZML="$WORKDIR/$SAMPLE.mzML.gz"
GZIP_MZML_RT="$WORKDIR/$SAMPLE.gzip_mzml.roundtrip.mzML"
ZSTD_MZML="$WORKDIR/$SAMPLE.mzML.zst"
ZSTD_MZML_RT="$WORKDIR/$SAMPLE.zstd_mzml.roundtrip.mzML"
BZIP2_MZML="$WORKDIR/$SAMPLE.mzML.bz2"
BZIP2_MZML_RT="$WORKDIR/$SAMPLE.bzip2_mzml.roundtrip.mzML"
LZ4_MZML="$WORKDIR/$SAMPLE.mzML.lz4"
LZ4_MZML_RT="$WORKDIR/$SAMPLE.lz4_mzml.roundtrip.mzML"
XZ_MZML="$WORKDIR/$SAMPLE.mzML.xz"
XZ_MZML_RT="$WORKDIR/$SAMPLE.xz_mzml.roundtrip.mzML"

MZARC_LOSSLESS="$WORKDIR/$SAMPLE.lossless.mzarc"
MZARC_LOSSLESS_RT="$WORKDIR/$SAMPLE.lossless.roundtrip.bin"
MZARC_LOSSY="$WORKDIR/$SAMPLE.lossy.q${QUANT}.mzarc"
MZARC_LOSSY_RT="$WORKDIR/$SAMPLE.lossy.q${QUANT}.roundtrip.bin"

# --------------------------------------------------------------------------- #
# 1. mzML dump (Python wrapped in zebrac)                                     #
# --------------------------------------------------------------------------- #
bench "mzml_dump" "python3 tools/mzml_dump.py $MZML -o $DUMP"

# --------------------------------------------------------------------------- #
# 2. dump-level compressors                                                   #
# --------------------------------------------------------------------------- #
bench "gzip_dump_encode"  "gzip -n -c $DUMP > $GZIP_DUMP"
bench "gzip_dump_decode"  "gzip -d -c $GZIP_DUMP > $GZIP_DUMP_RT"

bench "zstd_dump_encode"  "zstd -q -c $DUMP > $ZSTD_DUMP"
bench "zstd_dump_decode"  "zstd -q -d -c $ZSTD_DUMP > $ZSTD_DUMP_RT"

bench "bzip2_dump_encode" "bzip2 -c $DUMP > $BZIP2_DUMP"
bench "bzip2_dump_decode" "bzip2 -d -c $BZIP2_DUMP > $BZIP2_DUMP_RT"

bench "lz4_dump_encode"   "lz4 -q -c $DUMP > $LZ4_DUMP"
bench "lz4_dump_decode"   "lz4 -q -d -c $LZ4_DUMP > $LZ4_DUMP_RT"

bench "xz_dump_encode"    "xz -c $DUMP > $XZ_DUMP"
bench "xz_dump_decode"    "xz -d -c $XZ_DUMP > $XZ_DUMP_RT"

# --------------------------------------------------------------------------- #
# 3. mzML-level compressors                                                   #
# --------------------------------------------------------------------------- #
bench "gzip_mzml_encode"  "gzip -n -c $MZML > $GZIP_MZML"
bench "gzip_mzml_decode"  "gzip -d -c $GZIP_MZML > $GZIP_MZML_RT"

bench "zstd_mzml_encode"  "zstd -q -c $MZML > $ZSTD_MZML"
bench "zstd_mzml_decode"  "zstd -q -d -c $ZSTD_MZML > $ZSTD_MZML_RT"

bench "bzip2_mzml_encode" "bzip2 -c $MZML > $BZIP2_MZML"
bench "bzip2_mzml_decode" "bzip2 -d -c $BZIP2_MZML > $BZIP2_MZML_RT"

bench "lz4_mzml_encode"   "lz4 -q -c $MZML > $LZ4_MZML"
bench "lz4_mzml_decode"   "lz4 -q -d -c $LZ4_MZML > $LZ4_MZML_RT"

bench "xz_mzml_encode"    "xz -c $MZML > $XZ_MZML"
bench "xz_mzml_decode"    "xz -d -c $XZ_MZML > $XZ_MZML_RT"

# --------------------------------------------------------------------------- #
# 4. mzarc lossless                                                           #
# --------------------------------------------------------------------------- #
bench "mzarc_lossless_encode" "$MZARC encode $DUMP -o $MZARC_LOSSLESS"
bench "mzarc_lossless_decode" "$MZARC decode $MZARC_LOSSLESS -o $MZARC_LOSSLESS_RT"

# --------------------------------------------------------------------------- #
# 5. mzarc lossy (selected quant)                                             #
# --------------------------------------------------------------------------- #
bench "mzarc_lossy_encode" \
    "$MZARC encode $DUMP -o $MZARC_LOSSY --lossy --intensity-quant $QUANT"
bench "mzarc_lossy_decode" "$MZARC decode $MZARC_LOSSY -o $MZARC_LOSSY_RT"

# --------------------------------------------------------------------------- #
# 6. lossy sweep (extra quant levels, single encode+decode, no zebrac timing) #
# --------------------------------------------------------------------------- #
IFS=',' read -ra _SWEEP <<< "$LOSSY_SWEEP"
for q in "${_SWEEP[@]}"; do
    q="${q// /}"
    [[ "$q" == "$QUANT" ]] && continue
    SWEEP_ENC="$WORKDIR/$SAMPLE.lossy.q${q}.mzarc"
    SWEEP_DEC="$WORKDIR/$SAMPLE.lossy.q${q}.roundtrip.bin"
    log "lossy sweep q=$q encode"
    "$MZARC" encode "$DUMP" -o "$SWEEP_ENC" --lossy --intensity-quant "$q" 2>/dev/null
    log "lossy sweep q=$q decode"
    "$MZARC" decode "$SWEEP_ENC" -o "$SWEEP_DEC" 2>/dev/null
done

# --------------------------------------------------------------------------- #
# 7. external baselines (optional, requires Python packages)                  #
# --------------------------------------------------------------------------- #
_AVAIL=$(python3 tools/benchmark_external.py available 2>/dev/null || true)

for _TOOL in mzmlb numpress mscompress; do
    if echo "$_AVAIL" | grep -qw "$_TOOL"; then
        case "$_TOOL" in
            mzmlb)
                _EXT_ART="$WORKDIR/$SAMPLE.mzMLb"
                _EXT_RT="$WORKDIR/$SAMPLE.mzmlb.roundtrip.bin"
                _EXT_LABEL="mzMLb"
                ;;
            numpress)
                _EXT_ART="$WORKDIR/$SAMPLE.numpress.mzML"
                _EXT_RT="$WORKDIR/$SAMPLE.numpress.roundtrip.bin"
                _EXT_LABEL="MS-Numpress"
                ;;
            mscompress)
                _EXT_ART="$WORKDIR/$SAMPLE.msz"
                _EXT_RT="$WORKDIR/$SAMPLE.mscompress.roundtrip.bin"
                _EXT_LABEL="MScompress"
                ;;
        esac
        log "external: $_EXT_LABEL encode"
        bench "${_TOOL}_encode" \
            "python3 tools/benchmark_external.py encode $_TOOL $MZML $_EXT_ART"
        log "external: $_EXT_LABEL decode"
        bench "${_TOOL}_decode" \
            "python3 tools/benchmark_external.py decode $_TOOL $_EXT_ART $_EXT_RT"
    else
        log "external: $_TOOL not available, skipping"
    fi
done

# --------------------------------------------------------------------------- #
# 8. write manifest                                                           #
# --------------------------------------------------------------------------- #
log "writing manifest.json"
python3 tools/write_manifest.py \
    --mzml     "$MZML"    \
    --sample   "$SAMPLE"  \
    --workdir  "$WORKDIR" \
    --raw-dir  "$RAW"     \
    --output-dir "$OUTPUT_DIR" \
    --duration "$DURATION" \
    --quant    "$QUANT"   \
    --lossy-sweep "$LOSSY_SWEEP"

log "done.  Manifest: $RAW/manifest.json"
log "Next: tools/validate.sh"
log "Then: python3 tools/collect_report.py $RAW/manifest.json"
