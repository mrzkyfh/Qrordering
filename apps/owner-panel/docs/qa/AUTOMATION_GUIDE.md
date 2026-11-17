# Automation Guide — Owner Panel

**Versi:** 1.0
**Tanggal:** 2026-05-28

Dokumen ini menjelaskan setup dan struktur automated testing untuk `apps/owner-panel`.

---

## 1. Tooling

| Layer | Tool | Lokasi | Run command |
|---|---|---|---|
| **API tests** | `node:test` + native `fetch` | `tests/api/*.test.mjs` | `node --test tests/api/*.test.mjs` |
| **E2E browser** | Playwright (Chromium) | `tests/*.spec.ts` | `npm run test` |
| **Build / typecheck** | TypeScript | — | `npm run build` |
| **Lint** | ESLint | — | `npm run lint` |

## 2. Setup Awal

```bash
cd apps/owner-panel

# Install dependencies
npm install

# Install Playwright browser (sekali saja)
npx playwright install chromium

# Pastikan .env terisi (VITE_SUPABASE_URL + VITE_SUPABASE_ANON_KEY)
cp .env.example .env
# edit .env dengan kredensial Supabase
```

## 3. API Tests

### Lokasi & filosofi

- File: `tests/api/laporan-api.test.mjs` (18 test cases, fokus section laporan)
- **Pattern:** Hit Supabase REST endpoint langsung, validasi schema + RLS + edge cases
- **Tidak butuh browser** — cepat (< 10 detik untuk full suite)
- **Login optional** — schema bugs ketangkap walau anon (PostgREST validates query sebelum return data)

### Cara jalankan

```bash
# Semua API test
node --test tests/api/*.test.mjs

# Single file
node --test tests/api/laporan-api.test.mjs

# Filter test name
node --test --test-name-pattern="v_payment_summary" tests/api/laporan-api.test.mjs
```

### Pattern menulis API test baru

```js
import test from 'node:test'
import assert from 'node:assert/strict'

// 1. Definisikan helper
async function rest(path) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { headers: authHeaders() })
  return { status: res.status, body: await res.json() }
}

// 2. Tulis test
test('v_new_view — schema check', async () => {
  const { status, body } = await rest('v_new_view?select=*&limit=1')
  assert.equal(status, 200)
  if (body.length) {
    for (const k of ['outlet_id', 'col1', 'col2']) {
      assert.ok(k in body[0], `missing column: ${k}`)
    }
  }
})
```

### Pattern API tests yang sudah ada

| Kategori | Contoh |
|---|---|
| **Schema validation** | "expected columns exist in view" |
| **Filter behavior** | "date range filter returns correct subset" |
| **RLS smoke** | "anon role cannot read sensitive view" |
| **Edge cases** | "future date returns empty, malformed UUID returns 400" |
| **Business rules** | "gross_revenue ≥ net_revenue" |

## 4. E2E Tests (Playwright)

### Lokasi & konfigurasi

- Config: `playwright.config.ts`
- Specs: `tests/*.spec.ts`
- Helpers: `tests/helpers/*`

### Setup helper login

`tests/helpers/auth.ts`:
```ts
import { type Page } from '@playwright/test'

export const TEST_CREDENTIALS = {
  email: process.env.E2E_EMAIL ?? '',
  password: process.env.E2E_PASSWORD ?? '',
}

export async function login(page: Page) {
  await page.goto('/login')
  await page.waitForLoadState('networkidle')
  await page.locator('input[type="email"]').fill(TEST_CREDENTIALS.email)
  await page.locator('input[type="password"]').fill(TEST_CREDENTIALS.password)
  await page.locator('button[type="submit"]').click()
  await page.waitForURL((url) => !url.pathname.includes('/login'), { timeout: 15_000 })
}
```

### Cara jalankan

```bash
# Semua E2E test
npm run test

# UI mode interaktif (best untuk debug)
npm run test:ui

# Single spec
npx playwright test tests/laporan.spec.ts

# Single test name
npx playwright test -g "currency values tidak Rp0"

# Headed mode (lihat browser jalan)
npx playwright test --headed

# Debug step-by-step
npx playwright test --debug
```

### Pattern E2E test

```ts
import { test, expect } from '@playwright/test'
import { login } from './helpers/auth'

test.describe('Modul X', () => {
  test.beforeEach(async ({ page }) => {
    await login(page)
  })

  test('flow utama X', async ({ page }) => {
    await page.goto('/admin/x')
    await expect(page.locator('h1')).toContainText('Modul X')

    // Action
    await page.locator('button:has-text("Tambah")').click()
    await page.locator('input[name="nama"]').fill('Test')
    await page.locator('button[type="submit"]').click()

    // Assertion
    await expect(page.locator('text=Test')).toBeVisible()
  })
})
```

### Selectors — best practice

- Prefer `role` & `text` selector: `page.getByRole('button', { name: 'Simpan' })`
- Avoid testing implementation: jangan pakai class CSS yang volatile (`hover:bg-gray-50/60`)
- Tambah `data-testid` di kode aplikasi untuk element yg susah ditargetkan
- Untuk text Indonesia: `text=Tidak ada data`

