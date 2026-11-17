#!/usr/bin/env bash
#
# Default: delegasikan ke script root untuk bump + build AAB/APK tanpa upload.
# Upload Google Play hanya dilakukan jika PLAY_UPLOAD=1 diberikan eksplisit.
#
# Pemakaian:
#   ./release.sh                              # bump + build AAB dan APK
#   PLAY_UPLOAD=1 ./release.sh                # build + rilis track internal
#   PLAY_UPLOAD=1 ./release.sh production     # rilis production
#   PLAY_UPLOAD=1 ./release.sh production draft
#
# Versi dinaikkan OTOMATIS sebelum build (patch + versionCode). Atur lewat env:
#   BUMP=build ./release.sh          # naikkan versionCode saja (nama versi tetap)
#   BUMP=minor ./release.sh          # 1.1.6 -> 1.2.0
#   BUMP=none  ./release.sh          # jangan ubah versi (pakai isi pubspec apa adanya)
#
# Prasyarat (sekali saja):
#   - Taruh kunci service account di: android/play-service-account.json
#   - Aplikasi sudah pernah rilis manual sekali lewat Play Console.
#
set -euo pipefail
cd "$(dirname "$0")"

if [ "${PLAY_UPLOAD:-0}" != "1" ]; then
  exec ../../../release.sh "$@"
fi

TRACK="${1:-internal}"
STATUS="${2:-completed}"
VENV="tool/.venv"
JSON="${PLAY_JSON:-android/play-service-account.json}"
ENV_FILE="${ENV_FILE:-.env}"
SIGNING_PROPERTIES="android/key.properties"

# Environment aplikasi harus tersedia sebelum versi dinaikkan atau build dimulai.
# Flutter mengompilasi pasangan key/value ini ke dalam AAB/APK melalui
# --dart-define-from-file; isi nilainya sengaja tidak pernah dicetak ke log.
if [ ! -f "$ENV_FILE" ]; then
  echo "✗ File environment aplikasi tidak ada: $ENV_FILE"
  echo "  Salin .env.example ke .env, lalu isi nilainya."
  exit 1
fi

for key in SUPABASE_URL SUPABASE_ANON_KEY; do
  if ! awk -v wanted="$key" '
    /^[[:space:]]*(#|$)/ { next }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      split(line, pair, "=")
      name = pair[1]
      gsub(/[[:space:]]/, "", name)
      if (name != wanted) next

      sub(/^[^=]*=/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line != "" && line != "\"\"" && line != "\047\047") found = 1
    }
    END { exit(found ? 0 : 1) }
  ' "$ENV_FILE"; then
    echo "✗ $key belum diisi di $ENV_FILE"
    exit 1
  fi
done

echo "• Environment aplikasi: $ENV_FILE (key wajib tersedia)"

if [ ! -f "$SIGNING_PROPERTIES" ]; then
  echo "✗ Konfigurasi signing release tidak ada: $SIGNING_PROPERTIES"
  echo "  Buat key.properties yang menunjuk ke upload keystore Google Play."
  exit 1
fi

echo "• Konfigurasi signing release tersedia"

if [ ! -f "$JSON" ]; then
  echo "✗ Kunci service account tidak ada: $JSON"
  echo "  Taruh file JSON dari Google Cloud di sana, lalu ulangi."
  exit 1
fi

# 1. Siapkan environment Python + dependency (hanya sekali; di-cache di tool/.venv).
if [ ! -x "$VENV/bin/python" ]; then
  echo "• Menyiapkan environment Python (sekali saja)..."
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet -r tool/requirements.txt
fi

# 2. Naikkan versi otomatis (versionCode wajib naik tiap rilis; sync appBuild).
BUMP="${BUMP:-patch}"
NEW_VERSION="$(python3 tool/bump_version.py "$BUMP")"
echo "• Versi rilis: $NEW_VERSION (bump: $BUMP)"

# 3. Build AAB rilis (tertanda tangan upload key) dan kompilasi environment.
# Dart AOT diobfuscate terpisah dari bytecode Android yang diproses R8. Simpan
# symbol map per versi; file ini diperlukan untuk membaca stack trace produksi.
SYMBOLS_ROOT="${SYMBOLS_ROOT:-release-symbols}"
SYMBOLS_DIR="$SYMBOLS_ROOT/$NEW_VERSION"
mkdir -p "$SYMBOLS_DIR"
echo "• Build AAB rilis + obfuscation (symbol: $SYMBOLS_DIR)..."
flutter build appbundle \
  --release \
  --obfuscate \
  --split-debug-info="$SYMBOLS_DIR" \
  --dart-define-from-file="$ENV_FILE"

# 4. Upload + rilis ke track.
echo "• Upload ke Google Play (track: $TRACK, status: $STATUS)..."
PLAY_JSON="$JSON" "$VENV/bin/python" tool/play_upload.py --track "$TRACK" --status "$STATUS"

echo "✓ Selesai."
