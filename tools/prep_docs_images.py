#!/usr/bin/env python3
"""Re-encode the README screenshots so the repository stays small.

Source files live outside the tree (they are straight off the phones / the
LuCI page).  Run this after replacing a screenshot:

    python tools/prep_docs_images.py [--src R:/]

Only the JPEG quality changes; resolution is kept, because these are text
screenshots and downscaling them makes the numbers unreadable.
"""

import argparse
import os
import sys

from PIL import Image

IMAGES = [
    ("luci.jpeg", "docs/img/luci.jpg", 85),
    ("带0.jpg", "docs/img/band0.jpg", 86),
    ("带2.jpg", "docs/img/band2.jpg", 86),
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default="R:/", help="directory holding the source images")
    ap.add_argument("--out", default="docs/img", help="output directory")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    for src_name, dst_name, quality in IMAGES:
        src = os.path.join(args.src, src_name)
        dst = os.path.join(args.out, os.path.basename(dst_name))
        if not os.path.exists(src):
            print("missing: %s" % src, file=sys.stderr)
            return 1
        with Image.open(src) as im:
            im = im.convert("RGB")
            im.save(dst, "JPEG", quality=quality, optimize=True, progressive=True)
            print("%-12s %4dx%-4d -> %-22s %6.1f kB"
                  % (src_name, im.width, im.height, dst, os.path.getsize(dst) / 1024.0))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
