#!/usr/bin/env bash

# Bump versi lalu build Android App Bundle (AAB) dan APK release QrOrdering tanpa
# upload ke Google Play. Jalankan dari mana saja dengan: ./release.sh
#
# Opsi:
#   ENV_FILE=/path/ke/.env ./release.sh  Gunakan environment tertentu.
#   BUMP=build ./release.sh              Naikkan versionCode saja.
#   BUMP=minor ./release.sh              Naikkan minor + versionCode.
#   BUMP=major ./release.sh              Naikkan major + versionCode.
#   BUMP=none ./release.sh               Jangan mengubah versi.
#   SKIP_CHECKS=1 ./release.sh           Lewati analyze dan test.
#   CLEAN=1 ./release.sh                 Jalankan flutter clean sebelum build.

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$ROOT_DIR/apps/mobile/qrordering"
ENV_FILE="${ENV_FILE:-$APP_DIR/.env}"
AAB_RELATIVE_PATH="build/app/outputs/bundle/release/app-release.aab"
AAB_PATH="$APP_DIR/$AAB_RELATIVE_PATH"
APK_RELATIVE_PATH="build/app/outputs/flutter-apk/app-release.apk"
APK_PATH="$APP_DIR/$APK_RELATIVE_PATH"
BUMP="${BUMP:-patch}"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

fail() {
  echo "✗ $*" >&2
  exit 1
}

command -v flutter >/dev/null 2>&1 || fail "Flutter tidak ditemukan di PATH."
command -v python3 >/dev/null 2>&1 || fail "Python 3 tidak ditemukan di PATH."
[ -d "$APP_DIR" ] || fail "Project Flutter tidak ditemukan: $APP_DIR"
[ -f "$ENV_FILE" ] || fail "File environment tidak ditemukan: $ENV_FILE"
[ -f "$APP_DIR/android/key.properties" ] || fail \
  "Signing release belum dikonfigurasi: $APP_DIR/android/key.properties"

for key in SUPABASE_URL SUPABASE_ANON_KEY; do
  if ! awk -v wanted="$key" '
    /^[[:space:]]*(#|$)/ { next }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      name = line
      sub(/=.*/, "", name)
      gsub(/[[:space:]]/, "", name)
      if (name != wanted) next

      sub(/^[^=]*=/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line != "" && line != "\"\"" && line != "\047\047") found = 1
    }
    END { exit(found ? 0 : 1) }
  ' "$ENV_FILE"; then
    fail "$key belum diisi di $ENV_FILE"
  fi
done

cd "$APP_DIR"

if [ "${CLEAN:-0}" = "1" ]; then
  echo "• Membersihkan build sebelumnya..."
  flutter clean
fi

echo "• Mengambil dependency Flutter..."
flutter pub get

if [ "${SKIP_CHECKS:-0}" != "1" ]; then
  echo "• Menjalankan analyzer..."
  flutter analyze

  echo "• Menjalankan test..."
  flutter test
fi

NEW_VERSION="$(python3 tool/bump_version.py "$BUMP")"
SYMBOLS_DIR="release-symbols/$NEW_VERSION"
mkdir -p "$SYMBOLS_DIR"
echo "• Versi release: $NEW_VERSION (bump: $BUMP)"

echo "• Membuat Android App Bundle release..."
flutter build appbundle \
  --release \
  --obfuscate \
  --split-debug-info="$SYMBOLS_DIR" \
  --dart-define-from-file="$ENV_FILE"

[ -s "$AAB_PATH" ] || fail "Build selesai tetapi AAB tidak ditemukan."

echo "• Membuat APK release..."
flutter build apk \
  --release \
  --obfuscate \
  --split-debug-info="$SYMBOLS_DIR" \
  --dart-define-from-file="$ENV_FILE"

[ -s "$APK_PATH" ] || fail "Build selesai tetapi APK tidak ditemukan."

AAB_SIZE="$(du -h "$AAB_PATH" | awk '{print $1}')"
APK_SIZE="$(du -h "$APK_PATH" | awk '{print $1}')"
echo "✓ Release $NEW_VERSION berhasil dibuat"
echo "  AAB ($AAB_SIZE): $AAB_PATH"
echo "  APK ($APK_SIZE): $APK_PATH"
echo "  Symbol map: $APP_DIR/$SYMBOLS_DIR"
