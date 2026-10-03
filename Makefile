CONFIGURATION ?= release
BENCH_FILES ?= 50000
BENCH_RUNS ?= 5

.PHONY: test test-mariadb build run benchmark

test:
	swift test

test-mariadb:
	sh scripts/test-mariadb.sh

build:
	CONFIGURATION="$(CONFIGURATION)" sh scripts/build-app.sh

run: build
	open build/DevBox.app

benchmark:
	BENCH_FILES="$(BENCH_FILES)" BENCH_RUNS="$(BENCH_RUNS)" sh scripts/benchmark-sizes.sh
