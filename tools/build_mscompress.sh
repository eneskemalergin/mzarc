#!/usr/bin/env bash

set -euo pipefail

readonly VERSION="1.0.16"
readonly COMMIT="0886057b4bf73ccc2a02d54dd1b6e5e22d1076f5"
readonly REPOSITORY="https://github.com/chrisagrams/mscompress.git"

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_dir="$repo_root/tmp/tools/mscompress-$VERSION/source"
build_dir="$repo_root/tmp/tools/mscompress-$VERSION/build"
output="$repo_root/tools/bin/mscompress-msz"

for command in git cmake; do
    if ! command -v "$command" >/dev/null; then
        echo "error: required command not found: $command" >&2
        exit 1
    fi
done

if [[ ! -d "$source_dir/.git" ]]; then
    mkdir -p "$(dirname "$source_dir")"
    git clone --recurse-submodules --depth 1 --branch "v$VERSION" \
        "$REPOSITORY" "$source_dir"
fi

actual_commit=$(git -C "$source_dir" rev-parse HEAD)
if [[ "$actual_commit" != "$COMMIT" ]]; then
    echo "error: expected MScompress $COMMIT, found $actual_commit" >&2
    exit 1
fi

git -C "$source_dir" submodule update --init --recursive
cmake -S "$source_dir/cli" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_DEBUG_SYMBOLS=OFF
cmake --build "$build_dir" --parallel
ctest --test-dir "$build_dir" --output-on-failure

mkdir -p "$(dirname "$output")"
install -m 0755 "$build_dir/mscompress" "$output"
if command -v strip >/dev/null; then
    strip "$output"
fi

"$output" --json --version
echo "installed: $output"
