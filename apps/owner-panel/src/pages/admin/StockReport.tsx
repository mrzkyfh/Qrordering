import { useState, useMemo } from 'react'
import { format, startOfDay, endOfDay, subDays } from 'date-fns'
import { id } from 'date-fns/locale'
import { useStockDaily } from '@/hooks/queries/useStockDaily'
import { useIngredients } from '@/hooks/queries/useIngredients'
import { useOutlet } from '@/hooks/useOutlet'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { DataTable } from '@/components/ui/DataTable'
import { DateRangePicker } from '@/components/ui/DateRangePicker'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { FileText } from 'lucide-react'
import { exportReportExcel, exportReportPDF } from '@/utils/exportReport'
import { useToast } from '@/hooks/use-toast'
import type { DateRange } from '@/components/ui/DateRangePicker'

type StockStatus = 'normal' | 'low' | 'critical' | 'out'

function getStatus(stockQty: number, minQty: number): StockStatus {
  if (stockQty <= 0) return 'out'
  if (stockQty <= minQty) return 'critical'
  if (stockQty <= minQty * 1.5) return 'low'
  return 'normal'
}

function StockStatusBadge({ status }: { status: StockStatus }) {
  if (status === 'out')      return <Badge variant="destructive">Habis</Badge>
  if (status === 'critical') return <Badge className="bg-orange-100 text-orange-700 hover:bg-orange-100">Kritis</Badge>
  if (status === 'low')      return <Badge className="bg-yellow-100 text-yellow-700 hover:bg-yellow-100">Rendah</Badge>
  return <Badge variant="outline" className="text-green-600">Normal</Badge>
}

function fmtQty(n: number, unit: string) {
  return `${n % 1 === 0 ? n : n.toFixed(2)} ${unit}`
}

