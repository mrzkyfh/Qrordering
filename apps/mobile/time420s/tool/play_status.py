#!/usr/bin/env python3
"""Tampilkan status track Google Play tanpa mengubah rilis."""

import os
import sys
import warnings

warnings.simplefilter("ignore", FutureWarning)

try:
    from google.oauth2 import service_account
    from googleapiclient.discovery import build
except ImportError:
    sys.exit("Jalankan melalui tool/.venv/bin/python.")

PACKAGE = "com.time420s.pos"
SCOPES = ["https://www.googleapis.com/auth/androidpublisher"]
DEFAULT_JSON = "android/play-service-account.json"


def main() -> None:
    key_file = os.environ.get("PLAY_JSON", DEFAULT_JSON)
    if not os.path.exists(key_file):
        sys.exit(f"Kunci service account tidak ditemukan: {key_file}")

    credentials = service_account.Credentials.from_service_account_file(
        key_file,
        scopes=SCOPES,
    )
    service = build(
        "androidpublisher",
        "v3",
        credentials=credentials,
        cache_discovery=False,
    )
    edits = service.edits()
    edit_id = edits.insert(packageName=PACKAGE, body={}).execute(
        num_retries=3,
    )["id"]
    try:
        tracks = edits.tracks().list(
            packageName=PACKAGE,
            editId=edit_id,
        ).execute(num_retries=3)
        for track in tracks.get("tracks", []):
            releases = track.get("releases", [])
            if not releases:
                continue
            for release in releases:
                versions = ",".join(release.get("versionCodes", [])) or "-"
                status = release.get("status", "-")
                fraction = release.get("userFraction")
                suffix = f", fraction={fraction}" if fraction is not None else ""
                print(
                    f"{track.get('track', '-')}: "
                    f"status={status}, versionCodes={versions}{suffix}"
                )
    finally:
        edits.delete(
            packageName=PACKAGE,
            editId=edit_id,
        ).execute(num_retries=3)


if __name__ == "__main__":
    main()
