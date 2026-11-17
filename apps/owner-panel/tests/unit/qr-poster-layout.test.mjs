import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'

const source = await readFile(
  new URL('../../src/pages/admin/QRManager.tsx', import.meta.url),
  'utf8',
)

test('poster QR konsisten memakai A5 portrait di unduhan, cetak, dan preview', () => {
  assert.match(source, /canvas\.width\s*=\s*1748/)
  assert.match(source, /canvas\.height\s*=\s*2480/)
  assert.match(source, /@page \{ size: A5 portrait; margin: 0; \}/)
  assert.match(source, /width:\s*148mm;/)
  assert.match(source, /height:\s*210mm;/)
  assert.match(source, /aspect-\[148\/210\]/)
})

test('poster QR tidak lagi memuat kalimat pesan langsung dari meja', () => {
  assert.doesNotMatch(source, /PESAN LANGSUNG DARI MEJA/i)
})