## 5. Struktur Spec Files (Recommended)

```
tests/
├── helpers/
│   ├── auth.ts
│   ├── outlet.ts          # pilih outlet, helper untuk multi-outlet test
│   └── fixtures.ts        # seed data jika perlu
├── auth.spec.ts           # TC-AUTH-01..10
├── dashboard.spec.ts      # TC-DASH-O-01.., TC-DASH-A-01..
├── produk.spec.ts         # menu, dept, cat, extras
├── laporan.spec.ts        # ringkasan + breakdown (sudah ada)
├── pesanan.spec.ts        # orders, shifts
├── inventori.spec.ts      # stock, stock-report
├── keuangan.spec.ts       # expenses, finance
├── operasional.spec.ts    # tables, qr
├── promosi.spec.ts        # promos, loyalty
├── pembayaran.spec.ts     # payments, taxes, receipt
├── staff.spec.ts          # staff manager
├── settings.spec.ts       # outlet settings
├── mobile.spec.ts         # mobile responsive (viewport 375x667)
└── api/
    ├── laporan-api.test.mjs
    ├── menu-api.test.mjs           # (TODO)
    ├── orders-api.test.mjs         # (TODO)
    └── staff-api.test.mjs          # (TODO)
```

## 6. Coverage Targets (Per Modul)

| Modul | API tests | E2E tests | Status |
|---|---|---|---|
| Laporan | ✅ 18 cases | ✅ existing | DONE |
| Auth | ⏳ TODO | ⏳ TODO | PENDING |
| Menu/Produk | ⏳ TODO | ⏳ TODO | PENDING |
| Orders | ⏳ TODO | ⏳ TODO | PENDING |
| Stock | ⏳ TODO | ⏳ TODO | PENDING |
| Staff | ⏳ TODO | ⏳ TODO | PENDING |
| Mobile responsive | N/A | ⏳ TODO | PENDING |

## 7. CI Integration (Recommended)

Tambah `.github/workflows/test.yml`:

```yaml
name: Test
on: [push, pull_request]
jobs:
  api-tests:
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: apps/owner-panel } }
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20' }
      - run: npm ci
      - run: node --test tests/api/*.test.mjs
        env:
          VITE_SUPABASE_URL: ${{ secrets.SUPABASE_URL }}
          VITE_SUPABASE_ANON_KEY: ${{ secrets.SUPABASE_ANON_KEY }}

  e2e-tests:
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: apps/owner-panel } }
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20' }
      - run: npm ci
      - run: npx playwright install --with-deps chromium
      - run: npm run build
      - run: npm run test
        env:
          VITE_SUPABASE_URL: ${{ secrets.SUPABASE_URL }}
          VITE_SUPABASE_ANON_KEY: ${{ secrets.SUPABASE_ANON_KEY }}
```

## 8. Best Practices

### DO
- ✅ Bersihkan state sebelum/sesudah test (logout, delete seed data)
- ✅ Pakai `test.describe.serial` jika test berurutan
- ✅ Pakai timeout eksplisit untuk async action (`{ timeout: 10_000 }`)
- ✅ Screenshot otomatis on fail (Playwright default)
- ✅ Test data dengan prefix `[TEST]` agar mudah dibersihkan

### DON'T
- ❌ Jangan hardcode UUID di test — derive dari query/setup
- ❌ Jangan rely pada urutan test (kecuali eksplisit serial)
- ❌ Jangan test third-party (Supabase Auth flow, Stripe) — mock di edge
- ❌ Jangan commit `.env` dengan kredensial production
- ❌ Jangan pakai `setTimeout` arbitrer — pakai `waitFor` / `waitForLoadState`

## 9. Troubleshooting

| Problem | Solution |
|---|---|
| `Login failed 400 invalid_credentials` | Reset password user QA di Supabase Dashboard (BUG-LAP-API-001) |
| `Browser executable not found` | `npx playwright install chromium` |
| `Port 5173 already in use` | Set `reuseExistingServer: true` di playwright.config.ts (sudah) |
| `Test timeout exceeded` | Naikkan timeout: `test('...', { timeout: 30_000 }, ...)` |
| `Element not found` | Pakai `page.pause()` untuk debug interaktif |
| `Flaky test` | Tambah `await page.waitForLoadState('networkidle')` atau retry |

## 10. Untuk QA Engineer Baru

Onboarding 30 menit:

1. `git clone` repo
2. `cd apps/owner-panel && npm install && npx playwright install chromium`
3. Copy `.env.example` → `.env`, isi kredensial
4. `node --test tests/api/laporan-api.test.mjs` — pastikan jalan
5. `npm run test:ui` — eksplorasi UI mode Playwright
6. Baca [TEST_PLAN.md](./TEST_PLAN.md) dan [TEST_CASES.md](./TEST_CASES.md)
7. Coba tambah 1 test baru sesuai pattern di `tests/laporan.spec.ts`
