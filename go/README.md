# go

Three small CLIs covering the three ways a Go service touches blob storage.

| Command | Library | What |
|---|---|---|
| `cmd/blobctl` | `azure-sdk-for-go/.../azblob` | `ls`, `tree`, `stat`, `get`, `put`, `rm`, `containers`. |
| `cmd/portable` | `gocloud.dev/blob` | Same ops, one URL swaps the backend. |
| `cmd/blobq` | `marcboeker/go-duckdb/v2` | DuckDB in-process over `az://` Parquet. |

```bash
make go-build                                   # -> go/bin
make blobctl ARGS="tree events"
make blobq   ARGS="SELECT region, count(*) FROM events GROUP BY region"
make blobq                                      # default query, no ARGS
```

## blobctl

The `tree` command is the useful reference. Blob storage has a flat namespace;
listing with a `/` delimiter is the only reason it can look like directories:

```go
pager := containerClient.NewListBlobsHierarchyPager("/", opts)
// resp.Segment.BlobPrefixes -> directories
// resp.Segment.BlobItems    -> files
```

If your in-house UI paginates every blob and rebuilds the hierarchy in
application code, this is the call that replaces it.

## portable

Backend is entirely a URL, so dev and prod differ by an env var, not a code
path:

```bash
BLOB_URL='azblob://data?protocol=http&domain=127.0.0.1:10000&localemu=true' make portable ARGS=ls
BLOB_URL='azblob://data'                                                    make portable ARGS=ls  # real Azure
BLOB_URL='s3://data?endpoint=http://127.0.0.1:8080&region=us-east-1'        make portable ARGS=ls
BLOB_URL='file:///tmp/blobs'                                                make portable ARGS=ls
BLOB_URL='mem://'                                                           make portable ARGS=ls  # tests
```

Credentials come from whatever the chosen driver expects
(`AZURE_STORAGE_ACCOUNT`/`AZURE_STORAGE_KEY`, `AWS_ACCESS_KEY_ID`, …). The cost
is a large dependency tree — the Go CDK pulls in every driver's SDK.

## blobq

Same engine and same `az://` URLs as the DuckDB UI, so a query prototyped in
the browser drops straight into Go.

**Gotcha:** needs `CGO_ENABLED=1`, and the `azure` extension is *not*
statically linked into go-duckdb. The first run downloads it from the DuckDB
extension repository, then caches it in `~/.duckdb/extensions`. In a container,
either pre-warm that cache or bake the extension into the image.

## ARGS quoting

`ARGS` is exported by the Makefile and quoted as `"$ARGS"` in the `blobq`
recipe, so SQL containing `(`, `*`, `>` or quotes reaches DuckDB intact.
`blobctl` and `portable` deliberately leave it unquoted, because those take
subcommands that must word-split:

```bash
make blobq   ARGS="SELECT count(*) FROM events WHERE amount > 0"   # one argument
make blobctl ARGS="ls events"                                      # two arguments
```

Running the binaries directly, quote as usual:
`go run ./cmd/blobq "SELECT count(*) FROM events"`.
