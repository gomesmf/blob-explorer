SHELL := /bin/bash
ROOT  := $(shell cd $(dir $(lastword $(MAKEFILE_LIST))) && pwd)
PY    := uv run --directory $(ROOT)/python
DUCK  := duckdb -init $(ROOT)/duckdb/init.sql $(ROOT)/dev.duckdb
RC    := rclone --config $(ROOT)/rclone/rclone.conf
MNT   := $(ROOT)/.rclone-mnt

.DEFAULT_GOAL := help

## ---- stack ----------------------------------------------------------------

up: ## start azurite + s3proxy + filestash
	docker compose up -d
	@$(MAKE) --no-print-directory ports

up-all: ## also start the rclone web GUI (profile: ui)
	docker compose --profile ui up -d
	@$(MAKE) --no-print-directory ports

down: ## stop containers, keep data
	docker compose --profile ui down

nuke: ## stop containers and delete all blob data
	docker compose --profile ui down -v
	rm -f $(ROOT)/dev.duckdb $(ROOT)/dev.duckdb.wal

logs: ## tail all container logs
	docker compose logs -f

ports: ## show what is listening where
	@printf '  %-28s %s\n' \
	  'http://127.0.0.1:8334'  'Filestash  - browse blobs like a filesystem' \
	  'http://127.0.0.1:10000' 'Azurite    - blob endpoint' \
	  'http://127.0.0.1:8080'  's3proxy    - S3 API over the same blobs' \
	  'http://127.0.0.1:5572'  'rclone GUI - only with `make up-all`' \
	  'http://127.0.0.1:4213'  'DuckDB UI  - after `make ui`'

## ---- data -----------------------------------------------------------------

seed: ## generate hive-partitioned parquet and upload it
	$(PY) blobx-seed

browse: ## tree view of the container (python/adlfs)
	$(PY) blobx-browse

## ---- query ----------------------------------------------------------------

ui: duckdb-check ## DuckDB local web UI on :4213
	$(DUCK) -ui

sql: duckdb-check ## DuckDB CLI with azure + s3 secrets loaded
	$(DUCK)

tui: ## Harlequin terminal SQL IDE
	uvx harlequin --init-path $(ROOT)/duckdb/init.sql $(ROOT)/dev.duckdb

notebook: ## marimo notebook with SQL cells
	$(PY) marimo edit $(ROOT)/python/notebooks/explore.py

query: ## python: duckdb azure extension (add ARGS=--write to demo COPY TO)
	$(PY) blobx-query $(ARGS)

query-fsspec: ## python: duckdb over fsspec/adlfs instead of the extension
	$(PY) blobx-query-fsspec

duckdb-secret: duckdb-check ## persist the azure secret for GUI clients (DBeaver, VS Code)
	@$(DUCK) -c "$$(sed 's/CREATE OR REPLACE SECRET/CREATE OR REPLACE PERSISTENT SECRET/' $(ROOT)/duckdb/init.sql)" \
	  && echo 'persistent secrets written to ~/.duckdb/stored_secrets'

duckdb-check:
	@command -v duckdb >/dev/null || { echo 'duckdb not found -> brew install duckdb'; exit 1; }

## ---- go -------------------------------------------------------------------

go-build: ## build the three Go CLIs into go/bin
	cd $(ROOT)/go && CGO_ENABLED=1 go build -o bin/ ./cmd/...
	@ls -1 $(ROOT)/go/bin

blobctl: ## go: browse blobs with the Azure SDK (ARGS="tree events")
	cd $(ROOT)/go && go run ./cmd/blobctl $(ARGS)

portable: ## go: same ops through gocloud.dev (BLOB_URL swaps backend)
	cd $(ROOT)/go && go run ./cmd/portable $(ARGS)

blobq: ## go: query blob parquet with duckdb in-process (ARGS="SELECT ...")
	cd $(ROOT)/go && CGO_ENABLED=1 go run ./cmd/blobq $(ARGS)

## ---- rclone ---------------------------------------------------------------

rclone-ls: rclone-check ## list blobs
	$(RC) ls azurite:$${BLOB_CONTAINER:-data}

rclone-tree: rclone-check ## tree view
	$(RC) tree azurite:$${BLOB_CONTAINER:-data}

rclone-ncdu: rclone-check ## interactive TUI browser
	$(RC) ncdu azurite:$${BLOB_CONTAINER:-data}

rclone-webdav: rclone-check ## serve blobs over WebDAV on :8081
	@echo 'Finder: Cmd+K -> http://127.0.0.1:8081 (no macFUSE needed)'
	$(RC) serve webdav azurite:$${BLOB_CONTAINER:-data} --addr 127.0.0.1:8081

rclone-mount: rclone-check ## mount blobs as a Finder folder (needs macFUSE)
	@mkdir -p $(MNT)
	$(RC) mount azurite:$${BLOB_CONTAINER:-data} $(MNT) --vfs-cache-mode full

rclone-unmount: ## unmount the folder from rclone-mount
	-umount $(MNT) 2>/dev/null || diskutil unmount force $(MNT)

rclone-check:
	@command -v rclone >/dev/null || { echo 'rclone not found -> brew install rclone'; exit 1; }

## ---- misc -----------------------------------------------------------------

s3-ls: ## list the same blobs through the S3 API
	AWS_ACCESS_KEY_ID=local AWS_SECRET_ACCESS_KEY=localsecret AWS_REGION=us-east-1 \
	  uvx --from awscli aws s3 ls s3://$${BLOB_CONTAINER:-data}/ --recursive \
	  --endpoint-url http://127.0.0.1:8080

verify: ## run every path and check they agree
	@bash $(ROOT)/scripts/verify.sh

help: ## this list
	@grep -hE '^[a-z0-9-]+:.*##' $(MAKEFILE_LIST) \
	  | sort | awk -F':.*## ' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: up up-all down nuke logs ports seed browse ui sql tui notebook query \
        query-fsspec duckdb-secret duckdb-check go-build blobctl portable blobq \
        rclone-ls rclone-tree rclone-ncdu rclone-webdav rclone-mount \
        rclone-unmount rclone-check s3-ls verify help
