#!/usr/bin/env python3
"""Mask CFA/Bayer metadata inside XISF files without changing file length.

PixInsight's masterLight XISF still carries BAYERPAT and PCL:CFASourcePattern,
which makes WBPP re-demosaic already-debayered RGB masters. This tool replaces
those XML elements with same-length XML comments so WBPP classifies the file
as RGB and skips the Debayer step.
"""

import re
import sys


PATTERNS = [
    re.compile(rb"<FITSKeyword name=\"BAYERPAT\".*?/>", re.S),
    re.compile(rb"<Property id=\"PCL:CFASourcePattern\".*?</Property>", re.S),
]


def mask_xisf(path: str) -> int:
    with open(path, "rb") as fh:
        data = fh.read()

    matches = []
    for pat in PATTERNS:
        matches.extend((m.start(), m.end()) for m in pat.finditer(data))

    if not matches:
        print(f"{path}: no CFA metadata to mask")
        return 0

    matches.sort(reverse=True)
    for start, end in matches:
        seg = data[start:end]
        repl = b"<!--" + b" " * (len(seg) - 7) + b"-->"
        assert len(repl) == len(seg)
        data = data[:start] + repl + data[end:]

    with open(path, "wb") as fh:
        fh.write(data)

    print(f"{path}: masked {len(matches)} CFA element(s)")
    return len(matches)


def main() -> None:
    if len(sys.argv) < 2:
        print("usage: strip_cfa_xisf.py <file.xisf> [more.xisf ...]")
        sys.exit(2)
    total = 0
    for path in sys.argv[1:]:
        total += mask_xisf(path)
    print(f"done: {total} element(s) masked")


if __name__ == "__main__":
    main()
