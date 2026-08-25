"""Query blob Parquet through fsspec instead of DuckDB's azure extension.

Useful when the native extension can't be loaded (air-gapped box, locked-down
extension repo) or when the surrounding Python stack already has fsspec auth
configured -- pandas, polars and pyarrow all read the same filesystem object.

Gotcha: the registered protocol is `abfs`, not `abfss`.
"""

from __future__ import annotations

import argparse

import duckdb
import fsspec
from rich.console import Console

from .config import CONNECTION_STRING, CONTAINER

console = Console()


def connect() -> duckdb.DuckDBPyConnection:
    con = duckdb.connect()
    con.register_filesystem(
        fsspec.filesystem("abfs", connection_string=CONNECTION_STRING)
    )
    return con


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sql", nargs="?")
    args = parser.parse_args()

    con = connect()
    glob = f"abfs://{CONTAINER}/events/**/*.parquet"

    if args.sql:
        console.print(con.sql(args.sql))
        return

    console.rule("via fsspec/adlfs")
    console.print(con.sql(f"SELECT count(*) AS rows FROM read_parquet('{glob}')"))
    console.print(
        con.sql(f"""
        SELECT event, count(*) AS n, round(avg(amount), 2) AS avg_amount
        FROM read_parquet('{glob}')
        GROUP BY event ORDER BY n DESC
        """)
    )


if __name__ == "__main__":
    main()
