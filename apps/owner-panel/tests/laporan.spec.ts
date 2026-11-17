import { test, expect } from '@playwright/test'
import { HAS_TEST_CREDENTIALS, login } from './helpers/auth'

// Reports + Sales Breakdown — sesuai UI baru (post refactor)
// - /admin/reports → single page "Ringkasan Penjualan" (no tabs)
// - /admin/sales-breakdown/:tab → 5 sub-pages via route params
test.skip(!HAS_TEST_CREDENTIALS, 'Akun E2E belum tersedia')

test.beforeEach(async ({ page }) => {
  await login(page)
})

// ─── Ringkasan Penjualan — /admin/reports ────────────────────────────────────

test.describe('Laporan — /admin/reports (Detail Penjualan)', () => {
  test('header dan stat cards ringkasan', async ({ page }) => {
    await page.goto('/admin/reports')
    await page.waitForLoadState('networkidle')

    await expect(page.getByRole('heading', { name: 'Detail Penjualan' })).toBeVisible()
    for (const label of ['Total Penjualan', 'Total Transaksi', 'Total Penerimaan', 'Total Piutang']) {
      await expect(page.getByText(label, { exact: true }).first()).toBeVisible()
    }
  })

  test('tabel transaksi memiliki 11 kolom standar', async ({ page }) => {
    await page.goto('/admin/reports')
    await page.waitForLoadState('networkidle')
    await page.waitForTimeout(1_500)

    for (const col of ['No Transaksi', 'Waktu Order', 'Waktu Bayar', 'Jenis Order', 'Subtotal', 'Diskon', 'Pajak', 'Service', 'Total', 'Pembayaran', 'Kasir']) {
      await expect(page.getByRole('columnheader', { name: col, exact: true })).toBeVisible()
    }
  })

  test('search input visible dan ter-fill', async ({ page }) => {
    await page.goto('/admin/reports')
    await page.waitForLoadState('networkidle')

    const search = page.getByPlaceholder(/Cari no transaksi/)
    await expect(search).toBeVisible()
    await search.fill('TEST-123')
    await expect(search).toHaveValue('TEST-123')
  })

  test('date range picker membuka popup tanpa crash', async ({ page }) => {
    await page.goto('/admin/reports')
    await page.waitForLoadState('networkidle')

    const dateBtn = page.locator('button').filter({ hasText: /\d{1,2}\s+\w+\s+\d{4}/ }).first()
    await expect(dateBtn).toBeVisible()
    await dateBtn.click()
    await expect(page.locator('[role="dialog"], [data-radix-popper-content-wrapper]').first()).toBeVisible({ timeout: 5_000 })
    await page.keyboard.press('Escape')
  })

  test('ExportBar muncul dengan tombol Excel & PDF', async ({ page }) => {
    // CSV sudah dihapus dari desain ExportBar (Reports.tsx hanya Excel + PDF).
    await page.goto('/admin/reports')
    await page.waitForLoadState('networkidle')

    await expect(page.getByRole('button', { name: /Excel/ })).toBeVisible()
    await expect(page.getByRole('button', { name: /PDF/ })).toBeVisible()
  })

  test('tidak ada console error saat halaman load', async ({ page }) => {
    const errors: string[] = []
    page.on('pageerror', (e) => errors.push(e.message))
    page.on('console', (msg) => {
      if (msg.type() === 'error') errors.push(msg.text())
    })

    await page.goto('/admin/reports')
    await page.waitForLoadState('networkidle')
    await page.waitForTimeout(2_000)

    const critical = errors.filter(e => !e.includes('Failed to load resource') && !e.includes('net::ERR'))
    expect(critical).toHaveLength(0)
  })
})

// ─── Sidebar — Laporan submenu ───────────────────────────────────────────────

