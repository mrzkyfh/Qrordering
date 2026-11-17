import { useState, useMemo } from 'react'
import {
  addDays, addWeeks, addMonths,
  startOfDay, endOfDay, startOfWeek, endOfWeek, startOfMonth, endOfMonth,
  eachDayOfInterval, format,
} from 'date-fns'
import { id } from 'date-fns/locale'
import {
  LineChart, Line, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid,
} from 'recharts'
import { ChevronLeft, ChevronRight } from 'lucide-react'
import { Link } from 'react-router'
import {
  useDailySales,
  useTopMenuItemsRange,
  usePaymentSummaryRange,
  useCategorySalesRange,
  useKasirPerformanceRange,
  usePeakHours,
  useProfitLossRange,
} from '@/hooks/queries/useSales'
import { useOutlets } from '@/hooks/queries/useOutlets'
import { useStaff } from '@/hooks/queries/useStaff'
import { PeakHoursCard } from '@/components/ui/PeakHoursCard'
import { CurrencyDisplay } from '@/components/ui/CurrencyDisplay'
import { formatCurrency } from '@/lib/currency'
import { Skeleton } from '@/components/ui/skeleton'
import { Badge } from '@/components/ui/badge'
import { cn } from '@/lib/utils'
import { getJakartaNow } from '@/lib/businessDate'
import { summarizeDailySales } from '@/lib/dashboardMetrics'

type Period = 'daily' | 'weekly' | 'monthly'

// Keep long Rupiah values readable inside the five-column summary at every
// dashboard width. The previous fixed `text-2xl` + `break-words` combination
// could split a value in the middle (for example Rp15.058.000 -> Rp15.058.0 / 00).
const responsiveMoneyClass = 'text-[clamp(0.95rem,1.1vw,1.5rem)] leading-tight tracking-tight whitespace-nowrap'

function getRange(period: Period, offset: number) {
  const base = getJakartaNow()
  if (period === 'daily') {
    const d = addDays(base, offset)
    return {
      range: { from: startOfDay(d), to: endOfDay(d) },
      chartRange: { from: startOfDay(d), to: endOfDay(d) },
      label: format(d, 'd MMM yy', { locale: id }),
    }
  }
  if (period === 'weekly') {
    const w = addWeeks(base, offset)
    const from = startOfWeek(w, { weekStartsOn: 1 })
    const to = endOfWeek(w, { weekStartsOn: 1 })
    return {
      range: { from, to },
      chartRange: { from, to },
      label: `${format(from, 'd MMM')} – ${format(to, 'd MMM yy', { locale: id })}`,
    }
  }
  const m = addMonths(base, offset)
  const from = startOfMonth(m)
  const to = endOfMonth(m)
  return {
    range: { from, to },
    chartRange: { from, to },
    label: format(m, 'MMMM yyyy', { locale: id }),
  }
}

const PAYMENT_LABEL: Record<string, string> = {
  cash: 'Tunai', qris: 'QRIS', debit: 'Debit',
  credit: 'Kredit', ewallet: 'E-Wallet', transfer: 'Transfer',
}

function MiniCard({
  title, viewHref, children, loading,
}: {
  title: string; viewHref?: string; children: React.ReactNode; loading?: boolean
}) {
  return (
    <div className="rounded-xl border bg-white shadow-sm flex flex-col" style={{ minHeight: 200 }}>
      <div className="px-4 pt-4 pb-2">
        <p className="font-bold text-sm">{title}</p>
      </div>
      <div className="flex-1 flex items-center justify-center px-4">
        {loading
          ? <Skeleton className="h-5 w-3/4" />
          : children}
      </div>
      <div className="border-t flex items-center justify-end px-4 py-2.5 min-h-10">
        {viewHref && (
          <Link
            to={viewHref}
            className="flex items-center gap-0.5 text-xs font-semibold text-primary hover:underline"
          >
            Lihat Semua <ChevronRight className="h-3.5 w-3.5" />
          </Link>
        )}
      </div>
    </div>
  )
}

function EmptyCard({ text }: { text: string }) {
  return <p className="text-xs text-muted-foreground">{text}</p>
}

function DataList({ rows }: { rows: { label: string; value: React.ReactNode }[] }) {
  return (
    <div className="w-full space-y-1.5">
      {rows.map((r, i) => (
        <div key={`${r.label}-${i}`} className="flex justify-between text-xs w-full">
          <span className="text-muted-foreground truncate max-w-[120px]">{r.label}</span>
          <span className="font-semibold">{r.value}</span>
        </div>
      ))}
    </div>
  )
}

