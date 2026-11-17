import { test, expect, type Page } from '@playwright/test'
import { HAS_TEST_CREDENTIALS, login } from './helpers/auth'

// Smoke test: visit every main page, verify it loads without crash/error
// Tujuan: ensure no halaman yg crash white-screen, semua route accessible

const ROUTES_ADMIN: { path: string; name: string }[] = [
  { path: '/admin/dashboard',                    name: 'Admin Dashboard' },
  { path: '/admin/departments',                  name: 'Departments' },
  { path: '/admin/categories',                   name: 'Categories' },
  { path: '/admin/menu',                         name: 'Menu' },
  { path: '/admin/extras',                       name: 'Extras' },
  { path: '/admin/reports',                      name: 'Ringkasan Penjualan' },
  { path: '/admin/sales-breakdown/departemen',   name: 'Laporan Departemen' },
  { path: '/admin/sales-breakdown/kategori',     name: 'Laporan Kategori' },
  { path: '/admin/sales-breakdown/menu',         name: 'Laporan Menu' },
  { path: '/admin/sales-breakdown/extra',        name: 'Laporan Extra' },
  { path: '/admin/sales-breakdown/service',      name: 'Laporan Service Charge' },
  { path: '/admin/sales-breakdown/sub-extra',    name: 'Laporan Sub-extra' },
  { path: '/admin/sales-breakdown/pajak',        name: 'Laporan Pajak' },
  { path: '/admin/orders',                       name: 'Daftar Pesanan' },
  { path: '/admin/shifts',                       name: 'Shift Kasir' },
  { path: '/admin/sales-summary',                name: 'Ringkasan Laba Rugi' },
  { path: '/admin/void-report',                  name: 'Laporan Void' },
  { path: '/admin/refund-report',                name: 'Laporan Refund' },
  { path: '/admin/partial-refund-report',        name: 'Laporan Refund Sebagian' },
  { path: '/admin/stock',                        name: 'Stok' },
  { path: '/admin/stock-report',                 name: 'Laporan Stok' },
  { path: '/admin/stock-opname',                 name: 'Stock Opname' },
  { path: '/admin/waste-report',                 name: 'Laporan Waste' },
  { path: '/admin/suppliers',                    name: 'Suppliers' },
  { path: '/admin/expenses',                     name: 'Pengeluaran' },
  { path: '/admin/tables',                       name: 'Tables' },
  { path: '/admin/qr-codes',                     name: 'QR Codes' },
  { path: '/admin/promos',                       name: 'Promos' },
  { path: '/admin/bundles',                      name: 'Bundles' },
  { path: '/admin/loyalty',                      name: 'Loyalty' },
  { path: '/admin/customers',                    name: 'Customers' },
  { path: '/admin/payments',                     name: 'Payment Methods' },
  { path: '/admin/receipt',                      name: 'Receipt Settings' },
  { path: '/admin/print-stations',               name: 'Print Stations' },
  { path: '/admin/charges',                      name: 'Charges' },
  { path: '/admin/taxes',                        name: 'Tax Settings' },
  { path: '/admin/staff',                        name: 'Admin Staff' },
  { path: '/admin/attendance',                   name: 'Laporan Absensi' },
  { path: '/admin/settings',                     name: 'Outlet Settings' },
]

const ROUTES_OWNER: { path: string; name: string }[] = [
  { path: '/owner/dashboard', name: 'Owner Dashboard' },
  { path: '/owner/branches',  name: 'Branch Monitoring' },
  { path: '/owner/finance',   name: 'Finance Report' },
  { path: '/owner/staff',     name: 'Owner Staff' },
  { path: '/owner/error-logs', name: 'Error Log Viewer' },
  { path: '/owner/payment-methods',     name: 'Detail Metode Pembayaran' },
  { path: '/owner/outlet-performance',  name: 'Detail Performa Outlet' },
  { path: '/owner/top-products',        name: 'Detail Produk Terlaris' },
  { path: '/owner/sales-by-category',   name: 'Detail Penjualan per Kategori' },
  { path: '/owner/sales-by-kasir',      name: 'Detail Penjualan per Kasir' },
]

// Errors yang OK di-ignore (false-positives umum: source map, dev warning, dll)
const IGNORE_PATTERNS = [
  /Failed to load resource.*favicon/i,
  /\[vite\]/i,
  /DevTools/i,
  /Source map/i,
]

