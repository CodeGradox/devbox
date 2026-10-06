#!/bin/sh
# Opt-in synthetic benchmark. Everything, including HOME, stays under .build.
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build
dir=$(mktemp -d "$PWD/.build/benchmark-refresh.XXXXXX")
cleanup() {
    rm -rf "$dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$dir/module-cache" "$dir/home" "$dir/fixture"
swiftc -O -swift-version 6 -module-cache-path "$dir/module-cache" \
    Sources/DevBoxCore/GitService.swift Sources/DevBoxCore/FTSDiskScanner.swift \
    Sources/DevBoxCore/BlockingIOExecutor.swift \
    Benchmarks/WorktreeRefreshBenchmark.swift -o "$dir/benchmark"
HOME="$dir/home" XDG_CONFIG_HOME="$dir/home" "$dir/benchmark" \
    "$dir/fixture" "${BENCH_WORKTREES:-12}" "${BENCH_STATUS_FILES:-2000}" "${BENCH_RUNS:-5}"
