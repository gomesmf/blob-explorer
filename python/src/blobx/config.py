"""Shared configuration, read from the repo-root .env or the environment."""

from __future__ import annotations

import os
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]

DEFAULT_CONNECTION_STRING = (
    "DefaultEndpointsProtocol=http;"
    "AccountName=devstoreaccount1;"
    "AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/"
    "K1SZFPTOtr/KBHBeksoGMGw==;"
    "BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1;"
)


def _load_dotenv() -> None:
    """Populate os.environ from .env without pulling in python-dotenv.

    Values already in the environment win, so `FOO=x uv run ...` still works.
    """
    env_file = REPO_ROOT / ".env"
    if not env_file.exists():
        return
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip())


_load_dotenv()

CONNECTION_STRING = os.environ.get(
    "AZURE_STORAGE_CONNECTION_STRING", DEFAULT_CONNECTION_STRING
)
CONTAINER = os.environ.get("BLOB_CONTAINER", "data")
EVENTS_GLOB = f"az://{CONTAINER}/events/**/*.parquet"