async function visitWithChecks(page: Page, path: string) {
  const errors: string[] = []
  const responses: { url: string; status: number }[] = []

  page.on('console', (msg) => {
    if (msg.type() === 'error') {
      const text = msg.text()
      if (!IGNORE_PATTERNS.some((p) => p.test(text))) errors.push(`[console] ${text.slice(0, 200)}`)
    }
  })
  page.on('pageerror', (err) => errors.push(`[pageerror] ${err.message.slice(0, 200)}`))
  page.on('response', (res) => {
    if (res.status() >= 500) responses.push({ url: res.url(), status: res.status() })
  })

  await page.goto(path, { waitUntil: 'domcontentloaded' })
  await page.waitForLoadState('networkidle', { timeout: 10_000 }).catch(() => {})

  // Route yang tidak terdaftar tidak boleh lolos hanya karena wildcard redirect.
  expect(new URL(page.url()).pathname).toBe(path)
  // Body harus visible (bukan white-screen)
  await expect(page.locator('body')).toBeVisible()
  // Sidebar selalu ada di app layout
  await expect(page.locator('aside')).toBeVisible({ timeout: 5_000 })

  // Kontrak tombol lintas halaman:
  // - semua tombol yang terlihat harus memiliki nama yang dapat dipahami pengguna;
  // - type harus eksplisit agar tombol non-submit tidak memicu form tanpa sengaja.
  const buttonViolations = await page.locator('button:visible').evaluateAll((buttons) =>
    buttons.flatMap((button, index) => {
      const labelledBy = button.getAttribute('aria-labelledby')
      const labelledText = labelledBy
        ? labelledBy
            .split(/\s+/)
            .map((id) => document.getElementById(id)?.textContent?.trim() ?? '')
            .join(' ')
            .trim()
        : ''
      const nativeLabelText = Array.from((button as HTMLButtonElement).labels ?? [])
        .map((label) => label.textContent?.trim() ?? '')
        .join(' ')
        .trim()
      const name = (
        button.getAttribute('aria-label')
        || labelledText
        || nativeLabelText
        || button.textContent
        || button.getAttribute('title')
        || ''
      ).trim()
      const problems: string[] = []
      if (!name) problems.push('tanpa nama aksesibel')
      if (!button.getAttribute('type')) problems.push('tanpa type eksplisit')
      return problems.length > 0
        ? [`button #${index + 1} (${button.outerHTML.slice(0, 160)}): ${problems.join(', ')}`]
        : []
    }),
  )
  expect(buttonViolations, `Kontrak tombol gagal di ${path}:\n${buttonViolations.join('\n')}`).toEqual([])

  return { errors, responses }
}

test.describe.serial('Smoke — Admin pages', () => {
  test.skip(!HAS_TEST_CREDENTIALS, 'Akun E2E belum tersedia')
  test.beforeEach(async ({ page }) => { await login(page) })

  for (const r of ROUTES_ADMIN) {
    test(`[ADMIN] ${r.name} → ${r.path}`, async ({ page }) => {
      const { errors, responses } = await visitWithChecks(page, r.path)
      expect(errors, `Console errors di ${r.path}:\n${errors.join('\n')}`).toEqual([])
      expect(responses, `5xx responses di ${r.path}:\n${JSON.stringify(responses)}`).toEqual([])
    })
  }
})

test.describe.serial('Smoke — Owner pages', () => {
  test.skip(!HAS_TEST_CREDENTIALS, 'Akun E2E belum tersedia')
  test.beforeEach(async ({ page }) => { await login(page) })

  for (const r of ROUTES_OWNER) {
    test(`[OWNER] ${r.name} → ${r.path}`, async ({ page }) => {
      const { errors, responses } = await visitWithChecks(page, r.path)
      expect(errors, `Console errors di ${r.path}:\n${errors.join('\n')}`).toEqual([])
      expect(responses, `5xx responses di ${r.path}:\n${JSON.stringify(responses)}`).toEqual([])
    })
  }
})

// Mobile responsive smoke
test.describe('Mobile responsive (375x667)', () => {
  test.skip(!HAS_TEST_CREDENTIALS, 'Akun E2E belum tersedia')
  test.use({ viewport: { width: 375, height: 667 } })

  test.beforeEach(async ({ page }) => { await login(page) })

  // Semua section ikut regression mobile, bukan hanya beberapa halaman contoh.
  const MOBILE_PAGES = [...ROUTES_ADMIN, ...ROUTES_OWNER].map((route) => route.path)

  for (const path of MOBILE_PAGES) {
    test(`[MOBILE] ${path} render tanpa horizontal overflow`, async ({ page }) => {
      await page.goto(path, { waitUntil: 'domcontentloaded' })
      await page.waitForLoadState('networkidle', { timeout: 10_000 }).catch(() => {})

      // Body width tidak melebihi viewport (kecuali table yg memang scroll horizontal)
      const docWidth = await page.evaluate(() => document.documentElement.scrollWidth)
      const viewWidth = await page.evaluate(() => window.innerWidth)

      // Toleransi 20px untuk scrollbar
      expect(docWidth, `doc width ${docWidth} > viewport ${viewWidth} at ${path}`).toBeLessThanOrEqual(viewWidth + 20)
    })
  }
})
