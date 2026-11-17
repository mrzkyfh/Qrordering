import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

const menu = readFileSync(new URL('../../src/pages/admin/MenuManager.tsx', import.meta.url), 'utf8')
const qr = readFileSync(new URL('../../src/pages/admin/QRManager.tsx', import.meta.url), 'utf8')
const headers = readFileSync(new URL('../../public/_headers', import.meta.url), 'utf8')

test('replacement persists new URL before attempting old image cleanup', () => {
  const write = menu.indexOf("await table.update(payload).eq('id', item.id)")
  const cleanupTrigger = menu.indexOf('markImagePersisted()', write)
  assert.ok(write >= 0 && cleanupTrigger > write)
  assert.match(menu, /const markImagePersisted[\s\S]*void removeImageAsset\(previous\)/)
})

test('Owner Panel CSP permits dual Supabase and production R2 reads', () => {
  assert.match(headers, /img-src[^;]*https:\/\/\*\.supabase\.co/)
  assert.match(headers, /img-src[^;]*https:\/\/assets\.qrordering\.my\.id/)
  assert.match(headers, /img-src[^;]*https:\/\/qrordering-r2-staging\.official-b0d\.workers\.dev/)
  assert.match(headers, /connect-src[^;]*https:\/\/qrordering-r2-staging\.official-b0d\.workers\.dev/)
  assert.match(headers, /connect-src[^;]*https:\/\/qrordering-r2-production\.official-b0d\.workers\.dev/)
})

test('Kelola Meja and QR generation contracts remain present', () => {
  assert.match(qr, /QRCode\.toDataURL\(menuUrl/)
  assert.match(qr, /qr_token/)
  assert.match(qr, /qr_code_url/)
  assert.match(qr, /VITE_MENU_BASE_URL/)
})
