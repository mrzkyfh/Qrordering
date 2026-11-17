import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'

const source = await readFile(
  new URL('../../src/pages/admin/MenuManager.tsx', import.meta.url),
  'utf8',
)

test('foto menu memenuhi preview unggahan dan kartu daftar menu tanpa gepeng', () => {
  const fitImages = source.match(/h-full w-full object-cover/g) ?? []
  assert.equal(fitImages.length, 2)
})
