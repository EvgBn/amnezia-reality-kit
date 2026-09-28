#!/usr/bin/env python3
"""Remove a [Peer] block from an AmneziaWG server config.

Match by (first hit wins):
  1. AWG_CLIENT_PUBKEY — PublicKey line inside the peer block
  2. AWG_CLIENT — ``# <name>`` comment immediately after [Peer]

Env: AWG_CONF (required), AWG_CLIENT and/or AWG_CLIENT_PUBKEY.
Exit codes: 0 removed, 3 peer not found.
"""
import os
import re
import sys


def peer_blocks(text: str) -> list[tuple[int, int, list[str]]]:
    """Return (start, end, lines) for each [Peer] block."""
    lines = text.splitlines(keepends=True)
    blocks: list[tuple[int, int, list[str]]] = []
    i = 0
    while i < len(lines):
        if lines[i].rstrip("\n") == "[Peer]":
            start = i
            block = [lines[i]]
            i += 1
            while i < len(lines) and not lines[i].startswith("[Peer]") and not (
                lines[i].startswith("[") and lines[i].rstrip("\n") != "[Peer]"
            ):
                if lines[i].startswith("[") and lines[i].rstrip("\n") != "[Peer]":
                    break
                block.append(lines[i])
                i += 1
            blocks.append((start, i, block))
        else:
            i += 1
    return blocks


def block_matches(block: list[str], client: str | None, pubkey: str | None) -> bool:
    body = "".join(block)
    if pubkey and f"PublicKey = {pubkey}\n" in body:
        return True
    if client:
        pattern = re.compile(r"^\[Peer\]\n# " + re.escape(client) + r"\n", re.MULTILINE)
        if pattern.search("".join(block)):
            return True
    return False


def main() -> int:
    conf = os.environ.get("AWG_CONF")
    if not conf:
        print("AWG_CONF is required", file=sys.stderr)
        return 2

    client = os.environ.get("AWG_CLIENT")
    pubkey = os.environ.get("AWG_CLIENT_PUBKEY")
    if not client and not pubkey:
        print("AWG_CLIENT and/or AWG_CLIENT_PUBKEY is required", file=sys.stderr)
        return 2

    with open(conf, encoding="utf-8") as f:
        text = f.read()

    blocks = peer_blocks(text)
    remove_ranges: list[tuple[int, int]] = []
    for start, end, block in blocks:
        if block_matches(block, client, pubkey):
            remove_ranges.append((start, end))

    if not remove_ranges:
        return 3

    lines = text.splitlines(keepends=True)
    for start, end in sorted(remove_ranges, reverse=True):
        del lines[start:end]

    new_text = "".join(lines)
    new_text = re.sub(r"\n{3,}", "\n\n", new_text).rstrip() + "\n"

    # In-place write preserves the inode so a running :ro bind-mounted container
    # still sees updates (os.replace would leave the mount on a stale unlinked file).
    with open(conf, "r+", encoding="utf-8") as f:
        f.seek(0)
        f.write(new_text)
        f.truncate()
        f.flush()
        os.fsync(f.fileno())

    return 0


if __name__ == "__main__":
    sys.exit(main())
