"""Query Parquet in blob storage with DuckDB's native `azure` extension.

This is the path the DuckDB UI, Harlequin and DBeaver all use too -- the
secret is the only moving part.
"""

from __future__ import annotations

import argparse

import duckdb
from rich.console import Console

from .config import CONNECTION_STRING, CONTAINER, EVENTS_GLOB

console = Console()


def connect(database: str = ":memory:") -> duckdb.DuckDBPyConnection:
    """Open DuckDB with the azure extension loaded and the Azurite secret set."""
    con = duckdb.connect(database)
    con.execute("INSTALL azure; LOAD azure;")
    con.execute(
        """
        CREATE OR REPLACE SECRET azurite (
            TYPE azure,
            CONNECTION_STRING ?
        )
        """,
        [CONNECTION_STRING],
    )
    return con


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sql", nargs="?", help="SQL to run; omit for the demo queries")
    parser.add_argument("--write", action="store_true", help="also demo COPY TO az://")
    args = parser.parse_args()

    con = connect()

    if args.sql:
        console.print(con.sql(args.sql))
        return

    console.rule("row count")
    console.print(con.sql(f"SELECT count(*) AS rows FROM '{EVENTS_GLOB}'"))

    console.rule("partition pruning (hive)")
    console.print(
        con.sql(f"""
        SELECT dt, count(*) AS rows, round(sum(amount), 2) AS amount
        FROM read_parquet('{EVENTS_GLOB}', hive_partitioning := true)
        WHERE dt >= '2026-08-05'
        GROUP BY dt ORDER BY dt
        """)
    )

    console.rule("top regions")
    console.print(
        con.sql(f"""
        SELECT region, event, count(*) AS n, round(sum(amount), 2) AS amount
        FROM '{EVENTS_GLOB}'
        GROUP BY ALL ORDER BY amount DESC LIMIT 10
        """)
    )

    if args.write:
        console.rule("COPY TO az:// (the azure extension writes too)")
        target = f"az://{CONTAINER}/marts/revenue_by_region.parquet"
        con.execute(f"""
            COPY (
                SELECT region, round(sum(amount), 2) AS amount
                FROM '{EVENTS_GLOB}' GROUP BY region ORDER BY amount DESC
            ) TO '{target}' (FORMAT parquet)
        """)
        console.print(f"wrote [bold]{target}[/]")
        console.print(con.sql(f"SELECT * FROM '{target}'"))


if __name__ == "__main__":
    main()
