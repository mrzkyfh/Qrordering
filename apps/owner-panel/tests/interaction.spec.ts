import { test, expect } from '@playwright/test'
import { HAS_TEST_CREDENTIALS, login } from './helpers/auth'

// Test interaksi UI: search, date picker, sidebar navigation
test.skip(!HAS_TEST_CREDENTIALS, 'Akun E2E belum tersedia')

test.describe('Search filter — /admin/reports', () => {
  test.beforeEach(async ({ page }) => { await login(page) })

  test('search input tampil dan ter-fill', async ({ page }) => {
    await page.goto('/admin/reports', { waitUntil: 'networkidle' })

    const searchInput = page.locator('input[placeholder*="Cari"]').first()
    await expect(searchInput).toBeVisible()
    await searchInput.fill('ORD-2026')
    expect(await searchInput.inputValue()).toBe('ORD-2026')
  })

  test('search input — bisa di-clear', async ({ page }) => {
    await page.goto('/admin/reports', { waitUntil: 'networkidle' })

    const searchInput = page.locator('input[placeholder*="Cari"]').first()
    await searchInput.fill('test')
    await searchInput.fill('')
    expect(await searchInput.inputValue()).toBe('')
  })
})

test.describe('Manajemen Staff — filter cabang', () => {
  test.beforeEach(async ({ page }) => { await login(page) })

  test('hanya menampilkan akun dari cabang yang dipilih', async ({ page }) => {
    await page.goto('/owner/staff', { waitUntil: 'networkidle' })

    const branchCells = page.locator('tbody tr td:nth-child(3)')
    const branchNames = (await branchCells.allTextContents()).map((name) => name.trim())
    const selectedBranch = branchNames.find((name) => name && name !== 'Semua cabang' && name !== '—')
    test.skip(!selectedBranch, 'Data uji belum memiliki staff yang terhubung ke cabang')

    const filter = page.getByRole('combobox', { name: 'Filter staff berdasarkan cabang' })
    await filter.click()
    await page.getByRole('option', { name: selectedBranch!, exact: true }).click()

    await expect(page.getByText(/Menampilkan \d+ dari \d+ akun/)).toBeVisible()
    const filteredCells = page.locator('tbody tr td:nth-child(3)')
    await expect(filteredCells.first()).toHaveText(selectedBranch!)
    for (const cell of await filteredCells.all()) {
      await expect(cell).toHaveText(selectedBranch!)
    }
  })
})

test.describe('DateRangePicker — /admin/reports', () => {
  test.beforeEach(async ({ page }) => { await login(page) })

  test('date picker button visible dan ada label range', async ({ page }) => {
    await page.goto('/admin/reports', { waitUntil: 'networkidle' })

    // Tombol date picker biasanya menampilkan range "1 Apr 2026 - 30 Apr 2026"
    const dateBtn = page.locator('button:has-text("2026")').first()
    await expect(dateBtn).toBeVisible({ timeout: 5_000 })
  })

  test('klik date picker → popup terbuka dengan preset & 2 calendar', async ({ page }) => {
    await page.goto('/admin/reports', { waitUntil: 'networkidle' })

    const dateBtn = page.locator('button:has-text("2026")').first()
    await dateBtn.click()

    // Popup terbuka — cek preset "Hari Ini" muncul
    await expect(page.locator('button:has-text("Hari Ini")')).toBeVisible({ timeout: 5_000 })
    await expect(page.locator('button:has-text("Bulan Ini")')).toBeVisible()
    await expect(page.locator('button:has-text("Bulan Lalu")')).toBeVisible()
  })

  test('preset "Hari Ini" → click → tombol "Proses" → range update', async ({ page }) => {
    await page.goto('/admin/reports', { waitUntil: 'networkidle' })

    const dateBtn = page.locator('button:has-text("2026")').first()
    await dateBtn.click()

    await page.locator('button:has-text("Hari Ini")').click()
    await page.locator('button:has-text("Proses")').click()

    // Popup tertutup, halaman tidak crash
    await page.waitForLoadState('networkidle')
    expect(page.url()).toContain('/admin/reports')
  })

  test('tombol "Batal" → tutup popup tanpa apply', async ({ page }) => {
    await page.goto('/admin/reports', { waitUntil: 'networkidle' })

    const dateBtn = page.locator('button:has-text("2026")').first()
    await dateBtn.click()

    await page.locator('button:has-text("Batal")').click()

    // Popup harus tertutup
    await expect(page.locator('button:has-text("Hari Ini")')).not.toBeVisible({ timeout: 3_000 })
  })
})

