#!/usr/bin/env python3
"""Decode the game's .sav files into human-readable text.

Both formats are little-endian, header-less binary dumps written by the game:

  player.sav  - one PlayerSave struct (src/main.zig): 5 f32 = x, y, z, yaw, pitch
  world.sav   - block edits (World.serialize, src/world.zig): a flat list of
                chunk records, each:
                    i32 x, i32 y, i32 z      chunk coordinate
                    u32 count                number of edited blocks
                    count * (u16 index,      linear block index within the chunk
                             u16 block_id)    BlockId (see below)

Usage:
    tools/decode_sav.py [path ...]        # defaults to player.sav world.sav
"""

import struct
import sys

# Mirror of BlockId in src/block.zig (enum(u16), declaration order = value).
BLOCKS = ["air", "stone", "dirt", "grass", "sand", "water"]


def block_name(bid):
    return BLOCKS[bid] if 0 <= bid < len(BLOCKS) else f"?{bid}"


def decode_player(data):
    if len(data) < 20:
        return f"  too short: {len(data)} bytes (expected >= 20)"
    x, y, z, yaw, pitch = struct.unpack_from("<5f", data)
    return (
        f"  pos   = ({x:.3f}, {y:.3f}, {z:.3f})   (feet)\n"
        f"  yaw   = {yaw:.4f} rad\n"
        f"  pitch = {pitch:.4f} rad"
    )


def decode_world(data):
    out = []
    i = 0
    while i + 16 <= len(data):
        cx, cy, cz, count = struct.unpack_from("<iiiI", data, i)
        i += 16
        edits = []
        n = 0
        while n < count and i + 4 <= len(data):
            idx, bid = struct.unpack_from("<HH", data, i)
            i += 4
            edits.append((idx, bid))
            n += 1
        out.append(f"  chunk ({cx}, {cy}, {cz}) - {count} edit(s):")
        for idx, bid in edits:
            out.append(f"    index {idx:>5} -> {block_name(bid)}")
    if i != len(data):
        out.append(f"  (warning: {len(data) - i} trailing byte(s) undecoded)")
    return "\n".join(out) if out else "  (no edits)"


def main(argv):
    paths = argv[1:] or ["player.sav", "world.sav"]
    for path in paths:
        try:
            data = open(path, "rb").read()
        except OSError as e:
            print(f"{path}: {e}\n")
            continue
        print(f"{path} ({len(data)} bytes):")
        if path.endswith("player.sav"):
            print(decode_player(data))
        elif path.endswith("world.sav"):
            print(decode_world(data))
        else:
            print("  unknown save type (name must end in player.sav or world.sav)")
        print()


if __name__ == "__main__":
    main(sys.argv)
