import 'package:flutter_test/flutter_test.dart';
import 'package:qrordering/core/config/app_config.dart';

void main() {
  const primary = 'https://project.supabase.co';
  const fallback = 'https://gateway.example.workers.dev';

  test('URL storage mengikuti gateway ketika backend fallback aktif', () {
    const imageUrl =
        '$primary/storage/v1/object/public/menu-images/outlet/menu.png';

    expect(
      AppConfig.resolveBackendAssetUrl(
        imageUrl,
        primaryUrl: primary,
        activeUrl: fallback,
      ),
      '$fallback/storage/v1/object/public/menu-images/outlet/menu.png',
    );
  });

  test('query URL storage tetap dipertahankan ketika host diganti', () {
    const imageUrl =
        '$primary/storage/v1/render/image/public/menu-images/menu.webp?width=600&quality=80';

    expect(
      AppConfig.resolveBackendAssetUrl(
        imageUrl,
        primaryUrl: primary,
        activeUrl: fallback,
      ),
      '$fallback/storage/v1/render/image/public/menu-images/menu.webp?width=600&quality=80',
    );
  });

  test('gambar dari host eksternal tidak diubah', () {
    const external = 'https://cdn.example.com/menu.jpg';

    expect(
      AppConfig.resolveBackendAssetUrl(
        external,
        primaryUrl: primary,
        activeUrl: fallback,
      ),
      external,
    );
  });

  test('gambar production R2 diteruskan tanpa asumsi Supabase', () {
    const r2 =
        'https://assets.qrordering.my.id/menu-images/outlet/menu/image.webp';

    expect(
      AppConfig.resolveBackendAssetUrls(
        r2,
        primaryUrl: primary,
        activeUrl: fallback,
        fallbackUrl: fallback,
      ),
      [r2],
    );
  });

  test('URL tidak berubah ketika jalur utama yang aktif', () {
    const imageUrl =
        '$primary/storage/v1/object/public/menu-images/outlet/menu.png';

    expect(
      AppConfig.resolveBackendAssetUrl(
        imageUrl,
        primaryUrl: primary,
        activeUrl: primary,
      ),
      imageUrl,
    );
  });

  test('host utama diikuti gateway agar gambar punya jalur cadangan', () {
    const imageUrl =
        '$primary/storage/v1/object/public/menu-images/outlet/menu.png';

    expect(
      AppConfig.resolveBackendAssetUrls(
        imageUrl,
        primaryUrl: primary,
        activeUrl: primary,
        fallbackUrl: fallback,
      ),
      [
        imageUrl,
        '$fallback/storage/v1/object/public/menu-images/outlet/menu.png',
      ],
    );
  });

  test('gateway aktif dicoba sebelum host utama tanpa URL duplikat', () {
    const imageUrl =
        '$primary/storage/v1/object/public/menu-images/outlet/menu.png';

    expect(
      AppConfig.resolveBackendAssetUrls(
        imageUrl,
        primaryUrl: primary,
        activeUrl: fallback,
        fallbackUrl: fallback,
      ),
      [
        '$fallback/storage/v1/object/public/menu-images/outlet/menu.png',
        imageUrl,
      ],
    );
  });
}
