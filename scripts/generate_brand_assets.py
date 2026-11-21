from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parents[1]
ASSET_DIR = ROOT / "assets" / "images"
# The tracked source logo placed by the project owner.
SOURCE = ROOT / "cirrus_icon_source.png"
ANDROID_RES = ROOT / "android" / "app" / "src" / "main" / "res"
WINDOWS_ICON = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"
LAUNCHER_SIZES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}
# Brand accent — keep in sync with lib/brand.dart kCirrusBlue.
BRAND_BG = (0x1F, 0x4E, 0x79, 255)


def contain(image: Image.Image, box: int, fraction: float) -> Image.Image:
    """Fit image inside a square canvas, scaled to `fraction` of the box."""
    source = image.convert("RGBA")
    inner = max(1, int(box * fraction))
    fitted = ImageOps.contain(source, (inner, inner), method=Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", (box, box), (0, 0, 0, 0))
    canvas.alpha_composite(fitted, ((box - fitted.width) // 2, (box - fitted.height) // 2))
    return canvas


def main() -> None:
    if not SOURCE.is_file():
        raise FileNotFoundError(f"Brand source missing: {SOURCE}")
    with Image.open(SOURCE) as im:
        im.load()
        source = im.convert("RGBA")
    print(f"Brand source: {SOURCE.relative_to(ROOT)} ({source.width}x{source.height})")

    ASSET_DIR.mkdir(parents=True, exist_ok=True)
    # In-app artwork used by pubspec + cirrus_mark.dart.
    contain(source, 512, 0.94).convert("RGB").save(
        ASSET_DIR / "cirrus_icon.jpg", quality=92
    )
    # Optimized PNG copy of the same artwork.
    contain(source, 512, 0.94).save(ASSET_DIR / "cirrus_logo.png", format="PNG", optimize=True)
    # Root icon for CI/external references.
    contain(source, 512, 0.94).save(ROOT / "cirrus_icon.png", format="PNG", optimize=True)

    nodpi = ANDROID_RES / "drawable-nodpi"
    nodpi.mkdir(parents=True, exist_ok=True)
    contain(source, 512, 0.94).save(nodpi / "cirrus_icon.png", format="PNG", optimize=True)

    drawable = ANDROID_RES / "drawable"
    drawable.mkdir(parents=True, exist_ok=True)
    # Adaptive-icon foreground (432px canvas, icon ~68% inside safe zone).
    contain(source, 432, 0.68).save(
        drawable / "ic_cirrus_foreground_image.png", format="PNG", optimize=True
    )
    contain(source, 432, 0.68).save(
        drawable / "ic_launcher_foreground.png", format="PNG", optimize=True
    )
    contain(source, 432, 0.94).save(
        drawable / "ic_launcher_full_432.png", format="PNG", optimize=True
    )
    Image.new("RGBA", (432, 432), BRAND_BG).save(
        drawable / "ic_launcher_background.png", format="PNG", optimize=True
    )

    for folder, size in LAUNCHER_SIZES.items():
        target = ANDROID_RES / folder
        target.mkdir(parents=True, exist_ok=True)
        contain(source, size, 0.70).save(target / "ic_launcher.png", format="PNG", optimize=True)
        print(f"Android icon {folder}: {size}x{size}")

    WINDOWS_ICON.parent.mkdir(parents=True, exist_ok=True)
    contain(source, 256, 0.78).convert("RGB").save(
        WINDOWS_ICON,
        format="ICO",
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )
    print("Windows EXE icon: multi-size ICO generated")

    print("Done — Cirrus brand assets regenerated from cirrus_icon_source.png")


if __name__ == "__main__":
    main()
