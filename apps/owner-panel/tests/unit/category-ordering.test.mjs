import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'

const [pageSource, hookSource] = await Promise.all([
  readFile(new URL('../../src/pages/admin/CategoryManager.tsx', import.meta.url), 'utf8'),
  readFile(new URL('../../src/hooks/queries/useMenuItems.ts', import.meta.url), 'utf8'),
])

test('urutan kategori dapat dipilih dari daftar dan disimpan berurutan mulai dari satu', () => {
  assert.match(pageSource, /aria-label={`Urutan kategori \$\{cat\.name\}`}/)
  assert.match(pageSource, /categoryIds:\s*reordered\.map/)
  assert.match(hookSource, /update\(\{ sort_order: index \+ 1 \}\)/)
  assert.match(hookSource, /invalidateQueries\(\{ queryKey: \['menu-categories'\] \}\)/)
})
