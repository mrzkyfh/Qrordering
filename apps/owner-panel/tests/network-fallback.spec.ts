import { expect, test } from '@playwright/test'

test('Wi-Fi memblokir Supabase langsung → web memakai jalur cadangan', async ({
  page,
}) => {
  let fallbackHealthCalled = false

  await page.route(
    /https:\/\/[^/]+\.supabase\.co\/auth\/v1\/health/,
    (route) => route.abort('internetdisconnected'),
  )
  await page.route(
    'https://api.time420s.my.id/auth/v1/health',
    (route) => route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ name: 'GoTrue' }),
      headers: { 'Access-Control-Allow-Origin': 'http://localhost:5173' },
    }),
  )
  page.on('request', (request) => {
    if (
      request
        .url()
        .startsWith(
          'https://api.time420s.my.id/auth/v1/health',
        )
    ) {
      fallbackHealthCalled = true
    }
  })

  await page.goto('/login')

  await expect(page.locator('input[type="email"]')).toBeVisible({
    timeout: 15_000,
  })
  expect(fallbackHealthCalled).toBe(true)
  expect(
    await page.evaluate(() => window.__TIME420S_BACKEND_ROUTE__),
  ).toBe('fallback')
})