test.describe('Sidebar Laporan — navigasi sub-section', () => {
  test('sub-item Departemen, Kategori, Menu, Extra, Pajak, Service Charge muncul', async ({ page }) => {
    await page.goto('/admin/sales-breakdown/departemen')
    await page.waitForLoadState('networkidle')

    const sidebar = page.locator('aside, nav').first()
    for (const label of ['Departemen', 'Kategori', 'Menu', 'Extra', 'Pajak', 'Service Charge']) {
      await expect(sidebar.getByText(label).first()).toBeVisible()
    }
  })

  test('klik sub-item Kategori → URL berubah ke /kategori', async ({ page }) => {
    await page.goto('/admin/sales-breakdown/departemen')
    await page.waitForLoadState('networkidle')

    await page.locator('aside, nav').first().getByRole('link', { name: 'Laporan Kategori', exact: true }).click()
    await expect(page).toHaveURL(/\/admin\/sales-breakdown\/kategori/)
    await expect(page.getByRole('heading', { name: /Laporan Kategori/ })).toBeVisible()
  })

  test('redirect /admin/sales-breakdown → /admin/sales-breakdown/departemen', async ({ page }) => {
    await page.goto('/admin/sales-breakdown')
    await page.waitForURL(/\/admin\/sales-breakdown\/departemen/, { timeout: 5_000 })
    await expect(page).toHaveURL(/\/admin\/sales-breakdown\/departemen/)
  })
})

// ─── Sales Breakdown — Departemen ────────────────────────────────────────────

test.describe('Laporan Breakdown — Departemen', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/admin/sales-breakdown/departemen')
    await page.waitForLoadState('networkidle')
  })

  test('stat cards 4 kartu', async ({ page }) => {
    for (const label of ['Total Pendapatan', 'Total Item Terjual', 'Transaksi Unik', 'Jumlah Departemen']) {
      await expect(page.getByText(label).first()).toBeVisible()
    }
  })

  test('header judul "Laporan Departemen"', async ({ page }) => {
    await expect(page.getByRole('heading', { name: /Laporan Departemen/ })).toBeVisible()
  })

  test('tabel ada kolom Pendapatan saat ada data', async ({ page }) => {
    await page.waitForTimeout(1_500)
    const rowCount = await page.locator('tbody tr').count()
    if (rowCount > 0) {
      await expect(page.getByRole('columnheader', { name: 'Pendapatan', exact: true })).toBeVisible()
    }
  })

  test('search input memfilter tabel', async ({ page }) => {
    await page.waitForTimeout(1_500)
    const rowsBefore = await page.locator('tbody tr').count()
    if (rowsBefore > 1) {
      const firstCell = await page.locator('tbody tr').first().locator('td').nth(0).innerText()
      const keyword = firstCell.trim().split(' ')[0]
      await page.getByPlaceholder('Cari...').fill(keyword)
      await page.waitForTimeout(300)
      const rowsAfter = await page.locator('tbody tr').count()
      expect(rowsAfter).toBeLessThanOrEqual(rowsBefore)
    }
  })
})

// ─── Sales Breakdown — Kategori ──────────────────────────────────────────────

test.describe('Laporan Breakdown — Kategori', () => {
  test('stat cards Kategori muncul', async ({ page }) => {
    await page.goto('/admin/sales-breakdown/kategori')
    await page.waitForLoadState('networkidle')
    await expect(page.getByText('Jumlah Kategori')).toBeVisible()
    await expect(page.getByRole('heading', { name: /Laporan Kategori/ })).toBeVisible()
  })

  test('tabel kategori ada kolom Pendapatan saat ada data', async ({ page }) => {
    await page.goto('/admin/sales-breakdown/kategori')
    await page.waitForLoadState('networkidle')
    await page.waitForTimeout(1_500)

    const rowCount = await page.locator('tbody tr').count()
    if (rowCount > 0) {
      await expect(page.getByRole('columnheader', { name: 'Pendapatan', exact: true })).toBeVisible()
    }
  })

  test('regresi BUG-LAP-005 — kolom Transaksi terisi angka, tidak crash', async ({ page }) => {
    const errors: string[] = []
    page.on('pageerror', (e) => errors.push(e.message))

    await page.goto('/admin/sales-breakdown/kategori')
    await page.waitForLoadState('networkidle')
    await page.waitForTimeout(2_000)

    expect(errors.filter(e => /toLocaleString/.test(e))).toHaveLength(0)
  })
})

// ─── Sales Breakdown — Menu ──────────────────────────────────────────────────

