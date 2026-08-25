"""Generate hive-partitioned Parquet and upload it to blob storage.

Idempotent: re-running overwrites the same blob paths.
"""

from __future__ import annotations

import argparse
import datetime as dt
import io
import random

import polars as pl
from azure.core.exceptions import ResourceExistsError
from azure.storage.blob import BlobServiceClient
from rich.console import Console

from .config import CONNECTION_STRING, CONTAINER

console = Console()

EVENTS = ["view", "click", "add_to_cart", "purchase", "refund"]
REGIONS = ["us-east", "us-west", "eu-central", "sa-east", "ap-south"]


def make_day(day: dt.date, rows: int, rng: random.Random) -> pl.DataFrame:
    midnight = dt.datetime.combine(day, dt.time.min)
    return pl.DataFrame(
        {
            "ts": [
                midnight + dt.timedelta(seconds=rng.randrange(86_400))
                for _ in range(rows)
            ],
            "user_id": [rng.randrange(1, 5_000) for _ in range(rows)],
            "event": [rng.choice(EVENTS) for _ in range(rows)],
            "amount": [round(rng.lognormvariate(3, 1), 2) for _ in range(rows)],
            "region": [rng.choice(REGIONS) for _ in range(rows)],
        }
    ).sort("ts")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--rows-per-day", type=int, default=7_000)
    parser.add_argument("--start", default="2026-08-01")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    rng = random.Random(args.seed)
    start = dt.date.fromisoformat(args.start)

    service = BlobServiceClient.from_connection_string(CONNECTION_STRING)
    try:
        service.create_container(CONTAINER)
        console.print(f"created container [bold]{CONTAINER}[/]")
    except ResourceExistsError:
        console.print(f"container [bold]{CONTAINER}[/] already exists")

    container = service.get_container_client(CONTAINER)
    total = 0

    for offset in range(args.days):
        day = start + dt.timedelta(days=offset)
        frame = make_day(day, args.rows_per_day, rng)
        buf = io.BytesIO()
        frame.write_parquet(buf, compression="zstd")
        blob = f"events/dt={day.isoformat()}/part-000.parquet"
        container.upload_blob(blob, buf.getvalue(), overwrite=True)
        total += frame.height
        console.print(f"  {blob}  [dim]{frame.height} rows, {buf.tell():,} B[/]")

    # Non-parquet files so Filestash previews have something to render.
    sample = make_day(start, 200, rng)
    container.upload_blob("raw/sample.csv", sample.write_csv().encode(), overwrite=True)
    container.upload_blob(
        "raw/sample.json", sample.write_json().encode(), overwrite=True
    )
    container.upload_blob(
        "raw/README.txt",
        b"Seeded by `make seed`. Parquet lives under events/dt=YYYY-MM-DD/.\n",
        overwrite=True,
    )

    console.print(f"\n[green]seeded[/] {total:,} rows across {args.days} days")


if __name__ == "__main__":
    main()
