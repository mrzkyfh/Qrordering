import { useState, useMemo } from 'react'
import { format, startOfMonth, endOfMonth } from 'date-fns'
import { useOutlets } from '@/hooks/queries/useOutlets'
import { useProfitLoss, useDailySales } from '@/hooks/queries/useSales'
import { useExpensesByCategory } from '@/hooks/queries/useExpenses'
import { PageHeader } from '@/components/ui/PageHeader'
import { MonthPicker } from '@/components/ui/DateRangePicker'
import { CurrencyDisplay } from '@/components/ui/CurrencyDisplay'
import { formatCurrency } from '@/lib/currency'
import { exportReportExcel, exportReportPDF } from '@/utils/exportReport'
import { FileText } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Skeleton } from '@/components/ui/skeleton'
import type { ProfitLoss, ExpenseCategory } from '@/types/database'

const CATEGORY_LABELS: Record<ExpenseCategory, string> = {
  bahan_baku: 'Bahan Baku',
  operasional: 'Operasional',
  gaji: 'Gaji',
  peralatan: 'Peralatan',
  marketing: 'Marketing',
  lain_lain: 'Lain-lain',
}

function StatCard({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return (
    <div className="rounded-xl border border-gray-200 bg-white p-4 shadow-sm">
      <p className="text-xs font-medium text-muted-foreground">{label}</p>
      <p className="mt-1 text-xl font-bold text-gray-900 tabular-nums">{value}</p>
      {hint && <p className="mt-0.5 text-xs text-muted-foreground">{hint}</p>}
    </div>
  )
}

export default function OwnerFinanceReport() {
  const [month, setMonth] = useState(format(new Date(), 'yyyy-MM'))
  const [outletId, setOutletId] = useState<string | null>(null)
  const [isExporting, setIsExporting] = useState(false)
  const { data: outlets = [] } = useOutlets()
  const { data: pl = [], isLoading } = useProfitLoss(outletId, month)

  const monthRange = useMemo(() => {
    const base = /^\d{4}-\d{2}$/.test(month) ? new Date(`${month}-01`) : new Date()
    return { from: startOfMonth(base), to: endOfMonth(base) }
  }, [month])
  const { data: daily = [] } = useDailySales(outletId, monthRange)
  const { data: expenseRows = [] } = useExpensesByCategory(outletId, month)

  // ── Sisi biaya (dari v_profit_loss) ──────────────────────────────────────────
  const plData = useMemo(() => {
    if (pl.length === 0) return null
    if (outletId) return pl[0]
    return pl.reduce((acc, curr) => ({
      outlet_id: 'all', month: curr.month,
      gross_revenue: acc.gross_revenue + Number(curr.gross_revenue),
      total_discount: acc.total_discount + Number(curr.total_discount),
      total_refund: acc.total_refund + Number(curr.total_refund),
      net_revenue: acc.net_revenue + Number(curr.net_revenue),
      cost_of_goods: acc.cost_of_goods + Number(curr.cost_of_goods),
      gross_profit: acc.gross_profit + Number(curr.gross_profit),
      total_expenses: acc.total_expenses + Number(curr.total_expenses),
      net_profit: acc.net_profit + Number(curr.net_profit),
    }), {
      outlet_id: 'all', month: pl[0].month,
      gross_revenue: 0, total_discount: 0, total_refund: 0, net_revenue: 0,
      cost_of_goods: 0, gross_profit: 0, total_expenses: 0, net_profit: 0,
    } as ProfitLoss)
  }, [pl, outletId])

  // ── Sisi pendapatan (dari v_daily_sales — punya pajak & service charge) ───────
  const rev = useMemo(() => daily.reduce((a, d) => ({
    gross: a.gross + Number(d.gross_revenue),
    discount: a.discount + Number(d.total_discount),
    tax: a.tax + Number(d.total_tax),
    service: a.service + Number(d.total_service_charge),
    net: a.net + Number(d.net_revenue),
    orders: a.orders + Number(d.total_orders),
  }), { gross: 0, discount: 0, tax: 0, service: 0, net: 0, orders: 0 }), [daily])

  const cogs = plData?.cost_of_goods ?? 0
  const opex = plData?.total_expenses ?? 0
  const netRevenue = plData?.net_revenue ?? 0
  const grossProfit = netRevenue - cogs
  const netProfit = grossProfit - opex
  const avgPerTrx = rev.orders > 0 ? rev.net / rev.orders : 0
  const margin = netRevenue > 0 ? (netProfit / netRevenue) * 100 : 0

  const expenseByCat = useMemo(() => {
    const map: Record<string, number> = {}
    expenseRows.forEach((e) => { map[e.category] = (map[e.category] ?? 0) + Number(e.amount) })
    const total = Object.values(map).reduce((s, v) => s + v, 0)
    const rows = (Object.keys(CATEGORY_LABELS) as ExpenseCategory[])
      .map((c) => ({ label: CATEGORY_LABELS[c], value: map[c] ?? 0 }))
      .filter((r) => r.value > 0)
      .sort((a, b) => b.value - a.value)
    return { rows, total }
  }, [expenseRows])

  const monthLabel = /^\d{4}-\d{2}$/.test(month) ? format(new Date(`${month}-01`), 'MMMM yyyy') : month

  const plRows = plData ? [
    { label: 'Penjualan Produk (Kotor)', value: rev.gross },
    { label: 'Diskon', value: -rev.discount },
    { label: 'Tagihan Pelanggan Sebelum Refund', value: rev.net + plData.total_refund },
    { label: 'Refund', value: -(plData.total_refund) },
    { label: 'Total Penerimaan Pelanggan', value: rev.net, bold: true },
    { label: 'Pajak Pelanggan (tidak masuk laba)', value: -rev.tax },
    { label: 'Service Charge (tidak masuk laba)', value: -rev.service },
    { label: 'Pendapatan Bersih (tanpa pajak/service)', value: netRevenue, bold: true },
    { label: 'HPP / Bahan Baku', value: -cogs },
    { label: 'Laba Kotor', value: grossProfit, bold: true },
    { label: 'Pengeluaran Operasional', value: -opex },
    { label: 'Laba Bersih', value: netProfit, bold: true, highlight: true },
  ] : []

  const outletName = outletId
    ? outlets.find((o) => o.id === outletId)?.name ?? 'Outlet'
    : 'Semua Outlet'
  const exportRows = plRows.map(({ label, value }) => [
    label,
    formatCurrency(value),
  ])
  const exportConfig = {
    title: 'Laporan Keuangan',
    outletName,
    period: monthLabel,
    summaryStats: [
      { label: 'Total Penerimaan Pelanggan', value: formatCurrency(rev.net) },
      { label: 'Pendapatan Bersih', value: formatCurrency(netRevenue) },
      { label: 'HPP', value: formatCurrency(cogs) },
      { label: 'Laba Kotor', value: formatCurrency(grossProfit) },
      { label: 'Biaya Operasional', value: formatCurrency(opex) },
      { label: 'Laba Bersih', value: formatCurrency(netProfit) },
    ],
    tableHeaders: ['Keterangan', 'Nilai'],
    tableRows: exportRows,
    filename: `laporan-keuangan-${month}.`,
  }

  const handleExport = async (type: 'excel' | 'pdf') => {
    if (!plData || isExporting) return
    setIsExporting(true)
    try {
      if (type === 'excel') {
        exportReportExcel({ ...exportConfig, filename: `${exportConfig.filename}xls` })
      } else {
        await exportReportPDF({ ...exportConfig, filename: `${exportConfig.filename}pdf` })
      }
    } finally {
      setIsExporting(false)
    }
  }

  return (
    <div className="space-y-4">
      <PageHeader title="Laporan Keuangan" subtitle="Laba rugi & rincian per bulan">
        <div className="inline-flex items-center gap-0.5 rounded-lg border bg-white px-1.5 py-1 shadow-sm">
          <span className="text-[11px] font-medium text-muted-foreground px-1.5">Ekspor</span>
          <div className="w-px h-4 bg-border mx-0.5" />
          <Button
            variant="ghost"
            size="sm"
            className="h-7 px-2.5 text-xs gap-1.5 rounded-md"
            onClick={() => handleExport('excel')}
            disabled={!plData || isExporting}
          >
            <FileText className="h-3.5 w-3.5" /> Excel
          </Button>
          <Button
            variant="ghost"
            size="sm"
            className="h-7 px-2.5 text-xs gap-1.5 rounded-md"
            onClick={() => handleExport('pdf')}
            disabled={!plData || isExporting}
          >
            <FileText className="h-3.5 w-3.5" /> PDF
          </Button>
        </div>
      </PageHeader>

      <div className="flex items-center gap-3 flex-wrap">
        <MonthPicker value={month} onChange={setMonth} />
        <Select value={outletId ?? 'all'} onValueChange={(v) => setOutletId(v === 'all' ? null : v)}>
          <SelectTrigger className="w-48"><SelectValue placeholder="Semua Outlet" /></SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Semua Outlet</SelectItem>
            {outlets.map((o) => <SelectItem key={o.id} value={o.id}>{o.name}</SelectItem>)}
          </SelectContent>
        </Select>
      </div>

      {/* KPI ringkas */}
      <div className="grid gap-3 grid-cols-2 lg:grid-cols-5">
        {isLoading ? Array.from({ length: 5 }).map((_, i) => (
          <div key={i} className="rounded-xl border border-gray-200 bg-white p-4 shadow-sm">
            <Skeleton className="h-3 w-24" /><Skeleton className="h-6 w-28 mt-2" />
          </div>
        )) : (
          <>
            <StatCard label="Total Penerimaan Pelanggan" value={formatCurrency(rev.net)} hint="Uang dibayar pelanggan, termasuk pajak dan service charge" />
            <StatCard label="Pendapatan Bersih" value={formatCurrency(netRevenue)} hint="Penjualan produk setelah diskon/refund, tanpa pajak dan service" />
            <StatCard label="Total Transaksi" value={rev.orders.toLocaleString('id-ID')} />
            <StatCard label="Rata-rata / Transaksi" value={formatCurrency(avgPerTrx)} />
            <StatCard label="Margin Laba Bersih" value={`${margin.toFixed(1)}%`} hint={formatCurrency(netProfit)} />
          </>
        )}
      </div>

      <div className="grid gap-4 lg:grid-cols-2 items-start">
        {/* Laba Rugi */}
        <Card>
          <CardHeader><CardTitle className="text-base">Laporan Laba Rugi — {monthLabel}</CardTitle></CardHeader>
          <CardContent>
            {isLoading ? (
              <div className="space-y-3">{Array.from({ length: 10 }).map((_, i) => <div key={i} className="h-6 bg-muted rounded animate-pulse" />)}</div>
            ) : !plData ? (
              <p className="text-center text-muted-foreground py-8">Tidak ada data keuangan untuk periode ini.</p>
            ) : (
              <div className="divide-y">
                {plRows.map(({ label, value, bold, highlight }) => (
                  <div key={label} className={`flex justify-between py-2.5 ${bold ? 'font-semibold' : 'text-sm'}`}>
                    <span className={highlight ? (value >= 0 ? 'text-green-700' : 'text-destructive') : ''}>{label}</span>
                    <span className={`font-mono tabular-nums ${value < 0 ? 'text-destructive' : ''} ${highlight ? (value >= 0 ? 'text-green-700' : 'text-destructive') : ''}`}>
                      <CurrencyDisplay value={value} />
                    </span>
                  </div>
                ))}
              </div>
            )}
          </CardContent>
        </Card>

        {/* Rincian Pengeluaran per Kategori */}
        <Card>
          <CardHeader><CardTitle className="text-base">Rincian Pengeluaran per Kategori</CardTitle></CardHeader>
          <CardContent>
            {isLoading ? (
              <div className="space-y-3">{Array.from({ length: 5 }).map((_, i) => <div key={i} className="h-6 bg-muted rounded animate-pulse" />)}</div>
            ) : expenseByCat.rows.length === 0 ? (
              <p className="text-center text-muted-foreground py-8">Belum ada pengeluaran pada periode ini.</p>
            ) : (
              <div className="divide-y">
                {expenseByCat.rows.map(({ label, value }) => (
                  <div key={label} className="flex justify-between py-2.5 text-sm">
                    <span>{label}</span>
                    <span className="font-mono tabular-nums"><CurrencyDisplay value={value} /></span>
                  </div>
                ))}
                <div className="flex justify-between py-2.5 font-semibold">
                  <span>Total Pengeluaran</span>
                  <span className="font-mono tabular-nums"><CurrencyDisplay value={expenseByCat.total} /></span>
                </div>
              </div>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  )
}
