# Browsing blobs on a Mac

Ranked by how little they get in your way.

## 1. A real filesystem — `rclone nfsmount`, no macFUSE

```bash
brew install rclone
make rclone-mount           # mounts azurite:data at ./.rclone-mnt
```

Leave it running; in another shell the blobs are just files:

```console
$ ls .rclone-mnt
events  marts  raw
$ cat .rclone-mnt/raw/README.txt
$ find .rclone-mnt/events -name '*.parquet'
$ duckdb -c "SELECT count(*) FROM '.rclone-mnt/events/**/*.parquet'"
```

`make rclone-unmount` when done.

This is the one to use. Homebrew's rclone ships **no `mount` subcommand on
macOS** — it deliberately drops the FUSE dependency and gives you `nfsmount`
instead, which serves an NFS export to the loopback and mounts it with macOS's
built-in client. No kernel extension, no reboot, no sudo, and unlike WebDAV it
is a genuine POSIX filesystem, so ordinary tools (including DuckDB reading a
local glob) work against it.

## 2. Finder over WebDAV

```bash
make rclone-webdav          # serves azurite:data on :8081
```

Finder → **⌘K** → `http://127.0.0.1:8081` → Connect.

Mounts as a Finder volume with Quick Look and drag-and-drop. Better than
`nfsmount` when you want the GUI specifically; worse for command-line work.

## 2. Filestash — already running

```bash
make up && open http://127.0.0.1:8334
```

Pick the **Azurite** connection and log in:

| Field | Value |
|---|---|
| Access Key ID | `local` |
| Secret Access Key | `localsecret` |
| **Advanced** ▸ Endpoint | `http://s3proxy:80` |

You must click **Advanced** to reveal the Endpoint field — without it Filestash
talks to real AWS and fails with `Invalid account`. The endpoint is the
*container name*: Filestash dials from inside the compose network, so
`127.0.0.1:8080` is Filestash itself, not s3proxy. Region can be left blank.

Filestash will not remember these (see [tools.md](tools.md)), so they are
repeated in the connection label. The admin console at `/admin` is a separate
login, password `blobexplorer`.

Once in: folder navigation, inline preview for CSV/JSON/text/images, download,
drag-and-drop upload.

## 3. rclone in the terminal

```bash
make rclone-tree     # whole tree
make rclone-ncdu     # interactive TUI: arrow keys, sizes, delete
```

`ncdu` is genuinely good for "which prefix is eating all the space".

## 4. Cyberduck — native app, speaks Azure directly

```bash
brew install --cask cyberduck
```

New bookmark → **Azure Deployment/Storage**, then:

| Field | Value |
|---|---|
| Server | `127.0.0.1` |
| Port | `10000` |
| Access Key ID | `devstoreaccount1` |
| Secret Access Key | the Azurite key from `.env` |
| Path | `/devstoreaccount1/data` |

If the Azure profile refuses a plain-HTTP emulator, use Cyberduck's **S3**
profile against `http://127.0.0.1:8080` with `local` / `localsecret` instead —
same blobs, through s3proxy.

**Mountain Duck** (paid, same vendor) mounts any Cyberduck bookmark as a Finder
disk with offline caching. Worth it if you live in Finder.

## 5. VS Code — stay in the editor

Install the **Azure Storage** extension. In the Azure panel: *Attach to a local
emulator* → Blob. Gives a sidebar tree with upload, download, and preview.

Pair it with the **Azurite** extension if you'd rather run the emulator from
VS Code than from Docker — but note the rest of this repo assumes the container,
so ports must match (10000/10001/10002).

For SQL, add a DuckDB extension and point it at `dev.duckdb` after running
`make duckdb-secret` (GUI clients can't run an init script, so the azure secret
has to be persisted once).

## What to skip

**Azure Storage Explorer.** Electron, slow to start, and unreliable on Apple
Silicon — the reason this repo exists. Everything above does the job faster.
