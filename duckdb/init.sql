-- Bootstrap for every DuckDB session against Azurite.
--   duckdb -init duckdb/init.sql dev.duckdb        # CLI
--   duckdb -init duckdb/init.sql -ui dev.duckdb    # local web UI :4213
--   harlequin --init-path duckdb/init.sql dev.duckdb
--
-- The secret is session-scoped on purpose: nothing is written to ~/.duckdb.
-- Run `make duckdb-secret` instead if you need a persistent one for a GUI
-- client (DBeaver, VS Code) that cannot run an init script.

INSTALL azure;
LOAD azure;

CREATE OR REPLACE SECRET azurite (
    TYPE azure,
    CONNECTION_STRING 'DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1;'
);

-- Same bytes over the S3 API, served by the s3proxy container.
INSTALL httpfs;
LOAD httpfs;

CREATE OR REPLACE SECRET s3proxy (
    TYPE s3,
    KEY_ID 'local',
    SECRET 'localsecret',
    ENDPOINT '127.0.0.1:8080',
    URL_STYLE 'path',
    USE_SSL false
);

-- Views live in dev.duckdb, so the UI catalog sidebar is populated on open.
CREATE OR REPLACE VIEW events AS
    SELECT * FROM read_parquet('az://data/events/**/*.parquet', hive_partitioning := true);

CREATE OR REPLACE VIEW events_s3 AS
    SELECT * FROM read_parquet('s3://data/events/**/*.parquet', hive_partitioning := true);
