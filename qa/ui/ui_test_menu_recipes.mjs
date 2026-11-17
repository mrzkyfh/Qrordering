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
await page.goto('http://localhost:5174/admin/menu');
await page.waitForLoadState('networkidle');
await page.waitForTimeout(2000);
console.log('🔐 Login OK — di halaman Menu Manager\n');

// ── MENU-01: Halaman MenuManager muncul & ada daftar menu ──────────────
const pageTitle = await page.locator('h1, h2').filter({ hasText: 'Kelola Menu' }).isVisible().catch(() => false);
const menuCards = await page.locator('.grid > div').count();
await ss(page, 'menu01_halaman_awal');
log('MENU-01', 'MenuManager muncul dengan kartu menu',
  pageTitle && menuCards > 0 ? 'PASS' : menuCards > 0 ? 'WARN' : 'FAIL',
  `Title: ${pageTitle}, Kartu: ${menuCards}`);

// ── MENU-02: Search / filter menu ────────────────────────────────────────
const searchInput = page.locator('input[placeholder*="Cari"]');
const hasSearch = await searchInput.isVisible().catch(() => false);
if (hasSearch) {
  await searchInput.fill('zzz_tidak_ada_menu_ini');
  await page.waitForTimeout(500);
  const afterSearch = await page.locator('.grid > div').count();
  await searchInput.clear();
  await page.waitForTimeout(300);
  log('MENU-02', 'Search filter menu berfungsi',
    afterSearch === 0 ? 'PASS' : 'WARN',
    `Setelah search "zzz": ${afterSearch} kartu (harapan: 0)`);
} else {
  log('MENU-02', 'Search filter menu berfungsi', 'WARN', 'Search input tidak ditemukan');
}
await ss(page, 'menu02_search');

// ── MENU-03: Buka dialog edit menu item pertama ───────────────────────
await page.locator('button:has-text("Edit")').first().click();
await page.waitForTimeout(1000);
const dialogVisible = await page.locator('[role="dialog"]').isVisible().catch(() => false);
await ss(page, 'menu03_dialog_edit');
log('MENU-03', 'Dialog edit menu terbuka',
  dialogVisible ? 'PASS' : 'FAIL',
  dialogVisible ? 'Dialog muncul ✓' : 'Dialog tidak muncul');

// ── MENU-04: Section "Resep Bahan Baku" ada di dialog edit ─────────────
const recipeSection = await page.locator('text=Resep Bahan Baku').isVisible().catch(() => false);
log('MENU-04', 'Section "Resep Bahan Baku" tampil di dialog edit',
  recipeSection ? 'PASS' : 'FAIL',
  recipeSection ? 'Section muncul ✓' : 'Section tidak ada');

// ── MENU-05: Tampilkan resep yang sudah ada (atau pesan kosong) ─────────
await page.waitForTimeout(1000);
const existingRecipes = await page.locator('text=Belum ada resep').isVisible().catch(() => false);
const recipeItems = await page.locator('[role="dialog"] .rounded-lg.border.bg-muted\\/30').count();
await ss(page, 'menu05_recipe_section');
log('MENU-05', 'Resep tampil atau pesan "belum ada resep" muncul',
  existingRecipes || recipeItems > 0 ? 'PASS' : 'WARN',
  existingRecipes ? 'Belum ada resep' : `${recipeItems} resep sudah ada`);

// ── MENU-06: Tambah resep — validasi tanpa pilih bahan ──────────────────
// Coba klik tombol + tanpa pilih bahan dulu
const addRecipeBtn = page.locator('[role="dialog"] button').filter({ hasText: '' }).locator('svg').first();
// Cari tombol + di section resep (icon Plus)
const plusBtn = page.locator('[role="dialog"]').locator('button').filter({ has: page.locator('svg') }).last();

// Cek apakah ada select bahan yang tersedia
const ingredientSelect = page.locator('[role="dialog"] [role="combobox"]').last();
const hasIngredientSelect = await ingredientSelect.isVisible().catch(() => false);

if (hasIngredientSelect) {
  // Klik tombol + tanpa pilih bahan
  await plusBtn.click();
  await page.waitForTimeout(800);
  const toastError = await page.locator('text=Pilih bahan dan masukkan qty').isVisible().catch(() => false);
  await ss(page, 'menu06_tambah_tanpa_bahan');
  log('MENU-06', 'Validasi: klik + tanpa pilih bahan → toast error',
    toastError ? 'PASS' : 'WARN',
    toastError ? 'Toast error muncul ✓' : 'Tidak ada feedback error');
} else {
  log('MENU-06', 'Validasi: klik + tanpa pilih bahan → toast error', 'WARN',
    'Tidak ada select bahan — mungkin semua bahan sudah ditambahkan atau tidak ada bahan');
}

// ── MENU-07: Tambah resep bahan baku ke menu ───────────────────────────
const selectTrigger = page.locator('[role="dialog"]').locator('[role="combobox"]').last();
const hasSelect = await selectTrigger.isVisible().catch(() => false);

