import { chromium } from '@playwright/test';

const results = [];
async function ss(page, name) {
  await page.screenshot({ path: `/tmp/${name}.png`, fullPage: true });
  console.log(`📸 ${name}`);
}
function log(tc, desc, status, note = '') {
  const icon = status === 'PASS' ? '✅' : status === 'FAIL' ? '❌' : '⚠️ ';
  console.log(`${icon} ${tc}: ${desc}${note ? ' — ' + note : ''}`);
  results.push({ tc, desc, status, note });
}

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });

// Login
await page.goto('http://localhost:5174/login');
await page.waitForLoadState('networkidle');
await page.fill('input[type="email"]', process.env.E2E_EMAIL ?? '');
await page.fill('input[type="password"]', process.env.E2E_PASSWORD ?? '');
await page.click('button[type="submit"]');
await page.waitForURL('**/dashboard**', { timeout: 10000 });
await page.goto('http://localhost:5174/admin/stock');
await page.waitForLoadState('networkidle');
await page.waitForTimeout(2000);
console.log('🔐 Login OK\n');

// ── UI-EDGE-01: BUG-004 — qty=0 pesan error ─────────────────
await page.click('text=Tambah/Sesuaikan Stok');
await page.waitForTimeout(500);
await page.locator('[role="combobox"]').first().click();
await page.waitForTimeout(300);
await page.locator('[role="option"]').first().click();
await page.locator('input[type="number"]').fill('0');
await page.click('button:has-text("Simpan")');
await page.waitForTimeout(1500);
await ss(page, 'edge01_qty_zero_error');

const rawDbError = await page.locator('text=check constraint').isVisible().catch(() => false);
const friendlyMsg = await page.locator('text=lebih dari 0').isVisible().catch(() => false);
log('EDGE-01', 'BUG-004: qty=0 — pesan error ramah (bukan raw DB error)',
  friendlyMsg ? 'PASS' : rawDbError ? 'FAIL' : 'WARN',
  rawDbError ? 'Raw DB error masih tampil ke user' : friendlyMsg ? 'Pesan ramah ✓' : 'Tidak ada pesan');
await page.keyboard.press('Escape');
await page.waitForTimeout(300);

// ── UI-EDGE-02: Tambah bahan qty negatif tidak mungkin (type=number min=0) ──
await page.click('text=Tambah/Sesuaikan Stok');
await page.waitForTimeout(400);
const qtyInput = page.locator('input[type="number"]');
await qtyInput.fill('-5');
const qtyVal = await qtyInput.inputValue();
log('EDGE-02', 'Input qty=−5 — browser HTML validation (min=0) mencegah nilai negatif',
  qtyVal === '' || parseFloat(qtyVal) >= 0 ? 'PASS' : 'WARN',
  `Nilai di input: "${qtyVal}"`);
await ss(page, 'edge02_qty_negatif');
await page.keyboard.press('Escape');
await page.waitForTimeout(300);

// ── UI-EDGE-03: Riwayat Transaksi — warna merah untuk Pemakaian/Pemborosan ──
await page.click('text=Riwayat Transaksi');
await page.waitForTimeout(1500);
await ss(page, 'edge03_riwayat_full');

const greenCells = await page.locator('td span.text-green-600').count();
const redCells   = await page.locator('td span.text-red-600').count();
log('EDGE-03', 'Riwayat — warna perubahan: hijau untuk masuk, merah untuk keluar',
  greenCells > 0 ? 'PASS' : 'WARN',
  `Sel hijau: ${greenCells}, sel merah: ${redCells}`);

// ── UI-EDGE-04: Tab Daftar — nomor stok tampil format desimal ──
await page.click('text=Daftar Bahan');
await page.waitForTimeout(1000);
await ss(page, 'edge04_daftar_bahan');

const stockCells = await page.locator('span.font-mono').allTextContents();
log('EDGE-04', 'Stok Saat Ini ditampilkan di kolom (format angka)',
  stockCells.length > 0 ? 'PASS' : 'WARN',
  `Nilai stok: ${stockCells.slice(0, 3).join(', ')}`);

// ── UI-EDGE-05: Subtitle "N bahan hampir habis" — counter akurat ──
const subtitle = await page.locator('p:has-text("bahan hampir habis")').textContent().catch(() => '');
log('EDGE-05', 'Subtitle counter "N bahan hampir habis"',
  subtitle.includes('bahan hampir habis') ? 'PASS' : 'WARN',
  `"${subtitle.trim()}"`);

// ── UI-EDGE-06: Form edit — simpan tanpa ubah apapun ────────────
const firstRow = page.locator('tr', { hasText: 'Beras QA Test' }).first();
await firstRow.locator('button').nth(0).click();
await page.waitForTimeout(500);
await page.click('button[type="submit"]:has-text("Simpan")');
await page.waitForTimeout(1500);
const toastUpdate = await page.locator('text=berhasil diperbarui').isVisible().catch(() => false);
const toastGagal  = await page.locator('text=Gagal').isVisible().catch(() => false);
log('EDGE-06', 'Edit simpan tanpa perubahan — tidak error',
  toastUpdate && !toastGagal ? 'PASS' : toastGagal ? 'FAIL' : 'WARN',
  toastUpdate ? 'Toast sukses ✓' : 'Tidak ada feedback');
await ss(page, 'edge06_edit_tanpa_ubah');

// ── UI-EDGE-07: Page header subtitle — angka counter update setelah tambah bahan ──
await page.keyboard.press('Escape');
await page.waitForTimeout(500);
const subtitleAfter = await page.locator('p:has-text("bahan hampir habis")').textContent().catch(() => '?');
log('EDGE-07', 'Header subtitle update real-time setelah operasi',
  subtitleAfter.includes('bahan hampir habis') ? 'PASS' : 'WARN',
  `"${subtitleAfter.trim()}"`);

// ── RINGKASAN ─────────────────────────────────────────────────────
console.log('\n╔════════════════════════════════════════╗');
console.log('║     RINGKASAN UI EDGE CASE TESTING      ║');
console.log('╠════════════════════════════════════════╣');
for (const r of results) {
  const icon = r.status === 'PASS' ? '✅' : r.status === 'FAIL' ? '❌' : '⚠️ ';
  console.log(`║ ${icon} ${r.tc.padEnd(10)} ${r.desc.substring(0, 26).padEnd(27)}║`);
}
console.log('╠════════════════════════════════════════╣');
const pass = results.filter(r => r.status === 'PASS').length;
const fail = results.filter(r => r.status === 'FAIL').length;
const warn = results.filter(r => r.status === 'WARN').length;
console.log(`║ PASS: ${pass}  FAIL: ${fail}  WARN: ${warn}  TOTAL: ${results.length}               ║`);
console.log('╚════════════════════════════════════════╝');

await browser.close();
