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

Environment:
  MZARC_DATA      Local data root (default: ~/Github/data/mzml).
EOF
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
data_root=${MZARC_DATA:-$HOME/Github/data/mzml}

# Removes a scratch tree this script created without a recursive delete: plain files at most
# three levels deep, then the emptied directories. rmdir refuses anything left unexpected.
remove_scratch() {
    local root=$1 entry
    if [[ -z "$root" || ! -d "$root" ]]; then
        return 0
    fi
    for entry in "$root"/*/*/* "$root"/*/* "$root"/*; do
        if [[ -f "$entry" || -L "$entry" ]]; then
            rm -f -- "$entry"
        fi
    done
    for entry in "$root"/*/*/ "$root"/*/; do
        if [[ -d "$entry" ]]; then
            rmdir -- "$entry"
        fi
    done
    rmdir -- "$root"
}

run_checks() {
    local self="$repo_root/tools/benchmark.sh"
    local tiny="$data_root/examples/tiny.pwiz.1.1.mzML"
    local output report_text rows real_cmp
    benchmark_check_root=$(mktemp -d "${TMPDIR:-/var/tmp}/mzarc-benchmark-check.XXXXXX")
    trap 'remove_scratch "${benchmark_check_root:-}"' EXIT

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

    # The fake cmp gets its own PATH entry; the fake zebrac above must not shadow the real one.
    real_cmp=$(command -v cmp) || fail 'cmp is unavailable'
    mkdir "$benchmark_check_root/fake-cmp"
    cat >"$benchmark_check_root/fake-cmp/cmp" <<EOF
#!/usr/bin/env bash
if [[ \$# -eq 2 && \$1 == */source.bin && \$2 == */dump-gzip/source ]]; then
    echo 'injected byte mismatch' >&2
    exit 1
