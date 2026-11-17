import { readFile } from 'node:fs/promises'

const [html, app, styles, headers] = await Promise.all([
  readFile(new URL('../index.html', import.meta.url), 'utf8'),
  readFile(new URL('../app.js', import.meta.url), 'utf8'),
  readFile(new URL('../styles.css', import.meta.url), 'utf8'),
  readFile(new URL('../_headers', import.meta.url), 'utf8'),
])

const violations = []
const staticButtons = [...html.matchAll(/<button\b[^>]*>/gi)].map(match => match[0])
staticButtons.forEach((button, index) => {
  if (!/\btype=["']button["']/i.test(button)) {
    violations.push(`Tombol HTML #${index + 1} tidak memiliki type="button": ${button}`)
  }
})

if (!/<script src=["']vendor\/supabase\.js["']><\/script>/i.test(html)) {
  violations.push('Pustaka Supabase harus dimuat dari aset lokal.')
}
if (/cdn\.jsdelivr\.net|fonts\.googleapis\.com|fonts\.gstatic\.com/i.test(html)) {
  violations.push('Halaman masih bergantung pada CDN eksternal.')
}
if (!/Content-Security-Policy:/i.test(headers)) {
  violations.push('Header Content-Security-Policy tidak ditemukan.')
}
if (!/img-src[^;]*https:\/\/\*\.supabase\.co[^;]*https:\/\/assets\.time420s\.my\.id/i.test(headers)) {
  violations.push('CSP gambar harus mengizinkan Supabase dan R2 production.')
}
if (!/data-image-fallback/.test(app) || !/installImageFallbacks/.test(app)) {
  violations.push('Gambar menu yang gagal dimuat harus kembali ke placeholder teks.')
}
if (!/persistSession:\s*false/.test(app)) {
  violations.push('Menu pelanggan harus selalu menggunakan sesi anon.')
}
if (!/p_table_token:\s*state\.tableToken/.test(app)) {
  violations.push('Pengiriman pesanan tidak menyertakan token meja.')
}
if (!/id=["']initialCustomerName["'][^>]*\brequired\b/i.test(html)) {
  violations.push('Nama pemesan wajib diminta sebelum pelanggan masuk ke menu.')
}
if (!/id=["']customerName["'][^>]*\brequired\b/i.test(html) || !/requireCustomerName\('customerName'\)/.test(app)) {
  violations.push('Nama pemesan wajib divalidasi kembali saat checkout.')
}
if (!/\.menu-thumb\s*\{[^}]*aspect-ratio:\s*5\s*\/\s*4;/s.test(styles)) {
  violations.push('Area gambar kartu menu harus memakai rasio 5:4.')
}
if (!/\.menu-thumb img\s*\{[^}]*object-fit:\s*cover;/s.test(styles)) {
  violations.push('Gambar menu harus memenuhi seluruh area atas kartu.')
}
if (!/\.welcome-hero-image\s*\{[^}]*object-fit:\s*contain;/s.test(styles)) {
  violations.push('Foto sambutan harus tampil utuh tanpa terpotong.')
}
if (!/\.welcome-hero-backdrop\s*\{[^}]*object-fit:\s*cover;[^}]*filter:\s*blur\(/s.test(styles)) {
  violations.push('Sisi kosong foto sambutan harus diisi latar foto yang diburamkan.')
}
if (!/\.welcome-hero\.has-fitted-image\s*\{[^}]*aspect-ratio:\s*var\(--welcome-hero-aspect\)/s.test(styles)
    || !/hero\.naturalWidth[\s\S]*--welcome-hero-aspect/.test(app)) {
  violations.push('Area foto sambutan harus mengikuti rasio asli gambar.')
}
if (/welcomeBackBtn|welcome-back/.test(`${html}\n${app}\n${styles}`)) {
  violations.push('Tombol kembali tidak boleh tampil pada foto sambutan.')
}
if (!/id=["']categoryTabs["']/.test(html) || !/button\.addEventListener\('click',\s*\(\)\s*=>\s*selectCat/.test(app)) {
  violations.push('Navigasi kategori menu pelanggan harus berupa tab horizontal yang aktif.')
}
if (!/Rekomendasi Produk/.test(app) || !/menu-category-\$\{category\.id\}/.test(app)) {
  violations.push('Menu pelanggan harus menampilkan rekomendasi dan membagi produk per kategori.')
}
if (!/\.eq\('show_in_qr_menu', true\)/.test(app)) {
  violations.push('Jalur fallback menu pelanggan belum memfilter produk yang disembunyikan dari QR.')
}
if (!/p_request_id:\s*requestId/.test(app) || !/getOrCreateOrderRequestId/.test(app)) {
  violations.push('Pengiriman pesanan belum memiliki kunci idempotensi.')
}
if (!/if \(extrasRes\.error\) throw extrasRes\.error/.test(app)) {
  violations.push('Kegagalan memuat pilihan tambahan belum ditangani.')
}
if (/applyPromoBtn[\s\S]{0,100}\.onclick\s*=/.test(app)) {
  violations.push('Tombol promo memiliki pengendali klik ganda.')
}

if (violations.length > 0) {
  console.error(violations.join('\n'))
  process.exit(1)
}

console.log(`Audit menu pelanggan lulus: ${staticButtons.length} tombol statis dan kontrak keamanan utama valid.`)
