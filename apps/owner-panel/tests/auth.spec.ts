import { test, expect } from '@playwright/test'
import { HAS_TEST_CREDENTIALS, login, TEST_CREDENTIALS } from './helpers/auth'

test.describe('Auth — Login Flow', () => {
  test('TC-AUTH-01: login dengan kredensial valid → redirect ke dashboard', async ({ page }) => {
    test.skip(!HAS_TEST_CREDENTIALS, 'Akun E2E belum tersedia')
    await page.goto('/login')
    await page.locator('input[type="email"]').fill(TEST_CREDENTIALS.email)
    await page.locator('input[type="password"]').fill(TEST_CREDENTIALS.password)
    await page.locator('button[type="submit"]').click()

    await page.waitForURL((url) => !url.pathname.includes('/login'), { timeout: 10_000 })
    expect(page.url()).not.toContain('/login')
  })

  test('TC-AUTH-02: login dengan password salah → error message', async ({ page }) => {
    test.skip(!HAS_TEST_CREDENTIALS, 'Akun E2E belum tersedia')
    await page.goto('/login')
    await page.locator('input[type="email"]').fill(TEST_CREDENTIALS.email)
    await page.locator('input[type="password"]').fill('wrongpassword12345')
    await page.locator('button[type="submit"]').click()

    // Web-first assertion: tunggu error muncul (request auth bisa lambat —
    // fixed wait 2 detik membuat test flaky saat server > 2s merespons).
    await expect(page.locator('text=/salah|invalid|tidak valid/i').first())
      .toBeVisible({ timeout: 15_000 })
    expect(page.url()).toContain('/login')
  })

  test('TC-AUTH-03: login dengan email tidak terdaftar → error', async ({ page }) => {
    await page.goto('/login')
    await page.locator('input[type="email"]').fill('notexist-random@nowhere.io')
    await page.locator('input[type="password"]').fill('anyPassword123')
    await page.locator('button[type="submit"]').click()

    await page.waitForTimeout(2000)
    expect(page.url()).toContain('/login')
  })

  test('TC-AUTH-04: validasi password min 8 chars (client-side)', async ({ page }) => {
    await page.goto('/login')
    await page.locator('input[type="email"]').fill('test@test.com')
    await page.locator('input[type="password"]').fill('123')
    await page.locator('button[type="submit"]').click()
    await page.waitForTimeout(1000)

    // Should still be on login page
    expect(page.url()).toContain('/login')
  })

  test('TC-AUTH-05: validasi email format', async ({ page }) => {
    await page.goto('/login')
    await page.locator('input[type="email"]').fill('notanemail')
    await page.locator('input[type="password"]').fill('validpassword123')
    await page.locator('button[type="submit"]').click()
    await page.waitForTimeout(1000)

    expect(page.url()).toContain('/login')
  })

  test('TC-AUTH-06: toggle show password', async ({ page }) => {
    await page.goto('/login')
    const passInput = page.locator('input[name="password"]')
    await passInput.fill('secret123')

    const showButton = page.getByRole('button', { name: 'Tampilkan password' })
    await expect(showButton).toBeVisible()
    await showButton.focus()
    await page.keyboard.press('Enter')

    await expect(passInput).toHaveAttribute('type', 'text')
    const hideButton = page.getByRole('button', { name: 'Sembunyikan password' })
    await expect(hideButton).toHaveAttribute('aria-pressed', 'true')
    await hideButton.click()
    await expect(passInput).toHaveAttribute('type', 'password')
  })

  test('semua tombol login memiliki nama aksesibel dan type eksplisit', async ({ page }) => {
    await page.goto('/login')

    const buttons = page.locator('button:visible')
    await expect(buttons).toHaveCount(2)
    for (const button of await buttons.all()) {
      await expect(button).toHaveAttribute('type', /^(button|submit)$/)
      const name = await button.evaluate((element) =>
        (
          element.getAttribute('aria-label')
          || element.textContent
          || element.getAttribute('title')
          || ''
        ).trim(),
      )
      expect(name).not.toBe('')
    }
  })
})

test.describe('Auth — Protected Routes', () => {
  test('TC-AUTH-08: akses /admin/dashboard tanpa login → redirect /login', async ({ page, context }) => {
    await context.clearCookies()
    await page.goto('/admin/dashboard')

    await page.waitForURL((url) => url.pathname.includes('/login'), { timeout: 10_000 })
    expect(page.url()).toContain('/login')
  })

  test('akses /admin/reports tanpa login → redirect /login', async ({ page, context }) => {
    await context.clearCookies()
    await page.goto('/admin/reports')

    await page.waitForURL((url) => url.pathname.includes('/login'), { timeout: 10_000 })
    expect(page.url()).toContain('/login')
  })

  test('akses /owner/dashboard tanpa login → redirect /login', async ({ page, context }) => {
    await context.clearCookies()
    await page.goto('/owner/dashboard')

    await page.waitForURL((url) => url.pathname.includes('/login'), { timeout: 10_000 })
    expect(page.url()).toContain('/login')
  })
})

test.describe('Auth — Logout', () => {
  test.skip(!HAS_TEST_CREDENTIALS, 'Akun E2E belum tersedia')
  test('TC-AUTH-07: logout dari sidebar → redirect /login', async ({ page }) => {
    await login(page)
    expect(page.url()).not.toContain('/login')

    // Klik tombol Keluar di sidebar
    await page.locator('button:has-text("Keluar"), a:has-text("Keluar")').first().click()

    await page.waitForURL((url) => url.pathname.includes('/login'), { timeout: 10_000 })
    expect(page.url()).toContain('/login')
  })
})

test.describe('Auth — Session', () => {
  test.skip(!HAS_TEST_CREDENTIALS, 'Akun E2E belum tersedia')
  test('login → reload page → tetap login (session persisted)', async ({ page }) => {
    await login(page)
    const urlBefore = page.url()

    await page.reload()
    await page.waitForLoadState('domcontentloaded')

    // Should still be logged in
    expect(page.url()).not.toContain('/login')
    expect(page.url()).toBe(urlBefore)
  })
})
