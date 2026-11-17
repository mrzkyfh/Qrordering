import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'

const source = readFileSync(
  new URL('../../src/pages/admin/SalesBreakdownReport.tsx', import.meta.url),
  'utf8',
)

test('laporan departemen menampilkan seluruh komponen rekonsiliasi', () => {
  assert.match(source, /Subtotal Penjualan/)
  assert.match(source, /Pajak dalam Harga \(Informasi\)/)
  assert.match(source, /Pajak Tambahan pada Tagihan/)
  assert.match(source, /Belum Dialokasikan ke Departemen/)
  assert.match(source, /Total Penerimaan/)
  assert.match(source, /Pajak tambahan pada tagihan menambah penerimaan, tidak masuk subtotal/)
  assert.match(source, /Catatan perhitungan laporan/)
  assert.match(source, /shortLabel="Diskon & Poin"/)
})

test('laporan extra menjelaskan bahwa nilainya bukan pendapatan tambahan', () => {
  assert.match(source, /Rincian Penjualan Extra/)
  assert.match(source, /merupakan bagian dari pendapatan produk/)
  assert.match(source, /bukan untuk ditambahkan lagi ke Laporan Departemen atau Pendapatan Bersih/)
})
