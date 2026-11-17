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

// Login & navigate
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

// ── UI-01: Elemen utama ───────────────────────────────────────────
const hasTambahBahan = await page.locator('text=Tambah Bahan Baru').isVisible();
const hasTambahStok  = await page.locator('text=Tambah/Sesuaikan Stok').isVisible();
log('UI-01', 'Elemen utama tampil', hasTambahBahan && hasTambahStok ? 'PASS' : 'FAIL');

// ── UI-02: Form validasi kosong ───────────────────────────────────
await page.click('text=Tambah Bahan Baru');
await page.waitForTimeout(400);
await page.click('button[type="submit"]');
await page.waitForTimeout(400);
const namaErr   = await page.locator('text=Nama wajib diisi').isVisible();
const satuanErr = await page.locator('text=Satuan wajib diisi').isVisible();
const hargaErr  = await page.locator('text=Harga/unit wajib diisi').isVisible();
const minErr    = await page.locator('text=Min stok wajib diisi').isVisible();
log('UI-02', 'Validasi form kosong — semua error muncul',
  namaErr && satuanErr && hargaErr && minErr ? 'PASS' : 'FAIL',
  `nama=${namaErr} satuan=${satuanErr} harga=${hargaErr} min=${minErr}`);
await ss(page, 'ui02_validasi_kosong');

// ── UI-03: Thousand separator ─────────────────────────────────────
const hargaInput = page.locator('input[inputmode="numeric"]').first();
await hargaInput.pressSequentially('15000');
await page.waitForTimeout(200);
const hargaVal = await hargaInput.inputValue();
log('UI-03', 'Thousand separator — 15000 → 15.000', hargaVal === '15.000' ? 'PASS' : 'FAIL', `"${hargaVal}"`);

// ── UI-04: Tambah bahan sukses ────────────────────────────────────
await page.fill('input[placeholder="cth: Tepung Terigu"]', 'Beras QA Test');
await page.fill('input[placeholder="cth: kg, liter, pcs"]', 'kg');
await page.locator('input[type="number"]').nth(0).fill('10');
await page.locator('input[type="number"]').nth(1).fill('5');
await page.click('button[type="submit"]:has-text("Tambah")');
await page.waitForTimeout(2500);
const berasRow = await page.locator('text=Beras QA Test').first().isVisible();
log('UI-04', 'Tambah bahan — data muncul di tabel', berasRow ? 'PASS' : 'FAIL');
await ss(page, 'ui04_tambah_bahan');

// ── UI-05: StockBadge "Aman" — stok 10 ≥ min 5 ───────────────────
const statusAman     = await page.locator('text=Aman').first().isVisible().catch(() => false);
const statusRendah   = await page.locator('text=Rendah').isVisible().catch(() => false);
const statusKritis   = await page.locator('text=Kritis').isVisible().catch(() => false);
const statusHabis    = await page.locator('text=Habis').isVisible().catch(() => false);
log('UI-05', 'StockBadge — stok=10, min=5 → status "Aman"',
  statusAman ? 'PASS' : 'FAIL',
  statusAman ? 'Aman ✓' : statusRendah ? 'Rendah (salah)' : statusKritis ? 'Kritis (salah)' : 'Badge tidak terdeteksi');

// ── UI-05b: Subtitle header — "N bahan hampir habis" ─────────────
const subtitleEl = await page.locator('text=/bahan hampir habis/').textContent().catch(() => '');
log('UI-05b', 'Subtitle header menghitung bahan hampir habis',
  subtitleEl.includes('bahan hampir habis') ? 'PASS' : 'WARN', `"${subtitleEl}"`);

// ── UI-06: Edit dialog ────────────────────────────────────────────
// Cari row Beras QA Test pertama, klik tombol edit (pencil)
const row = page.locator('tr', { hasText: 'Beras QA Test' }).first();
await row.locator('button').nth(0).click();
await page.waitForTimeout(500);
const editDialog = await page.locator('text=Edit Bahan').isVisible();
log('UI-06', 'Tombol edit → dialog Edit Bahan terbuka', editDialog ? 'PASS' : 'FAIL');
await ss(page, 'ui06_edit_dialog');

// UI-06b: Harga sudah terformat di form edit
const editHarga = await page.locator('input[inputmode="numeric"]').first().inputValue();
log('UI-06b', 'Form edit — harga sudah terformat (ada separator)',
  editHarga.includes('.') ? 'PASS' : 'WARN', `Nilai: "${editHarga}"`);
await page.keyboard.press('Escape');
await page.waitForTimeout(300);

