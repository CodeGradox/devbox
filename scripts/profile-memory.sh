#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

# A separate optimized executable, not the installed app. No saved settings,
# credentials, real repository scans, or application sources are modified.
output="$PWD/build/memory-profile"
mkdir -p "$output/module-cache"
{
    date -u
    sw_vers
    swift --version
    git rev-parse HEAD
} > "$output/environment.txt" 2>&1
# HEAD alone cannot identify a benchmark of uncommitted changes.
shasum -a 256 Sources/DevBox/*.swift Sources/DevBoxCore/*.swift \
    Benchmarks/MemoryProfile.swift Benchmarks/SwiftUIBranchTargetPicker.swift \
    scripts/profile-memory.sh > "$output/sources.sha256"
swiftc -O -swift-version 6 -module-cache-path "$output/module-cache" \
    -emit-library -emit-module -module-name DevBoxCore Sources/DevBoxCore/*.swift \
    -emit-module-path "$output/DevBoxCore.swiftmodule" -o "$output/libDevBoxCore.dylib"
set --
for source in Sources/DevBox/*.swift; do
    case "$source" in
        */DevBoxApp.swift|*/BranchTargetPopUpButton.swift) ;;
        *) set -- "$@" "$source" ;;
    esac
done
pickers="${PROFILE_PICKERS:-swiftui native}"
for picker in $pickers; do
    case "$picker" in
        swiftui) source="Benchmarks/SwiftUIBranchTargetPicker.swift" ;;
        native) source="Sources/DevBox/BranchTargetPopUpButton.swift" ;;
        *) printf 'Unknown picker: %s\n' "$picker" >&2; exit 1 ;;
    esac
    swiftc -O -swift-version 6 -module-cache-path "$output/module-cache" \
        -parse-as-library -module-name DevBoxMemoryProfile \
        -I "$output" -L "$output" -lDevBoxCore -Xlinker -rpath -Xlinker @executable_path \
        "$@" "$source" Benchmarks/MemoryProfile.swift -o "$output/DevBoxMemoryProfile-$picker"
done

# Each case uses a fresh process; implementations differ only in the picker.
# Keep the windows unobscured and do not interact with them during collection.
# The final case intentionally opens the menu to check deferred allocation cost.
python3 - "$output" $pickers <<'PY'
import datetime
import json
import pathlib
import re
import shutil
import subprocess
import sys
import time

output = pathlib.Path(sys.argv[1])
pickers = sys.argv[2:]
reports = output / "runs" / datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
reports.mkdir(parents=True)
shutil.copyfile(output / "environment.txt", reports / "environment.txt")
shutil.copyfile(output / "sources.sha256", reports / "sources.sha256")
cases = [
    ("model-0-38", 0, 38, "model"),
    ("model-672-38", 672, 38, "model"),
    ("detail-0-38", 0, 38, "detail"),
    ("detail-168-38", 168, 38, "detail"),
    ("detail-672-38", 672, 38, "detail"),
    ("detail-0-38-repeat", 0, 38, "detail"),
    ("detail-672-38-repeat", 672, 38, "detail"),
    ("detail-open-672-38", 672, 38, "detail-open"),
]
results = []
print("Fresh optimized processes; sampled 8 seconds after launch; no disk scans.", flush=True)
# Model controls do not construct either picker, so one implementation suffices.
runs = [
    (case, branches, rows, mode, picker)
    for case, branches, rows, mode in cases
    for picker in (pickers[:1] if mode == "model" else pickers)
]
for case, branches, rows, mode, picker in runs:
    name = f"{picker}-{case}"
    with (reports / f"{name}.log").open("w") as log:
        process = subprocess.Popen(
            [str(output / f"DevBoxMemoryProfile-{picker}"), str(branches), str(rows), mode],
            stdout=log, stderr=subprocess.STDOUT,
        )
        try:
            time.sleep(8)
            if process.poll() is not None:
                raise RuntimeError(f"{name} exited early; see {name}.log")
            markers = (reports / f"{name}.log").read_text()
            if "PROFILE_READY" not in markers:
                raise RuntimeError(f"{name} did not render its window; see {name}.log")
            if mode == "detail-open" and (
                "PROFILE_MENU_OPEN" not in markers or "PROFILE_MENU_CLOSED" in markers
            ):
                raise RuntimeError(f"{name} did not keep its menu open; see {name}.log")
            measurement = {"picker": picker, "case": case, "branches": branches, "rows": rows}
            for tool, arguments in [
                ("vmmap", ["-summary"]),
                ("heap", ["-s", "--noContent"]),
            ]:
                result = subprocess.run(
                    [tool, *arguments, str(process.pid)],
                    capture_output=True, text=True, timeout=60, check=True,
                )
                (reports / f"{name}.{tool}.txt").write_text(result.stdout + result.stderr)
                if tool == "vmmap":
                    footprint = re.search(r"Physical footprint:\s+(\S+)", result.stdout)
                    measurement["footprint"] = footprint.group(1) if footprint else None
                else:
                    heap = re.search(r"All zones: (\d+) nodes \((\d+) bytes\)", result.stdout)
                    if heap:
                        measurement["allocations"] = int(heap.group(1))
                        measurement["heap_bytes"] = int(heap.group(2))
            if mode == "detail-open" and "PROFILE_MENU_CLOSED" in (reports / f"{name}.log").read_text():
                raise RuntimeError(f"{name} closed its menu during collection")
            results.append(measurement)
            (reports / "summary.json").write_text(json.dumps(results, indent=2) + "\n")
            print(f"{name}: {measurement}", flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
print(f"Reports: {reports}", flush=True)
PY
