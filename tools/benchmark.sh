#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: tools/benchmark.sh [options] input.mzML
       tools/benchmark.sh --check

Options:
  --output DIR    New result directory under tmp/bench/runs by default.
  --threads N     Fixed parallel worker count (default: 4).
  --samples N     Exact zebrac sample count per operation, 1 to 10000 (default: 5).
  --sanity        Label parser-example output as a sanity check.
  --check         Run the focused local benchmark checks.
  -h, --help      Show this help.
EOF
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

run_checks() {
    local self="$repo_root/tools/benchmark.sh"
    local tiny="$repo_root/data/examples/tiny.pwiz.1.1.mzML"
    local output report_text rows real_cmp
    benchmark_check_root=$(mktemp -d "${TMPDIR:-/tmp}/mzarc-benchmark-check.XXXXXX")
    trap 'rm -rf -- "${benchmark_check_root:-}"' EXIT

    unset MZARC_BENCH_CHECKING MZARC_BENCH_ZEBRAC MZARC_BENCH_MSCOMPRESS

    fail() {
        echo "FAIL benchmark check: $1" >&2
        exit 1
    }

    expect_failure() {
        local label=$1
        local expected=$2
        shift 2

        if output=$("$@" 2>&1); then
            fail "$label accepted an invalid run"
        fi
        if [[ "$output" != *"$expected"* ]]; then
            printf '%s\n' "$output" >&2
            fail "$label returned the wrong diagnostic"
        fi
        echo "PASS benchmark check: $label"
    }

    [[ -f "$tiny" ]] || fail "missing parser fixture: $tiny"
    expect_failure 'missing input' 'Usage:' bash "$self"
    expect_failure 'unknown option' 'unknown option' bash "$self" --unknown
    expect_failure 'multiple inputs' 'only one mzML input' bash "$self" "$tiny" "$tiny"
    expect_failure 'invalid thread count' '--threads must be a positive integer' \
        bash "$self" --threads 0 --sanity "$tiny"
    expect_failure 'excessive sample count' "10000-sample cap" \
        bash "$self" --samples 10001 --sanity "$tiny"
    expect_failure 'parser fixture benchmark' 'parser examples are sanity inputs' \
        bash "$self" "$tiny"

    mkdir "$benchmark_check_root/existing"
    printf 'keep\n' >"$benchmark_check_root/existing/sentinel"
    expect_failure 'existing output directory' 'output already exists' \
        bash "$self" --sanity --samples 1 \
        --output "$benchmark_check_root/existing" "$tiny"
    [[ $(<"$benchmark_check_root/existing/sentinel") == keep ]] || \
        fail 'existing output directory was modified'

    expect_failure 'missing MScompress' "$benchmark_check_root/missing-mscompress" \
        env MZARC_BENCH_CHECKING=true \
        MZARC_BENCH_MSCOMPRESS="$benchmark_check_root/missing-mscompress" \
        bash "$self" --sanity --samples 1 \
        --output "$benchmark_check_root/missing-tool" "$tiny"
    [[ ! -e "$benchmark_check_root/missing-tool" ]] || \
        fail 'missing tool created output'

    mkdir "$benchmark_check_root/fake"
    cat >"$benchmark_check_root/fake/zebrac" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --version ]]; then
    echo 'zebrac 0.6.2'
    exit 0
