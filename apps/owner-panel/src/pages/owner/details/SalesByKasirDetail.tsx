import { useMemo, useState } from 'react'
import { format } from 'date-fns'
import { useOutlets } from '@/hooks/queries/useOutlets'
import { useKasirPerformanceRange } from '@/hooks/queries/useSales'
import { getPresetRange, type DateRange } from '@/lib/dateRange'
import { formatCurrency } from '@/lib/currency'
import { OwnerDetailReport } from '@/components/OwnerDetailReport'

export default function SalesByKasirDetail() {
  const [range, setRange] = useState<DateRange>(() => getPresetRange('month'))
  const [outletId, setOutletId] = useState<string | null>(null)
  const { data: outlets = [] } = useOutlets()
  const dateFrom = format(range.from, 'yyyy-MM-dd')
  const dateTo = format(range.to, 'yyyy-MM-dd')
  const { data = [], isLoading } = useKasirPerformanceRange(outletId, dateFrom, dateTo)

  const { rows, totalOmzet, totalTx } = useMemo(() => {
    const map: Record<string, { name: string; tx: number; rev: number }> = {}
    data.forEach((k) => {
      const e = (map[k.kasir_id] ??= { name: k.kasir_name, tx: 0, rev: 0 })
      e.tx += k.total_orders
      e.rev += k.total_revenue
    })
    const sorted = Object.values(map).sort((a, b) => b.rev - a.rev)
    return {
      rows: sorted.map((e) => [
        e.name, e.tx.toLocaleString('id-ID'), formatCurrency(e.rev),
      ]) as (string | number)[][],
      totalOmzet: sorted.reduce((s, e) => s + e.rev, 0),
      totalTx: sorted.reduce((s, e) => s + e.tx, 0),
    }
  }, [data])

  return (
    <OwnerDetailReport
      title="Penjualan per Kasir"
      subtitle="Omzet & transaksi per kasir"
      range={range} onRangeChange={setRange}
      outletId={outletId} onOutletChange={setOutletId}
      outlets={outlets}
      summaryStats={[
        { label: 'Total Omzet', value: formatCurrency(totalOmzet) },
        { label: 'Total Transaksi', value: totalTx.toLocaleString('id-ID') },
        { label: 'Jumlah Kasir', value: rows.length.toString() },
      ]}
      headers={['Kasir', 'Transaksi', 'Omzet (Rp)']}
      rows={rows}
      loading={isLoading}
      filename="penjualan-per-kasir"
    />
  )
}