export default function OwnerDashboard() {
  const [period, setPeriod] = useState<Period>('daily')
  const [offset, setOffset] = useState(0)

  const { range, chartRange, label } = useMemo(() => getRange(period, offset), [period, offset])
  const dateFrom = format(range.from, 'yyyy-MM-dd')
  const dateTo = format(range.to, 'yyyy-MM-dd')

  const { data: outlets = [], isLoading: loadingOutlets } = useOutlets()
  const {
    data: sales = [],
    isLoading: loadingSales,
    dataUpdatedAt: salesUpdatedAt,
  } = useDailySales(null, chartRange)
  // Mode Harian: grafik per-jam dari v_peak_hours (hari yg dipilih)
  const dayKey = format(range.from, 'yyyy-MM-dd')
  const { data: hourly = [], isLoading: loadingHourly } = usePeakHours(null, dayKey, dayKey)
  const { data: topMenu = [], isLoading: loadingTop } = useTopMenuItemsRange(null, dateFrom, dateTo)
  const { data: payments = [], isLoading: loadingPayments } = usePaymentSummaryRange(null, dateFrom, dateTo)
  const { data: categorySales = [] } = useCategorySalesRange(null, dateFrom, dateTo)
  const { data: kasirData = [] } = useKasirPerformanceRange(null, dateFrom, dateTo)
  const {
    data: profitLoss,
    isLoading: loadingProfit,
  } = useProfitLossRange(null, dateFrom, dateTo)
  const { data: staff = [] } = useStaff()

  // Stats for selected range only
  const rangeData = useMemo(() => {
    const from = format(range.from, 'yyyy-MM-dd')
    const to = format(range.to, 'yyyy-MM-dd')
    return sales.filter((s) => s.sale_date >= from && s.sale_date <= to)
  }, [sales, range])

  const salesMetrics = useMemo(() => summarizeDailySales(rangeData), [rangeData])
  const totalSales = salesMetrics.grossRevenue
  const totalTransactions = salesMetrics.totalOrders
  const totalDiscount = salesMetrics.totalDiscount
  const totalReceipts = salesMetrics.totalReceipts
  const salesPerTrx = totalTransactions > 0 ? totalSales / totalTransactions : 0
  const activeOutlets = outlets.filter((o) => o.is_active).length

  // Rumus sama dengan laporan keuangan: pendapatan bersih - HPP - pengeluaran
  // operasional. RPC mencakup transaksi live dan data yang sudah diarsipkan.
  const totalExpenses = profitLoss?.total_expenses ?? 0
  const totalHpp = profitLoss?.cost_of_goods ?? 0
  const totalRefund = profitLoss?.total_refund ?? 0
  const netRevenue = profitLoss?.net_revenue ?? 0
  const labaBersih = profitLoss?.net_profit ?? 0

  // Chart data
  const chartData = useMemo(() => {
    // Harian → grafik per-jam (00:00–23:00) dari v_peak_hours
    if (period === 'daily') {
      const byHour = new Map<number, number>()
      hourly.forEach((h) => byHour.set(h.hour_of_day, (byHour.get(h.hour_of_day) ?? 0) + Number(h.total_revenue)))
      return Array.from({ length: 24 }, (_, hr) => ({
        label: String(hr).padStart(2, '0'),
        omzet: byHour.get(hr) ?? 0,
      }))
    }
    // Mingguan/Bulanan → grafik per-hari
    const days = eachDayOfInterval({ start: chartRange.from, end: chartRange.to })
    return days.map((d) => {
      const key = format(d, 'yyyy-MM-dd')
      const dayTotal = sales
        .filter((s) => s.sale_date === key)
        .reduce((sum, s) => sum + Number(s.gross_revenue), 0)
      return {
        label: format(d, period === 'monthly' ? 'd' : 'EEE', { locale: id }),
        omzet: dayTotal,
      }
    })
  }, [sales, hourly, chartRange, period])

  const hasChartData = useMemo(() => chartData.some((d) => d.omzet > 0), [chartData])

  // Payment breakdown
  const paymentRows = useMemo(() => {
    const map: Record<string, number> = {}
    payments.forEach((p) => { map[p.method] = (map[p.method] ?? 0) + Number(p.total_amount) })
    return Object.entries(map)
      .sort((a, b) => b[1] - a[1])
      .map(([k, v]) => ({ label: PAYMENT_LABEL[k] ?? k, value: <CurrencyDisplay value={v} /> }))
  }, [payments])

  // Outlet performance for the selected period. Keep the numeric omzet until
  // after sorting so "Outlet Terbaik" is based on revenue, not outlet name.
  const outletPerformance = useMemo(() => {
    return outlets.map((outlet) => {
      const omzet = rangeData
        .filter((s) => s.outlet_id === outlet.id)
        .reduce((s, d) => s + Number(d.gross_revenue), 0)
      return { label: outlet.name, omzet }
    }).sort((a, b) => b.omzet - a.omzet || a.label.localeCompare(b.label, 'id'))
  }, [outlets, rangeData])

  const outletRows = useMemo(() => outletPerformance.map((outlet) => ({
    label: outlet.label,
    value: <CurrencyDisplay value={outlet.omzet} />,
  })), [outletPerformance])

  // Rp0 means the selected period has no sales, so there is no best outlet.
  const bestOutletName = outletPerformance[0]?.omzet > 0
    ? outletPerformance[0].label
    : '—'

  const categoryRows = useMemo(() => {
    const map: Record<string, number> = {}
    categorySales.forEach((c) => {
      const key = c.category_name ?? 'Tanpa Kategori'
      map[key] = (map[key] ?? 0) + Number(c.total_revenue)
    })
    return Object.entries(map)
      .sort((a, b) => b[1] - a[1])
      .slice(0, 5)
      .map(([label, v]) => ({ label, value: <CurrencyDisplay value={v} /> }))
  }, [categorySales])

  const kasirRows = useMemo(() => {
    const map: Record<string, number> = {}
    kasirData.forEach((k) => { map[k.kasir_name] = (map[k.kasir_name] ?? 0) + Number(k.total_revenue) })
    return Object.entries(map)
      .sort((a, b) => b[1] - a[1])
      .slice(0, 5)
      .map(([label, v]) => ({ label, value: <CurrencyDisplay value={v} /> }))
  }, [kasirData])

  const staffRows = useMemo(() => {
    const active = staff.filter((s) => s.is_active)
    const count = (role: string) => active.filter((s) => s.role === role).length
    return [
      { label: 'Total Staff', value: `${active.length}` },
      { label: 'Admin', value: `${count('admin')}` },
      { label: 'Manajer', value: `${count('manajer')}` },
      { label: 'Kasir', value: `${count('kasir')}` },
    ]
  }, [staff])

  return (
    <div className="space-y-4">

      {/* ── Top card ─────────────────────────────────── */}
      <div className="rounded-xl border bg-white shadow-sm">

        {/* Header */}
        <div className="flex flex-wrap items-start justify-between gap-3 px-5 pt-5 pb-3">
          <div>
            <h1 className="text-lg font-bold">Dasbor Penjualan</h1>
            <p className="text-xs text-muted-foreground mt-0.5">
              Terakhir Diperbarui {salesUpdatedAt > 0
                ? format(new Date(salesUpdatedAt), 'd MMM yyyy, HH:mm:ss', { locale: id })
                : '—'}
            </p>
          </div>

          <div className="flex flex-wrap items-center gap-3">
            <div className="flex border rounded-lg overflow-hidden text-sm">
              {(['daily', 'weekly', 'monthly'] as Period[]).map((p) => (
                <button
                  key={p}
                  type="button"
                  onClick={() => { setPeriod(p); setOffset(0) }}
                  aria-pressed={period === p}
                  className={cn(
                    'px-4 py-1.5 font-medium transition-colors',
                    period === p ? 'bg-primary text-white' : 'text-muted-foreground hover:bg-muted'
                  )}
                >
                  {p === 'daily' ? 'Harian' : p === 'weekly' ? 'Mingguan' : 'Bulanan'}
                </button>
              ))}
            </div>
            <div className="flex items-center gap-1 text-sm font-medium">
              <button type="button" onClick={() => setOffset((o) => o - 1)} aria-label="Periode sebelumnya" className="p-1 rounded hover:bg-muted">
                <ChevronLeft className="h-4 w-4" />
              </button>
              <span className="min-w-[160px] text-center">{label}</span>
              <button
                type="button"
                onClick={() => setOffset((o) => Math.min(o + 1, 0))}
                aria-label="Periode berikutnya"
                disabled={offset === 0}
                className="p-1 rounded hover:bg-muted disabled:opacity-30"
              >
                <ChevronRight className="h-4 w-4" />
              </button>
            </div>
          </div>
        </div>

        <div className="border-t" />

        {/* Stats — 5 columns (Penjualan · Pengeluaran/Laba · Transaksi · …) */}
        <div className="grid grid-cols-2 lg:grid-cols-5 divide-x">
          <div className="px-5 py-4 min-w-0">
            <p className="text-xs text-muted-foreground">Penjualan Produk (Kotor)</p>
            {loadingSales
              ? <Skeleton className="h-8 w-28 mt-1" />
              : <p className={cn(responsiveMoneyClass, 'font-bold mt-1 tabular-nums')}><CurrencyDisplay value={totalSales} /></p>}
            <p className="text-xs text-muted-foreground mt-2 break-words">
              Diskon <CurrencyDisplay value={totalDiscount} />
            </p>
            <p className="text-xs text-muted-foreground mt-0.5 break-words">
              Per transaksi <CurrencyDisplay value={salesPerTrx} />
            </p>
          </div>

          <div className="px-5 py-4 space-y-3 min-w-0">
            <div>
              <p className="text-xs text-muted-foreground">Pengeluaran</p>
              <p className={cn(responsiveMoneyClass, 'font-bold mt-0.5 text-red-600 tabular-nums')}>
                <CurrencyDisplay value={totalExpenses} />
              </p>
            </div>
            <div className="border-t pt-3">
              <p className="text-xs text-muted-foreground">Laba Bersih</p>
              {loadingSales || loadingProfit
                ? <Skeleton className="h-5 w-20 mt-1" />
                : (
                  <p className={cn(responsiveMoneyClass, 'font-bold mt-0.5 tabular-nums', labaBersih < 0 ? 'text-red-600' : 'text-emerald-600')}>
                    <CurrencyDisplay value={labaBersih} />
                  </p>
                )}
            </div>
          </div>

          <div className="px-5 py-4 space-y-3 min-w-0">
            <div>
              <p className="text-xs text-muted-foreground">Transaksi</p>
              {loadingSales || loadingProfit
                ? <Skeleton className="h-5 w-12 mt-1" />
                : <p className="font-bold mt-0.5 tabular-nums">{totalTransactions}</p>}
            </div>
            <div className="border-t pt-3">
              <p className="text-xs text-muted-foreground">Per Transaksi</p>
              {loadingSales || loadingProfit
                ? <Skeleton className="h-5 w-20 mt-1" />
                : <p className="font-bold mt-0.5 tabular-nums break-words"><CurrencyDisplay value={salesPerTrx} /></p>}
            </div>
          </div>

          <div className="px-5 py-4 space-y-3 min-w-0">
            <div>
              <p className="text-xs text-muted-foreground">Outlet Aktif</p>
              {loadingOutlets
                ? <Skeleton className="h-5 w-12 mt-1" />
                : <p className="font-bold mt-0.5">{activeOutlets}</p>}
            </div>
            <div className="border-t pt-3">
              <p className="text-xs text-muted-foreground">Total Outlet</p>
              <p className="font-bold mt-0.5">{outlets.length}</p>
            </div>
          </div>

          <div className="px-5 py-4 space-y-3 min-w-0">
            <div>
              <p className="text-xs text-muted-foreground">Outlet Terbaik</p>
              {loadingSales || loadingOutlets
                ? <Skeleton className="h-5 w-24 mt-1" />
                : <p className="font-bold mt-0.5 text-sm truncate">
                    {bestOutletName}
                  </p>}
            </div>
            <div className="border-t pt-3">
              <p className="text-xs text-muted-foreground">Total Diskon</p>
              {loadingSales
                ? <Skeleton className="h-5 w-20 mt-1" />
                : <p className="font-bold mt-0.5 tabular-nums break-words"><CurrencyDisplay value={totalDiscount} /></p>}
            </div>
          </div>
        </div>

        <div className="border-t" />

        {/* Chart */}
        <div className="px-5 py-4">
          <div className="flex items-center justify-between mb-3">
            <p className="text-sm font-semibold">
              Penjualan <span className="font-normal text-muted-foreground">{label}{period === 'daily' ? ' (per jam)' : ''}</span>
            </p>
            <div className="flex items-center gap-4 text-xs text-muted-foreground">
              <span className="flex items-center gap-1.5">
                <span className="h-2 w-2 rounded-full bg-primary inline-block" />
                Total Penjualan
              </span>
            </div>
          </div>
          {loadingSales || (period === 'daily' && loadingHourly) ? <Skeleton className="h-44 w-full" /> : !hasChartData ? (
            <div className="flex h-44 items-center justify-center text-sm text-muted-foreground rounded-xl border bg-muted/20">
              Belum ada data penjualan untuk periode ini
            </div>
          ) : (
            <ResponsiveContainer width="100%" height={176}>
              <LineChart data={chartData} margin={{ left: -10, right: 10 }}>
                <CartesianGrid strokeDasharray="3 3" stroke="#f0f0f0" vertical={false} />
                <XAxis dataKey="label" tick={{ fontSize: 11 }} axisLine={false} tickLine={false} interval={period === 'daily' ? 2 : period === 'monthly' ? 3 : 0} />
                <YAxis
                  tickFormatter={(v) => v === 0 ? '0' : `${(v / 1_000_000).toFixed(1)}jt`}
                  tick={{ fontSize: 11 }}
                  axisLine={false}
                  tickLine={false}
                  width={38}
                />
                <Tooltip
                  formatter={(v) => typeof v === 'number' ? formatCurrency(v) : v}
                  contentStyle={{ fontSize: 12, borderRadius: 8 }}
                />
                <Line
                  type="monotone"
                  dataKey="omzet"
                  stroke="hsl(var(--primary))"
                  strokeWidth={2}
                  dot={{ r: 3, fill: 'hsl(var(--primary))' }}
                  activeDot={{ r: 5 }}
                  name="Total Penjualan"
                />
              </LineChart>
            </ResponsiveContainer>
          )}
        </div>
      </div>

      {/* ── Cards grid 4×2 ──────────────────────────── */}
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">

        <MiniCard title="Metode Pembayaran (Tanggal Bayar)" viewHref="/owner/payment-methods" loading={loadingPayments}>
          {paymentRows.length === 0
            ? <EmptyCard text="Belum ada pembayaran" />
            : <DataList rows={paymentRows} />}
        </MiniCard>

        <MiniCard title="Performa Outlet" viewHref="/owner/outlet-performance" loading={loadingSales || loadingOutlets}>
          {outletRows.length === 0
            ? <EmptyCard text="Belum ada outlet" />
            : <DataList rows={outletRows} />}
        </MiniCard>

        <MiniCard title="Produk Terlaris" viewHref="/owner/top-products" loading={loadingTop}>
          {topMenu.length === 0
            ? <EmptyCard text="Belum ada transaksi" />
            : <DataList rows={topMenu.slice(0, 5).map((i) => ({
                label: i.menu_item_name,
                value: `${i.qty_sold}x`,
              }))} />}
        </MiniCard>

        <MiniCard title="Penjualan per Kategori" viewHref="/owner/sales-by-category">
          {categoryRows.length === 0
            ? <EmptyCard text="Belum ada transaksi" />
            : <DataList rows={categoryRows} />}
        </MiniCard>

        <MiniCard title="Monitoring Cabang" viewHref="/owner/branches" loading={loadingOutlets}>
          {outlets.length === 0
            ? <EmptyCard text="Belum ada outlet" />
            : <DataList rows={outlets.map((o) => ({
                label: o.name,
                value: <Badge variant={o.is_active ? 'default' : 'secondary'} className="text-xs">
                  {o.is_active ? 'Aktif' : 'Nonaktif'}
                </Badge>,
              }))} />}
        </MiniCard>

        <MiniCard title="Penjualan per Kasir" viewHref="/owner/sales-by-kasir">
          {kasirRows.length === 0
            ? <EmptyCard text="Belum ada transaksi" />
            : <DataList rows={kasirRows} />}
        </MiniCard>

        <MiniCard title="Laporan Keuangan" viewHref="/owner/finance">
          {loadingSales || loadingProfit ? <Skeleton className="h-5 w-3/4" /> : (
            <DataList rows={[
              { label: 'Penjualan Produk (Kotor)', value: <CurrencyDisplay value={totalSales} /> },
              { label: 'Total Penerimaan Pelanggan', value: <CurrencyDisplay value={totalReceipts} /> },
              { label: 'Pendapatan Bersih (tanpa pajak/service)', value: <CurrencyDisplay value={netRevenue} /> },
              { label: 'HPP', value: <CurrencyDisplay value={totalHpp} /> },
              { label: 'Refund', value: <CurrencyDisplay value={totalRefund} /> },
              { label: 'Transaksi', value: `${totalTransactions}` },
              { label: 'Pengeluaran', value: <CurrencyDisplay value={totalExpenses} /> },
              { label: 'Laba Bersih', value: <CurrencyDisplay value={labaBersih} /> },
            ]} />
          )}
        </MiniCard>

        <MiniCard title="Manajemen Staf" viewHref="/owner/staff">
          {staff.length === 0
            ? <EmptyCard text="Belum ada staff" />
            : <DataList rows={staffRows} />}
        </MiniCard>

        <PeakHoursCard outletId={null} />

      </div>
    </div>
  )
}
