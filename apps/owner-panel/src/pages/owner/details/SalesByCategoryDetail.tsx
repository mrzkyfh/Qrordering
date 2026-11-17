import { useMemo, useState } from 'react'
import { format } from 'date-fns'
import { useOutlets } from '@/hooks/queries/useOutlets'
import { useCategorySalesRange } from '@/hooks/queries/useSales'
import { getPresetRange, type DateRange } from '@/lib/dateRange'
import { formatCurrency } from '@/lib/currency'
import { OwnerDetailReport } from '@/components/OwnerDetailReport'

export default function SalesByCategoryDetail() {
  const [range, setRange] = useState<DateRange>(() => getPresetRange('month'))
  const [outletId, setOutletId] = useState<string | null>(null)
  const { data: outlets = [] } = useOutlets()
  const dateFrom = format(range.from, 'yyyy-MM-dd')
  const dateTo = format(range.to, 'yyyy-MM-dd')
  const { data = [], isLoading } = useCategorySalesRange(outletId, dateFrom, dateTo)

  const { rows, totalRevenue, totalQty } = useMemo(() => {
    const map: Record<string, { qty: number; rev: number }> = {}
    data.forEach((c) => {
      const key = c.category_name ?? 'Tanpa Kategori'
      const e = (map[key] ??= { qty: 0, rev: 0 })
      e.qty += c.qty_sold
      e.rev += c.total_revenue
    })
    const sorted = Object.entries(map).sort((a, b) => b[1].rev - a[1].rev)
    return {
      rows: sorted.map(([name, v]) => [
        name, v.qty.toLocaleString('id-ID'), formatCurrency(v.rev),
      ]) as (string | number)[][],
      totalRevenue: sorted.reduce((s, [, v]) => s + v.rev, 0),
      totalQty: sorted.reduce((s, [, v]) => s + v.qty, 0),
    }
  }, [data])

  return (
    <OwnerDetailReport
      title="Penjualan per Kategori"
      subtitle="Omzet & jumlah terjual per kategori menu"
      range={range} onRangeChange={setRange}
      outletId={outletId} onOutletChange={setOutletId}
      outlets={outlets}
      summaryStats={[
        { label: 'Total Penjualan', value: formatCurrency(totalRevenue) },
        { label: 'Total Terjual', value: totalQty.toLocaleString('id-ID') },
        { label: 'Jumlah Kategori', value: rows.length.toString() },
      ]}
      headers={['Kategori', 'Qty Terjual', 'Total (Rp)']}
      rows={rows}
      loading={isLoading}
      filename="penjualan-per-kategori"
    />
  )
}
