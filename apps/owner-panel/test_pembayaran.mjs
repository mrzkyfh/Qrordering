import { chromium } from '@playwright/test'

// Kredensial uji diambil dari environment — JANGAN hardcode di repo.
//   E2E_EMAIL=... E2E_PASSWORD=... node test_pembayaran.mjs
const E2E_EMAIL = process.env.E2E_EMAIL
const E2E_PASSWORD = process.env.E2E_PASSWORD
if (!E2E_EMAIL || !E2E_PASSWORD) {
  console.error('Set environment variable E2E_EMAIL dan E2E_PASSWORD dulu.')
  process.exit(1)
}

const browser = await chromium.launch({ headless: true })
const page = await browser.newPage()

const errors = []
page.on('console', msg => {
  if (msg.type() === 'error') errors.push('[CONSOLE ERROR] ' + msg.text())
})
page.on('pageerror', err => errors.push('[PAGE ERROR] ' + err.message))

await page.goto('http://localhost:5175/login')
await page.waitForLoadState('networkidle')
console.log('URL:', page.url())
await page.screenshot({ path: 'c:/tmp/01_login.png', fullPage: true })

// Log in
const emailInput = page.locator('input[type="email"], input[placeholder*="email"], input[name="email"]').first()
const passInput = page.locator('input[type="password"]').first()
await emailInput.fill(E2E_EMAIL)
await passInput.fill(E2E_PASSWORD)
await page.locator('button[type="submit"]').click()
await page.waitForTimeout(3000)
console.log('After login URL:', page.url())
await page.screenshot({ path: 'c:/tmp/02_after_login.png', fullPage: true })

if (errors.length) console.log('ERRORS SO FAR:', errors.join('\n'))
await browser.close()