export default function StockReport() {
  const { activeOutlet, activeOutletId } = useOutlet()
  const { toast } = useToast()
  const [isExporting, setIsExporting] = useState(false)

  const [dateRange, setDateRange] = useState<DateRange>({
    from: startOfDay(subDays(new Date(), 6)),
    to: endOfDay(new Date()),
  })

  const dateFrom = format(dateRange.from, 'yyyy-MM-dd')
  const dateTo   = format(dateRange.to,   'yyyy-MM-dd')

  const { data: stockDaily = [], isLoading } = useStockDaily(activeOutletId ?? null, dateFrom, dateTo)
  const { data: ingredients = [] } = useIngredients(activeOutletId ?? '')

  // Aggregate stock movements per ingredient across selected date range
  const rows = useMemo(() => {
    const map: Record<string, { totalIn: number; totalOut: number; name: string; unit: string }> = {}

    stockDaily.forEach((s) => {
      if (!map[s.ingredient_id]) {
        map[s.ingredient_id] = { totalIn: 0, totalOut: 0, name: s.ingredient_name, unit: s.unit }
      }
      map[s.ingredient_id].totalIn  += s.total_in
      map[s.ingredient_id].totalOut += s.total_out
    })

    // Join with current stock_qty from ingredients
    return Object.entries(map).map(([ingredientId, agg]) => {
      const ingredient = ingredients.find((i) => i.id === ingredientId)
      const stockQty   = ingredient?.stock_qty ?? 0
      const minQty     = ingredient?.min_stock_qty ?? 0
      return {
        ingredientId,
        name:     agg.name,
        unit:     agg.unit,
        totalIn:  agg.totalIn,
        totalOut: agg.totalOut,
        net:      agg.totalIn - agg.totalOut,
        stockQty,
        minQty,
        status:   getStatus(stockQty, minQty),
      }
    }).sort((a, b) => {
      // Sort: out → critical → low → normal
      const order = { out: 0, critical: 1, low: 2, normal: 3 }
      return order[a.status] - order[b.status] || a.name.localeCompare(b.name)
    })
  }, [stockDaily, ingredients])

  const outletName = activeOutlet?.name ?? 'Semua Outlet'
  const period = `${format(dateRange.from, 'd MMM yyyy', { locale: id })} – ${format(dateRange.to, 'd MMM yyyy', { locale: id })}`

  const buildExportConfig = (ext: 'xls' | 'pdf') => ({
    title: 'Laporan Stok',
    outletName,
    period,
    summaryStats: [
      { label: 'Total Bahan', value: String(rows.length) },
      { label: 'Habis',       value: String(summary.out) },
      { label: 'Kritis',      value: String(summary.critical) },
      { label: 'Rendah',      value: String(summary.low) },
    ],
    tableHeaders: ['Bahan Baku', 'Satuan', 'Total Masuk', 'Total Keluar', 'Net', 'Stok Saat Ini', 'Status'],
    tableRows: rows.map((r) => [r.name, r.unit, r.totalIn, r.totalOut, r.net, r.stockQty, r.status]),
    filename: `laporan-stok-${dateFrom}-${dateTo}.${ext}`,
  })

  const noDataToast = () =>
    toast({ title: 'Tidak ada data', description: 'Tidak ada pergerakan stok untuk diekspor.', variant: 'destructive' })

  const handleExcel = () => {
    if (rows.length === 0) { noDataToast(); return }
    exportReportExcel(buildExportConfig('xls'))
  }
  const handlePDF = async () => {
    if (rows.length === 0) { noDataToast(); return }
    setIsExporting(true)
    try { await exportReportPDF(buildExportConfig('pdf')) } finally { setIsExporting(false) }
  }

  if (!activeOutletId) return <NoOutlet />

  const summary = {
    out:      rows.filter((r) => r.status === 'out').length,
    critical: rows.filter((r) => r.status === 'critical').length,
    low:      rows.filter((r) => r.status === 'low').length,
  }

  return (
    <div className="space-y-4">
      <PageHeader
        title="Laporan Stok"
        subtitle="Pergerakan stok bahan baku per periode"
      >
        <div className="inline-flex items-center gap-0.5 rounded-lg border bg-white px-1.5 py-1 shadow-sm">
          <span className="text-[11px] font-medium text-muted-foreground px-1.5">Ekspor</span>
          <div className="w-px h-4 bg-border mx-0.5" />
          <Button variant="ghost" size="sm" className="h-7 px-2.5 text-xs gap-1.5 rounded-md" onClick={handleExcel} disabled={isExporting || rows.length === 0}>
            <FileText className="h-3.5 w-3.5" /> Excel
          </Button>
          <Button variant="ghost" size="sm" className="h-7 px-2.5 text-xs gap-1.5 rounded-md" onClick={handlePDF} disabled={isExporting || rows.length === 0}>
            <FileText className="h-3.5 w-3.5" /> PDF
          </Button>
        </div>
      </PageHeader>

      {/* Filters */}
      <div className="flex flex-wrap gap-2 items-center">
        <DateRangePicker value={dateRange} onChange={setDateRange} />
        <span className="text-sm text-muted-foreground ml-auto">
          {rows.length} bahan
          {summary.out      > 0 && <>, <span className="text-red-600 font-medium">{summary.out} habis</span></>}
          {summary.critical > 0 && <>, <span className="text-orange-600 font-medium">{summary.critical} kritis</span></>}
          {summary.low      > 0 && <>, <span className="text-yellow-600 font-medium">{summary.low} rendah</span></>}
        </span>
      </div>

      {/* Range label */}
      <p className="text-xs text-muted-foreground">
        Periode: {format(dateRange.from, 'd MMM yyyy', { locale: id })} – {format(dateRange.to, 'd MMM yyyy', { locale: id })}
      </p>

      <DataTable
        data={rows}
        loading={isLoading}
        getRowKey={(r) => r.ingredientId}
        emptyMessage="Tidak ada pergerakan stok dalam periode ini."
        columns={[
          {
            key: 'name',
            header: 'Bahan Baku',
            cell: (r) => <span className="font-medium">{r.name}</span>,
          },
          {
            key: 'unit',
            header: 'Satuan',
            cell: (r) => r.unit,
          },
          {
            key: 'totalIn',
            header: 'Total Masuk',
            cell: (r) => (
              <span className="text-green-600 font-medium">
                {r.totalIn > 0 ? `+${fmtQty(r.totalIn, r.unit)}` : '—'}
              </span>
            ),
          },
          {
            key: 'totalOut',
            header: 'Total Keluar',
            cell: (r) => (
              <span className="text-red-600">
                {r.totalOut > 0 ? `−${fmtQty(r.totalOut, r.unit)}` : '—'}
              </span>
            ),
          },
          {
            key: 'net',
            header: 'Net',
            cell: (r) => {
              const n = r.net
              return (
                <span className={n > 0 ? 'text-green-600' : n < 0 ? 'text-red-600' : 'text-muted-foreground'}>
                  {n > 0 ? `+${fmtQty(n, r.unit)}` : n < 0 ? `−${fmtQty(-n, r.unit)}` : '0'}
                </span>
              )
            },
          },
          {
            key: 'stockQty',
            header: 'Stok Saat Ini',
            cell: (r) => fmtQty(r.stockQty, r.unit),
          },
          {
            key: 'status',
            header: 'Status',
            cell: (r) => <StockStatusBadge status={r.status} />,
          },
        ]}
      />
    </div>
  )
}
