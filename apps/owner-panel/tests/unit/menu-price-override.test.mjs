import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'

const source = await readFile(
  new URL('../../src/pages/admin/MenuManager.tsx', import.meta.url),
  'utf8',
)

test('form tambah dan edit menu menyediakan toggle izin ubah harga jual', () => {
  assert.match(source, /name="allow_price_override"/)
  assert.match(source, /Izinkan kasir mengubah harga jual produk ini saat transaksi/)
  assert.match(source, /allow_price_override:\s*values\.allow_price_override/)
  assert.match(source, /item\?\.allow_price_override \?\? false/)
})
