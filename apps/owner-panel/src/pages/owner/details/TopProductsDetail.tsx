import { useMemo, useState } from 'react'
import { format } from 'date-fns'
import { useOutlets } from '@/hooks/queries/useOutlets'
import { useMenuSales } from '@/hooks/queries/useSales'
import { getPresetRange, type DateRange } from '@/lib/dateRange'
import { formatCurrency } from '@/lib/currency'
import { OwnerDetailReport } from '@/components/OwnerDetailReport'

export default function TopProductsDetail() {
  const [range, setRange] = useState<DateRange>(() => getPresetRange('month'))
  const [outletId, setOutletId] = useState<string | null>(null)
  const { data: outlets = [] } = useOutlets()
  const dateFrom = format(range.from, 'yyyy-MM-dd')
  const dateTo = format(range.to, 'yyyy-MM-dd')
  const { data = [], isLoading } = useMenuSales(outletId, dateFrom, dateTo)

  const { rows, totalQty, totalRevenue } = useMemo(() => {
    const map: Record<string, { name: string; cat: string; qty: number; rev: number }> = {}
    data.forEach((m) => {
      const e = (map[m.menu_item_id] ??= { name: m.menu_name, cat: m.category_name ?? '—', qty: 0, rev: 0 })
      e.qty += m.qty_sold
      e.rev += m.total_revenue
    })
    const sorted = Object.values(map).sort((a, b) => b.qty - a.qty)
    return {
      rows: sorted.map((e, i) => [
        i + 1, e.name, e.cat, e.qty.toLocaleString('id-ID'), formatCurrency(e.rev),
      ]) as (string | number)[][],
      totalQty: sorted.reduce((s, e) => s + e.qty, 0),
      totalRevenue: sorted.reduce((s, e) => s + e.rev, 0),
    }
  }, [data])

  return (
    <OwnerDetailReport
      title="Produk Terlaris"
      subtitle="Menu berdasarkan jumlah terjual"
      range={range} onRangeChange={setRange}
      outletId={outletId} onOutletChange={setOutletId}
      outlets={outlets}
      summaryStats={[
        { label: 'Total Terjual', value: totalQty.toLocaleString('id-ID') },
        { label: 'Total Penjualan', value: formatCurrency(totalRevenue) },
        { label: 'Jumlah Menu', value: rows.length.toString() },
      ]}
      headers={['#', 'Menu', 'Kategori', 'Qty Terjual', 'Total (Rp)']}
      rows={rows}
      numericCols={[0, 3, 4]}
      loading={isLoading}
      filename="produk-terlaris"
    />
  )
}
