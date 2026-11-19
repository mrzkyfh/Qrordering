# mejaku

Aplikasi POS Flutter mejaku.

## Environment Android

Buat file `.env` dari contoh, lalu isi konfigurasi aplikasi:

```bash
cp .env.example .env
```

Key yang wajib tersedia:

```dotenv
SUPABASE_URL=https://project.supabase.co
SUPABASE_ANON_KEY=your-anon-key
SUPABASE_FALLBACK_URL=https://your-network-gateway.workers.dev
```

Build APK lokal dengan environment yang dikompilasi ke aplikasi (untuk uji
release lokal; APK ini tidak diobfuscate agar stack trace mudah dibaca):

```bash
flutter build apk --release --dart-define-from-file=.env
```

Untuk rilis Google Play, gunakan script rilis seperti biasa:

```bash
./release.sh
```

`release.sh` otomatis memvalidasi `.env`, mengaktifkan R8/resource shrinking,
dan mengobfuscate Dart sebelum membangun AAB. Symbol map disimpan per versi di
`release-symbols/`; arsipkan folder versi tersebut secara aman untuk membaca
stack trace produksi. Untuk file environment lain (misalnya production),
jalankan `ENV_FILE=.env.production ./release.sh`.

> Jangan simpan service-role key atau secret backend di `.env` mobile. Isi APK
> tetap dapat dianalisis pengguna; Supabase anon key memang ditujukan untuk
> aplikasi client dan keamanannya harus ditopang oleh RLS.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