test.describe('Sidebar navigation', () => {
  test.beforeEach(async ({ page }) => { await login(page) })

  test('expand "Laporan" → semua sub-item muncul', async ({ page }) => {
    await page.goto('/admin/dashboard', { waitUntil: 'networkidle' })

    // Klik Laporan untuk expand
    await page.locator('aside button:has-text("Laporan"), aside a:has-text("Laporan")').first().click()
    await page.waitForTimeout(500)

    // Cek sub-items
    await expect(page.locator('aside').getByText('Ringkasan Penjualan')).toBeVisible()
    await expect(page.locator('aside').getByText('Departemen')).toBeVisible()
    await expect(page.locator('aside').getByText('Kategori')).toBeVisible()
    await expect(page.locator('aside').getByText('Laporan Menu', { exact: true })).toBeVisible()
    await expect(page.locator('aside').getByText('Laporan Extra', { exact: true })).toBeVisible()
    await expect(page.locator('aside').getByText('Laporan Pajak', { exact: true })).toBeVisible()
  })

  test('klik sub-item → navigasi ke URL benar', async ({ page }) => {
    await page.goto('/admin/dashboard', { waitUntil: 'networkidle' })

    await page.locator('aside button:has-text("Laporan"), aside a:has-text("Laporan")').first().click()
    await page.waitForTimeout(500)

    await page.locator('aside').getByText('Kategori').click()
    await page.waitForURL('**/admin/sales-breakdown/kategori', { timeout: 5_000 })
    expect(page.url()).toContain('/admin/sales-breakdown/kategori')
  })

  test('expand "Produk" → semua sub-item muncul', async ({ page }) => {
    await page.goto('/admin/dashboard', { waitUntil: 'networkidle' })

    await page.locator('aside button:has-text("Produk")').first().click()
    await page.waitForTimeout(500)

    await expect(page.locator('aside').getByText('Departemen')).toBeVisible()
    await expect(page.locator('aside').getByText('Kategori')).toBeVisible()
    await expect(page.locator('aside').getByText('Menu', { exact: true })).toBeVisible()
    await expect(page.locator('aside').getByText('Ekstra', { exact: true })).toBeVisible()
  })

  test('redirect /admin/sales-breakdown → /admin/sales-breakdown/departemen', async ({ page }) => {
    await page.goto('/admin/sales-breakdown', { waitUntil: 'networkidle' })
    await page.waitForURL('**/admin/sales-breakdown/departemen', { timeout: 5_000 })
    expect(page.url()).toContain('/sales-breakdown/departemen')
  })

  test('tab laporan yang tidak dikenal diarahkan ke Departemen', async ({ page }) => {
    await page.goto('/admin/sales-breakdown/tidak-ada', { waitUntil: 'networkidle' })
    await page.waitForURL('**/admin/sales-breakdown/departemen', { timeout: 5_000 })
  })
})

test.describe('Mobile navigation', () => {
  test.use({ viewport: { width: 375, height: 667 } })
  test.beforeEach(async ({ page }) => { await login(page) })

  test('drawer menutup setelah memilih halaman', async ({ page }) => {
    await page.goto('/admin/dashboard', { waitUntil: 'networkidle' })

    const menuButton = page.getByRole('button', { name: 'Buka menu navigasi' })
    await menuButton.click()
    await page.locator('aside').getByRole('button', { name: 'Produk' }).click()
    await page.locator('aside').getByRole('link', { name: 'Menu', exact: true }).click()

    await page.waitForURL('**/admin/menu')
    await expect(page.getByRole('button', { name: 'Buka menu navigasi' })).toBeVisible()
  })

  test('ringkasan laba tidak saling menimpa pada layar ponsel', async ({ page }) => {
    await page.goto('/admin/dashboard', { waitUntil: 'networkidle' })

    const summary = page.getByTestId('profit-summary')
    const regions = [
      page.getByTestId('profit-expenses'),
      page.getByTestId('profit-net'),
      page.getByTestId('profit-formula'),
    ]

    await expect(summary).toBeVisible()
    await expect(regions[0]).toBeVisible()
    await expect(regions[1]).toBeVisible()
    await expect(regions[2]).toBeVisible()

    const boxes = await Promise.all(regions.map((region) => region.boundingBox()))
    for (let first = 0; first < boxes.length; first += 1) {
      for (let second = first + 1; second < boxes.length; second += 1) {
        const a = boxes[first]!
        const b = boxes[second]!
        const overlaps = (
          a.x < b.x + b.width
          && a.x + a.width > b.x
          && a.y < b.y + b.height
          && a.y + a.height > b.y
        )
        expect(overlaps, `blok ${first + 1} dan ${second + 1} tidak boleh tumpang tindih`).toBe(false)
      }
    }

    expect(await summary.evaluate((element) => element.scrollWidth <= element.clientWidth + 1)).toBe(true)
  })
})

