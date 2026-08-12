#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: tools/benchmark.sh [options] input.mzML

Options:
  --output DIR    New result directory under tmp/bench/runs by default.
  --threads N     Fixed parallel worker count (default: 4).
  --samples N     Exact zebrac sample count per operation (default: 5).
  --sanity        Label parser-example output as a sanity check.
  -h, --help      Show this help.
EOF
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
threads=4
samples=5
output_dir=""
input=""
sanity=false

while (($#)); do
    case "$1" in
        --output)
            output_dir=${2:?missing directory after --output}
            shift 2
            ;;
        --threads)
            threads=${2:?missing count after --threads}
            shift 2
            ;;
        --samples)
            samples=${2:?missing count after --samples}
            shift 2
            ;;
        --sanity)
            sanity=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            if [[ -n "$input" ]]; then
                echo "error: only one mzML input is accepted" >&2
                exit 1
            fi
            input=$1
            shift
            ;;
    esac
done

if [[ -z "$input" ]]; then
    usage >&2
    exit 1
fi
if [[ ! "$threads" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: --threads must be a positive integer" >&2
    exit 1
fi
if [[ ! "$samples" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: --samples must be a positive integer" >&2
    exit 1
fi

if [[ ! -f "$input" ]]; then
    echo "error: input not found: $input" >&2
    exit 1
fi
input=$(realpath "$input")
if [[ "$input" == "$repo_root/data/examples/"* && "$sanity" != true ]]; then
    echo 'error: parser examples are sanity inputs, not benchmark inputs' >&2
    echo 'rerun with --sanity to check harness wiring' >&2
    exit 1
fi
source_display=$input
if [[ "$input" == "$repo_root/"* ]]; then
    source_display=${input#"$repo_root/"}
fi

if [[ -z "$output_dir" ]]; then
    output_dir="$repo_root/tmp/bench/runs/local-$(date +%Y%m%d-%H%M%S)-$$"
elif [[ "$output_dir" != /* ]]; then
    output_dir="$repo_root/$output_dir"
fi
if [[ -e "$output_dir" ]]; then
    echo "error: output already exists: $output_dir" >&2
    exit 1
fi

readonly python="$repo_root/.venv/bin/python"
readonly zig="$repo_root/zig-0.16.0/zig"
readonly mzarc="$repo_root/zig-out/bin/mzarc"
readonly zebrac="$repo_root/tools/zebrac"
readonly mscompress="$repo_root/tools/bin/mscompress-msz"

for path in "$python" "$zig" "$zebrac" "$mscompress"; do
    if [[ ! -x "$path" ]]; then
        echo "error: required executable not found: $path" >&2
        if [[ "$path" == "$mscompress" ]]; then
            echo "run: bash tools/build_mscompress.sh" >&2
        fi
        exit 1
    fi
done

for command in gzip pigz zstd xz jq; do
    if ! command -v "$command" >/dev/null; then
        echo "error: required benchmark command not found: $command" >&2
        exit 1
    fi
done
gnuplot_bin=""
if command -v gnuplot >/dev/null; then
    gnuplot_bin=$(command -v gnuplot)
fi
gzip_bin=$(command -v gzip)
pigz_bin=$(command -v pigz)
zstd_bin=$(command -v zstd)
xz_bin=$(command -v xz)
jq_bin=$(command -v jq)
host=$(uname -srmo)
cpu="unknown"
if command -v lscpu >/dev/null; then
    cpu=$(lscpu | awk -F: '/^Model name:/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}')
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/mzarc-benchmark.XXXXXX")
cleanup() {
    rm -rf -- "$scratch"
}
trap cleanup EXIT

mkdir -p "$output_dir/zebrac"
cp "$input" "$scratch/source.mzML"

echo "building stripped ReleaseFast mzarc"
cd "$repo_root"
"$zig" build --release=fast \
    --cache-dir "$repo_root/.zig-cache" \
    --global-cache-dir "$scratch/zig-global" \
    --summary all

echo "creating one Dump V1 input"
"$python" "$repo_root/tools/mzml_dump.py" "$scratch/source.mzML" \
    -o "$scratch/source.bin"
"$mzarc" dump-inspect "$scratch/source.bin" >/dev/null

mzml_bytes=$(stat -c %s "$scratch/source.mzML")
dump_bytes=$(stat -c %s "$scratch/source.bin")
readonly mzml_bytes dump_bytes
readonly rows_dump="$output_dir/dump.tsv"
readonly rows_mzml="$output_dir/mzml.tsv"
: >"$rows_dump"
: >"$rows_mzml"

measure() {
    local operation_id=$1
    local command=$2
    local json="$output_dir/zebrac/$operation_id.json"

    "$zebrac" --duration 0 \
        --min-samples "$samples" \
        --max-samples "$samples" \
        --warmup 1 \
        --quiet \
        --json "$json" \
        -- "$command"

    "$jq_bin" -e \
        --argjson samples "$samples" \
        '.schema_version == 1 and
         .zebrac_version == "0.6.2" and
         (.results | length) == 1 and
         .results[0].sample_count == $samples and
         .results[0].failed_sample_count == 0' \
        "$json" >/dev/null
}

record_row() {
    local rows=$1
    local method=$2
    local thread_class=$3
    local validation=$4
    local input_bytes=$5
    local artifact=$6
    local encode_json=$7
    local decode_json=$8
    local artifact_bytes

    artifact_bytes=$(stat -c %s "$artifact")
    "$jq_bin" -r \
        --arg method "$method" \
        --arg threads "$thread_class" \
        --arg validation "$validation" \
        --argjson input_bytes "$input_bytes" \
        --argjson artifact_bytes "$artifact_bytes" \
        --slurpfile decode "$decode_json" '
        .results[0] as $encode |
        $decode[0].results[0] as $decode |
        [
          $method,
          $threads,
          $validation,
          $artifact_bytes,
          (100 * $artifact_bytes / $input_bytes),
          ($encode.wall_time.mean / 1000000),
          ($encode.wall_time.std_dev / 1000000),
          ($input_bytes * 1000000000 / $encode.wall_time.mean / 1048576),
          ($encode.peak_rss.median / 1048576),
          ($decode.wall_time.mean / 1000000),
          ($decode.wall_time.std_dev / 1000000),
          ($input_bytes * 1000000000 / $decode.wall_time.mean / 1048576),
          ($decode.peak_rss.median / 1048576)
        ] | @tsv' "$encode_json" >>"$rows"
}

write_comparison() {
    local title=$1
    local input_label=$2
    local input_bytes=$3
    local rows=$4
    local plot_name=$5
    local plot_path="$output_dir/$plot_name"
    local has_plot=false

    if [[ "$sanity" != true && -n "$gnuplot_bin" ]]; then
        if "$gnuplot_bin" -c "$repo_root/tools/benchmark_plot.gp" \
            "$rows" "$plot_path" "$title" "% of $input_label"; then
            has_plot=true
        else
            rm -f -- "$plot_path"
            echo "warning: gnuplot failed; keeping the complete tables without a figure" >&2
        fi
    fi

    {
        echo "## $title"
        echo
        echo "Comparison input: $input_label, $input_bytes bytes."
        echo
        if [[ "$has_plot" == true ]]; then
            echo "![$title summary]($plot_name)"
            echo
        fi
        echo '### Artifact'
        echo
        echo "| Method | Threads: encode / decode | Validation | Compressed bytes | Artifact / $input_label |"
        echo '| --- | --- | --- | ---: | ---: |'
        while IFS=$'\t' read -r method thread_class validation artifact_bytes percent encode_mean encode_std encode_rate encode_rss decode_mean decode_std decode_rate decode_rss; do
            printf '| %s | %s | %s | %s | %.2f%% |\n' \
                "$method" "$thread_class" "$validation" "$artifact_bytes" "$percent"
        done <"$rows"
        echo
        echo '### Encode'
        echo
        echo '| Method | Mean ± SD (ms) | MiB/s | Peak RSS (MiB) |'
        echo '| --- | ---: | ---: | ---: |'
        while IFS=$'\t' read -r method thread_class validation artifact_bytes percent encode_mean encode_std encode_rate encode_rss decode_mean decode_std decode_rate decode_rss; do
            printf '| %s | %.3f ± %.3f | %.2f | %.2f |\n' \
                "$method" "$encode_mean" "$encode_std" "$encode_rate" "$encode_rss"
        done <"$rows"
        echo
        echo '### Decode'
        echo
        echo '| Method | Mean ± SD (ms) | MiB/s | Peak RSS (MiB) |'
        echo '| --- | ---: | ---: | ---: |'
        while IFS=$'\t' read -r method thread_class validation artifact_bytes percent encode_mean encode_std encode_rate encode_rss decode_mean decode_std decode_rate decode_rss; do
            printf '| %s | %.3f ± %.3f | %.2f | %.2f |\n' \
                "$method" "$decode_mean" "$decode_std" "$decode_rate" "$decode_rss"
        done <"$rows"
        echo
    } >>"$output_dir/report.md"
}

run_mzarc_dump() {
    local work="$scratch/dump-mzarc"
    mkdir -p "$work"
    cp "$scratch/source.bin" "$work/source.bin"

    "$mzarc" encode "$work/source.bin" -o "$work/archive.mzarc"
    "$mzarc" decode "$work/archive.mzarc" -o "$work/decoded.bin"
    "$mzarc" validate "$work/source.bin" "$work/decoded.bin" --mode=lossless >/dev/null
    local validation="mzarc lossless policy"
    if cmp -s "$work/source.bin" "$work/decoded.bin"; then
        validation="byte exact"
    fi

    measure dump-mzarc-encode "$mzarc encode $work/source.bin -o $work/archive.mzarc"
    measure dump-mzarc-decode "$mzarc decode $work/archive.mzarc -o $work/decoded.bin"
    "$mzarc" validate "$work/source.bin" "$work/decoded.bin" --mode=lossless >/dev/null
    record_row "$rows_dump" 'mzarc lossless' 'single / single' "$validation" \
        "$dump_bytes" "$work/archive.mzarc" \
        "$output_dir/zebrac/dump-mzarc-encode.json" \
        "$output_dir/zebrac/dump-mzarc-decode.json"
}

run_gzip() {
    local lane=$1
    local source=$2
    local input_bytes=$3
    local rows=$4
    local work="$scratch/$lane-gzip"
    mkdir -p "$work"
    cp "$source" "$work/source"

    "$gzip_bin" -6 -n -f -k "$work/source"
    "$gzip_bin" -d -f -k "$work/source.gz"
    cmp "$source" "$work/source"

    measure "$lane-gzip-encode" "$gzip_bin -6 -n -f -k $work/source"
    measure "$lane-gzip-decode" "$gzip_bin -d -f -k $work/source.gz"
    cmp "$source" "$work/source"
    record_row "$rows" 'gzip -6' 'single / single' 'byte exact' \
        "$input_bytes" "$work/source.gz" \
        "$output_dir/zebrac/$lane-gzip-encode.json" \
        "$output_dir/zebrac/$lane-gzip-decode.json"
}

run_pigz() {
    local lane=$1
    local source=$2
    local input_bytes=$3
    local rows=$4
    local workers=$5
    local suffix=$6
    local label=$7
    local thread_class='single / single'
    local work="$scratch/$lane-pigz-$suffix"
    if ((workers > 1)); then
        thread_class="fixed-$workers / fixed-$workers helpers"
    fi
    mkdir -p "$work"
    cp "$source" "$work/source"

    "$pigz_bin" -6 -p "$workers" -n -f -k "$work/source"
    "$pigz_bin" -d -p "$workers" -f -k "$work/source.gz"
    cmp "$source" "$work/source"

    measure "$lane-pigz-$suffix-encode" "$pigz_bin -6 -p $workers -n -f -k $work/source"
    measure "$lane-pigz-$suffix-decode" "$pigz_bin -d -p $workers -f -k $work/source.gz"
    cmp "$source" "$work/source"
    record_row "$rows" "$label" "$thread_class" 'byte exact' \
        "$input_bytes" "$work/source.gz" \
        "$output_dir/zebrac/$lane-pigz-$suffix-encode.json" \
        "$output_dir/zebrac/$lane-pigz-$suffix-decode.json"
}

run_zstd() {
    local lane=$1
    local source=$2
    local input_bytes=$3
    local rows=$4
    local worker_arg=$5
    local suffix=$6
    local label=$7
    local thread_class=$8
    local work="$scratch/$lane-zstd-$suffix"
    mkdir -p "$work"

    "$zstd_bin" -q -3 "$worker_arg" --no-asyncio -f "$source" -o "$work/archive.zst"
    "$zstd_bin" -q -d --no-asyncio -f "$work/archive.zst" -o "$work/decoded"
    cmp "$source" "$work/decoded"

    measure "$lane-zstd-$suffix-encode" "$zstd_bin -q -3 $worker_arg --no-asyncio -f $source -o $work/archive.zst"
    measure "$lane-zstd-$suffix-decode" "$zstd_bin -q -d --no-asyncio -f $work/archive.zst -o $work/decoded"
    cmp "$source" "$work/decoded"
    record_row "$rows" "$label" "$thread_class" 'byte exact' \
        "$input_bytes" "$work/archive.zst" \
        "$output_dir/zebrac/$lane-zstd-$suffix-encode.json" \
        "$output_dir/zebrac/$lane-zstd-$suffix-decode.json"
}

run_xz() {
    local lane=$1
    local source=$2
    local input_bytes=$3
    local rows=$4
    local workers=$5
    local suffix=$6
    local label=$7
    local work="$scratch/$lane-xz-$suffix"
    mkdir -p "$work"
    cp "$source" "$work/source"

    "$xz_bin" -6 -T "$workers" -f -k "$work/source"
    "$xz_bin" -d -T "$workers" -f -k "$work/source.xz"
    cmp "$source" "$work/source"

    measure "$lane-xz-$suffix-encode" "$xz_bin -q -6 -T $workers -f -k $work/source"
    measure "$lane-xz-$suffix-decode" "$xz_bin -q -d -T $workers -f -k $work/source.xz"
    cmp "$source" "$work/source"
    record_row "$rows" "$label" "$suffix / $suffix" 'byte exact' \
        "$input_bytes" "$work/source.xz" \
        "$output_dir/zebrac/$lane-xz-$suffix-encode.json" \
        "$output_dir/zebrac/$lane-xz-$suffix-decode.json"
}

run_mscompress() {
    local workers=$1
    local suffix=$2
    local label=$3
    local work="$scratch/mzml-mscompress-$suffix"
    mkdir -p "$work"

    "$mscompress" -t "$workers" "$scratch/source.mzML" "$work/archive.msz"
    "$mscompress" -t "$workers" "$work/archive.msz" "$work/decoded.mzML"
    "$python" "$repo_root/tools/mzml_dump.py" "$work/decoded.mzML" \
        -o "$work/decoded.bin" >/dev/null
    cmp "$scratch/source.bin" "$work/decoded.bin"

    measure "mzml-mscompress-$suffix-encode" "$mscompress -t $workers $scratch/source.mzML $work/archive.msz"
    measure "mzml-mscompress-$suffix-decode" "$mscompress -t $workers $work/archive.msz $work/decoded.mzML"
    "$python" "$repo_root/tools/mzml_dump.py" "$work/decoded.mzML" \
        -o "$work/decoded.bin" >/dev/null
    cmp "$scratch/source.bin" "$work/decoded.bin"
    record_row "$rows_mzml" "$label" "$suffix / $suffix" 'Dump V1 exact' \
        "$mzml_bytes" "$work/archive.msz" \
        "$output_dir/zebrac/mzml-mscompress-$suffix-encode.json" \
        "$output_dir/zebrac/mzml-mscompress-$suffix-decode.json"
}

echo "testing and measuring the Dump V1 comparison"
run_mzarc_dump
run_gzip dump "$scratch/source.bin" "$dump_bytes" "$rows_dump"
run_pigz dump "$scratch/source.bin" "$dump_bytes" "$rows_dump" 1 single 'pigz -6 -p1'
run_pigz dump "$scratch/source.bin" "$dump_bytes" "$rows_dump" "$threads" "fixed-$threads" "pigz -6 -p$threads [P]"
run_zstd dump "$scratch/source.bin" "$dump_bytes" "$rows_dump" --single-thread single 'zstd -3 --single-thread' 'single / single'
run_zstd dump "$scratch/source.bin" "$dump_bytes" "$rows_dump" "-T$threads" "fixed-$threads" "zstd -3 -T$threads [P]" "fixed-$threads / single"
run_xz dump "$scratch/source.bin" "$dump_bytes" "$rows_dump" 1 single 'xz -6 -T1'
run_xz dump "$scratch/source.bin" "$dump_bytes" "$rows_dump" "$threads" "fixed-$threads" "xz -6 -T$threads [P]"

echo "testing and measuring the direct mzML comparison"
run_gzip mzml "$scratch/source.mzML" "$mzml_bytes" "$rows_mzml"
run_pigz mzml "$scratch/source.mzML" "$mzml_bytes" "$rows_mzml" 1 single 'pigz -6 -p1'
run_pigz mzml "$scratch/source.mzML" "$mzml_bytes" "$rows_mzml" "$threads" "fixed-$threads" "pigz -6 -p$threads [P]"
run_zstd mzml "$scratch/source.mzML" "$mzml_bytes" "$rows_mzml" --single-thread single 'zstd -3 --single-thread' 'single / single'
run_zstd mzml "$scratch/source.mzML" "$mzml_bytes" "$rows_mzml" "-T$threads" "fixed-$threads" "zstd -3 -T$threads [P]" "fixed-$threads / single"
run_xz mzml "$scratch/source.mzML" "$mzml_bytes" "$rows_mzml" 1 single 'xz -6 -T1'
run_xz mzml "$scratch/source.mzML" "$mzml_bytes" "$rows_mzml" "$threads" "fixed-$threads" "xz -6 -T$threads [P]"
run_mscompress 1 single 'MScompress -t1'
run_mscompress "$threads" "fixed-$threads" "MScompress -t$threads [P]"

{
    if [[ "$sanity" == true ]]; then
        echo '# Compression harness sanity check'
    else
        echo '# Reference compression benchmark'
    fi
    echo
    echo "- Source: \`$source_display\`"
    echo "- Measured: $(date --iso-8601=seconds)"
    echo "- Host: $cpu; $host"
    echo "- mzarc build: stripped ReleaseFast"
    echo "- Samples: $samples per operation after one warmup"
    echo "- Parallel rows: $threads workers, marked \`[P]\`"
    echo '- Throughput basis: uncompressed bytes for the input section'
    echo '- Peak RSS: zebrac direct-child RSS'
    echo
    if [[ "$sanity" == true ]]; then
        echo 'This parser-example run checks command wiring and round trips. Its size, timing, RSS, and rankings are not benchmark evidence.'
        echo
    else
        echo 'Compare methods only within the same input section. The Dump V1 and original mzML sections have different byte and validation contracts.'
        echo
    fi
} >"$output_dir/report.md"
if [[ "$sanity" != true ]]; then
    mzarc_bytes=$(awk -F $'\t' '$1 == "mzarc lossless" { print $4; exit }' "$rows_dump")
    dump_of_mzml=$(awk -v dump="$dump_bytes" -v mzml="$mzml_bytes" 'BEGIN { printf "%.2f", 100 * dump / mzml }')
    mzarc_of_mzml=$(awk -v artifact="$mzarc_bytes" -v mzml="$mzml_bytes" 'BEGIN { printf "%.2f", 100 * artifact / mzml }')
    {
        echo '## Pipeline size context'
        echo
        echo '| Representation | Bytes | Representation / original mzML |'
        echo '| --- | ---: | ---: |'
        printf '| Original mzML | %s | 100.00%% |\n' "$mzml_bytes"
        printf '| Dump V1 retained fields | %s | %s%% |\n' "$dump_bytes" "$dump_of_mzml"
        printf '| mzarc lossless | %s | %s%% |\n' "$mzarc_bytes" "$mzarc_of_mzml"
        echo
        echo 'mzarc reads Dump V1 and preserves its retained spectrum fields. It does not reproduce the original mzML document.'
        echo
    } >>"$output_dir/report.md"
fi
write_comparison 'Dump V1 comparison' 'Dump V1' "$dump_bytes" "$rows_dump" 'dump-summary.svg'
write_comparison 'Original mzML comparison' 'original mzML' "$mzml_bytes" "$rows_mzml" 'mzml-summary.svg'
cat >>"$output_dir/report.md" <<'EOF'
MScompress is spectrum-lossless in this report, not necessarily document-byte-lossless. Its decoded mzML is converted with the same Dump V1 converter and compared byte for byte with the original dump. Generic compressors use direct byte comparison against the original table input.

Run metadata and complete table rows: [tool versions](versions.txt), [Dump V1 TSV](dump.tsv), and [original mzML TSV](mzml.tsv).
EOF

{
    echo "host: $host"
    echo "cpu: $cpu"
    echo "mzarc commit: $(git -C "$repo_root" rev-parse HEAD)"
    echo "mzarc dirty: $(git -C "$repo_root" status --short | wc -l) paths"
    echo "zebrac: $("$zebrac" --version)"
    echo "gzip: $("$gzip_bin" --version | head -1)"
    echo "pigz: $("$pigz_bin" --version)"
    echo "zstd: $("$zstd_bin" --version)"
    echo "xz: $("$xz_bin" --version | head -1)"
    echo "MScompress: $("$mscompress" --json --version | "$jq_bin" -r .version)"
    if [[ -n "$gnuplot_bin" ]]; then
        echo "gnuplot: $("$gnuplot_bin" --version)"
    else
        echo 'gnuplot: not installed; summary figures omitted'
    fi
} >"$output_dir/versions.txt"

echo "report: $output_dir/report.md"
