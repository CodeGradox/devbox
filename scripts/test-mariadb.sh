#!/bin/sh
# No Homebrew services, TCP listener, default config, or existing datadir is used.
set -eu
cd "$(dirname "$0")/.."
root=$(pwd -P)
bin=
for prefix in /opt/homebrew /usr/local; do
    if [ -x "$prefix/opt/mariadb/bin/mariadbd" ]; then
        bin="$prefix/opt/mariadb/bin"
        break
    fi
done
[ -n "$bin" ] || { echo "Install MariaDB before running this opt-in integration test." >&2; exit 1; }
mkdir -p .build
dir=$(mktemp -d "$root/.build/db.XXXXXX")
socket="$dir/s"
pid=
cleanup() {
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    rm -rf "$dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
[ "${#socket}" -lt 104 ] || { echo "Repository path is too long for a Unix socket: $socket" >&2; exit 1; }
unset MYSQL_PWD MYSQL_HOST MYSQL_TCP_PORT MYSQL_UNIX_PORT
touch "$dir/devbox-isolated-test"
"$bin/mariadb-install-db" --no-defaults --datadir="$dir/data" \
    --auth-root-authentication-method=normal --skip-test-db >"$dir/init.log" 2>&1 \
    || { cat "$dir/init.log"; exit 1; }
"$bin/mariadbd" --no-defaults --datadir="$dir/data" --skip-networking \
    --socket="$socket" --pid-file="$dir/server.pid" --log-error="$dir/server.log" \
    --tmpdir="$dir" >"$dir/stdout.log" 2>&1 &
pid=$!
i=0
until "$bin/mariadb" --no-defaults --protocol=SOCKET --socket="$socket" \
    --user=root --skip-password --execute="SELECT 1" >/dev/null 2>&1; do
    i=$((i + 1))
    if ! kill -0 "$pid" 2>/dev/null || [ "$i" -ge 60 ]; then
        cat "$dir/server.log" "$dir/stdout.log"
        exit 1
    fi
    sleep 1
done
"$bin/mariadb" --no-defaults --protocol=SOCKET --socket="$socket" \
    --user=root --skip-password --default-character-set=utf8mb4 <<'SQL'
CREATE DATABASE `devbox_integration_plain`;
CREATE DATABASE `devbox_integration_``資料`;
CREATE DATABASE `devbox_integration_empty`;
CREATE TABLE `devbox_integration_plain`.`records` (id INT PRIMARY KEY) ENGINE=MyISAM;
INSERT INTO `devbox_integration_plain`.`records` VALUES (1), (2), (3);
CREATE VIEW `devbox_integration_plain`.`view_``資料` AS SELECT * FROM `devbox_integration_plain`.`records`;
CREATE TABLE `devbox_integration_``資料`.`history_``資料` (id INT PRIMARY KEY) ENGINE=InnoDB WITH SYSTEM VERSIONING;
CREATE USER 'devbox_metadata_reader'@'localhost' IDENTIFIED BY '';
GRANT SELECT ON `devbox_integration_plain`.`records` TO 'devbox_metadata_reader'@'localhost';
SQL
DEVBOX_TEST_MARIADB_SOCKET="$socket" sh scripts/test.sh --filter 'Database(Service|Integration)Tests'
