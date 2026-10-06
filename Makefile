CONFIGURATION ?= release
BENCH_FILES ?= 50000
BENCH_RUNS ?= 5
BENCH_WORKTREES ?= 12
BENCH_STATUS_FILES ?= 2000

.PHONY: test test-mariadb build run benchmark benchmark-refresh

test:
	sh scripts/test.sh

test-mariadb:
	sh scripts/test-mariadb.sh

build:
	CONFIGURATION="$(CONFIGURATION)" sh scripts/build-app.sh

run: build
	open build/DevBox.app

benchmark:
	BENCH_FILES="$(BENCH_FILES)" BENCH_RUNS="$(BENCH_RUNS)" sh scripts/benchmark-sizes.sh

benchmark-refresh:
	BENCH_WORKTREES="$(BENCH_WORKTREES)" BENCH_STATUS_FILES="$(BENCH_STATUS_FILES)" BENCH_RUNS="$(BENCH_RUNS)" sh scripts/benchmark-refresh.sh
