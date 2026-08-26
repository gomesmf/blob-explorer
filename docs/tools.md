# Tools

## Browsing blobs

| Tool | Browse | Download | Native Mac | Docker | Cost | Verdict |
|---|---|---|---|---|---|---|
| **Filestash** | folders, previews | yes | web | yes | free | Best default. In the stack already, `:8334`. |
| **rclone** | `ls`/`tree`/`ncdu` | yes | binary | no | free | Scriptable. `ncdu` is a real TUI browser. |
| **rclone nfsmount** | real filesystem | yes | POSIX mount | no | free | Best of the lot. No macFUSE, no sudo. See [mac.md](mac.md). |
| **rclone serve webdav** | Finder | yes | Finder volume | no | free | Finder volume, no kext. |
| **Cyberduck** | folders | yes | app | no | free | Native app, fast, speaks Azure Blob directly. |
| **Mountain Duck** | Finder | yes | Finder disk | no | paid | Cyberduck's mount-as-disk sibling. |
| **VS Code Azure Storage** | sidebar tree | yes | extension | no | free | Never leave the editor. |
| **blobctl** (this repo) | `ls`/`tree` | yes | binary | no | free | Go, ~300 lines, the reference for your own UI. |
| Azure Storage Explorer | folders | yes | Electron | no | free | The thing we are replacing. |

### Why blob storage can look like a filesystem at all

The namespace is flat — `events/dt=2026-08-01/part-000.parquet` is one key, not
three directories. Listing with a `/` **delimiter** makes the service return
common prefixes as pseudo-directories. That single call is what every browser
above is doing:

```go
// go/cmd/blobctl/main.go
pager := containerClient.NewListBlobsHierarchyPager("/", opts)
// -> resp.Segment.BlobPrefixes  (directories)
// -> resp.Segment.BlobItems     (files)
```

Python's `adlfs` and `gocloud.dev/blob` (`Delimiter: "/"`) do the same thing.

## Querying Parquet

| Tool | Interface | Setup | Verdict |
|---|---|---|---|
| **DuckDB UI** | browser notebook | `make ui` | Best default. Catalog sidebar, column stats, autocomplete. Ships with DuckDB ≥1.2.1, runs fully local. |
| **Harlequin** | terminal | `make tui` | SQL IDE in the terminal. Catalog tree, query history, no browser. |
| **marimo** | Python notebook | `make notebook` | SQL cells + Python in one reactive doc, stored as plain `.py`. |
| **blobq** (this repo) | CLI | `make blobq` | DuckDB in-process from Go — the production path. |
| **DBeaver / VS Code** | GUI | `make duckdb-secret` first | They cannot run an init script, so the secret must be persisted. |

## Two ways to reach the blobs

**Native Azure** — DuckDB's `azure` extension, `az://` URLs, one secret:

```sql
CREATE OR REPLACE SECRET azurite (TYPE azure, CONNECTION_STRING '...');
SELECT count(*) FROM 'az://data/events/**/*.parquet';
```

It reads *and* writes: `COPY (...) TO 'az://data/marts/x.parquet'` works.

**S3 API** — `s3proxy` fronts Azurite, so `httpfs` and every S3 tool works
against the identical bytes:

```sql
SELECT count(*) FROM 's3://data/events/**/*.parquet';
```

Both return the same rows; `make verify` asserts it.

## Gotchas

- **Filestash cannot talk to Azurite directly.** Its Azure backend hardcodes
  `https://<account>.blob.core.windows.net/` with no endpoint override, so it
  reaches Azurite through s3proxy instead. That is why s3proxy runs by default
  rather than behind a profile.
- **s3proxy's entrypoint maps no `JCLOUDS_ENDPOINT`.** Only provider, identity
  and credential become properties. The endpoint goes in via
  `S3PROXY_JAVA_OPTS: -Djclouds.endpoint=...`, since system properties override
  the generated file.
- **Filestash's `secret_key` must be exactly 16, 24 or 32 bytes.** It is the
  AES key for stored connection credentials; any other length fails the admin
  console with `Crypto/aes: invalid key size N`.
- **Filestash's API needs `X-Requested-With: XmlHttpRequest`.** Without it
  every call returns `Not Allowed` — CSRF protection, not a misconfiguration.
- **Filestash rewrites its bind-mounted config.json** on boot, filling in
  defaults and the `auth` block. Expect the committed file to be the
  normalised form.
- **Azurite rejects `Put Block From URL`**, so s3proxy streams server-side
  copies through itself. Slower, harmless for dev.
- **DuckDB is single-writer.** A running `make ui` holds the lock on
  `dev.duckdb`; a second `duckdb dev.duckdb` fails with `Conflicting lock is
  held`. Close the UI, or point the other session at a different database —
  the views are only a convenience, `az://` globs work from anywhere.
- **`abfs://`, not `abfss://`** when registering adlfs with DuckDB.
- **`go-duckdb` needs `CGO_ENABLED=1`**, and the azure extension is not
  statically linked — the first run downloads it, then caches in
  `~/.duckdb/extensions`.
- **`curl --aws-sigv4` fails against s3proxy on uploads** (it omits
  `x-amz-content-sha256`). Not an s3proxy bug; use a real S3 client.
- **Homebrew's rclone has no `mount` on macOS.** It drops the FUSE dependency
  on purpose; use `nfsmount` (what `make rclone-mount` runs) instead.
- **Azurite's account key is public.** It is Microsoft's documented emulator
  fixture, safe to commit, useless against real Azure.
