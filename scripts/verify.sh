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
# Azurite 403s an unsigned request; Filestash 307s to /login. Both mean "alive".
probe_http() {
  local name="$1" url="$2" want="$3"
  local got
  got=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null)
  if [[ "$got" =~ ^($want)$ ]]; then ok "$name responds ($got)"
  else bad "$name responds" "expected $want, got ${got:-none}"; fi
}
probe_http azurite   "http://127.0.0.1:10000/devstoreaccount1?comp=list" '403'
probe_http filestash "http://127.0.0.1:8334/"                            '200|307'
probe_http s3proxy   "http://127.0.0.1:8080/"                            '403|400'

echo
echo "filestash (drives the real API, not just the status code)"

# secret_key encrypts stored connection credentials with AES: 16, 24 or 32 bytes.
key_len=$(python3 -c 'import json;print(len(json.load(open("docker/filestash/config.json"))["general"]["secret_key"]))' 2>/dev/null)
if [[ "$key_len" =~ ^(16|24|32)$ ]]; then
  ok "secret_key is a valid AES length ($key_len)"
else
  bad "secret_key length" "must be 16/24/32 bytes, got ${key_len:-none}"
fi

# The documented admin password must actually work. Filestash rewrites the
# bind-mounted config on boot, so a hand-seeded hash can silently be replaced.
adm=$(curl -s --max-time 15 -X POST http://127.0.0.1:8334/admin/api/session \
  -H 'Content-Type: application/json' -d '{"password":"blobexplorer"}' 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' 2>/dev/null)
check "documented admin password works" "ok" "${adm:-none}"

# Exactly what a person types at /login: two keys plus the endpoint that lives
# behind the Advanced toggle. Region is optional.
jar=$(mktemp)
sess=$(curl -s --max-time 20 -X POST http://127.0.0.1:8334/api/session \
  -H 'Content-Type: application/json' -c "$jar" \
  -d '{"type":"s3","access_key_id":"local","secret_access_key":"localsecret","endpoint":"http://s3proxy:80"}' \
  2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' 2>/dev/null)
check "login with the documented fields" "ok" "${sess:-none}"

# The endpoint is the only hint that survives Filestash's config rewrite.
label=$(curl -s --max-time 20 -H 'X-Requested-With: XmlHttpRequest' \
  http://127.0.0.1:8334/api/config 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["connections"][0]["label"])' 2>/dev/null)
case "$label" in
  *s3proxy:80*) ok "login hint reaches the form" ;;
  *) bad "login hint reaches the form" "label lost the endpoint: ${label:-none}" ;;
esac

# X-Requested-With is required; without it every call is "Not Allowed".
fs_dirs=$(curl -s --max-time 25 -b "$jar" -H 'X-Requested-With: XmlHttpRequest' \
  'http://127.0.0.1:8334/api/files/ls?path=%2Fdata%2Fevents%2F' 2>/dev/null \
  | python3 -c 'import json,sys; print(sum(1 for f in json.load(sys.stdin)["results"] if f["type"]=="directory"))' 2>/dev/null)
check "lists blob prefixes as folders" "7" "${fs_dirs:-none}"

fs_cat=$(curl -s --max-time 25 -b "$jar" -H 'X-Requested-With: XmlHttpRequest' \
  'http://127.0.0.1:8334/api/files/cat?path=%2Fdata%2Fraw%2FREADME.txt' 2>/dev/null | head -c 6)
check "downloads a file" "Seeded" "${fs_cat:-none}"
rm -f "$jar"

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
  # DuckDB is single-writer: a running `make ui` holds the lock on dev.duckdb.
  # Use a scratch database so verify works whether or not the UI is open.
  scratch=$(mktemp -u).duckdb
  cli_rows=$(duckdb -init duckdb/init.sql -noheader -list "$scratch" \
    -c "SELECT count(*) FROM events" 2>/dev/null | tail -1 | tr -d ' ')
  rm -f "$scratch" "$scratch".wal
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
  rc_files=$(rclone --config rclone/rclone.conf ls azurite:data/events 2>/dev/null | grep -c '\.parquet')
  check "rclone / azureblob" "7" "${rc_files:-none}"
else
  note "rclone" "brew install rclone"
fi

echo
echo "make targets (ARGS must survive the shell, not be parsed by it)"

# Parentheses and globs in SQL used to blow up: $(ARGS) expanded straight into
# the recipe, so bash parsed the query. ARGS is exported and quoted now.
mk_rows=$(make -s blobq ARGS="SELECT count(*) AS n FROM 'az://data/events/**/*.parquet' WHERE 1 > 0" 2>/dev/null \
  | tail -1 | tr -d ' ')
check "make blobq ARGS with ( ) * >" "$EXPECTED_ROWS" "${mk_rows:-none}"

# blobctl still needs word splitting, so its ARGS must not be over-quoted.
mk_dirs=$(make -s blobctl ARGS="ls events" 2>/dev/null | grep -c 'dt=')
check "make blobctl ARGS word splitting" "7" "${mk_dirs:-none}"

echo
printf '%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[[ "$fail" -eq 0 ]]
