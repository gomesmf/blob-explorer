"""Filesystem-style view of a blob container, via fsspec/adlfs.

Blob storage is a flat namespace; adlfs turns `/`-delimited names into
directories, which is the same trick every good blob browser uses.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from adlfs import AzureBlobFileSystem
from rich.console import Console
from rich.tree import Tree

from .config import CONNECTION_STRING, CONTAINER

console = Console()


def human(size: int) -> str:
    value = float(size)
    for unit in ("B", "KB", "MB", "GB"):
        if value < 1024 or unit == "GB":
            return f"{value:,.0f} {unit}" if unit == "B" else f"{value:,.1f} {unit}"
        value /= 1024
    return f"{value:.1f} GB"


def build(fs: AzureBlobFileSystem, path: str, node: Tree) -> tuple[int, int]:
    files = bytes_ = 0
    for entry in sorted(fs.ls(path, detail=True), key=lambda e: e["name"]):
        name = entry["name"].rstrip("/").rsplit("/", 1)[-1]
        if entry["type"] == "directory":
            child = node.add(f"[bold cyan]{name}/[/]")
            sub_files, sub_bytes = build(fs, entry["name"], child)
            files += sub_files
            bytes_ += sub_bytes
        else:
            size = entry.get("size") or 0
            node.add(f"{name}  [dim]{human(size)}[/]")
            files += 1
            bytes_ += size
    return files, bytes_


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", nargs="?", default=CONTAINER, help="container[/prefix]")
    parser.add_argument("--download", metavar="DEST", help="mirror the path into DEST")
    args = parser.parse_args()

    fs = AzureBlobFileSystem(connection_string=CONNECTION_STRING)

    if args.download:
        dest = Path(args.download)
        dest.mkdir(parents=True, exist_ok=True)
        fs.get(args.path.rstrip("/") + "/", str(dest), recursive=True)
        console.print(f"[green]downloaded[/] {args.path} -> {dest}")
        return

    tree = Tree(f"[bold]az://{args.path}[/]")
    files, bytes_ = build(fs, args.path, tree)
    console.print(tree)
    console.print(f"\n{files} files, {human(bytes_)}")


if __name__ == "__main__":
    main()
