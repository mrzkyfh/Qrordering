import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'

const [router, menuManager, editor] = await Promise.all([
  readFile(new URL('../../src/router/index.tsx', import.meta.url), 'utf8'),
  readFile(new URL('../../src/pages/admin/MenuManager.tsx', import.meta.url), 'utf8'),
  readFile(new URL('../../src/pages/admin/MenuItemEditor.tsx', import.meta.url), 'utf8'),
])

test('tambah dan edit menu menggunakan halaman khusus', () => {
  assert.match(router, /path: 'admin\/menu\/new'/)
  assert.match(router, /path: 'admin\/menu\/:menuItemId\/edit'/)
  assert.match(menuManager, /navigate\('\/admin\/menu\/new'\)/)
  assert.match(menuManager, /navigate\(`\/admin\/menu\/\$\{item\.id\}\/edit`\)/)
  assert.doesNotMatch(menuManager, /<Dialog open=/)
  assert.match(editor, /<MenuItemForm/)
  assert.match(editor, /max-w-4xl/)
})
