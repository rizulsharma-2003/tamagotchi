#!/usr/bin/env python3
"""Builds the Live Activity animation fonts from rendered frames (needs fontTools).

Live Activities can't run animations, but a live timer can tick in any font. Each font here maps the
digits 0–9 to ten colour bitmap frames (an `sbix` table, like Apple Color Emoji), so a timer's last
digit — the seconds — shows the next frame every second.

usage: make_anim_fonts.py <frames dir> <output dir>
  frames: scene-<phase>-<0…9>.png (420×216, 3x) and sprite-<phase>-<0…9>.png (102×90), each with a
          .runs.json silhouette. The silhouette becomes the glyph's outline, so a renderer that doesn't
          draw colour bitmaps still shows the animation as a shape.
"""
import json
import pathlib
import struct
import sys

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import newTable
from fontTools.ttLib.tables.sbixGlyph import Glyph
from fontTools.ttLib.tables.sbixStrike import Strike

PHASES = ["working", "waiting", "done", "error", "idle", "asleep"]
DIGITS = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
UPM = 1000


def png_size(data):
    width, height = struct.unpack(">II", data[16:24])
    return width, height


def build(kind, phase, frames_dir, out_dir):
    frames = [(frames_dir / f"{kind}-{phase}-{k}.png").read_bytes() for k in range(10)]
    width, height = png_size(frames[0])
    advance = round(UPM * width / height)
    name = f"Mochi{kind.capitalize()}-{phase}"
    order = [".notdef", "space", "colon"] + DIGITS
    fb = FontBuilder(UPM, isTTF=True)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap({0x20: "space", 0x3A: "colon", **{0x30 + k: DIGITS[k] for k in range(10)}})
    empty = TTGlyphPen(None).glyph()
    glyphs = {glyph: empty for glyph in order}
    for k in range(10):
        shape = json.loads((frames_dir / f"{kind}-{phase}-{k}.runs.json").read_text())
        cell = UPM / shape["rows"]
        pen = TTGlyphPen(None)
        for row, first, last in shape["runs"]:
            bottom = round((shape["rows"] - 1 - row) * cell)
            top = round((shape["rows"] - row) * cell)
            left, right = round(first * cell), round((last + 1) * cell)
            # Clockwise, as TrueType fills.
            pen.moveTo((left, bottom))
            pen.lineTo((left, top))
            pen.lineTo((right, top))
            pen.lineTo((right, bottom))
            pen.closePath()
        glyphs[DIGITS[k]] = pen.glyph()
    fb.setupGlyf(glyphs)
    fb.setupHorizontalMetrics({".notdef": (0, 0), "space": (0, 0), "colon": (0, 0), **{d: (advance, 0) for d in DIGITS}})
    fb.setupHorizontalHeader(ascent=UPM, descent=0)
    fb.setupNameTable({"familyName": name, "styleName": "Regular", "uniqueFontIdentifier": name,
                       "fullName": name, "psName": name, "version": "Version 1.0"})
    fb.setupOS2(sTypoAscender=UPM, sTypoDescender=0, sTypoLineGap=0, usWinAscent=UPM, usWinDescent=0,
                sxHeight=UPM // 2, sCapHeight=UPM)
    fb.setupPost()
    sbix = newTable("sbix")
    sbix.version = 1
    sbix.flags = 1
    strike = Strike(ppem=height, resolution=72)
    for k, data in enumerate(frames):
        strike.glyphs[DIGITS[k]] = Glyph(glyphName=DIGITS[k], graphicType="png ", imageData=data, originOffsetX=0, originOffsetY=0)
    sbix.strikes = {height: strike}
    fb.font["sbix"] = sbix
    path = out_dir / f"{name}.ttf"
    fb.save(str(path))
    return path, width, height


def main():
    frames_dir, out_dir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)
    for phase in PHASES:
        for kind in ("scene", "sprite"):
            path, width, height = build(kind, phase, frames_dir, out_dir)
            print(f"{path.name}: {width}×{height} frames, {path.stat().st_size // 1024} KB")


main()
