# python

Managed by [uv](https://docs.astral.sh/uv/). `uv sync` once; `make` targets do
the rest.

| Module | Command | What |
|---|---|---|
| `seed.py` | `make seed` | Generate hive-partitioned Parquet, upload with `azure-storage-blob`. Idempotent. |
| `browse.py` | `make browse` | Tree view via `adlfs`. `--download DEST` mirrors a prefix locally. |
| `query_azure.py` | `make query` | DuckDB + the native `azure` extension. `ARGS=--write` demos `COPY TO az://`. |
| `query_fsspec.py` | `make query-fsspec` | DuckDB over `fsspec`/`adlfs` instead of the extension. |
| `notebooks/explore.py` | `make notebook` | marimo: SQL cells, reactive filters, plain `.py` on disk. |

`config.py` reads the repo-root `.env`, falling back to Azurite's defaults, so
every script works with zero setup and retargets real Azure by changing one
connection string.

## Which query path?

`query_azure.py` is the one to copy. `query_fsspec.py` exists for when the
native extension isn't an option (no network for the extension repo, or the
surrounding stack already has fsspec auth wired up) — the tradeoff is that
reads go through Python instead of DuckDB's own HTTP layer, so it's slower on
wide scans.

**Gotcha:** the fsspec protocol is `abfs://`, not `abfss://` as in Spark.
