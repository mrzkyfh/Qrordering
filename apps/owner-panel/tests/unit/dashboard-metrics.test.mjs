import test from 'node:test'
import assert from 'node:assert/strict'
import { getJakartaNow } from '../../src/lib/businessDate.ts'
import { calculateNetProfit, calculateNetRevenue, summarizeDailySales } from '../../src/lib/dashboardMetrics.ts'

test('tanggal bisnis selalu mengikuti Asia/Jakarta pada batas pergantian hari', () => {
  const jakarta = getJakartaNow(new Date('2026-08-01T18:30:45.000Z'))
  assert.equal(jakarta.getFullYear(), 2026)
  assert.equal(jakarta.getMonth(), 7)
  assert.equal(jakarta.getDate(), 2)
  assert.equal(jakarta.getHours(), 1)
  assert.equal(jakarta.getMinutes(), 30)
})

test('NUMERIC string dari PostgREST dijumlahkan sebagai angka', () => {
  assert.deepEqual(summarizeDailySales([
    { gross_revenue: '100000', total_orders: '2', total_discount: '5000', total_tax: '9500', total_service_charge: '1500', net_revenue: '106000' },
    { gross_revenue: 25000, total_orders: 1, total_discount: null, total_tax: 2500, total_service_charge: 500, net_revenue: 28000 },
  ]), {
    grossRevenue: 125000,
    totalOrders: 3,
    totalDiscount: 5000,
    totalTax: 12000,
    totalServiceCharge: 2000,
    totalReceipts: 134000,
  })
})

test('laba bersih mengurangi HPP dan pengeluaran dari pendapatan bersih', () => {
  assert.equal(calculateNetProfit('134000', '44000', '25000'), 65000)
})

test('pendapatan bersih tidak memasukkan pajak dan service charge pelanggan', () => {
  assert.equal(calculateNetRevenue('1292710', '116950', '6260'), 1169500)
})

test('nilai database tidak valid tidak menghasilkan NaN pada dashboard', () => {
  assert.deepEqual(summarizeDailySales([
    { gross_revenue: 'invalid', total_orders: null, total_discount: '', net_revenue: 'NaN' },
  ]), {
    grossRevenue: 0,
    totalOrders: 0,
    totalDiscount: 0,
    totalTax: 0,
    totalServiceCharge: 0,
    totalReceipts: 0,
  })
})