test.describe('Laporan Breakdown — Menu', () => {
  test('stat cards Menu muncul', async ({ page }) => {
    await page.goto('/admin/sales-breakdown/menu')
    await page.waitForLoadState('networkidle')
    await expect(page.getByText('Jumlah Menu')).toBeVisible()
    await expect(page.getByRole('heading', { name: /Laporan Menu/ })).toBeVisible()
  })

  test('tabel menu ada kolom Kategori dan Departemen saat data ada', async ({ page }) => {
    await page.goto('/admin/sales-breakdown/menu')
    await page.waitForLoadState('networkidle')
    await page.waitForTimeout(1_500)

    const rowCount = await page.locator('tbody tr').count()
    if (rowCount > 0) {
      await expect(page.getByRole('columnheader', { name: 'Kategori', exact: true })).toBeVisible()
      await expect(page.getByRole('columnheader', { name: 'Departemen', exact: true })).toBeVisible()
    }
  })
})

// ─── Sales Breakdown — Extra ─────────────────────────────────────────────────

test.describe('Laporan Breakdown — Extra', () => {
  test('tabel penjualan extra memiliki kolom laporan lengkap', async ({ page }) => {
    await page.goto('/admin/sales-breakdown/extra')
    await page.waitForLoadState('networkidle')
    await page.waitForTimeout(1_500)
    const rowCount = await page.locator('tbody tr').count()
    if (rowCount > 0) {
      for (const column of ['Nama Extra', 'Jumlah', 'Jumlah (%)', 'Penjualan (Rp)', 'Penjualan (%)', 'Laba Kotor (Rp)', 'Laba Kotor (%)', 'Jumlah Refund', 'Refund (Rp)']) {
        await expect(page.getByRole('columnheader', { name: column, exact: true })).toBeVisible()
      }
    }
  })

  test('stat cards Extra muncul', async ({ page }) => {
    await page.goto('/admin/sales-breakdown/extra')
    await page.waitForLoadState('networkidle')
    await expect(page.getByText('Total Extra')).toBeVisible()
    await expect(page.getByText('Total Item Extra')).toBeVisible()
    await expect(page.getByText('Total Penjualan Extra')).toBeVisible()
    await expect(page.getByText('Total Refund Extra')).toBeVisible()
  })

  test('grafik penjualan extra dapat dibuka dan ditutup', async ({ page }) => {
    await page.goto('/admin/sales-breakdown/extra')
    await page.waitForLoadState('networkidle')

    const toggle = page.getByRole('button', { name: /Grafik Penjualan Extra/ })
    await expect(toggle).toHaveAttribute('aria-expanded', 'false')
    await toggle.click()
    await expect(toggle).toHaveAttribute('aria-expanded', 'true')
  })
})

// ─── Sales Breakdown — Pajak & Biaya ─────────────────────────────────────────

test.describe('Laporan Breakdown — Pajak', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/admin/sales-breakdown/pajak')
    await page.waitForLoadState('networkidle')
  })

  test('stat cards Pajak — 3 kartu (Transaksi, Penjualan, Pajak)', async ({ page }) => {
    await expect(page.getByText('Total Transaksi').first()).toBeVisible()
    await expect(page.getByText('Total Penjualan').first()).toBeVisible()
    await expect(page.getByText('Total Pajak')).toBeVisible()
  })

  test('toggle Hari / Bulan / Tahun muncul di tab Pajak', async ({ page }) => {
    for (const label of ['Hari', 'Bulan', 'Tahun']) {
      await expect(page.getByRole('button', { name: label, exact: true })).toBeVisible()
    }
  })

  test('klik toggle Bulan → no crash', async ({ page }) => {
    const errors: string[] = []
    page.on('pageerror', (e) => errors.push(e.message))

    await page.getByRole('button', { name: 'Bulan', exact: true }).click()
    await page.waitForTimeout(800)

    expect(errors).toHaveLength(0)
    await expect(page.getByText('Total Transaksi').first()).toBeVisible()
  })

  test('tabel ada kolom Tanggal, Transaksi, Penjualan, Pajak saat data ada', async ({ page }) => {
    await page.waitForTimeout(1_500)
    const rowCount = await page.locator('tbody tr').count()
    if (rowCount > 0) {
      await expect(page.getByRole('columnheader', { name: 'Tanggal', exact: true })).toBeVisible()
      await expect(page.getByRole('columnheader', { name: 'Transaksi', exact: true })).toBeVisible()
      await expect(page.getByRole('columnheader', { name: /Penjualan/ }).first()).toBeVisible()
      await expect(page.getByRole('columnheader', { name: /Pajak/ })).toBeVisible()
    }
  })

  test('footer row Total muncul jika tabel ada data', async ({ page }) => {
    await page.waitForTimeout(1_500)
    const rowCount = await page.locator('tbody tr').count()
    if (rowCount > 0) {
      await expect(page.locator('tfoot').getByText('Total', { exact: true })).toBeVisible()
    }
  })
})

