"""Packs Mochi's icons for Windows (stdlib only; macOS's `sips` resizes).

- windows/runner/resources/app_icon.ico: the iPhone app's icon (iOS/MochiPocket/.../AppIcon-1024.png) at 16-256 px.
- assets/tray/tray_icon.ico and tray_icon.png: Mochi's face drawn by mochi_art (tool/render_tray_icons_test.dart writes
  build/tray_icons/ first).

    flutter test tool/render_tray_icons_test.dart && python3 tool/make_icons.py

ICO entries are PNG-compressed (supported by Windows since Vista, including LoadImage for tray icons).
"""

import pathlib
import shutil
import struct
import subprocess
import tempfile

APP = pathlib.Path(__file__).resolve().parent.parent
REPO = APP.parent.parent.parent
IOS_ICON = REPO / "iOS/MochiPocket/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"


def ico(pngs: list[tuple[int, bytes]]) -> bytes:
    header = struct.pack("<HHH", 0, 1, len(pngs))
    entries = b""
    data = b""
    offset = 6 + 16 * len(pngs)
    for size, png in pngs:
        dimension = 0 if size >= 256 else size
        entries += struct.pack("<BBBBHHII", dimension, dimension, 0, 0, 1, 32, len(png), offset + len(data))
        data += png
    return header + entries + data


def resized(source: pathlib.Path, size: int, folder: pathlib.Path) -> bytes:
    target = folder / f"{size}.png"
    subprocess.run(["sips", "-s", "format", "png", "-z", str(size), str(size), str(source), "--out", str(target)],
                   check=True, capture_output=True)
    return target.read_bytes()


def main() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        folder = pathlib.Path(temporary)
        app_icon = ico([(size, resized(IOS_ICON, size, folder)) for size in (16, 24, 32, 48, 64, 128, 256)])
    (APP / "windows/runner/resources/app_icon.ico").write_bytes(app_icon)

    rendered = APP / "build/tray_icons"
    tray = ico([(size, (rendered / f"tray_{size}.png").read_bytes()) for size in (16, 20, 24, 32, 40, 48, 64, 256)])
    (APP / "assets/tray").mkdir(parents=True, exist_ok=True)
    (APP / "assets/tray/tray_icon.ico").write_bytes(tray)
    # The macOS menu bar: 18 pt at 2x.
    shutil.copy(rendered / "tray_36.png", APP / "assets/tray/tray_icon.png")
    print("app_icon.ico, tray_icon.ico, tray_icon.png written")


if __name__ == "__main__":
    main()
