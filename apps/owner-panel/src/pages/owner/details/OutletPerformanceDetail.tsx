import { useMemo, useState } from 'react'
import { useOutlets } from '@/hooks/queries/useOutlets'
import { useDailySales } from '@/hooks/queries/useSales'
import { getPresetRange, type DateRange } from '@/lib/dateRange'
import { formatCurrency } from '@/lib/currency'
import { OwnerDetailReport } from '@/components/OwnerDetailReport'

export default function OutletPerformanceDetail() {
  const [range, setRange] = useState<DateRange>(() => getPresetRange('month'))
  const [outletId, setOutletId] = useState<string | null>(null)
  const { data: outlets = [] } = useOutlets()
  const { data = [], isLoading } = useDailySales(outletId, range)

  const { rows, totalOmzet, totalTx, totalNet } = useMemo(() => {
    const map: Record<string, { omzet: number; tx: number; diskon: number; net: number }> = {}
    data.forEach((d) => {
      const m = (map[d.outlet_id] ??= { omzet: 0, tx: 0, diskon: 0, net: 0 })
      m.omzet += d.gross_revenue
      m.tx += d.total_orders
      m.diskon += d.total_discount
      m.net += d.net_revenue
    })
    const nameOf = (id: string) => outlets.find((o) => o.id === id)?.name ?? id
    const sorted = Object.entries(map).sort((a, b) => b[1].omzet - a[1].omzet)
    return {
      rows: sorted.map(([id, v]) => [
        nameOf(id), v.tx, formatCurrency(v.omzet), formatCurrency(v.diskon), formatCurrency(v.net),
      ]) as (string | number)[][],
      totalOmzet: sorted.reduce((s, [, v]) => s + v.omzet, 0),
      totalTx: sorted.reduce((s, [, v]) => s + v.tx, 0),
      totalNet: sorted.reduce((s, [, v]) => s + v.net, 0),
    }
  }, [data, outlets])

  return (
    <OwnerDetailReport
      title="Performa Outlet"
      subtitle="Omzet & transaksi per cabang"
      range={range} onRangeChange={setRange}
      outletId={outletId} onOutletChange={setOutletId}
      outlets={outlets}
      summaryStats={[
        { label: 'Total Omzet', value: formatCurrency(totalOmzet) },
        { label: 'Total Transaksi', value: totalTx.toLocaleString('id-ID') },
        { label: 'Penjualan Bersih', value: formatCurrency(totalNet) },
      ]}
      headers={['Outlet', 'Transaksi', 'Omzet (Rp)', 'Diskon (Rp)', 'Bersih (Rp)']}
      rows={rows}
      loading={isLoading}
      filename="performa-outlet"
    />
  )
}
