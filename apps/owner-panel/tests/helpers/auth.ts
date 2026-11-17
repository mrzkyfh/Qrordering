import { type Page } from '@playwright/test'

export const TEST_CREDENTIALS = {
  email: process.env.E2E_EMAIL ?? '',
  password: process.env.E2E_PASSWORD ?? '',
}

export const HAS_TEST_CREDENTIALS = Boolean(
  TEST_CREDENTIALS.email && TEST_CREDENTIALS.password,
)

export async function login(page: Page) {
  if (!HAS_TEST_CREDENTIALS) {
    throw new Error('E2E_EMAIL dan E2E_PASSWORD wajib diisi untuk test terautentikasi')
  }
  await page.goto('/login')
  await page.waitForLoadState('networkidle')

  const emailInput = page.locator('input[type="email"], input[name="email"]').first()
  const passInput  = page.locator('input[type="password"]').first()
  await emailInput.fill(TEST_CREDENTIALS.email)
  await passInput.fill(TEST_CREDENTIALS.password)
  await page.locator('button[type="submit"]').click()

  // Wait until redirected away from /login
  await page.waitForURL((url) => !url.pathname.includes('/login'), { timeout: 15_000 })
}
