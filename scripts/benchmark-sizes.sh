#!/bin/sh
# Opt-in synthetic benchmark; never inspects user repositories or databases.
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build
dir=$(mktemp -d "$PWD/.build/benchmark-sizes.XXXXXX")
cleanup() {
    rm -rf "$dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Keep the executable, compiler cache, Git templates, and fixture in our own directory.
mkdir -p "$dir/module-cache" "$dir/templates"
swiftc -O -swift-version 6 -module-cache-path "$dir/module-cache" \
    Sources/DevBoxCore/GitService.swift Sources/DevBoxCore/FTSDiskScanner.swift \
    Sources/DevBoxCore/BlockingIOExecutor.swift \
    Benchmarks/DirectorySizeBenchmark.swift -o "$dir/benchmark"
mkdir "$dir/repository"
git -c init.templateDir="$dir/templates" init --quiet "$dir/repository"
"$dir/benchmark" "$dir/repository" "${BENCH_FILES:-50000}" "${BENCH_RUNS:-5}"
