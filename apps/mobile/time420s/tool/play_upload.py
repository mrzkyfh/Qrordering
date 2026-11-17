#!/usr/bin/env python3
"""Upload AAB ke Google Play & rilis ke sebuah track — via Play Developer API.

Dipakai oleh release.sh, tapi bisa dijalankan langsung:
    python3 tool/play_upload.py --track internal
    python3 tool/play_upload.py --track production --status draft --notes "Perbaikan bug"

Syarat:
  - Kunci service account JSON (default: android/play-service-account.json;
    bisa di-override lewat env PLAY_JSON atau argumen --json).
  - Aplikasi sudah pernah rilis manual MINIMAL SEKALI lewat Play Console
    (aturan Google — upload API pertama akan ditolak bila belum).
"""
import argparse
import os
import socket
import sys
import warnings

# Redam FutureWarning dari google-auth soal Python 3.9 EOL agar output rilis rapi.
warnings.simplefilter("ignore", FutureWarning)

try:
    from google.oauth2 import service_account
    from googleapiclient.discovery import build
    from googleapiclient.http import MediaFileUpload
    from googleapiclient.errors import HttpError
except ImportError:
    sys.exit(
        "Dependency Python belum ada.\n"
        "Jalankan lewat ./release.sh (otomatis setup), atau manual:\n"
        "  python3 -m pip install google-api-python-client google-auth"
    )

PACKAGE = "com.time420s.pos"
SCOPES = ["https://www.googleapis.com/auth/androidpublisher"]
DEFAULT_AAB = "build/app/outputs/bundle/release/app-release.aab"
DEFAULT_JSON = "android/play-service-account.json"
UPLOAD_TIMEOUT_SECONDS = 300
UPLOAD_RETRIES = 5
UPLOAD_CHUNK_SIZE = 5 * 1024 * 1024


def main() -> None:
    # AAB cukup besar. Timeout bawaan koneksi terlalu pendek pada jaringan
    # outlet dan dapat putus setelah edit dibuat tetapi sebelum bundle masuk.
    socket.setdefaulttimeout(UPLOAD_TIMEOUT_SECONDS)

    p = argparse.ArgumentParser(description="Upload & rilis AAB ke Google Play.")
    p.add_argument("--track", default="internal",
                   help="internal | alpha | beta | production (default: internal)")
    p.add_argument("--status", default="completed",
                   help="completed | draft | inProgress (default: completed)")
    p.add_argument("--aab", default=os.environ.get("PLAY_AAB", DEFAULT_AAB))
    p.add_argument("--json", default=os.environ.get("PLAY_JSON", DEFAULT_JSON))
    p.add_argument("--notes", default=None, help="Catatan rilis (bahasa id-ID)")
    args = p.parse_args()

    if not os.path.exists(args.aab):
        sys.exit(f"AAB tidak ditemukan: {args.aab}\n"
                 f"Build dulu: flutter build appbundle --release")
    if not os.path.exists(args.json):
        sys.exit(f"Kunci service account tidak ditemukan: {args.json}\n"
                 f"Taruh file JSON dari Google Cloud di lokasi itu "
                 f"(atau set env PLAY_JSON).")

    creds = service_account.Credentials.from_service_account_file(
        args.json, scopes=SCOPES)
    service = build("androidpublisher", "v3", credentials=creds,
                    cache_discovery=False)
    edits = service.edits()

    edit_id = edits.insert(
        packageName=PACKAGE,
        body={},
    ).execute(num_retries=UPLOAD_RETRIES)["id"]
    print(f"• Edit dibuat: {edit_id}")
    try:
        media = MediaFileUpload(
            args.aab,
            mimetype="application/octet-stream",
            chunksize=UPLOAD_CHUNK_SIZE,
            resumable=True,
        )
        bundle = edits.bundles().upload(
            packageName=PACKAGE,
            editId=edit_id,
            media_body=media,
        ).execute(num_retries=UPLOAD_RETRIES)
        version_code = bundle["versionCode"]
        print(f"• AAB terunggah — versionCode {version_code}")

        release = {"versionCodes": [str(version_code)], "status": args.status}
        if args.notes:
            release["releaseNotes"] = [{"language": "id-ID", "text": args.notes}]
        edits.tracks().update(
            packageName=PACKAGE, editId=edit_id, track=args.track,
            body={"track": args.track, "releases": [release]},
        ).execute(num_retries=UPLOAD_RETRIES)
        print(f"• Ditugaskan ke track '{args.track}' (status: {args.status})")

        edits.commit(
            packageName=PACKAGE,
            editId=edit_id,
        ).execute(num_retries=UPLOAD_RETRIES)
        print(f"✓ Rilis terkirim ke Google Play (track {args.track}).")
    except Exception as e:
        # Batalkan edit yang gagal agar tidak menggantung.
        try:
            edits.delete(
                packageName=PACKAGE,
                editId=edit_id,
            ).execute(num_retries=UPLOAD_RETRIES)
        except Exception:
            pass
        if isinstance(e, HttpError):
            sys.exit(f"Gagal upload/rilis: {e}")
        sys.exit(f"Gagal upload/rilis karena koneksi: {e}")


if __name__ == "__main__":
    main()