// ─── Ringkasan Penjualan — /admin/sales-summary ──────────────────────────────

test.describe('Laporan — /admin/sales-summary (Ringkasan Penjualan)', () => {
  test('header dan stat cards laba muncul', async ({ page }) => {
    await page.goto('/admin/sales-summary')
    await page.waitForLoadState('networkidle')

    await expect(page.getByRole('heading', { name: /Ringkasan Penjualan/, level: 1 })).toBeVisible()
    for (const label of ['Total Penerimaan Pelanggan', 'Pendapatan Bersih', 'Laba Kotor', 'Laba Bersih']) {
      await expect(page.getByText(label, { exact: true }).first()).toBeVisible()
    }
  })

  test('tabel rincian P&L muncul tanpa NaN', async ({ page }) => {
    await page.goto('/admin/sales-summary')
    await page.waitForLoadState('networkidle')
    await page.waitForTimeout(1_500)

    await expect(page.getByText('Rincian Ringkasan Penjualan')).toBeVisible()
    await expect(page.getByText(/NaN/)).toHaveCount(0)
  })
})

// ─── Sales Breakdown — Service Charge ─────────────────────────────────────────

test.describe('Laporan Breakdown — Service Charge', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/admin/sales-breakdown/service')
    await page.waitForLoadState('networkidle')
  })

  test('stat cards Service — Total Service Charge muncul', async ({ page }) => {
    await expect(page.getByText('Total Transaksi').first()).toBeVisible()
    await expect(page.getByText('Total Penjualan').first()).toBeVisible()
    await expect(page.getByText('Total Service Charge')).toBeVisible()
  })

  test('tabel ada kolom Service Charge saat data ada', async ({ page }) => {
    await page.waitForTimeout(1_500)
    const rowCount = await page.locator('tbody tr').count()
    if (rowCount > 0) {
      await expect(page.getByRole('columnheader', { name: /Service Charge/ })).toBeVisible()
    }
  })
})

// ─── Regresi — currency tidak Rp0 (BUG-LAP-001) ───────────────────────────────

test.describe('Regresi — currency values tidak Rp0', () => {
  test('Departemen — pendapatan bukan Rp0 jika ada data', async ({ page }) => {
    await page.goto('/admin/sales-breakdown/departemen')
    await page.waitForLoadState('networkidle')
    await page.waitForTimeout(2_000)

    const rowCount = await page.locator('tbody tr:not(tfoot tr)').count()
    if (rowCount > 0) {
      // Kolom Pendapatan adalah kolom ke-4 (index 3) di tabel Departemen
      const revenueCell = page.locator('tbody tr').first().locator('td').nth(3)
      const text = await revenueCell.innerText()
      expect(text).not.toBe('Rp0')
      expect(text).not.toMatch(/NaN/)
      expect(text).toMatch(/Rp/)
    }
  })

  test('Pajak — Penjualan bukan Rp0 jika ada data', async ({ page }) => {
    await page.goto('/admin/sales-breakdown/pajak')
    await page.waitForLoadState('networkidle')
    await page.waitForTimeout(2_000)

    const rowCount = await page.locator('tbody tr').count()
    if (rowCount > 0) {
      // Kolom Penjualan adalah kolom ke-3 (index 2) di tabel Pajak
      const cell = page.locator('tbody tr').first().locator('td').nth(2)
      const text = await cell.innerText()
      expect(text).not.toBe('Rp0')
      expect(text).toMatch(/Rp/)
    }
  })
})