fi
exec "$real_cmp" "\$@"
EOF
    chmod +x "$benchmark_check_root/fake-cmp/cmp"
    expect_failure 'failed peer validation' 'injected byte mismatch' \
        env PATH="$benchmark_check_root/fake-cmp:$PATH" \
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
        'byte exact' 'Dump V1 exact' '| mzarc exact ' '## Lossy archives' \
        'mzML lossy bounds' 'Dump V1 lossy bounds' '## mzML ingest' 'IQR / median' \
        'Load average'; do
        [[ "$report_text" == *"$expected"* ]] || \
            fail "report is missing: $expected"
    done
    shopt -s nullglob
    local json_files=("$benchmark_check_root/success/zebrac/"*.json)
    shopt -u nullglob
    ((${#json_files[@]} == 41)) || fail 'sanity run did not retain 41 zebrac results'
    rows=$(wc -l <"$benchmark_check_root/success/dump.tsv")
    ((rows == 8)) || fail 'sanity run did not retain eight Dump V1 rows'
    rows=$(wc -l <"$benchmark_check_root/success/mzml.tsv")
    ((rows == 10)) || fail 'sanity run did not retain ten original mzML rows'
    rows=$(wc -l <"$benchmark_check_root/success/lossy.tsv")
    ((rows == 2)) || fail 'sanity run did not retain two lossy rows'
    rows=$(wc -l <"$benchmark_check_root/success/lossy-errors.tsv")
    ((rows == 2)) || fail 'sanity run did not retain two lossy error rows'
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
if [[ "$input" == "$(realpath -m "$data_root")/examples/"* && "$sanity" != true ]]; then
    echo 'error: parser examples are sanity inputs, not benchmark inputs' >&2
    echo 'rerun with --sanity to check harness wiring' >&2
    exit 1
fi
source_display=$input
data_root_real=$(realpath -m "$data_root")
if [[ "$input" == "$repo_root/"* ]]; then
    source_display=${input#"$repo_root/"}
elif [[ "$input" == "$data_root_real/"* ]]; then
    source_display="<data root>/${input#"$data_root_real/"}"
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

zig=$(command -v zig || true)
readonly zig
readonly mzarc="$repo_root/zig-out/bin/mzarc"
zebrac=$(command -v zebrac || true)
mscompress="$repo_root/tools/bin/mscompress-msz"
if [[ ${MZARC_BENCH_CHECKING:-} == true ]]; then
    zebrac="${MZARC_BENCH_ZEBRAC:-$zebrac}"
    mscompress="${MZARC_BENCH_MSCOMPRESS:-$mscompress}"
fi
readonly zebrac mscompress

for path in "$zig" "$zebrac" "$mscompress"; do
    if [[ -z "$path" || ! -x "$path" ]]; then
        echo "error: required executable not found: ${path:-zig or zebrac on PATH}" >&2
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
mzarc_commit=$(git -C "$repo_root" rev-parse --short HEAD)
if [[ -n $(git -C "$repo_root" status --porcelain --untracked-files=no) ]]; then
    mzarc_commit+=" (dirty)"
fi
if [[ "$zig_version" != 0.16.0 ]]; then
    echo "error: Zig 0.16.0 is required; $zig reports $zig_version" >&2
    exit 1
fi
# The build fetches zmz by URL and hash, so the pinned package hash names the exact zmz source.
zmz_version=$(awk -F'"' '/^[[:space:]]*\.hash = "zmz-/ { sub(/^zmz-/, "", $2); split($2, part, "-"); print part[1]; exit }' "$repo_root/build.zig.zon")
if [[ ! "$zmz_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: could not read the pinned zmz version from build.zig.zon" >&2
    exit 1
fi
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
readonly mzarc_version changelog_version zig_version zmz_version mzarc_commit
readonly zebrac_version zebrac_json_version gzip_version pigz_version zstd_version
readonly xz_version mscompress_version jq_version gnuplot_version measurement_word

cpu_governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)
load_start=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo unknown)
readonly cpu_governor load_start

scratch=$(mktemp -d "${TMPDIR:-/var/tmp}/mzarc-benchmark.XXXXXX")
trap 'remove_scratch "$scratch"' EXIT

mkdir -p "$output_dir/zebrac"
cp "$input" "$scratch/source.mzML"

echo "building stripped ReleaseFast mzarc"
cd "$repo_root"
"$zig" build --release=fast \
    --cache-dir "$repo_root/.zig-cache" \
    --summary all

echo "creating one Dump V1 input"
"$mzarc" dump "$scratch/source.mzML" -o "$scratch/source.bin"
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
readonly rows_mzml="$output_dir/mzml.tsv"
readonly rows_lossy="$output_dir/lossy.tsv"
readonly lossy_errors="$output_dir/lossy-errors.tsv"
readonly rows_ingest="$output_dir/ingest.tsv"
: >"$rows_dump"
: >"$rows_mzml"
: >"$rows_lossy"
: >"$lossy_errors"
: >"$rows_ingest"

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
         (.results[0].wall_time.median | type == "number") and
         (.results[0].wall_time.q1 | type == "number") and
         (.results[0].wall_time.q3 | type == "number") and
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
          ($encode.wall_time.median / 1000000),
          (($encode.wall_time.q3 - $encode.wall_time.q1) / 1000000),
          ($input_bytes * 1000000000 / $encode.wall_time.median / 1048576),
          ($encode.peak_rss.median / 1048576),
          ($decode.wall_time.median / 1000000),
          (($decode.wall_time.q3 - $decode.wall_time.q1) / 1000000),
          ($input_bytes * 1000000000 / $decode.wall_time.median / 1048576),
          ($decode.peak_rss.median / 1048576),
          ($encode.wall_time.mean / 1000000),
          ($encode.wall_time.std_dev / 1000000),
          ($decode.wall_time.mean / 1000000),
          ($decode.wall_time.std_dev / 1000000),
          ($encode.instructions.median // ""),
          ($decode.instructions.median // ""),
          $input_bytes
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

# Prints one timing table (encode or decode) from rows; spread is the IQR as a share of the median.
write_timing_table() {
    local rows=$1
    local direction=$2
    local method thread_class validation artifact_bytes percent
    local encode_median encode_iqr encode_rate encode_rss decode_median decode_iqr decode_rate decode_rss rest
    local median iqr rate rss

    echo '| Method | Median (ms) | IQR (ms) | IQR / median | MiB/s | Peak RSS (MiB) |'
    echo '| --- | ---: | ---: | ---: | ---: | ---: |'
    while IFS=$'\t' read -r method thread_class validation artifact_bytes percent \
        encode_median encode_iqr encode_rate encode_rss decode_median decode_iqr decode_rate decode_rss rest; do
        if [[ "$direction" == encode ]]; then
            median=$encode_median iqr=$encode_iqr rate=$encode_rate rss=$encode_rss
        else
            median=$decode_median iqr=$decode_iqr rate=$decode_rate rss=$decode_rss
        fi
        awk -v method="$method" -v median="$median" -v iqr="$iqr" -v rate="$rate" -v rss="$rss" \
            'BEGIN { printf "| %s | %.3f | %.3f | %.1f%% | %.2f | %.2f |\n", method, median, iqr, 100 * iqr / median, rate, rss }'
    done <"$rows"
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
    local method thread_class validation artifact_bytes percent rest

    if [[ -n "$input_bytes" ]]; then
        input_mib=$(awk -v bytes="$input_bytes" 'BEGIN { printf "%.2f", bytes / 1048576 }')
    fi

    if [[ "$sanity" != true && -n "$gnuplot_bin" && -n "$plot_name" ]]; then
        if "$gnuplot_bin" -c "$repo_root/tools/benchmark_plot.gp" \
            "$rows" "$plot_path" "$figure_title ($input_mib MiB input)" \
            "% of $input_label" \
            "$highlight_row" \
            "n = $samples measurements after 1 warmup; throughput basis = input bytes / median time; peak RSS = median; [P] = $threads workers"; then
            has_plot=true
        else
            rm -f -- "$plot_path"
            echo "warning: gnuplot failed; keeping the complete tables without a figure" >&2
        fi
    fi

    {
        echo "## $title"
        echo
        if [[ -n "$input_bytes" ]]; then
            echo "Comparison input: $input_label, $input_mib MiB ($input_bytes bytes)."
            echo
        fi
        if [[ "$has_plot" == true ]]; then
            echo "![$title summary]($plot_name)"
            echo
        fi
        echo '### Artifact'
        echo
        echo "| Method | Threads (encode / decode) | Validation | Artifact bytes | Artifact / $input_label |"
        echo '| --- | --- | --- | ---: | ---: |'
        while IFS=$'\t' read -r method thread_class validation artifact_bytes percent rest; do
            printf '| %s | %s | %s | %s | %.2f%% |\n' \
                "$method" "$thread_class" "$validation" "$artifact_bytes" "$percent"
        done <"$rows"
        echo
        echo '### Encode'
        echo
        write_timing_table "$rows" encode
        echo
        echo '### Decode'
        echo
        write_timing_table "$rows" decode
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

run_mzarc_mzml() {
    local work="$scratch/mzml-mzarc"
    mkdir -p "$work"

    "$mzarc" encode "$scratch/source.mzML" -o "$work/archive.mzarc" >/dev/null
    "$mzarc" decode "$work/archive.mzarc" -o "$work/decoded.mzML" >/dev/null
    cmp "$scratch/source.mzML" "$work/decoded.mzML"

    measure mzml-mzarc-encode "$mzarc" encode "$scratch/source.mzML" -o "$work/archive.mzarc"
    measure mzml-mzarc-decode "$mzarc" decode "$work/archive.mzarc" -o "$work/decoded.mzML"
    cmp "$scratch/source.mzML" "$work/decoded.mzML"
    record_row "$rows_mzml" 'mzarc exact' 'single / single' 'byte exact' \
        "$mzml_bytes" "$work/archive.mzarc" \
        "$output_dir/zebrac/mzml-mzarc-encode.json" \
        "$output_dir/zebrac/mzml-mzarc-decode.json"
}

# Validates a lossy round trip and keeps the largest m/z and log1p intensity errors it observed.
validate_lossy() {
    local method=$1
    local mode=$2
    local source=$3
    local decoded=$4
    local arrays=$5
    local output

    output=$("$mzarc" validate "$source" "$decoded" "--mode=$mode")
    awk -v method="$method" -v arrays="$arrays" '
        $2 == "mz_max_observed_error" { mz = $3 }
        $2 == "intensity_log1p_max_error" { log_error = $3; limit = $5 }
        END {
            if (mz == "" || log_error == "") exit 2
            printf "%s\t%s\t%s\t%s\t%s\n", method, mz, log_error, limit, arrays
        }
    ' <<<"$output" >>"$lossy_errors"
}

run_mzarc_lossy_dump() {
    local method='mzarc lossy (Dump V1 input)'
    local work="$scratch/lossy-dump-mzarc"
    mkdir -p "$work"

    "$mzarc" encode "$scratch/source.bin" -o "$work/archive.mzarc" --lossy
    "$mzarc" decode "$work/archive.mzarc" -o "$work/decoded.bin"
    "$mzarc" validate "$scratch/source.bin" "$work/decoded.bin" --mode=lossy >/dev/null

    measure lossy-dump-mzarc-encode "$mzarc" encode "$scratch/source.bin" -o "$work/archive.mzarc" --lossy
    measure lossy-dump-mzarc-decode "$mzarc" decode "$work/archive.mzarc" -o "$work/decoded.bin"
    validate_lossy "$method" lossy "$scratch/source.bin" "$work/decoded.bin" 'every array'
    record_row "$rows_lossy" "$method" 'single / single' 'Dump V1 lossy bounds' \
        "$dump_bytes" "$work/archive.mzarc" \
        "$output_dir/zebrac/lossy-dump-mzarc-encode.json" \
        "$output_dir/zebrac/lossy-dump-mzarc-decode.json"
}

run_mzarc_lossy_mzml() {
    local method='mzarc lossy (mzML input)'
    local work="$scratch/lossy-mzml-mzarc"
    mkdir -p "$work"

    local summary arrays
    summary=$("$mzarc" encode "$scratch/source.mzML" -o "$work/archive.mzarc" --lossy)
    arrays=$(awk -F': ' '
        $1 == "arrays coded" { coded = $2 }
        $1 == "arrays kept exact" { kept = $2 }
        END { if (coded == "" || kept == "") exit 2; printf "%d of %d", coded, coded + kept }
    ' <<<"$summary")
    "$mzarc" decode "$work/archive.mzarc" -o "$work/decoded.mzML" >/dev/null
    "$mzarc" dump "$work/decoded.mzML" -o "$work/decoded.bin" >/dev/null
    "$mzarc" validate "$scratch/source.bin" "$work/decoded.bin" --mode=mzml-lossy >/dev/null

    measure lossy-mzml-mzarc-encode "$mzarc" encode "$scratch/source.mzML" -o "$work/archive.mzarc" --lossy
    measure lossy-mzml-mzarc-decode "$mzarc" decode "$work/archive.mzarc" -o "$work/decoded.mzML"
    "$mzarc" dump "$work/decoded.mzML" -o "$work/decoded.bin" >/dev/null
    validate_lossy "$method" mzml-lossy "$scratch/source.bin" "$work/decoded.bin" "$arrays"
    record_row "$rows_lossy" "$method" 'single / single' 'mzML lossy bounds' \
        "$mzml_bytes" "$work/archive.mzarc" \
        "$output_dir/zebrac/lossy-mzml-mzarc-encode.json" \
        "$output_dir/zebrac/lossy-mzml-mzarc-decode.json"
}

# Measures mzML to Dump V1 ingest; its output must equal the dump every other row starts from.
run_mzarc_ingest() {
    local work="$scratch/ingest"
    mkdir -p "$work"

    measure mzml-mzarc-dump "$mzarc" dump "$scratch/source.mzML" -o "$work/source.bin"
    cmp "$scratch/source.bin" "$work/source.bin"
    "$jq_bin" -r --argjson input_bytes "$mzml_bytes" --argjson output_bytes "$dump_bytes" '
        .results[0] as $dump |
        [
          "mzarc dump",
          $output_bytes,
          ($dump.wall_time.median / 1000000),
          (($dump.wall_time.q3 - $dump.wall_time.q1) / 1000000),
          ($input_bytes * 1000000000 / $dump.wall_time.median / 1048576),
          ($dump.peak_rss.median / 1048576),
          ($dump.instructions.median // "")
        ] | @tsv' "$output_dir/zebrac/mzml-mzarc-dump.json" >"$rows_ingest"
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
    "$mzarc" dump "$work/decoded.mzML" -o "$work/decoded.bin" >/dev/null
    cmp "$scratch/source.bin" "$work/decoded.bin"

    measure "mzml-mscompress-$suffix-encode" "$mscompress" -t "$workers" "$scratch/source.mzML" "$work/archive.msz"
    measure "mzml-mscompress-$suffix-decode" "$mscompress" -t "$workers" "$work/archive.msz" "$work/decoded.mzML"
    "$mzarc" dump "$work/decoded.mzML" -o "$work/decoded.bin" >/dev/null
    cmp "$scratch/source.bin" "$work/decoded.bin"
    record_row "$rows_mzml" "$label" "$suffix / $suffix" 'Dump V1 exact' \
        "$mzml_bytes" "$work/archive.msz" \
        "$output_dir/zebrac/mzml-mscompress-$suffix-encode.json" \
        "$output_dir/zebrac/mzml-mscompress-$suffix-decode.json"
}

echo "measuring mzML to Dump V1 ingest"
run_mzarc_ingest

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
run_mzarc_mzml
run_gzip mzml "$scratch/source.mzML" "$mzml_bytes" "$rows_mzml"
run_pigz mzml "$scratch/source.mzML" "$mzml_bytes" "$rows_mzml" 1 single 'pigz -6 -p1'
run_pigz mzml "$scratch/source.mzML" "$mzml_bytes" "$rows_mzml" "$threads" "fixed-$threads" "pigz -6 -p$threads [P]"
run_zstd mzml "$scratch/source.mzML" "$mzml_bytes" "$rows_mzml" --single-thread single 'zstd -3 --single-thread' 'single / single'
run_zstd mzml "$scratch/source.mzML" "$mzml_bytes" "$rows_mzml" "-T$threads" "fixed-$threads" "zstd -3 -T$threads [P]" "fixed-$threads / single"
run_xz mzml "$scratch/source.mzML" "$mzml_bytes" "$rows_mzml" 1 single 'xz -6 -T1'
run_xz mzml "$scratch/source.mzML" "$mzml_bytes" "$rows_mzml" "$threads" "fixed-$threads" "xz -6 -T$threads [P]"
run_mscompress 1 single 'MScompress -t1'
run_mscompress "$threads" "fixed-$threads" "MScompress -t$threads [P]"

echo "testing and measuring the lossy profiles"
run_mzarc_lossy_dump
run_mzarc_lossy_mzml
load_end=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo unknown)
readonly load_end

# Findings are computed from the rows, so the wording follows whatever this run measured.
# Columns: 1 method, 2 threads, 4 bytes, 5 percent, 8 encode MiB/s, 9 encode RSS, 12 decode MiB/s, 13 decode RSS.
findings_awk='
    function mib(bytes) { return bytes / 1048576 }
    function versus(own, other) {
        if (own <= other) return sprintf("%.2f%% smaller than", 100 * (other - own) / other)
        return sprintf("%.2f%% larger than", 100 * (own - other) / other)
    }
    function rank(column, own, row, count) {
        count = 1
        for (row = 1; row <= rows; row++) if (value[row, column] > own) count++
        return count
    }
    {
        rows++
        name[rows] = $1; threads[rows] = $2; validation[rows] = $3
        for (column = 4; column <= 13; column++) value[rows, column] = $column
        if ($1 == target) own = rows
    }
    function best(column, lowest, single_only, exact_only, row, found) {
        found = 0
        for (row = 1; row <= rows; row++) {
            if (row == own) continue
            if (single_only && threads[row] != "single / single") continue
            if (exact_only && validation[row] != "byte exact") continue
            if (!found || (lowest ? value[row, column] < value[found, column] : value[row, column] > value[found, column])) found = row
        }
        return found
    }
    END {
        if (!own) exit 2
        small = best(4, 1, 0, 1); fast_single = best(8, 0, 1, 0); fast_encode = best(8, 0, 0, 0); fast_decode = best(12, 0, 0, 0)
        low_encode = best(9, 1, 0, 0); low_decode = best(13, 1, 0, 0)
        if (!small || !fast_single || !fast_encode || !fast_decode) exit 2
        printf "- **%s:** `%s` writes %.2f MiB (%.2f%% of the input), %s the smallest byte-exact peer, `%s` (%.2f MiB).", label, target, mib(value[own, 4]), value[own, 5], versus(value[own, 4], value[small, 4]), name[small], mib(value[small, 4])
        other = best(4, 1, 0, 0)
        if (other && other != small && value[other, 4] < value[own, 4]) printf " `%s` writes %.2f MiB but is validated as %s.", name[other], mib(value[other, 4]), validation[other]
        printf "\n"
        printf "  Encode: %.2f MiB/s, rank %d of %d rows; the fastest single-threaded peer is `%s` at %.2f MiB/s", value[own, 8], rank(8, value[own, 8]), rows, name[fast_single], value[fast_single, 8]
        if (fast_encode != fast_single) printf " and the fastest peer overall is `%s` at %.2f MiB/s", name[fast_encode], value[fast_encode, 8]
        printf "."
        printf " Decode: %.2f MiB/s, rank %d of %d; the fastest is `%s` at %.2f MiB/s.", value[own, 12], rank(12, value[own, 12]), rows, name[fast_decode], value[fast_decode, 12]
        printf " Peak RSS: %.2f MiB encode and %.2f MiB decode; the lowest peers are `%s` (%.2f MiB) and `%s` (%.2f MiB).\n", value[own, 9], value[own, 13], name[low_encode], value[low_encode, 9], name[low_decode], value[low_decode, 13]
    }
'

{
    echo '<!-- markdownlint-disable MD024 -->'
    echo
    if [[ "$sanity" == true ]]; then
        echo '# Compression harness sanity check'
        echo
        echo 'This parser-example run checks command wiring and round trips. Its size, timing, RSS, and rankings are not benchmark evidence.'
    else
        echo '# Reference compression benchmark'
        echo
        echo 'This report measures one mzML file three ways: lossless compression of its Dump V1 spectra, lossless compression of the original document, and the mzarc lossy profiles. Compare methods only within one section, because the inputs and validation contracts differ.'
        echo
        echo '## Key findings'
        echo
        awk -F $'\t' -v target='mzarc lossless' -v label='Dump V1' "$findings_awk" "$rows_dump"
        awk -F $'\t' -v target='mzarc exact' -v label='Original mzML' "$findings_awk" "$rows_mzml"
        awk -F $'\t' -v exact_bytes="$(awk -F $'\t' '$1 == "mzarc exact" { print $4 }' "$rows_mzml")" \
            -v lossless_bytes="$(awk -F $'\t' '$1 == "mzarc lossless" { print $4 }' "$rows_dump")" '
            FNR == NR { mz_error[$1] = $2; log_error[$1] = $3; limit[$1] = $4; next }
            $1 ~ /Dump V1/ { dump_pct = $5; dump_bytes = $4; dump_name = $1 }
            $1 ~ /mzML/ { mzml_pct = $5; mzml_bytes = $4; mzml_name = $1 }
            function versus(own, other) {
                if (own <= other) return sprintf("%.2f%% smaller than", 100 * (other - own) / other)
                return sprintf("%.2f%% larger than", 100 * (own - other) / other)
            }
            END {
                if (!dump_bytes || !mzml_bytes || !exact_bytes || !lossless_bytes) exit 2
                printf "- **Lossy:** the mzML lossy archive is %.2f%% of the original document, %s the exact archive; the Dump V1 lossy archive is %.2f%% of its input, %s the lossless archive. Largest observed errors: m/z %s Da and log1p intensity %s (mzML), m/z %s Da and log1p intensity %s (Dump V1), against a format-wide log1p limit of %s.\n", mzml_pct, versus(mzml_bytes, exact_bytes), dump_pct, versus(dump_bytes, lossless_bytes), mz_error[mzml_name], log_error[mzml_name], mz_error[dump_name], log_error[dump_name], limit[mzml_name]
            }
        ' "$lossy_errors" "$rows_lossy"
    fi
    echo
    echo '## Run context'
    echo
    echo "- Source: \`$source_display\`"
    echo "- Source shape: $spectra spectra; $total_peaks peaks; $ms1_count MS1 and $ms2_count MS2 spectra"
    echo "- Measured: $(date --iso-8601=seconds)"
    echo "- Host: $cpu; $host"
    echo "- CPU frequency governor: $cpu_governor"
    echo "- Load average (1, 5, 15 min): $load_start before the build, $load_end after the last measurement"
    echo '- mzarc build: stripped ReleaseFast, single-threaded'
    echo "- Sampling: $samples $measurement_word per operation after one warmup"
    echo "- Parallel rows: $threads workers, marked \`[P]\`; direction-specific behavior remains in the tables"
    echo '- Execution: each operation is measured independently; files are reused after untimed validation and one warmup'
    echo '- Timing: median wall time with its interquartile range (IQR); throughput is uncompressed input bytes divided by the median'
    echo '- Peak RSS: median zebrac direct-child RSS'
    awk -F $'\t' -v threshold=5 '
        {
            for (direction = 0; direction < 2; direction++) {
                median = $(6 + 4 * direction); iqr = $(7 + 4 * direction); total++
                if (median <= 0 || 100 * iqr / median <= threshold) continue
                noisy++; spread[noisy] = 100 * iqr / median
                label[noisy] = sprintf("`%s` %s", $1, direction ? "decode" : "encode")
            }
        }
        END {
            if (!noisy) { printf "- Spread: every one of the %d operations has an IQR at or below %d%% of its median\n", total, threshold; exit }
            for (shown = 1; shown <= 3 && shown <= noisy; shown++) {
                worst = 0
                for (row = 1; row <= noisy; row++) if (!(row in used) && (!worst || spread[row] > spread[worst])) worst = row
                used[worst] = 1; list = list (shown > 1 ? ", " : "") sprintf("%s %.1f%%", label[worst], spread[worst])
            }
            printf "- Spread: %d of %d operations have an IQR above %d%% of their median (largest: %s); compare those timings only after a repeat run\n", noisy, total, threshold, list
        }
    ' "$rows_dump" "$rows_mzml" "$rows_lossy"
    echo
} >"$output_dir/report.md"

{
    echo '## Input size context'
    echo
    echo '| Representation | Bytes | MiB | Representation / original mzML |'
    echo '| --- | ---: | ---: | ---: |'
    awk -F $'\t' -v mzml="$mzml_bytes" -v dump="$dump_bytes" '
        function row(label, bytes) { printf "| %s | %d | %.2f | %.2f%% |\n", label, bytes, bytes / 1048576, 100 * bytes / mzml }
        FILENAME ~ /dump.tsv$/ && $1 == "mzarc lossless" { lossless = $4 }
        FILENAME ~ /mzml.tsv$/ && $1 == "mzarc exact" { exact = $4 }
        FILENAME ~ /lossy.tsv$/ && $1 ~ /mzML/ { lossy_mzml = $4 }
        FILENAME ~ /lossy.tsv$/ && $1 ~ /Dump V1/ { lossy_dump = $4 }
        END {
            row("Original mzML", mzml)
            row("mzarc exact archive of the document", exact)
            row("mzarc lossy archive of the document", lossy_mzml)
            row("Dump V1 retained fields", dump)
            row("mzarc lossless archive of Dump V1", lossless)
            row("mzarc lossy archive of Dump V1", lossy_dump)
        }
    ' "$rows_dump" "$rows_mzml" "$rows_lossy"
    echo
    echo 'The document archives restore the whole mzML file: exactly, or with only spectrum m/z and intensity values changed within their bounds. The Dump V1 archives restore only the spectrum fields Dump V1 keeps.'
    echo
    echo '## mzML ingest'
    echo
    echo 'Converting the original mzML to Dump V1 with `mzarc dump`. Its output is checked byte for byte against the dump every Dump V1 row starts from.'
    echo
    echo '| Step | Output bytes | Median (ms) | IQR (ms) | mzML MiB/s | Peak RSS (MiB) |'
    echo '| --- | ---: | ---: | ---: | ---: | ---: |'
    awk -F $'\t' '{ printf "| `%s` | %d | %.3f | %.3f | %.2f | %.2f |\n", $1, $2, $3, $4, $5, $6 }' "$rows_ingest"
    echo
} >>"$output_dir/report.md"

write_comparison 'Dump V1 round trip' 'Dump V1' "$dump_bytes" "$rows_dump" \
    'dump-summary.svg' 0 "mzML-derived Dump V1 round trip: $source_name"
write_comparison 'Original mzML round trip' 'original mzML' "$mzml_bytes" "$rows_mzml" \
    'mzml-summary.svg' 0 "Original mzML round trip: $source_name"
write_comparison 'Lossy archives' 'its input' '' "$rows_lossy" '' '' ''
{
    echo 'Observed errors, from `mzarc validate` after the timed runs:'
    echo
    echo '| Method | Arrays transformed | Max m/z error (Da) | Max log1p intensity error | Format-wide log1p limit |'
    echo '| --- | ---: | ---: | ---: | ---: |'
    awk -F $'\t' '{ printf "| %s | %s | %s | %s | %s |\n", $1, $5, $2, $3, $4 }' "$lossy_errors"
    echo
    echo 'The mzML profile keeps an array exact when the profile cannot hold it: 32-bit m/z, unsupported compression, negative or non-finite intensity. A transformed f64 m/z array whose values are all f32 decodes to its source values exactly. Errors are measured over the values that changed.'
    echo
    echo '## Validation boundaries'
    echo
    echo '- mzarc lossless, gzip, pigz, zstd, and xz reproduce their Dump V1 input byte for byte.'
    echo '- mzarc exact, gzip, pigz, zstd, and xz reproduce the original mzML document byte for byte.'
    echo '- MScompress reproduces the fields retained by Dump V1 here, not necessarily the original document bytes. Its decoded mzML is converted through the same Dump V1 converter and compared byte for byte with the source dump.'
    echo '- mzarc lossy (Dump V1 input) passes `mzarc validate --mode=lossy`: metadata exact, every m/z equal to its quantized value, and intensity within the format-wide log1p limit.'
    echo '- mzarc lossy (mzML input) passes `mzarc validate --mode=mzml-lossy` on the Dump V1 of its decoded document: every peak is unchanged or carries the same transform within the same limit. The archive format restores every other document byte; the test suite checks that.'
    echo
    echo '## Limits'
    echo
    echo '- This report covers one file and one acquisition shape. It does not establish performance or RSS behavior across the broader corpus.'
    echo '- Lossy rows are not comparable with the lossless and exact rows; they trade bounded spectrum error for size.'
    echo '- The runner does not clear filesystem caches, randomize operation order, isolate CPUs, or control system load and CPU frequency. The load average and spread lines above show how quiet the run was.'
    echo '- Wall time and RSS are measurements from one host, not portable guarantees.'
    echo
    echo '## Tool versions'
    echo
    echo "- mzarc: \`v$mzarc_version\` at \`$mzarc_commit\`"
    echo "- Build: Zig \`$zig_version\`; stripped ReleaseFast; single-threaded"
    echo "- Ingest and mzML reading: \`mzarc dump\` on zmz \`$zmz_version\`"
    echo "- Measurement: \`$zebrac_version\`"
    echo "- Compression peers: \`$gzip_version\`; \`$pigz_version\`; \`$zstd_version\`; \`$xz_version\`; \`MScompress $mscompress_version\`"
    if [[ -n "$gnuplot_bin" ]]; then
        echo "- Report generation: \`$jq_version\`; \`$gnuplot_version\`"
    else
        echo "- Report generation: \`$jq_version\`; gnuplot not installed, so figures were omitted"
    fi
    echo
    echo '## Machine-readable rows'
    echo
    if [[ "$sanity" == true ]]; then
        echo 'The full-precision rows are retained beside this report. They are sanity output, not benchmark evidence.'
    else
        echo 'The full-precision rows are retained beside this report for direct local comparisons; the tables above are rounded. The zebrac results behind them stay in the run directory'"'"'s `zebrac/` folder.'
    fi
    echo
    echo '- [dump.tsv](dump.tsv), [mzml.tsv](mzml.tsv), and [lossy.tsv](lossy.tsv): method, thread class, validation, artifact bytes, artifact percentage of input, encode median ms, encode IQR ms, encode MiB/s, encode RSS MiB, decode median ms, decode IQR ms, decode MiB/s, decode RSS MiB, encode mean ms, encode SD ms, decode mean ms, decode SD ms, encode median instructions, decode median instructions, and input bytes.'
    echo '- [lossy-errors.tsv](lossy-errors.tsv): method, max m/z error in Da, max log1p intensity error, the format-wide log1p limit, and the arrays transformed.'
    echo '- [ingest.tsv](ingest.tsv): step, output bytes, median ms, IQR ms, mzML MiB/s, peak RSS MiB, and median instructions.'
} >>"$output_dir/report.md"

align_markdown_tables "$output_dir/report.md"
echo "report: $output_dir/report.md"
