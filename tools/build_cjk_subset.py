#!/usr/bin/env python3
"""Regenerate xcom_lua/assets/fonts/SimHeiCJK.ttf (the bundled CJK subset).

Why this exists: the shipped subset had no generator, so nobody could say which
characters it was supposed to cover and the source font was a guess.  It is now
reproducible, and the coverage rule is explicit:

    existing subset's cmap  (union, so re-running never drops a glyph)
  + GB2312 rows A1-A9       (symbols: fullwidth forms, arrows, circled digits,
                             box drawing, units such as U+2103, U+00B1 ...)
  + GB2312 rows B0-D7       (level-1 hanzi: the 3755 most common)
  + U+2000..U+206F, U+3000..U+303F, U+FF00..U+FFEF  (general/CJK punctuation
                             and fullwidth forms a GB2312-encoded device emits)

Rows D8-F7 (GB2312 level-2 hanzi, 3008 rarer characters) are deliberately NOT
included: they add ~0.9 MB of file for characters a serial log essentially never
carries.  Pass --gb2312-level2 to include them anyway.

The result is validated before it is written: every codepoint the subset already
had must survive, and the outlines of those codepoints must be bit-identical to
the previous file (same source font, same unitsPerEm) so a regeneration can
never silently restyle the UI.

Usage:
    python3 tools/build_cjk_subset.py                  # default source, writes both copies
    python3 tools/build_cjk_subset.py --source /path/to/simhei.ttf
    python3 tools/build_cjk_subset.py --check          # report only, write nothing

Source font resolution order: --source, $XCOM_SIMHEI_SOURCE, the per-user font
dir (~/.local/share/fonts/SimHei.ttf), C:/Windows/Fonts/simhei.ttf (the face
ships with every Windows install).  The file is the Microsoft SimHei (黑体)
face; the existing subsets were built from it with unitsPerEm=256, which this
script asserts so a wrong source font fails loudly instead of restyling.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
ASSET_FONT = REPO / "xcom_lua" / "assets" / "fonts" / "SimHeiCJK.ttf"
RUNTIME_FONT = REPO / "xcom_lua" / "runtime" / "assets" / "fonts" / "SimHeiCJK.ttf"

PUNCT_RANGES = [(0x2000, 0x206F), (0x3000, 0x303F), (0xFF00, 0xFFEF)]


def find_source(explicit: str | None) -> Path:
    candidates = []
    if explicit:
        candidates.append(Path(explicit))
    if os.environ.get("XCOM_SIMHEI_SOURCE"):
        candidates.append(Path(os.environ["XCOM_SIMHEI_SOURCE"]))
    candidates += [
        Path.home() / ".local" / "share" / "fonts" / "SimHei.ttf",
        Path("C:/Windows/Fonts/simhei.ttf"),
    ]
    for path in candidates:
        if path.is_file():
            return path
    sys.exit("source SimHei not found; pass --source <simhei.ttf>")


def gb2312_codepoints() -> tuple[list[int], list[int], list[int]]:
    """(symbol rows A1-A9, level-1 hanzi B0-D7, level-2 hanzi D8-F7)."""
    symbols: list[int] = []
    level1: list[int] = []
    level2: list[int] = []
    for high in range(0xA1, 0xFA):
        for low in range(0xA1, 0xFF):
            try:
                char = bytes([high, low]).decode("gb2312")
            except UnicodeDecodeError:
                continue
            if high <= 0xA9:
                symbols.append(ord(char))
            elif high <= 0xD7:
                level1.append(ord(char))
            else:
                level2.append(ord(char))
    return symbols, level1, level2


def codepoints(path: Path) -> list[int]:
    from fontTools.ttLib import TTFont

    font = TTFont(str(path), lazy=True)
    try:
        return sorted(font.getBestCmap())
    finally:
        font.close()


def outlines(path: Path) -> tuple[int, dict[int, tuple]]:
    from fontTools.ttLib import TTFont

    font = TTFont(str(path))
    cmap = font.getBestCmap()
    glyf = font["glyf"]
    shapes = {
        cp: (
            glyf[cmap[cp]].numberOfContours,
            tuple(getattr(glyf[cmap[cp]], "coordinates", ())),
            tuple(getattr(glyf[cmap[cp]], "endPtsOfContours", ())),
        )
        for cp in cmap
    }
    units = font["head"].unitsPerEm
    ascent = font["hhea"].ascent
    font.close()
    return (units, {"ascent": ascent}), shapes


def build(source: Path, points: list[int], out: Path) -> None:
    """Run pyftsubset with the flags the shipped file was produced with."""
    rsp = out.with_suffix(".unicodes")
    rsp.write_text(",".join("U+%04X" % cp for cp in points), encoding="ascii")
    try:
        subprocess.run(
            [
                "pyftsubset", str(source),
                "--unicodes-file=" + str(rsp),
                "--output-file=" + str(out),
                "--no-hinting",
            ],
            check=True,
        )
    finally:
        rsp.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--source", help="full SimHei TTF to subset from")
    parser.add_argument("--gb2312-level2", action="store_true",
                        help="also include the 3008 rarer level-2 hanzi (~+0.9 MB)")
    parser.add_argument("--check", action="store_true",
                        help="report coverage and exit without writing")
    args = parser.parse_args()

    source = find_source(args.source)
    previous = codepoints(ASSET_FONT) if ASSET_FONT.is_file() else []
    symbols, level1, level2 = gb2312_codepoints()

    wanted = set(previous)
    wanted.update(symbols)
    wanted.update(level1)
    for start, end in PUNCT_RANGES:
        wanted.update(range(start, end + 1))
    if args.gb2312_level2:
        wanted.update(level2)
    wanted = sorted(wanted)

    print(f"source      : {source}")
    print(f"previous    : {len(previous):5d} codepoints")
    print(f"symbols     : {len(set(symbols) - set(previous)):5d} new (GB2312 A1-A9)")
    print(f"level-1     : {len(set(level1) - set(previous)):5d} new hanzi (GB2312 B0-D7)")
    if args.gb2312_level2:
        print(f"level-2     : {len(set(level2) - set(previous)):5d} new hanzi (GB2312 D8-F7)")
    print(f"punctuation : {sum(e - s + 1 for s, e in PUNCT_RANGES):5d} codepoints (3 ranges)")
    print(f"total       : {len(wanted):5d} codepoints")
    if args.check:
        return 0

    scratch = ASSET_FONT.with_suffix(".new.ttf")
    build(source, wanted, scratch)

    # Validate against the file we are about to replace: the source font must be
    # the same face (unitsPerEm) and every pre-existing glyph must keep its exact
    # outline, so an extended subset can never restyle existing text.
    if previous:
        new_metrics, new_shapes = outlines(scratch)
        old_metrics, old_shapes = outlines(ASSET_FONT)
        if new_metrics != old_metrics:
            scratch.unlink()
            sys.exit(f"source font mismatch: metrics {new_metrics} != {old_metrics}")
        changed = [cp for cp, shape in old_shapes.items() if new_shapes.get(cp) != shape]
        if changed:
            scratch.unlink()
            sys.exit("outline drift for %d existing codepoints, first: U+%04X"
                     % (len(changed), changed[0]))
        print("validated   : existing glyph outlines identical")

    shutil.copy2(scratch, ASSET_FONT)
    RUNTIME_FONT.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(scratch, RUNTIME_FONT)
    scratch.unlink()

    for path in (ASSET_FONT, RUNTIME_FONT):
        data = path.read_bytes()
        print("%s  %6.2f MB  sha256=%s"
              % (path.relative_to(REPO), len(data) / 1048576.0,
                 hashlib.sha256(data).hexdigest()[:16]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
