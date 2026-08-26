# blob-explorer

Local Azure Blob Storage that you can actually see into and query. Azurite in
Docker, Parquet seeded into it, and a set of existing tools wired up so you
never open Azure Storage Explorer again.

## Quickstart

```bash
cp .env.example .env
make up          # azurite + s3proxy + filestash
make seed        # 49k rows of hive-partitioned parquet
make ui          # DuckDB SQL notebook on :4213
```

Then `open http://127.0.0.1:8334` to browse the blobs as folders.

Prerequisites: Docker, [uv](https://docs.astral.sh/uv/). Optional but worth it:
`brew install duckdb rclone`.

## What's listening

| URL | What |
|---|---|
| `:8334` | Filestash — browse blobs like a filesystem, preview, download |
| `:4213` | DuckDB UI — SQL notebook, catalog browser (after `make ui`) |
| `:10000` | Azurite — the blob endpoint itself |
| `:8080` | s3proxy — the same blobs over the S3 API |
| `:5572` | rclone web GUI (`make up-all`) |

## Seeing blobs

| Want | Do |
|---|---|
| Folder UI in a browser | `make up`, open `:8334` |
| Tree in the terminal | `make browse` (Python) or `make blobctl ARGS=tree` (Go) |
| Interactive TUI | `make rclone-ncdu` |
| Blobs as real files on disk | `make rclone-mount` (NFS, no macFUSE) |
| A Finder volume | `make rclone-webdav`, then Finder ⌘K → `http://127.0.0.1:8081` |
| A native Mac app | [docs/mac.md](docs/mac.md) — Cyberduck, VS Code |

## Querying blobs

| Want | Do |
|---|---|
| SQL notebook in a browser | `make ui` |
| SQL IDE in the terminal | `make tui` (Harlequin) |
| Python notebook with SQL cells | `make notebook` (marimo) |
| One-off query | `make query`, or `make blobq ARGS="SELECT ..."` |

Every one of these reads `az://data/events/**/*.parquet` in place — DuckDB
range-reads only the row groups it needs, nothing is downloaded first.

## Code examples

- [python/](python/) — seed, browse via `adlfs`, query two different ways
- [go/](go/) — Azure SDK, `gocloud.dev/blob`, and DuckDB in-process

Both languages, plus the CLI and the UI, are checked against each other:

```bash
make verify
```

## Reference

- [docs/tools.md](docs/tools.md) — every tool compared, and the gotchas
- [docs/mac.md](docs/mac.md) — Mac-native browsing without Storage Explorer

## Notes

The Azurite account (`devstoreaccount1`) and its key are Microsoft's published
emulator fixture, not a secret — that is why they are committed. `.env` is
gitignored anyway so you can point the same commands at a real storage account
by changing one connection string.
