"""marimo notebook: SQL cells over Parquet living in Azurite.

    make notebook        # uv run marimo edit python/notebooks/explore.py

Reactive and stored as plain Python, so it diffs in git like normal code.
"""

import marimo

__generated_with = "0.9.0"
app = marimo.App(width="medium")


@app.cell
def _():
    import marimo as mo

    from blobx.config import CONTAINER
    from blobx.query_azure import connect

    # Same helper the CLI uses: duckdb + azure extension + the Azurite secret.
    con = connect()
    return CONTAINER, con, mo


@app.cell
def _(CONTAINER, con):
    # Register the parquet glob once; every SQL cell below reads `events`.
    con.execute(f"""
        CREATE OR REPLACE VIEW events AS
        SELECT * FROM read_parquet(
            'az://{CONTAINER}/events/**/*.parquet',
            hive_partitioning := true
        )
    """)
    return


@app.cell
def _(mo):
    mo.md(
        """
        # blob-explorer

        Parquet in Azurite, queried in place. Nothing is downloaded first —
        DuckDB range-reads the row groups it needs straight out of blob storage.
        """
    )
    return


@app.cell
def _(con, mo):
    overview = mo.sql(
        """
        SELECT dt, count(*) AS rows, round(sum(amount), 2) AS amount
        FROM events
        GROUP BY dt
        ORDER BY dt
        """,
        engine=con,
    )
    return (overview,)


@app.cell
def _(mo):
    # Reactive filter: change it and every dependent cell re-runs.
    region = mo.ui.dropdown(
        options=["us-east", "us-west", "eu-central", "sa-east", "ap-south"],
        value="eu-central",
        label="region",
    )
    region
    return (region,)


@app.cell
def _(con, mo, region):
    breakdown = mo.sql(
        f"""
        SELECT event,
               count(*)                 AS n,
               round(sum(amount), 2)    AS amount,
               round(avg(amount), 2)    AS avg_amount
        FROM events
        WHERE region = '{region.value}'
        GROUP BY event
        ORDER BY amount DESC
        """,
        engine=con,
    )
    return (breakdown,)


@app.cell
def _(mo):
    mo.md(
        """
        ## Writing back

        The azure extension writes too, so a notebook can publish a mart:

        ```sql
        COPY (SELECT region, sum(amount) AS amount FROM events GROUP BY region)
        TO 'az://data/marts/revenue_by_region.parquet' (FORMAT parquet);
        ```
        """
    )
    return


if __name__ == "__main__":
    app.run()