fi
json=""
while (($#)); do
    if [[ $1 == --json ]]; then
        json=$2
        shift 2
    else
        shift
    fi
done
[[ -n "$json" ]]
printf '{}\n' >"$json"
EOF
    chmod +x "$benchmark_check_root/fake/zebrac"
    expect_failure 'malformed zebrac result' 'invalid zebrac result' \
        env MZARC_BENCH_CHECKING=true \
        MZARC_BENCH_ZEBRAC="$benchmark_check_root/fake/zebrac" \
        bash "$self" --sanity --samples 1 \
        --output "$benchmark_check_root/malformed" "$tiny"
    [[ ! -e "$benchmark_check_root/malformed/report.md" ]] || \
        fail 'malformed zebrac result produced a report'

    real_cmp=$(command -v cmp) || fail 'cmp is unavailable'
    cat >"$benchmark_check_root/fake/cmp" <<EOF
#!/usr/bin/env bash
if [[ \$# -eq 2 && \$1 == */source.bin && \$2 == */dump-gzip/source ]]; then
    echo 'injected byte mismatch' >&2
    exit 1
fi
exec "$real_cmp" "\$@"
EOF
    chmod +x "$benchmark_check_root/fake/cmp"
    expect_failure 'failed peer validation' 'injected byte mismatch' \
        env PATH="$benchmark_check_root/fake:$PATH" \
        bash "$self" --sanity --samples 1 \
        --output "$benchmark_check_root/validation" "$tiny"
    [[ ! -e "$benchmark_check_root/validation/report.md" ]] || \
        fail 'failed validation produced a report'

    if ! output=$(bash "$self" --sanity --samples 1 \
        --output "$benchmark_check_root/success" "$tiny" 2>&1); then
        printf '%s\n' "$output" >&2
        fail 'complete sanity run'
    fi
    [[ -f "$benchmark_check_root/success/report.md" ]] || \
        fail 'sanity run did not produce a report'
    [[ -f "$benchmark_check_root/success/dump.tsv" ]] || \
        fail 'sanity run did not retain Dump V1 rows'
    report_text=$(<"$benchmark_check_root/success/report.md")
    for expected in '# Compression harness sanity check' 'Artifact / Dump V1' \
        'Artifact / original mzML' 'Threads (encode / decode)' '[P]' \
        'byte exact' 'Dump V1 exact'; do
        [[ "$report_text" == *"$expected"* ]] || \
            fail "report is missing: $expected"
    done
    shopt -s nullglob
    local json_files=("$benchmark_check_root/success/zebrac/"*.json)
    shopt -u nullglob
    ((${#json_files[@]} == 34)) || fail 'sanity run did not retain 34 zebrac results'
    rows=$(wc -l <"$benchmark_check_root/success/dump.tsv")
    ((rows == 8)) || fail 'sanity run did not retain eight Dump V1 rows'
    echo 'PASS benchmark check: complete sanity run'
}

if [[ ${1:-} == --check ]]; then
    (($# == 1)) || {
        usage >&2
        exit 1
    }
    run_checks
    exit 0
fi

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
if ((samples > 10000)); then
    echo "error: --samples cannot exceed zebrac's 10000-sample cap" >&2
    exit 1
fi

if [[ ! -f "$input" ]]; then
    echo "error: input not found: $input" >&2
    exit 1
fi
input=$(realpath "$input")
readonly source_name=${input##*/}
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
zebrac="$repo_root/tools/zebrac"
mscompress="$repo_root/tools/bin/mscompress-msz"
if [[ ${MZARC_BENCH_CHECKING:-} == true ]]; then
    zebrac="${MZARC_BENCH_ZEBRAC:-$zebrac}"
    mscompress="${MZARC_BENCH_MSCOMPRESS:-$mscompress}"
fi
readonly zebrac mscompress

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

mzarc_version=$(awk -F'"' '/^[[:space:]]*\.version = "[0-9]+\.[0-9]+\.[0-9]+"/ { print $2; exit }' "$repo_root/build.zig.zon")
changelog_version=$(awk -F'[][]' '/^## \[[0-9]+\.[0-9]+\.[0-9]+\]/ { print $2; exit }' "$repo_root/CHANGELOG.md")
if [[ -z "$mzarc_version" || "$mzarc_version" != "$changelog_version" ]]; then
    echo "error: build version '$mzarc_version' does not match latest changelog version '$changelog_version'" >&2
    exit 1
fi
zig_version=$("$zig" version)
python_version=$("$python" --version 2>&1)
python_version=${python_version#Python }
pyteomics_version=$("$python" -c 'import importlib.metadata; print(importlib.metadata.version("pyteomics"))')
zebrac_version=$("$zebrac" --version)
zebrac_json_version=${zebrac_version#zebrac }
if [[ -z "$zebrac_json_version" || "$zebrac_json_version" == "$zebrac_version" ]]; then
    echo "error: unexpected zebrac version output: $zebrac_version" >&2
    exit 1
fi
gzip_version=$("$gzip_bin" --version | sed -n '1p')
pigz_version=$("$pigz_bin" --version)
zstd_version=$("$zstd_bin" --version | sed -E 's/^.* v([^,]+),.*$/zstd \1/')
xz_version=$("$xz_bin" --version | sed -n '1p' | awk '{ print "xz " $NF }')
mscompress_version=$("$mscompress" --json --version | "$jq_bin" -r .version)
jq_version=$("$jq_bin" --version)
gnuplot_version=""
if [[ -n "$gnuplot_bin" ]]; then
    gnuplot_version=$("$gnuplot_bin" --version)
fi
measurement_word='measurements'
if ((samples == 1)); then
    measurement_word='measurement'
fi
readonly mzarc_version changelog_version zig_version python_version pyteomics_version
readonly zebrac_version zebrac_json_version gzip_version pigz_version zstd_version
readonly xz_version mscompress_version jq_version gnuplot_version measurement_word

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
dump_info=$("$mzarc" dump-inspect "$scratch/source.bin" 2>&1)
spectra=$(awk -F': ' '$1 == "spectra" { print $2; exit }' <<<"$dump_info")
total_peaks=$(awk -F': ' '$1 == "total peaks" { print $2; exit }' <<<"$dump_info")
ms1_count=$(awk -F': ' '$1 == "ms1 count" { print $2; exit }' <<<"$dump_info")
ms2_count=$(awk -F': ' '$1 == "ms2 count" { print $2; exit }' <<<"$dump_info")
readonly spectra total_peaks ms1_count ms2_count
for value in "$spectra" "$total_peaks" "$ms1_count" "$ms2_count"; do
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo 'error: could not read source shape from mzarc dump-inspect' >&2
        exit 1
    fi
done

mzml_bytes=$(stat -c %s "$scratch/source.mzML")
dump_bytes=$(stat -c %s "$scratch/source.bin")
readonly mzml_bytes dump_bytes
readonly rows_dump="$output_dir/dump.tsv"
readonly rows_mzml="$scratch/mzml.tsv"
: >"$rows_dump"
: >"$rows_mzml"

zebrac_command() {
    local command=""
    local argument encoded character
    local index

    for argument in "$@"; do
        encoded=""
        if [[ -z "$argument" ]]; then
            encoded="''"
        else
            for ((index = 0; index < ${#argument}; index++)); do
                character=${argument:index:1}
                case "$character" in
                    [[:alnum:]]|'_'|'.'|'/'|'-'|':'|'='|','|'+'|'@'|'%') encoded+="$character" ;;
                    *) encoded+="\\$character" ;;
                esac
            done
        fi
        if [[ -n "$command" ]]; then
            command+=' '
        fi
        command+="$encoded"
    done
    printf '%s' "$command"
}

measure() {
    local operation_id=$1
    shift
    local command expected_argv
    local json="$output_dir/zebrac/$operation_id.json"

    command=$(zebrac_command "$@")
    expected_argv=$("$jq_bin" -cn --args '$ARGS.positional' -- "$@")

    "$zebrac" --duration 0 \
        --min-samples "$samples" \
        --max-samples "$samples" \
        --warmup 1 \
        --quiet \
        --json "$json" \
        -- "$command"

    if ! "$jq_bin" -e \
        --argjson samples "$samples" \
        --argjson expected_argv "$expected_argv" \
        --arg command "$command" \
        --arg zebrac_version "$zebrac_json_version" \
        '.schema_version == 1 and
         .zebrac_version == $zebrac_version and
         .config.duration_ms == 0 and
         .config.min_samples == $samples and
         .config.max_samples == $samples and
         .config.warmup == 1 and
         .config.allow_failures == false and
         (.results | length) == 1 and
         .results[0].command == $command and
         .results[0].argv == $expected_argv and
         .results[0].sample_count == $samples and
         .results[0].failed_sample_count == 0 and
         .results[0].wall_time.unit == "nanoseconds" and
         .results[0].wall_time.sample_count == $samples and
         (.results[0].wall_time.mean | type == "number") and
         (.results[0].wall_time.std_dev | type == "number") and
         .results[0].peak_rss.unit == "bytes" and
         .results[0].peak_rss.sample_count == $samples and
         (.results[0].peak_rss.median | type == "number")' \
        "$json" >/dev/null; then
        echo "error: invalid zebrac result: $json" >&2
        return 1
    fi
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

align_markdown_tables() {
    local report=$1
    local formatted="$scratch/formatted-report.md"

    awk '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        function repeat_char(character, count, result) {
            result = ""
            while (count-- > 0) {
                result = result character
            }
            return result
        }
        function clear_table(key) {
            for (key in cells) delete cells[key]
            for (key in widths) delete widths[key]
            for (key in align_right) delete align_right[key]
            row_count = 0
            column_count = 0
        }
        function add_row(line, row, content, parts, count, column, value) {
            content = line
            sub(/^[[:space:]]*\|/, "", content)
            sub(/\|[[:space:]]*$/, "", content)
            count = split(content, parts, /\|/)
            if (count > column_count) column_count = count
            for (column = 1; column <= count; column++) {
                value = trim(parts[column])
                cells[row, column] = value
                if (length(value) > widths[column]) widths[column] = length(value)
            }
        }
        function flush_table(column, row, marker, left_colon, right_colon, minimum, value) {
            if (row_count == 0) return
            for (column = 1; column <= column_count; column++) {
                marker = cells[2, column]
                left_colon = marker ~ /^:/
                right_colon = marker ~ /:$/
                align_right[column] = right_colon
                minimum = 3 + left_colon + right_colon
                if (widths[column] < minimum) widths[column] = minimum
            }
            for (row = 1; row <= row_count; row++) {
                printf "|"
                for (column = 1; column <= column_count; column++) {
                    value = cells[row, column]
                    if (row == 2) {
                        left_colon = value ~ /^:/
                        right_colon = value ~ /:$/
                        value = (left_colon ? ":" : "") repeat_char("-", widths[column] - left_colon - right_colon) (right_colon ? ":" : "")
                        printf " %s |", value
                    } else if (align_right[column]) {
                        printf " %*s |", widths[column], value
                    } else {
                        printf " %-*s |", widths[column], value
                    }
                }
                printf "\n"
            }
            clear_table()
        }
        {
            if ($0 ~ /^[[:space:]]*\|.*\|[[:space:]]*$/) {
                row_count++
                add_row($0, row_count)
                next
            }
            flush_table()
            print
        }
        END { flush_table() }
    ' "$report" >"$formatted"
    mv "$formatted" "$report"
}

write_comparison() {
    local title=$1
    local input_label=$2
    local input_bytes=$3
    local rows=$4
    local plot_name=$5
    local highlight_row=$6
    local figure_title=$7
    local plot_path="$output_dir/$plot_name"
    local has_plot=false
    local input_mib

    input_mib=$(awk -v bytes="$input_bytes" 'BEGIN { printf "%.2f", bytes / 1048576 }')

    if [[ "$sanity" != true && -n "$gnuplot_bin" ]]; then
        if "$gnuplot_bin" -c "$repo_root/tools/benchmark_plot.gp" \
            "$rows" "$plot_path" "$figure_title ($input_mib MiB input)" \
            "% of $input_label" \
            "$highlight_row" \
            "n = $samples measurements after 1 warmup; throughput basis = input bytes; peak RSS = median; [P] = $threads workers"; then
            has_plot=true
        else
            rm -f -- "$plot_path"
            echo "warning: gnuplot failed; keeping the complete tables without a figure" >&2
        fi
    fi

    {
        echo "## $title"
        echo
        echo "Comparison input: $input_label, $input_mib MiB ($input_bytes bytes)."
        echo
        if [[ "$has_plot" == true ]]; then
            echo "![$title summary]($plot_name)"
            echo
        fi
        echo '### Artifact'
        echo
        echo "| Method | Threads (encode / decode) | Validation | Artifact bytes | Artifact / $input_label |"
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

    measure dump-mzarc-encode "$mzarc" encode "$work/source.bin" -o "$work/archive.mzarc"
    measure dump-mzarc-decode "$mzarc" decode "$work/archive.mzarc" -o "$work/decoded.bin"
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

    measure "$lane-gzip-encode" "$gzip_bin" -6 -n -f -k "$work/source"
    measure "$lane-gzip-decode" "$gzip_bin" -d -f -k "$work/source.gz"
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

    measure "$lane-pigz-$suffix-encode" "$pigz_bin" -6 -p "$workers" -n -f -k "$work/source"
    measure "$lane-pigz-$suffix-decode" "$pigz_bin" -d -p "$workers" -f -k "$work/source.gz"
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

    measure "$lane-zstd-$suffix-encode" "$zstd_bin" -q -3 "$worker_arg" --no-asyncio -f "$source" -o "$work/archive.zst"
    measure "$lane-zstd-$suffix-decode" "$zstd_bin" -q -d --no-asyncio -f "$work/archive.zst" -o "$work/decoded"
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

    measure "$lane-xz-$suffix-encode" "$xz_bin" -q -6 -T "$workers" -f -k "$work/source"
    measure "$lane-xz-$suffix-decode" "$xz_bin" -q -d -T "$workers" -f -k "$work/source.xz"
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

    measure "mzml-mscompress-$suffix-encode" "$mscompress" -t "$workers" "$scratch/source.mzML" "$work/archive.msz"
    measure "mzml-mscompress-$suffix-decode" "$mscompress" -t "$workers" "$work/archive.msz" "$work/decoded.mzML"
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
        echo '<!-- markdownlint-disable MD024 -->'
        echo
        echo '# Compression harness sanity check'
        echo
        echo 'This parser-example run checks command wiring and round trips. Its size, timing, RSS, and rankings are not benchmark evidence.'
    else
        echo '<!-- markdownlint-disable MD024 -->'
        echo
        echo '# Reference compression benchmark'
        echo
        echo 'This report compares lossless compression of one mzML-derived Dump V1 input and the original mzML document. Compare methods only within the same input section because the inputs and validation contracts differ.'
        echo
        echo '## Key findings'
        echo
        awk -F $'\t' -v workers="$threads" '
            $1 == "mzarc lossless" { mzarc_bytes = $4; mzarc_pct = $5; mzarc_encode = $8; mzarc_encode_rss = $9; mzarc_decode = $12; mzarc_decode_rss = $13 }
            $1 == "xz -6 -T1" { xz_bytes = $4 }
            $1 == "zstd -3 --single-thread" { zstd_decode = $12 }
            $1 ~ /^zstd -3 -T[0-9]+ \[P\]$/ { zstd_parallel_encode = $8; zstd_parallel_decode = $12 }
            $1 == "gzip -6" { gzip_encode_rss = $9; gzip_decode_rss = $13 }
            END {
                if (!mzarc_bytes || !xz_bytes || !zstd_decode || !zstd_parallel_encode || !zstd_parallel_decode || !gzip_encode_rss) exit 2
                printf "- mzarc produces a %.2f MiB artifact from the Dump V1 input (%.2f%% of input), %.2f%% smaller than the next-smallest single-threaded byte-exact row, xz `-6 -T1`.\n", mzarc_bytes / 1048576, mzarc_pct, 100 * (xz_bytes - mzarc_bytes) / xz_bytes
                printf "- mzarc is the fastest single-threaded Dump V1 encoder at %.2f MiB/s. The fixed-%d zstd row leads overall encode at %.2f MiB/s. zstd records %.2f MiB/s decode for the single-thread artifact and %.2f MiB/s for the fixed-%d artifact; both decode operations are single-threaded.\n", mzarc_encode, workers, zstd_parallel_encode, zstd_decode, zstd_parallel_decode, workers
                printf "- mzarc peak RSS is %.2f MiB for encode and %.2f MiB for decode on this file. gzip records the lowest values in the Dump V1 table at %.2f MiB and %.2f MiB.\n", mzarc_encode_rss, mzarc_decode_rss, gzip_encode_rss, gzip_decode_rss
            }
        ' "$rows_dump"
        awk -F $'\t' -v workers="$threads" '
            $1 == "xz -6 -T1" { xz_pct = $5 }
            $1 ~ /^zstd -3 -T[0-9]+ \[P\]$/ { zstd_encode = $8; zstd_decode = $12 }
            $1 ~ /^MScompress -t[0-9]+ \[P\]$/ { mscompress_pct = $5 }
            END {
                if (!xz_pct || !zstd_encode || !zstd_decode || !mscompress_pct) exit 2
                printf "- On original mzML, MScompress `-t%d` writes the smallest artifact at %.2f%% but is validated as Dump V1 exact. xz `-6 -T1` is the smallest document-byte-exact row at %.2f%%. The fixed-%d zstd row records %.2f MiB/s encode; its single-threaded decode records %.2f MiB/s.\n", workers, mscompress_pct, xz_pct, workers, zstd_encode, zstd_decode
            }
        ' "$rows_mzml"
    fi
    echo
    echo '## Run context'
    echo
    echo "- Source: \`$source_display\`"
    echo "- Source shape: $spectra spectra; $total_peaks peaks; $ms1_count MS1 and $ms2_count MS2 spectra"
    echo "- Measured: $(date --iso-8601=seconds)"
    echo "- Host: $cpu; $host"
    echo '- mzarc build: stripped ReleaseFast, single-threaded'
    echo "- Sampling: $samples $measurement_word per operation after one warmup"
    echo "- Parallel rows: $threads workers, marked \`[P]\`; direction-specific behavior remains in the tables"
    echo '- Execution: each operation is measured independently; files are reused after untimed validation and one warmup'
    echo '- Throughput: uncompressed input bytes divided by mean wall time'
    echo '- Peak RSS: median zebrac direct-child RSS'
    echo
} >"$output_dir/report.md"
if [[ "$sanity" != true ]]; then
    mzarc_bytes=$(awk -F $'\t' '$1 == "mzarc lossless" { print $4; exit }' "$rows_dump")
    dump_of_mzml=$(awk -v dump="$dump_bytes" -v mzml="$mzml_bytes" 'BEGIN { printf "%.2f", 100 * dump / mzml }')
    mzarc_of_mzml=$(awk -v artifact="$mzarc_bytes" -v mzml="$mzml_bytes" 'BEGIN { printf "%.2f", 100 * artifact / mzml }')
    {
        echo '## Input size context'
        echo
        echo '| Representation | Bytes | MiB | Representation / original mzML |'
        echo '| --- | ---: | ---: | ---: |'
        awk -v bytes="$mzml_bytes" 'BEGIN { printf "| Original mzML | %d | %.2f | 100.00%% |\n", bytes, bytes / 1048576 }'
        awk -v bytes="$dump_bytes" -v pct="$dump_of_mzml" 'BEGIN { printf "| Dump V1 retained fields | %d | %.2f | %s%% |\n", bytes, bytes / 1048576, pct }'
        awk -v bytes="$mzarc_bytes" -v pct="$mzarc_of_mzml" 'BEGIN { printf "| mzarc lossless | %d | %.2f | %s%% |\n", bytes, bytes / 1048576, pct }'
        echo
        echo 'The mzarc percentage against original mzML describes the current mzML-to-Dump-V1-to-mzarc storage path. mzarc reads Dump V1 and does not reproduce the original mzML document.'
        echo
    } >>"$output_dir/report.md"
fi
write_comparison 'Dump V1 round trip' 'Dump V1' "$dump_bytes" "$rows_dump" \
    'dump-summary.svg' 0 "mzML-derived Dump V1 round trip: $source_name"
write_comparison 'Original mzML round trip' 'original mzML' "$mzml_bytes" "$rows_mzml" \
    'mzml-summary.svg' -1 "Original mzML round trip: $source_name"
{
    echo '## Validation boundaries'
    echo
    echo '- mzarc, gzip, pigz, zstd, and xz reproduce their Dump V1 input byte for byte.'
    echo '- gzip, pigz, zstd, and xz reproduce the original mzML document byte for byte.'
    echo '- MScompress reproduces the fields retained by Dump V1 here, not necessarily the original document bytes. Its decoded mzML is converted through the same Dump V1 converter and compared byte for byte with the source dump.'
    echo
    echo '## Limits'
    echo
    echo '- This report covers one file and one acquisition shape. It does not establish performance or RSS behavior across the broader corpus.'
    echo '- mzarc currently starts from Dump V1. The original mzML section therefore has no mzarc row.'
    echo '- The runner does not clear filesystem caches, randomize operation order, isolate CPUs, or control system load and CPU frequency.'
    echo '- Wall time and RSS are measurements from one host, not portable guarantees.'
    echo
    echo '## Tool versions'
    echo
    echo "- mzarc: \`v$mzarc_version\`"
    echo "- Build: Zig \`$zig_version\`; stripped ReleaseFast; single-threaded"
    echo "- Ingest: Python \`$python_version\`; Pyteomics \`$pyteomics_version\`"
    echo "- Measurement: \`$zebrac_version\`"
    echo "- Compression peers: \`$gzip_version\`; \`$pigz_version\`; \`$zstd_version\`; \`$xz_version\`; \`MScompress $mscompress_version\`"
    if [[ -n "$gnuplot_bin" ]]; then
        echo "- Report generation: \`$jq_version\`; \`$gnuplot_version\`"
    else
        echo "- Report generation: \`$jq_version\`; gnuplot not installed, so figures were omitted"
    fi
    echo
    if [[ "$sanity" == true ]]; then
        echo '## Machine-readable rows'
        echo
        echo 'The full-precision Dump V1 rows are retained in [dump.tsv](dump.tsv). They are sanity output, not benchmark evidence.'
    else
        echo '## Machine-readable rows'
        echo
        echo 'The full-precision Dump V1 rows are retained in [dump.tsv](dump.tsv) for direct local comparisons. The reader-facing tables above are rounded.'
        echo
        echo 'Column order: method, thread class, validation, artifact bytes, artifact percentage, encode mean ms, encode SD ms, encode MiB/s, encode RSS MiB, decode mean ms, decode SD ms, decode MiB/s, and decode RSS MiB.'
    fi
} >>"$output_dir/report.md"

align_markdown_tables "$output_dir/report.md"
echo "report: $output_dir/report.md"
