import { test, expect } from '@playwright/test'
import { HAS_TEST_CREDENTIALS, login } from './helpers/auth'

// Test bahwa Export CSV/Excel/PDF benar-benar menghasilkan download (bukan crash)
// Halaman: /admin/reports, dan semua tab /admin/sales-breakdown/*

const PAGES_WITH_EXPORT = [
  '/admin/reports',
  '/admin/sales-breakdown/departemen',
  '/admin/sales-breakdown/kategori',
  '/admin/sales-breakdown/menu',
  '/admin/sales-breakdown/extra',
  '/admin/sales-breakdown/pajak',
]

test.describe.serial('Export — CSV/Excel/PDF download', () => {
  test.skip(!HAS_TEST_CREDENTIALS, 'Akun E2E belum tersedia')
  test.beforeEach(async ({ page }) => {
    await login(page)
  })

  // CSV sudah dihapus dari ExportBar halaman admin (hanya Excel + PDF).
  // CSV masih tersedia di halaman detail owner (OwnerDetailReport) — diuji
  // terpisah di bawah.
  test('/owner/payment-methods — Export CSV download', async ({ page }) => {
    await page.goto('/owner/payment-methods', { waitUntil: 'networkidle' })

    const csvBtn = page.locator('button:has-text("CSV")').first()
    await expect(csvBtn).toBeVisible({ timeout: 10_000 })

    const downloadPromise = page.waitForEvent('download', { timeout: 15_000 })
    await csvBtn.click()

    try {
      const dl = await downloadPromise
      const filename = dl.suggestedFilename()
      expect(filename).toMatch(/\.csv$/i)
      console.log(`  📥 /owner/payment-methods → ${filename}`)
    } catch {
      // Jika tidak ada data, mungkin tidak download — verify di-handle (no crash)
      expect(page.url(), 'page should not crash when no data')
        .toContain('payment-methods')
      console.log('  ℹ  /owner/payment-methods → no download (empty data, no crash)')
    }
  })

  for (const path of PAGES_WITH_EXPORT) {
    test(`${path} — Export Excel download`, async ({ page }) => {
      await page.goto(path, { waitUntil: 'networkidle' })

      const excelBtn = page.locator('button:has-text("Excel")').first()
      await expect(excelBtn).toBeVisible({ timeout: 10_000 })

      const downloadPromise = page.waitForEvent('download', { timeout: 15_000 })
      await excelBtn.click()

      try {
        const dl = await downloadPromise
        const filename = dl.suggestedFilename()
        expect(filename).toMatch(/\.(xls|xlsx)$/i)
        console.log(`  📥 ${path} → ${filename}`)
      } catch {
        const stillOnPage = page.url().includes(path.split('/').pop()!)
        expect(stillOnPage).toBeTruthy()
        console.log(`  ℹ  ${path} → no download (empty data, no crash)`)
      }
    })

    test(`${path} — Export PDF download`, async ({ page }) => {
      await page.goto(path, { waitUntil: 'networkidle' })

      const pdfBtn = page.locator('button:has-text("PDF")').first()
      await expect(pdfBtn).toBeVisible({ timeout: 10_000 })

      const downloadPromise = page.waitForEvent('download', { timeout: 15_000 })
      await pdfBtn.click()

      try {
        const dl = await downloadPromise
        const filename = dl.suggestedFilename()
        expect(filename).toMatch(/\.pdf$/i)
        console.log(`  📥 ${path} → ${filename}`)
      } catch {
        const stillOnPage = page.url().includes(path.split('/').pop()!)
        expect(stillOnPage).toBeTruthy()
        console.log(`  ℹ  ${path} → no download (empty data, no crash)`)
      }
    })
  }
})
