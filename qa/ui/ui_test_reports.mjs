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
await page.goto('http://localhost:5174/admin/reports');
await page.waitForLoadState('networkidle');
await page.waitForTimeout(3000);
console.log('🔐 Login OK — di halaman Reports\n');

// ── RPT-01: Halaman Reports muncul tanpa error ──────────────────────────
const hasError = await page.locator('text=Error').isVisible().catch(() => false);
const hasCrash = await page.locator('text=Something went wrong').isVisible().catch(() => false);
const hasTabs = await page.locator('[role="tablist"]').isVisible().catch(() => false);
await ss(page, 'rpt01_halaman_awal');
log('RPT-01', 'Halaman Reports muncul tanpa error',
  !hasError && !hasCrash ? 'PASS' : 'FAIL',
  hasError ? 'Ada error' : hasCrash ? 'App crash' : `Tabs: ${hasTabs}`);

// ── RPT-02: Tabs tersedia ──────────────────────────────────────────────
const tabCount = await page.locator('[role="tab"]').count();
const tabNames = await page.locator('[role="tab"]').allTextContents();
log('RPT-02', 'Tabs laporan tersedia',
  tabCount >= 2 ? 'PASS' : 'WARN',
  `${tabCount} tab: ${tabNames.join(', ')}`);

// ── RPT-03: Chart/grafik penjualan muncul ─────────────────────────────
const hasChart = await page.locator('.recharts-wrapper, [class*="recharts"]').first().isVisible().catch(() => false);
const hasSvg = await page.locator('svg').count();
await ss(page, 'rpt03_chart');
log('RPT-03', 'Grafik penjualan muncul (recharts)',
  hasChart ? 'PASS' : 'WARN',
  hasChart ? 'Chart muncul ✓' : `Tidak ada chart, SVG count: ${hasSvg}`);

// ── RPT-04: Kartu ringkasan (total penjualan, dll) ada ────────────────
const cards = await page.locator('[class*="rounded"][class*="border"]').count();
const hasCurrency = await page.locator('text=Rp').first().isVisible().catch(() => false);
log('RPT-04', 'Kartu ringkasan dengan nilai currency tampil',
  hasCurrency ? 'PASS' : 'WARN',
  `Card elements: ${cards}, Ada Rp: ${hasCurrency}`);

// ── RPT-05: Filter tanggal — date range picker ada ────────────────────
const hasDatePicker = await page.locator('button').filter({ hasText: /Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec|2024|2025|2026|Pilih|tanggal/i }).first().isVisible().catch(() => false);
const hasDateInput = await page.locator('input[type="date"]').count();
await ss(page, 'rpt05_date_filter');
log('RPT-05', 'Filter tanggal tersedia',
  hasDatePicker || hasDateInput > 0 ? 'PASS' : 'WARN',
  `DatePicker: ${hasDatePicker}, Input date: ${hasDateInput}`);

// ── RPT-06: Switch tab kedua (Top Menu / Penjualan) ──────────────────
if (tabCount >= 2) {
  const secondTab = page.locator('[role="tab"]').nth(1);
  const tabName = await secondTab.textContent();
  await secondTab.click();
  await page.waitForTimeout(1500);
  const tabContent = await page.locator('[role="tabpanel"]').isVisible().catch(() => false);
  await ss(page, 'rpt06_tab2');
  log('RPT-06', `Tab "${tabName?.trim()}" bisa dibuka`,
    tabContent ? 'PASS' : 'WARN',
    tabContent ? 'Tab content muncul ✓' : 'Tidak ada content');
}

// ── RPT-07: Tab ketiga (jika ada) ────────────────────────────────────
if (tabCount >= 3) {
  const thirdTab = page.locator('[role="tab"]').nth(2);
  const tabName = await thirdTab.textContent();
  await thirdTab.click();
  await page.waitForTimeout(1500);
  await ss(page, 'rpt07_tab3');
  log('RPT-07', `Tab "${tabName?.trim()}" bisa dibuka`,
    'PASS', 'Tab terbuka tanpa crash');
}

// ── RPT-08: Tombol Export CSV ada dan bisa diklik ─────────────────────
// Kembali ke tab pertama
await page.locator('[role="tab"]').first().click();
await page.waitForTimeout(500);

const csvBtn = page.locator('button').filter({ hasText: /CSV/i }).first();
const hasCSV = await csvBtn.isVisible().catch(() => false);
if (hasCSV) {
  // Set up download listener sebelum klik
  const [download] = await Promise.all([
    page.waitForEvent('download', { timeout: 5000 }).catch(() => null),
    csvBtn.click(),
  ]);
  await page.waitForTimeout(1000);
  const toastEmpty = await page.locator('text=Tidak ada data').isVisible().catch(() => false);
  await ss(page, 'rpt08_export_csv');
  log('RPT-08', 'Export CSV bisa diklik',
    download || toastEmpty ? 'PASS' : 'WARN',
    download ? `File: ${download.suggestedFilename()}` : toastEmpty ? 'Toast "Tidak ada data" (data kosong)' : 'Tidak ada feedback');
} else {
  log('RPT-08', 'Tombol Export CSV ada', 'WARN', 'Tombol CSV tidak ditemukan');
}

// ── RPT-09: Halaman tidak ada tabel dengan data kosong blank ─────────
const emptyMsg = await page.locator('text=Belum ada, text=Tidak ada data, text=Kosong').first().isVisible().catch(() => false);
const tableRows = await page.locator('tbody tr').count();
await ss(page, 'rpt09_data_state');
log('RPT-09', 'State kosong atau data tampil (tidak blank putih)',
  emptyMsg || tableRows > 0 ? 'PASS' : 'WARN',
  emptyMsg ? 'Pesan kosong muncul ✓' : `${tableRows} baris data`);

// ── RPT-10: Dashboard — metrics muncul ────────────────────────────────
await page.goto('http://localhost:5174/admin/dashboard');
await page.waitForLoadState('networkidle');
await page.waitForTimeout(2000);

const dashHasError = await page.locator('text=Error, text=Something went wrong').first().isVisible().catch(() => false);
const dashCards = await page.locator('[class*="rounded"][class*="border"]').count();
await ss(page, 'rpt10_dashboard');
log('RPT-10', 'Dashboard muncul dengan metric cards',
  !dashHasError && dashCards > 0 ? 'PASS' : dashHasError ? 'FAIL' : 'WARN',
  dashHasError ? 'Ada error' : `${dashCards} card elements`);

// ── RINGKASAN ─────────────────────────────────────────────────────────
console.log('\n╔════════════════════════════════════════╗');
console.log('║     RINGKASAN REPORTS TESTING           ║');
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
