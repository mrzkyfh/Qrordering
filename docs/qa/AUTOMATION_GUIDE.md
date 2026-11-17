# Automation Guide — Owner Panel
**Stack:** Playwright + TypeScript  
**Tanggal:** 2026-05-27

---

## 1. Setup

```bash
cd apps/owner-panel
npm install -D @playwright/test
npx playwright install chromium
```

Buat `playwright.config.ts`:
```ts
import { defineConfig } from '@playwright/test'

export default defineConfig({
  testDir: './e2e',
  use: {
    baseURL: 'http://localhost:5173',
    headless: true,
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },
  reporter: [['html', { outputFolder: 'playwright-report' }]],
})
```

---

## 2. Struktur Folder

```
apps/owner-panel/e2e/
├── fixtures/
│   └── auth.ts          # Login helper
├── pages/
│   ├── LoginPage.ts     # Page Object
│   ├── MenuPage.ts
│   ├── StockPage.ts
│   └── ...
├── tests/
│   ├── auth.spec.ts
│   ├── menu.spec.ts
│   ├── stock.spec.ts
│   ├── orders.spec.ts
│   ├── reports.spec.ts
│   └── loyalty.spec.ts
└── utils/
    └── supabase-seed.ts # Reset data test
```

---

## 3. Auth Fixture

```ts
// e2e/fixtures/auth.ts
import { test as base, Page } from '@playwright/test'

type AuthFixture = { ownerPage: Page; adminPage: Page }

export const test = base.extend<AuthFixture>({
  ownerPage: async ({ browser }, use) => {
    const ctx = await browser.newContext({ storageState: 'e2e/.auth/owner.json' })
    const page = await ctx.newPage()
    await use(page)
    await ctx.close()
  },
  adminPage: async ({ browser }, use) => {
    const ctx = await browser.newContext({ storageState: 'e2e/.auth/admin.json' })
    const page = await ctx.newPage()
    await use(page)
    await ctx.close()
  },
})

// Setup: simpan session sekali
export async function saveAdminSession(page: Page) {
  await page.goto('/login')
  await page.fill('[name=email]', process.env.TEST_ADMIN_EMAIL!)
  await page.fill('[name=password]', process.env.TEST_ADMIN_PASS!)
  await page.click('button[type=submit]')
  await page.waitForURL('/admin/dashboard')
  await page.context().storageState({ path: 'e2e/.auth/admin.json' })
}
```

---

## 4. Contoh Test Case

### Auth Test
```ts
// e2e/tests/auth.spec.ts
import { test, expect } from '@playwright/test'

test('TC-001-03: Login email salah menampilkan error', async ({ page }) => {
  await page.goto('/login')
  await page.fill('[name=email]', 'salah@example.com')
  await page.fill('[name=password]', 'password123')
  await page.click('button[type=submit]')
  await expect(page.getByText('Email atau password salah')).toBeVisible()
})

test('TC-001-06: Email format invalid', async ({ page }) => {
  await page.goto('/login')
  await page.fill('[name=email]', 'bukanEmail')
  await page.fill('[name=password]', 'password123')
  await page.click('button[type=submit]')
  await expect(page.locator('[role=alert]').first()).toBeVisible()
})

test('TC-001-11: Logout berhasil', async ({ page }) => {
  // Setelah login
  await page.click('[data-testid=logout-button]')
  await page.waitForURL('/login')
  await expect(page).toHaveURL('/login')
})
```

### Menu Manager Test
```ts
// e2e/tests/menu.spec.ts
import { test } from '../fixtures/auth'
import { expect } from '@playwright/test'

test('TC-008-05: Tambah menu valid', async ({ adminPage: page }) => {
  await page.goto('/admin/menu')
  await page.click('[data-testid=add-menu-btn]')
  await page.fill('[name=name]', 'Nasi Goreng Test')
  await page.fill('[name=price]', '25000')
  await page.click('button[type=submit]')
  await expect(page.getByText('Nasi Goreng Test')).toBeVisible()
})

test('TC-008-07: Harga 0 ditolak', async ({ adminPage: page }) => {
  await page.goto('/admin/menu')
  await page.click('[data-testid=add-menu-btn]')
  await page.fill('[name=name]', 'Test Item')
  await page.fill('[name=price]', '0')
  await page.click('button[type=submit]')
  await expect(page.getByText(/harga.*positif|harga.*0/i)).toBeVisible()
})
```

### Stock Adjustment Test
```ts
test('TC-010-09: Adjustment pembelian berhasil', async ({ adminPage: page }) => {
  await page.goto('/admin/stock')
  await page.click('[data-testid=adjust-btn]').first()
  await page.selectOption('[name=type]', 'purchase')
  await page.fill('[name=qty]', '10')
  await page.click('button[type=submit]')
  await expect(page.getByText(/berhasil/i)).toBeVisible()
})

test('TC-010-11: Qty negatif diblokir', async ({ adminPage: page }) => {
  await page.goto('/admin/stock')
  await page.click('[data-testid=adjust-btn]').first()
  await page.fill('[name=qty]', '-5')
  const qtyValue = await page.inputValue('[name=qty]')
  expect(Number(qtyValue)).toBeGreaterThanOrEqual(0)
})
```

---

## 5. Jalankan Test

```bash
# Semua test
npx playwright test

# Test spesifik
npx playwright test e2e/tests/auth.spec.ts

# Dengan UI (headed)
npx playwright test --headed

# Generate report
npx playwright show-report
```

---

## 6. CI Integration (GitHub Actions)

```yaml
# .github/workflows/e2e.yml
name: E2E Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20' }
      - run: npm ci
        working-directory: apps/owner-panel
      - run: npx playwright install --with-deps chromium
        working-directory: apps/owner-panel
      - run: npx playwright test
        working-directory: apps/owner-panel
        env:
          TEST_ADMIN_EMAIL: ${{ secrets.TEST_ADMIN_EMAIL }}
          TEST_ADMIN_PASS: ${{ secrets.TEST_ADMIN_PASS }}
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: playwright-report
          path: apps/owner-panel/playwright-report/
```

---

## 7. Prioritas Automasi

| Fase | Test Cases | Target |
|------|-----------|--------|
| Fase 1 (sekarang) | Auth, Route Guard, CRUD Menu, Stock Adjustment | Sprint ini |
| Fase 2 | Order List, Reports Export, Shift | Sprint +1 |
| Fase 3 | Loyalty, Promo, Finance Report | Sprint +2 |
| Ongoing | Regression sebelum deploy | Setiap deploy |