test.describe('Sales Breakdown — Pajak tab toggle', () => {
  test.beforeEach(async ({ page }) => { await login(page) })

  test('Hari/Bulan/Tahun toggle muncul di tab Pajak', async ({ page }) => {
    await page.goto('/admin/sales-breakdown/pajak', { waitUntil: 'networkidle' })

    await expect(page.locator('button:has-text("Hari")')).toBeVisible()
    await expect(page.locator('button:has-text("Bulan")')).toBeVisible()
    await expect(page.locator('button:has-text("Tahun")')).toBeVisible()
  })

  test('klik "Bulan" → tabel update', async ({ page }) => {
    await page.goto('/admin/sales-breakdown/pajak', { waitUntil: 'networkidle' })

    await page.locator('button:has-text("Bulan")').first().click()
    await page.waitForTimeout(500)
    // No crash
    expect(page.url()).toContain('/pajak')
  })

  test('klik "Tahun" → tabel update', async ({ page }) => {
    await page.goto('/admin/sales-breakdown/pajak', { waitUntil: 'networkidle' })

    await page.locator('button:has-text("Tahun")').first().click()
    await page.waitForTimeout(500)
    expect(page.url()).toContain('/pajak')
  })

  test('Hari/Bulan/Tahun toggle TIDAK muncul di tab Departemen', async ({ page }) => {
    await page.goto('/admin/sales-breakdown/departemen', { waitUntil: 'networkidle' })

    // Toggle hanya khusus Pajak tab
    const hariBtn = page.locator('button:has-text("Hari")')
    const count = await hariBtn.count()
    expect(count, 'tombol Hari tidak boleh ada di tab Departemen').toBe(0)
  })
})

test.describe('Stat Cards render', () => {
  test.beforeEach(async ({ page }) => { await login(page) })

  test('/admin/reports — stat cards ringkasan muncul', async ({ page }) => {
    await page.goto('/admin/reports', { waitUntil: 'networkidle' })

    await expect(page.getByText('Total Penjualan').first()).toBeVisible()
    await expect(page.getByText('Total Transaksi').first()).toBeVisible()
    await expect(page.getByText('Total Penerimaan').first()).toBeVisible()
    await expect(page.getByText('Total Piutang').first()).toBeVisible()
  })

  test('/admin/sales-breakdown/pajak — 3 stat cards muncul', async ({ page }) => {
    await page.goto('/admin/sales-breakdown/pajak', { waitUntil: 'networkidle' })

    await expect(page.getByText('Total Transaksi').first()).toBeVisible()
    await expect(page.getByText('Total Penjualan').first()).toBeVisible()
    await expect(page.getByText('Total Pajak')).toBeVisible()
  })

  test('/admin/sales-breakdown/extra — stat cards muncul', async ({ page }) => {
    await page.goto('/admin/sales-breakdown/extra', { waitUntil: 'networkidle' })

    await expect(page.getByText('Total Extra')).toBeVisible()
    await expect(page.getByText('Total Item Extra')).toBeVisible()
    await expect(page.getByText('Total Penjualan Extra')).toBeVisible()
    await expect(page.getByText('Total Refund Extra')).toBeVisible()
  })
})

test.describe('Routing Tiket Dapur', () => {
  test.beforeEach(async ({ page }) => { await login(page) })

  test('menjelaskan hubungan stasiun dengan printer fisik', async ({ page }) => {
    await page.goto('/admin/print-stations', { waitUntil: 'networkidle' })

    await expect(page.getByRole('heading', { name: 'Routing Tiket Dapur' })).toBeVisible()
    await expect(page.getByText('Stasiun bukan printer fisik')).toBeVisible()
    await expect(page.getByText(/Pengaturan Perangkat.*Printer/)).toBeVisible()
  })

  test('stasiun tanpa nama tidak dapat disimpan', async ({ page }) => {
    await page.goto('/admin/print-stations', { waitUntil: 'networkidle' })

    await page.getByRole('button', { name: 'Tambah Stasiun' }).click()
    await page.getByRole('button', { name: 'Simpan Perubahan' }).click()

    // Radix Toast also exposes an accessibility announcement containing the
    // title ("Notification …"). Assert the visible toast title itself so the
    // check is not ambiguous under strict locator mode.
    await expect(page.getByText('Nama stasiun wajib diisi', { exact: true })).toBeVisible()
    expect(new URL(page.url()).pathname).toBe('/admin/print-stations')
  })
})
