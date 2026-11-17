import assert from 'node:assert/strict'
import test from 'node:test'
import { readFile } from 'node:fs/promises'
import { normalizeShiftCloseReport } from '../../src/lib/shiftCloseReport.ts'

test('laporan tutup kasir menormalkan NUMERIC JSONB dan seluruh rinciannya', () => {
  const report = normalizeShiftCloseReport({
    shift_id: 'shift-1',
    outlet: { name: 'TIME420S' },
    cashier_name: 'Kasir Satu',
    opening_cash: '100000',
    total_receipts: '441100',
    cash_difference: '-5000',
    completed_transactions: 4,
    payment_methods: [{ method: 'cash', amount: '300000' }],
    products: [{ name: 'Kopi', quantity: '2', amount: '50000' }],
    expenses: [{ id: 'e1', description: 'Es batu', amount: '10000' }],
  })

  assert.equal(report.opening_cash, 100000)
  assert.equal(report.total_receipts, 441100)
  assert.equal(report.cash_difference, -5000)
  assert.equal(report.payment_methods[0].amount, 300000)
  assert.equal(report.products[0].quantity, 2)
  assert.equal(report.expenses[0].category, 'lain_lain')
})

test('halaman web memuat RPC laporan tutup kasir dan menampilkannya', async () => {
  const [hook, page] = await Promise.all([
    readFile(new URL('../../src/hooks/queries/useShifts.ts', import.meta.url), 'utf8'),
    readFile(new URL('../../src/pages/admin/ShiftList.tsx', import.meta.url), 'utf8'),
  ])
  assert.match(hook, /rpc\('get_shift_close_report'/)
  assert.match(page, /ShiftCloseReportDetails/)
  assert.match(page, /Metode Pembayaran/)
  assert.match(page, /Produk Terjual/)
  assert.match(page, /Ringkasan Transaksi/)
})