if (hasSelect) {
  await selectTrigger.click();
  await page.waitForTimeout(400);
  const firstOption = page.locator('[role="option"]').first();
  const hasOption = await firstOption.isVisible().catch(() => false);

  if (hasOption) {
    const ingredientName = await firstOption.textContent();
    await firstOption.click();
    await page.waitForTimeout(200);

    // Isi qty
    const qtyInput = page.locator('[role="dialog"] input[placeholder="Qty"]');
    await qtyInput.fill('0.5');

    // Klik tombol +
    await page.locator('[role="dialog"] button').filter({ has: page.locator('svg.lucide-plus') }).last().click();
    await page.waitForTimeout(1500);

    const toastSuccess = await page.locator('text=Bahan ditambahkan ke resep').isVisible().catch(() => false);
    const recipeAfter = await page.locator('[role="dialog"] .rounded-lg.border.bg-muted\\/30').count();
    await ss(page, 'menu07_tambah_resep');
    log('MENU-07', `Tambah bahan "${ingredientName?.trim()}" ke resep berhasil`,
      toastSuccess ? 'PASS' : recipeAfter > recipeItems ? 'PASS' : 'FAIL',
      toastSuccess ? `Toast sukses ✓, ${recipeAfter} resep` : `${recipeAfter} resep setelah tambah`);
  } else {
    log('MENU-07', 'Tambah bahan ke resep', 'WARN', 'Tidak ada opsi bahan tersedia di dropdown');
  }
} else {
  log('MENU-07', 'Tambah bahan ke resep', 'WARN', 'Tidak ada select bahan — semua bahan sudah dipakai atau tidak ada bahan');
}

// ── MENU-08: Hapus resep yang baru ditambahkan ────────────────────────
await page.waitForTimeout(500);
const recipeItemsNow = await page.locator('[role="dialog"] .rounded-lg.border.bg-muted\\/30').count();
if (recipeItemsNow > 0) {
  // Klik X pada resep terakhir
  const deleteBtn = page.locator('[role="dialog"] .rounded-lg.border.bg-muted\\/30').last().locator('button');
  await deleteBtn.click();
  await page.waitForTimeout(1500);
  const toastDel = await page.locator('text=Bahan dihapus dari resep').isVisible().catch(() => false);
  const recipeAfterDel = await page.locator('[role="dialog"] .rounded-lg.border.bg-muted\\/30').count();
  await ss(page, 'menu08_hapus_resep');
  log('MENU-08', 'Hapus bahan dari resep berhasil',
    toastDel || recipeAfterDel < recipeItemsNow ? 'PASS' : 'FAIL',
    toastDel ? `Toast sukses ✓, tersisa ${recipeAfterDel} resep` : `Sebelum: ${recipeItemsNow}, sesudah: ${recipeAfterDel}`);
} else {
  log('MENU-08', 'Hapus bahan dari resep', 'WARN', 'Tidak ada resep untuk dihapus');
}

// ── MENU-09: Tutup dialog, kembali ke daftar menu ─────────────────────
await page.keyboard.press('Escape');
await page.waitForTimeout(500);
const dialogGone = await page.locator('[role="dialog"]').isVisible().catch(() => false);
log('MENU-09', 'Dialog tutup kembali ke daftar menu',
  !dialogGone ? 'PASS' : 'WARN',
  !dialogGone ? 'Dialog tertutup ✓' : 'Dialog masih terbuka');

// ── MENU-10: Tambah menu baru → form terbuka ─────────────────────────
await page.click('button:has-text("Tambah Menu")');
await page.waitForTimeout(800);
const addDialogVisible = await page.locator('[role="dialog"]').isVisible().catch(() => false);
const nameInput = page.locator('[role="dialog"] input[placeholder*="Nasi Goreng"]');
const hasNameInput = await nameInput.isVisible().catch(() => false);
await ss(page, 'menu10_tambah_menu_form');
log('MENU-10', 'Form tambah menu baru terbuka dengan field nama',
  addDialogVisible && hasNameInput ? 'PASS' : 'WARN',
  `Dialog: ${addDialogVisible}, Field nama: ${hasNameInput}`);
await page.keyboard.press('Escape');

// ── RINGKASAN ─────────────────────────────────────────────────────────
console.log('\n╔════════════════════════════════════════╗');
console.log('║     RINGKASAN MENU MANAGER TESTING      ║');
console.log('╠════════════════════════════════════════╣');
for (const r of results) {
  const icon = r.status === 'PASS' ? '✅' : r.status === 'FAIL' ? '❌' : '⚠️ ';
  console.log(`║ ${icon} ${r.tc.padEnd(9)} ${r.desc.substring(0, 26).padEnd(27)}║`);
}
console.log('╠════════════════════════════════════════╣');
const pass = results.filter(r => r.status === 'PASS').length;
const fail = results.filter(r => r.status === 'FAIL').length;
const warn = results.filter(r => r.status === 'WARN').length;
console.log(`║ PASS: ${pass}  FAIL: ${fail}  WARN: ${warn}  TOTAL: ${results.length}               ║`);
console.log('╚════════════════════════════════════════╝');

await browser.close();
