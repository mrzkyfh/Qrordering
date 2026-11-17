import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'

const migration = readFileSync(
  new URL('../../../supabase/migrations/221_department_financial_reconciliation.sql', import.meta.url),
  'utf8',
)

test('rekonsiliasi memakai snapshot finansial order dan tidak membaca settings', () => {
  assert.match(migration, /o\.tax_amount/)
  assert.match(migration, /o\.tax_inclusive/)
  assert.match(migration, /o\.service_charge/)
  assert.doesNotMatch(migration, /outlets\.settings|settings->/)
})

test('pajak inclusive bersifat informasional dan hanya exclusive masuk total bersih', () => {
  assert.match(migration, /allocated_tax_exclusive \+ c\.allocated_service/)
  assert.doesNotMatch(migration, /department_subtotal - c\.allocated_discount\s*\+ c\.allocated_tax_inclusive/)
})

test('refund tanpa breakdown dan arsip masuk penyesuaian transparan', () => {
  assert.match(migration, /refund_residuals/)
  assert.match(migration, /Penyesuaian \/ Belum Terdistribusi/)
  assert.match(migration, /transaction_archive_manifest/)
})

test('sisa pembulatan alokasi diberikan deterministik ke bobot terbesar', () => {
  assert.match(migration, /ROW_NUMBER\(\) OVER/)
  assert.match(migration, /allocation_rank = 1/)
  assert.match(migration, /ORDER BY d\.department_subtotal DESC/)
})
