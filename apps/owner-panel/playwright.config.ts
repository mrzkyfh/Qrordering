import { defineConfig, devices } from '@playwright/test'

export default defineConfig({
  testDir: './tests',
  // Berkas *.test.mjs memakai node:test dan membutuhkan akun integrasi.
  // Jangan biarkan Playwright mengoleksinya sebagai test UI.
  testIgnore: ['api/**', '**/*.test.mjs'],
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: 1,
  reporter: [['html', { open: 'never' }], ['list']],
  use: {
    baseURL: 'http://localhost:5173',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'off',
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
  ],
  webServer: {
    command: 'npm run dev',
    url: 'http://localhost:5173',
    reuseExistingServer: true,
    timeout: 30_000,
  },
})
