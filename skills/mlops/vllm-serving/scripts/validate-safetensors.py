#!/usr/bin/env python3
"""
validate-safetensors.py — Validate safetensor model shard integrity.

Reads the header of each .safetensors file in the target directory, parses
the tensor metadata, and checks that the file size covers all declared data
offsets. Reports OK, TRUNCATED, or CORRUPT per file.

Usage:
    python3 validate-safetensors.py [directory]
    python3 validate-safetensors.py /mnt/chubee-data/super-weights/Qwen2.5-32B-Instruct-GPTQ-Int4

When directory is omitted, checks the current working directory.
"""

import os
import sys
import struct
import json


def validate_file(path: str) -> tuple[str, str, float | None]:
    """Validate a safetensor file. Returns (filename, status, size_gb)."""
    base = os.path.basename(path)
    try:
        sz = os.path.getsize(path)
    except OSError as e:
        return base, f"UNREADABLE ({e})", None

    if sz < 8:
        return base, "EMPTY", sz / 1e9 if sz else 0

    try:
        with open(path, "rb") as fh:
            header_len = struct.unpack("<Q", fh.read(8))[0]

            if header_len > 50_000_000:  # 50 MB sanity cap
                return base, f"HEADER TOO LARGE ({header_len / 1e6:.0f} MB)", sz / 1e9

            fh.seek(8)
            header_bytes = fh.read(header_len)
            if len(header_bytes) < header_len:
                return base, "HEADER TRUNCATED", sz / 1e9

            metadata = json.loads(header_bytes.decode("utf-8"))
    except json.JSONDecodeError as e:
        return base, f"INVALID JSON HEADER ({e})", sz / 1e9
    except struct.error as e:
        return base, f"HEADER READ FAILED ({e})", sz / 1e9
    except Exception as e:
        return base, f"CORRUPT ({e})", sz / 1e9

    # Calculate expected minimum file size from tensor data_offsets
    expected_min = header_len + 8  # header + length field
    tensor_count = 0
    for name, info in metadata.items():
        if name == "metadata":
            continue
        tensor_count += 1
        offsets = info.get("data_offsets", [0, 0])
        expected_min = max(expected_min, offsets[1] + 8)  # +8 for trailing metadata

    if sz >= expected_min - 8:
        return base, "OK", sz / 1e9
    else:
        return base, f"TRUNCATED (needs ≥{expected_min / 1e9:.1f}GB, has {sz / 1e9:.1f}GB)", sz / 1e9


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else "."
    if not os.path.isdir(target):
        print(f"Error: '{target}' is not a directory")
        sys.exit(1)

    files = sorted(
        f for f in os.listdir(target)
        if f.endswith(".safetensors") and not f.endswith(".aria2")
    )

    if not files:
        print(f"No .safetensors files found in '{target}'")
        sys.exit(0)

    print(f"Validating {len(files)} file(s) in '{target}'")
    print()

    ok = truncated = corrupt = 0
    for fname in files:
        path = os.path.join(target, fname)
        name, status, size = validate_file(path)
        size_str = f"({size:.1f}GB)" if size is not None else ""
        if status == "OK":
            print(f"  ✓ {name}: {status} {size_str}")
            ok += 1
        elif status.startswith("TRUNCATED"):
            print(f"  ✗ {name}: {status}")
            truncated += 1
        else:
            print(f"  ✗ {name}: {status}")
            corrupt += 1

    print()
    print(f"Results: {ok} OK, {truncated} truncated, {corrupt} corrupt")
    sys.exit(1 if truncated or corrupt else 0)


if __name__ == "__main__":
    main()