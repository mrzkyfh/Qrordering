import { useMemo, useState } from 'react'
import { format } from 'date-fns'
import { useOutlets } from '@/hooks/queries/useOutlets'
import { usePaymentSummaryRange } from '@/hooks/queries/useSales'
import { getPresetRange, type DateRange } from '@/lib/dateRange'
import { formatCurrency } from '@/lib/currency'
import { OwnerDetailReport } from '@/components/OwnerDetailReport'

const PAYMENT_LABEL: Record<string, string> = {
  cash: 'Tunai', qris: 'QRIS', debit: 'Kartu Debit', credit: 'Kartu Kredit',
  ewallet: 'E-Wallet', transfer: 'Transfer',
}

export default function PaymentMethodsDetail() {
  const [range, setRange] = useState<DateRange>(() => getPresetRange('month'))
  const [outletId, setOutletId] = useState<string | null>(null)
  const { data: outlets = [] } = useOutlets()
  const dateFrom = format(range.from, 'yyyy-MM-dd')
  const dateTo = format(range.to, 'yyyy-MM-dd')
  const { data = [], isLoading } = usePaymentSummaryRange(outletId, dateFrom, dateTo)

  const { rows, totalAmount, totalTx } = useMemo(() => {
    const map: Record<string, { amount: number; tx: number }> = {}
    data.forEach((p) => {
      const m = (map[p.method] ??= { amount: 0, tx: 0 })
      m.amount += p.total_amount
      m.tx += p.total_transactions
    })
    const sorted = Object.entries(map).sort((a, b) => b[1].amount - a[1].amount)
    return {
      rows: sorted.map(([method, v]) => [
        PAYMENT_LABEL[method] ?? method, v.tx, formatCurrency(v.amount),
      ]) as (string | number)[][],
      totalAmount: sorted.reduce((s, [, v]) => s + v.amount, 0),
      totalTx: sorted.reduce((s, [, v]) => s + v.tx, 0),
    }
  }, [data])

  return (
    <OwnerDetailReport
      title="Metode Pembayaran"
      subtitle="Rincian pembayaran per metode"
      range={range} onRangeChange={setRange}
      outletId={outletId} onOutletChange={setOutletId}
      outlets={outlets}
      summaryStats={[
        { label: 'Total Pembayaran', value: formatCurrency(totalAmount) },
        { label: 'Total Transaksi', value: totalTx.toLocaleString('id-ID') },
        { label: 'Jumlah Metode', value: rows.length.toString() },
      ]}
      headers={['Metode', 'Transaksi', 'Total (Rp)']}
      rows={rows}
      loading={isLoading}
      filename="metode-pembayaran"
    />
  )
}
