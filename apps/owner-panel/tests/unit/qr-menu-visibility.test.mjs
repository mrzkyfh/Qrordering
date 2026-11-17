import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'

const [menuManager, settings, hooks, migration, cleanupMigration, customerMenu] = await Promise.all([
  readFile(new URL('../../src/pages/admin/MenuManager.tsx', import.meta.url), 'utf8'),
  readFile(new URL('../../src/pages/admin/Settings.tsx', import.meta.url), 'utf8'),
  readFile(new URL('../../src/hooks/queries/useMenuItems.ts', import.meta.url), 'utf8'),
  readFile(new URL('../../../supabase/migrations/191_qr_menu_visibility.sql', import.meta.url), 'utf8'),
  readFile(new URL('../../../supabase/migrations/192_remove_bulk_qr_menu_visibility_rpc.sql', import.meta.url), 'utf8'),
  readFile(new URL('../../../customer-menu/app.js', import.meta.url), 'utf8'),
])

test('form tambah dan edit produk menyediakan toggle Menu QR', () => {
  assert.match(menuManager, /name="show_in_qr_menu"/)
  assert.match(menuManager, /Tampilkan produk ini di Menu QR/)
  assert.match(menuManager, /show_in_qr_menu:\s*values\.show_in_qr_menu/)
  assert.match(menuManager, /item\?\.show_in_qr_menu \?\? true/)
  assert.doesNotMatch(settings, /Menu yang Ditampilkan di QR/)
  assert.doesNotMatch(hooks, /set_qr_menu_visibility/)
  assert.match(cleanupMigration, /DROP FUNCTION IF EXISTS public\.set_qr_menu_visibility/)
})

test('produk tersembunyi difilter dan ditolak oleh server self-order', () => {
  assert.match(migration, /ADD COLUMN IF NOT EXISTS show_in_qr_menu BOOLEAN NOT NULL DEFAULT TRUE/)
  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.get_public_menu_snapshot/)
  assert.match(migration, /AND m\.show_in_qr_menu/)
  assert.match(migration, /AND mi\.show_in_qr_menu = TRUE/)
  assert.match(customerMenu, /\.eq\('show_in_qr_menu', true\)/)
})
