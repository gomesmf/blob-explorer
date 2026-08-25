#!/usr/bin/env bash
# Runs every access path against the same seeded data and checks they agree.
# Anything that disagrees is a broken integration, not a flaky test.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

EXPECTED_ROWS=49000
pass=0 fail=0 skip=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s: %s\n' "$1" "$2"; fail=$((fail + 1)); }
note() { printf '  \033[33mskip\033[0m  %s (%s)\n' "$1" "$2"; skip=$((skip + 1)); }

# check <label> <expected> <actual>
check() {
  if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1" "expected $2, got $3"; fi
}

echo "containers"
for c in bx-azurite bx-s3proxy bx-filestash; do
  if [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" == "true" ]]; then
    ok "$c running"
  else
    bad "$c running" "not up — run 'make up'"
  fi
done

echo
echo "http endpoints"
for probe in "azurite:http://127.0.0.1:10000/devstoreaccount1?comp=list:403" \
             "filestash:http://127.0.0.1:8334/:200"; do
  name="${probe%%:*}"; rest="${probe#*:}"
  url="${rest%:*}"; want="${rest##*:}"
  got=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null)
  check "$name responds ($want)" "$want" "$got"
done

echo
echo "row counts (every path reads the same parquet)"

py_rows=$(uv run --directory python python -c '
from blobx.query_azure import connect
from blobx.config import EVENTS_GLOB
print(connect().sql(f"SELECT count(*) FROM \"{EVENTS_GLOB}\"").fetchone()[0])
' 2>/dev/null | tail -1)
check "python / duckdb azure ext" "$EXPECTED_ROWS" "${py_rows:-none}"

fs_rows=$(uv run --directory python python -c '
from blobx.query_fsspec import connect
from blobx.config import CONTAINER
g = f"abfs://{CONTAINER}/events/**/*.parquet"
print(connect().sql(f"SELECT count(*) FROM read_parquet(\"{g}\")").fetchone()[0])
' 2>/dev/null | tail -1)
check "python / fsspec+adlfs" "$EXPECTED_ROWS" "${fs_rows:-none}"

s3_rows=$(uv run --directory python python -c '
import duckdb
con = duckdb.connect()
con.execute("INSTALL httpfs; LOAD httpfs;")
con.execute("""CREATE OR REPLACE SECRET s3proxy (TYPE s3, KEY_ID \"local\",
  SECRET \"localsecret\", ENDPOINT \"127.0.0.1:8080\", URL_STYLE \"path\", USE_SSL false)""")
print(con.sql("SELECT count(*) FROM read_parquet(\"s3://data/events/**/*.parquet\")").fetchone()[0])
' 2>/dev/null | tail -1)
check "duckdb / s3proxy (S3 API)" "$EXPECTED_ROWS" "${s3_rows:-none}"

go_rows=$(cd go && CGO_ENABLED=1 go run ./cmd/blobq -format csv \
  "SELECT count(*) AS n FROM events" 2>/dev/null | tail -1 | tr -d ' ')
check "go / go-duckdb" "$EXPECTED_ROWS" "${go_rows:-none}"

if command -v duckdb >/dev/null; then
  cli_rows=$(duckdb -init duckdb/init.sql -noheader -list dev.duckdb \
    -c "SELECT count(*) FROM events" 2>/dev/null | tail -1 | tr -d ' ')
  check "duckdb CLI / init.sql views" "$EXPECTED_ROWS" "${cli_rows:-none}"
else
  note "duckdb CLI" "brew install duckdb"
fi

echo
echo "blob listings (all should see 7 parquet files)"

py_files=$(uv run --directory python python -c '
from adlfs import AzureBlobFileSystem
from blobx.config import CONNECTION_STRING, CONTAINER
fs = AzureBlobFileSystem(connection_string=CONNECTION_STRING)
print(len(fs.glob(f"{CONTAINER}/events/**/*.parquet")))
' 2>/dev/null | tail -1)
check "python / adlfs" "7" "${py_files:-none}"

go_files=$(cd go && go run ./cmd/blobctl tree events 2>/dev/null | grep -c '\.parquet')
check "go / azure sdk" "7" "${go_files:-none}"

gocloud_files=$(cd go && go run ./cmd/portable ls "events/" 2>/dev/null | grep -c 'dt=')
check "go / gocloud.dev" "7" "${gocloud_files:-none}"

if command -v rclone >/dev/null; then
  rc_files=$(rclone --config rclone/rclone.conf ls azurite:data 2>/dev/null | grep -c '\.parquet')
  check "rclone / azureblob" "7" "${rc_files:-none}"
else
  note "rclone" "brew install rclone"
fi

echo
printf '%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[[ "$fail" -eq 0 ]]
