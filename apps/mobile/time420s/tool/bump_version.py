#!/usr/bin/env python3
"""Naikkan versi di pubspec.yaml + sinkron appBuild di app_config.dart.

Pemakaian:
    python3 tool/bump_version.py [patch|minor|major|build|none]

- patch  (default): 1.1.6+12 -> 1.1.7+13   (naikkan patch & versionCode)
- minor            : 1.1.6+12 -> 1.2.0+13
- major            : 1.1.6+12 -> 2.0.0+13
- build            : 1.1.6+12 -> 1.1.6+13   (versionCode saja, nama tetap)
- none             : tidak mengubah apa pun (hanya cetak versi sekarang)

versionCode (angka setelah '+') SELALU naik +1 kecuali 'none' — Google Play
menolak versionCode yang sama. Mencetak versi baru ke stdout.
"""
import re
import sys
from pathlib import Path

PUBSPEC = Path("pubspec.yaml")
APPCONFIG = Path("lib/core/config/app_config.dart")


def main() -> None:
    part = sys.argv[1] if len(sys.argv) > 1 else "patch"
    if part not in {"patch", "minor", "major", "build", "none"}:
        sys.exit(f"Bagian tidak dikenal: {part} (patch|minor|major|build|none)")

    text = PUBSPEC.read_text()
    m = re.search(r'^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)', text, re.M)
    if not m:
        sys.exit("Tidak menemukan baris 'version: X.Y.Z+B' di pubspec.yaml")
    major, minor, patch, build = map(int, m.groups())

    if part == "none":
        print(f"{major}.{minor}.{patch}+{build}")
        return

    build += 1  # versionCode selalu naik
    if part == "major":
        major, minor, patch = major + 1, 0, 0
    elif part == "minor":
        minor, patch = minor + 1, 0
    elif part == "patch":
        patch += 1
    # 'build' → nama versi tetap

    new_version = f"{major}.{minor}.{patch}+{build}"
    PUBSPEC.write_text(text.replace(m.group(0), f"version: {new_version}", 1))

    # Sinkronkan appBuild (dipakai server untuk memaksa update device lama).
    if APPCONFIG.exists():
        cfg = APPCONFIG.read_text()
        new_cfg = re.sub(r'appBuild\s*=\s*\d+', f'appBuild = {build}', cfg, count=1)
        if new_cfg != cfg:
            APPCONFIG.write_text(new_cfg)

    print(new_version)


if __name__ == "__main__":
    main()