// ── UI-07: Tab Riwayat Transaksi ──────────────────────────────────
await page.click('text=Riwayat Transaksi');
await page.waitForTimeout(1500);
await ss(page, 'ui07_riwayat_transaksi');
const colTanggal   = await page.getByRole('columnheader', { name: 'Tanggal', exact: true }).isVisible();
const colPerubahan = await page.getByRole('columnheader', { name: 'Perubahan', exact: true }).isVisible();
const colBahan     = await page.getByRole('columnheader', { name: 'Bahan', exact: true }).isVisible();
log('UI-07', 'Tab Riwayat — kolom tabel tampil semua',
  colTanggal && colPerubahan && colBahan ? 'PASS' : 'FAIL',
  `Tanggal=${colTanggal} Perubahan=${colPerubahan} Bahan=${colBahan}`);

// UI-07b: Ada transaksi awal di riwayat
const hasPurchase = await page.locator('text=Pembelian').isVisible().catch(() => false);
const hasStokAwal = await page.locator('text=Stok awal').isVisible().catch(() => false);
log('UI-07b', 'Riwayat — transaksi stok awal tercatat',
  hasPurchase || hasStokAwal ? 'PASS' : 'WARN',
  hasPurchase ? 'type=Pembelian ✓' : hasStokAwal ? 'label=Stok awal ✓' : 'Tidak ada transaksi awal');

// UI-07c: Warna perubahan — Pembelian = hijau
const greenVal = await page.locator('td span.text-green-600').first().isVisible().catch(() => false);
log('UI-07c', 'Perubahan Pembelian tampil warna hijau dengan prefix "+"',
  greenVal ? 'PASS' : 'WARN', greenVal ? 'text-green-600 ✓' : 'Tidak terdeteksi via class');

// ── UI-08: Adjustment qty=0 ───────────────────────────────────────
await page.click('text=Daftar Bahan');
await page.waitForTimeout(300);
await page.click('text=Tambah/Sesuaikan Stok');
await page.waitForTimeout(500);
// Pilih bahan
await page.locator('[role="combobox"]').first().click();
await page.waitForTimeout(300);
await page.locator('[role="option"]').first().click();
// Qty = 0
await page.locator('input[type="number"]').fill('0');
await page.click('button:has-text("Simpan")');
await page.waitForTimeout(1500);
await ss(page, 'ui08_adj_qty_zero');
const toastGagal  = await page.locator('text=Gagal').isVisible().catch(() => false);
const toastSukses = await page.locator('text=berhasil diperbarui').isVisible().catch(() => false);
log('UI-08', 'Adjustment qty=0 — harus ditolak (DB: qty > 0)',
  toastGagal ? 'PASS' : toastSukses ? 'FAIL' : 'WARN',
  toastGagal ? 'Toast Gagal muncul ✓' : toastSukses ? 'DITERIMA — bug!' : 'Tidak ada feedback');

// ── UI-09: Delete confirm dialog ──────────────────────────────────
await page.keyboard.press('Escape');
await page.waitForTimeout(300);
const rowDel = page.locator('tr', { hasText: 'Beras QA Test' }).first();
await rowDel.locator('button').nth(1).click();
await page.waitForTimeout(500);
const hapusDialog = await page.locator('text=Hapus Bahan?').isVisible();
log('UI-09', 'Tombol hapus → konfirmasi AlertDialog muncul', hapusDialog ? 'PASS' : 'FAIL');
await ss(page, 'ui09_delete_confirm');

// UI-10: Cancel delete
await page.locator('button:has-text("Batal")').last().click();
await page.waitForTimeout(500);
const stillThere = await page.locator('text=Beras QA Test').first().isVisible();
log('UI-10', 'Cancel hapus — bahan tetap ada', stillThere ? 'PASS' : 'FAIL');
await ss(page, 'ui10_setelah_cancel');

// ── RINGKASAN ─────────────────────────────────────────────────────
console.log('\n╔═══════════════════════════════════════╗');
console.log('║         RINGKASAN UI TESTING           ║');
console.log('╠═══════════════════════════════════════╣');
for (const r of results) {
  const icon = r.status === 'PASS' ? '✅' : r.status === 'FAIL' ? '❌' : '⚠️ ';
  console.log(`║ ${icon} ${r.tc.padEnd(8)} ${r.desc.substring(0,28).padEnd(29)}║`);
}
console.log('╠═══════════════════════════════════════╣');
const pass = results.filter(r => r.status === 'PASS').length;
const fail = results.filter(r => r.status === 'FAIL').length;
const warn = results.filter(r => r.status === 'WARN').length;
console.log(`║ PASS: ${pass}  FAIL: ${fail}  WARN: ${warn}  TOTAL: ${results.length}          ║`);
console.log('╚═══════════════════════════════════════╝');

await browser.close();
