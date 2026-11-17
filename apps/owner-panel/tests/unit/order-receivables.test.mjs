import assert from 'node:assert/strict'
import test from 'node:test'
import { remainingReceivable, totalReceivables } from '../../src/lib/orderReceivables.ts'

test('order yang pembayarannya penuh tidak dihitung sebagai piutang', () => {
  assert.equal(remainingReceivable({
    total_amount: 441100,
    payments: [{ amount: 323950 }, { amount: 117150 }],
  }), 0)
})

test('piutang hanya menghitung sisa pembayaran parsial', () => {
  assert.equal(totalReceivables([
    { total_amount: 100000, payments: [{ amount: 40000 }] },
    { total_amount: '50000', payments: [] },
    { total_amount: 25000, payments: [{ amount: 30000 }] },
  ]), 110000)
})
