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
import { useOutlet } from '@/hooks/useOutlet'
import {
  useDailySales,
  useTopMenuItemsRange,
  usePaymentSummaryRange,
  useCategorySalesRange,
  useKasirPerformanceRange,
  usePeakHours,
  useProfitLossRange,
} from '@/hooks/queries/useSales'
import { PeakHoursCard } from '@/components/ui/PeakHoursCard'
import { useActiveOrders, useActiveOrderSummary } from '@/hooks/queries/useOrders'
import { useLowStock } from '@/hooks/queries/useIngredients'
import { useTables } from '@/hooks/queries/useOutlets'
import { useRealtimeOrders } from '@/hooks/useRealtimeOrders'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { CurrencyDisplay } from '@/components/ui/CurrencyDisplay'
import { formatCurrency } from '@/lib/currency'
import { Skeleton } from '@/components/ui/skeleton'
import { StatusBadge } from '@/components/ui/StatusBadge'
import { cn } from '@/lib/utils'
import { getJakartaNow } from '@/lib/businessDate'
import { summarizeDailySales } from '@/lib/dashboardMetrics'

type Period = 'daily' | 'weekly' | 'monthly'

// Prevent long Rupiah values from wrapping in the middle while allowing the
// type to scale down smoothly when the dashboard summary columns get narrow.
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
const ORDER_TYPE_LABEL: Record<string, string> = {
  dine_in: 'Dine In', takeaway: 'Takeaway', self_order: 'Self Order',
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
  return (
    <p className="text-xs text-muted-foreground">{text}</p>
  )
}

function DataList({ rows }: { rows: { label: string; value: React.ReactNode }[] }) {
  return (
    <div className="w-full space-y-1.5">
      {rows.map((r, i) => (
        <div key={`${r.label}-${i}`} className="flex justify-between text-xs w-full">
          <span className="text-muted-foreground">{r.label}</span>
          <span className="font-semibold">{r.value}</span>
        </div>
      ))}
    </div>
  )
}

export default function AdminDashboard() {
  const { activeOutletId } = useOutlet()
  const [period, setPeriod] = useState<Period>('daily')
  const [offset, setOffset] = useState(0)

  const { range, chartRange, label } = useMemo(() => getRange(period, offset), [period, offset])
  const dateFrom = format(range.from, 'yyyy-MM-dd')
  const dateTo = format(range.to, 'yyyy-MM-dd')

  const {
    data: sales = [],
    isLoading: loadingSales,
    dataUpdatedAt: salesUpdatedAt,
  } = useDailySales(activeOutletId, chartRange)
  const dayKey = format(range.from, 'yyyy-MM-dd')
  const { data: hourly = [], isLoading: loadingHourly } = usePeakHours(activeOutletId, dayKey, dayKey)
  const { data: activeOrders = [], isLoading: loadingOrders } = useActiveOrders(activeOutletId ?? '')
  const {
    data: activeOrderSummary,
    isLoading: loadingOrderSummary,
  } = useActiveOrderSummary(activeOutletId ?? '')
  const { data: lowStock = [], isLoading: loadingStock } = useLowStock(activeOutletId ?? '')
  const { data: topItems = [], isLoading: loadingTop } = useTopMenuItemsRange(activeOutletId, dateFrom, dateTo)
  const { data: payments = [], isLoading: loadingPayments } = usePaymentSummaryRange(activeOutletId, dateFrom, dateTo)
  const { data: tables = [] } = useTables(activeOutletId ?? '')
  const { data: categorySales = [] } = useCategorySalesRange(activeOutletId, dateFrom, dateTo)
  const { data: kasirData = [] } = useKasirPerformanceRange(activeOutletId, dateFrom, dateTo)
  const {
    data: profitLoss,
    isLoading: loadingProfit,
  } = useProfitLossRange(activeOutletId, dateFrom, dateTo)

  useRealtimeOrders(activeOutletId)

  const rangeData = useMemo(() => {
    const from = format(range.from, 'yyyy-MM-dd')
    const to = format(range.to, 'yyyy-MM-dd')
    return sales.filter((s) => s.sale_date >= from && s.sale_date <= to)
  }, [sales, range])

  const salesMetrics = useMemo(() => summarizeDailySales(rangeData), [rangeData])
  const totalSales = salesMetrics.grossRevenue
  const totalTransactions = salesMetrics.totalOrders
  const totalDiscount = salesMetrics.totalDiscount
  const totalTax = salesMetrics.totalTax
  const totalServiceCharge = salesMetrics.totalServiceCharge
  const totalReceipts = salesMetrics.totalReceipts
  const unpaidAmount = activeOrderSummary?.totalAmount ?? 0
  const salesPerTrx = totalTransactions > 0 ? totalSales / totalTransactions : 0

  // Rumus sama dengan laporan keuangan: pendapatan bersih - HPP - pengeluaran.
  const totalExpenses = profitLoss?.total_expenses ?? 0
  const totalHpp = profitLoss?.cost_of_goods ?? 0
  const totalRefund = profitLoss?.total_refund ?? 0
  const netRevenue = profitLoss?.net_revenue ?? 0
  const labaBersih = profitLoss?.net_profit ?? 0

  const chartData = useMemo(() => {
    if (period === 'daily') {
      const byHour = new Map<number, number>()
      hourly.forEach((h) => byHour.set(
        Number(h.hour_of_day),
        (byHour.get(Number(h.hour_of_day)) ?? 0) + Number(h.total_revenue),
      ))
      return Array.from({ length: 24 }, (_, hour) => ({
        label: String(hour).padStart(2, '0'),
        omzet: byHour.get(hour) ?? 0,
      }))
    }
    const days = eachDayOfInterval({ start: chartRange.from, end: chartRange.to })
    return days.map((d) => {
      const key = format(d, 'yyyy-MM-dd')
      const row = sales.find((s) => s.sale_date === key)
      return {
        label: format(d, period === 'monthly' ? 'd' : 'EEE', { locale: id }),
        omzet: Number(row?.gross_revenue ?? 0),
      }
    })
  }, [sales, hourly, chartRange, period])

  const hasChartData = useMemo(() => chartData.some((row) => row.omzet > 0), [chartData])

  const paymentRows = useMemo(() => {
    const map: Record<string, number> = {}
    payments.forEach((p) => { map[p.method] = (map[p.method] ?? 0) + Number(p.total_amount) })
    return Object.entries(map)
      .sort((a, b) => b[1] - a[1])
      .map(([k, v]) => ({ label: PAYMENT_LABEL[k] ?? k, value: <CurrencyDisplay value={v} /> }))
  }, [payments])

  const orderTypeRows = useMemo(() => {
    const map: Record<string, number> = {}
    Object.entries(activeOrderSummary?.byOrderType ?? {}).forEach(([type, count]) => {
      if (count > 0) map[type] = count
    })
    return Object.entries(map)
      .sort((a, b) => b[1] - a[1])
      .map(([k, v]) => ({ label: ORDER_TYPE_LABEL[k] ?? k, value: `${v}` }))
  }, [activeOrderSummary])

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

  if (!activeOutletId) return <NoOutlet />

  return (
    <div className="space-y-4">

      {/* ── Top card ─────────────────────────────────── */}
      <div className="rounded-xl border bg-white shadow-sm">

        {/* Header row */}
        <div className="flex flex-wrap items-start justify-between gap-3 px-5 pt-5 pb-3">
          <div>
            <h1 className="text-lg font-bold">Dasbor Penjualan</h1>
            <p className="text-xs text-muted-foreground mt-0.5">
              Terakhir Diperbarui {salesUpdatedAt > 0
                ? format(new Date(salesUpdatedAt), 'd MMM yyyy, HH:mm:ss', { locale: id })
                : '—'}
            </p>
          </div>

          {/* Period tabs + date nav */}
          <div className="flex flex-wrap items-center gap-3">
            <div className="flex border rounded-lg overflow-hidden text-sm">
              {(['daily', 'weekly', 'monthly'] as Period[]).map((p) => (
                <button
                  key={p}
                  type="button"
                  onClick={() => { setPeriod(p); setOffset(0) }}
                  aria-pressed={period === p}
                  className={cn(
                    'px-4 py-1.5 font-medium transition-colors capitalize',
                    period === p
                      ? 'bg-primary text-white'
                      : 'text-muted-foreground hover:bg-muted'
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

        {/* Stats row — 4 columns with vertical dividers */}
        <div className="grid grid-cols-2 lg:grid-cols-4 divide-x px-0">

          {/* Col 1: Total Sales */}
          <div className="px-5 py-4">
            <p className="text-xs text-muted-foreground">Penjualan Produk (Kotor)</p>
            {loadingSales
              ? <Skeleton className="h-8 w-28 mt-1" />
              : <p className={cn(responsiveMoneyClass, 'font-bold mt-1 tabular-nums')}><CurrencyDisplay value={totalSales} /></p>}
            <p className="text-xs text-muted-foreground mt-2">
              Subtotal produk sebelum diskon, pajak, dan service
            </p>
            <p className="text-xs text-muted-foreground mt-0.5">
              Diskon <CurrencyDisplay value={totalDiscount} />
            </p>
          </div>

          {/* Col 2: Unpaid / Paid */}
          <div className="px-5 py-4 space-y-3">
            <div>
              <p className="text-xs text-muted-foreground">Belum Dibayar Saat Ini</p>
              {loadingOrderSummary
                ? <Skeleton className="h-5 w-20 mt-1" />
                : <p className="font-bold mt-0.5"><CurrencyDisplay value={unpaidAmount} /></p>}
            </div>
            <div className="border-t pt-3">
              <p className="text-xs text-muted-foreground">Total Penerimaan Pelanggan</p>
              {loadingSales || loadingProfit
                ? <Skeleton className="h-5 w-20 mt-1" />
                : <p className="font-bold mt-0.5"><CurrencyDisplay value={totalReceipts} /></p>}
              <p className="mt-0.5 text-[11px] leading-snug text-muted-foreground">
                Termasuk pajak dan service, setelah refund
              </p>
            </div>
          </div>

          {/* Col 3: Transactions / Active Orders */}
          <div className="px-5 py-4 space-y-3">
            <div>
              <p className="text-xs text-muted-foreground">Transaksi</p>
              {loadingSales
                ? <Skeleton className="h-5 w-12 mt-1" />
                : <p className="font-bold mt-0.5">{totalTransactions}</p>}
            </div>
            <div className="border-t pt-3">
              <p className="text-xs text-muted-foreground">Pesanan Aktif</p>
              {loadingOrderSummary
                ? <Skeleton className="h-5 w-12 mt-1" />
                : <p className="font-bold mt-0.5">{activeOrderSummary?.totalOrders ?? 0}</p>}
            </div>
          </div>

          {/* Col 4: Per transaction / Tables */}
          <div className="px-5 py-4 space-y-3">
            <div>
              <p className="text-xs text-muted-foreground">Rata-rata Penjualan Produk</p>
              {loadingSales
                ? <Skeleton className="h-5 w-20 mt-1" />
                : <p className="font-bold mt-0.5"><CurrencyDisplay value={salesPerTrx} /></p>}
            </div>
            <div className="border-t pt-3">
              <p className="text-xs text-muted-foreground">Meja Terisi</p>
              <p className="font-bold mt-0.5">
                {tables.filter((t) => t.status === 'occupied').length}/{tables.length}
              </p>
            </div>
          </div>
        </div>

        {/* Pengeluaran & Laba Bersih row */}
        <div
          data-testid="profit-summary"
          className="grid min-w-0 grid-cols-1 border-t lg:grid-cols-2 lg:divide-x"
        >
          <div className="grid min-w-0 grid-cols-1 sm:grid-cols-2 sm:divide-x">
            <div
              data-testid="profit-expenses"
              className="min-w-0 overflow-hidden border-b px-5 py-4 sm:border-b-0"
            >
              <p className="text-xs text-muted-foreground">Total Pengeluaran</p>
              {loadingProfit
                ? <Skeleton className="h-5 w-24 mt-1" />
                : <p className="mt-1 break-words text-lg font-bold leading-tight tabular-nums text-red-500 [overflow-wrap:anywhere]">
                    - <CurrencyDisplay value={totalExpenses} />
                  </p>}
            </div>
            <div
              data-testid="profit-net"
              className="min-w-0 overflow-hidden px-5 py-4"
            >
              <p className="text-xs text-muted-foreground">Laba Bersih</p>
              {loadingSales || loadingProfit
                ? <Skeleton className="h-5 w-24 mt-1" />
                : <p className={cn('mt-1 break-words text-lg font-bold leading-tight tabular-nums [overflow-wrap:anywhere]', labaBersih >= 0 ? 'text-emerald-600' : 'text-red-500')}>
                    <CurrencyDisplay value={labaBersih} />
                  </p>}
              <p className="mt-1 text-xs leading-relaxed text-muted-foreground">
                Pendapatan bersih − HPP − pengeluaran
              </p>
            </div>
          </div>
          <div
            data-testid="profit-formula"
            className="min-w-0 overflow-hidden border-t px-5 py-4 lg:border-t-0"
          >
            <p className="text-xs font-medium text-foreground">Rincian laba bersih</p>
            <p className="mt-0.5 text-[11px] leading-relaxed text-muted-foreground">
              Pajak dan service charge tidak dihitung sebagai laba.
            </p>
            <dl className="mt-3 grid min-w-0 grid-cols-[minmax(0,1fr)_auto] gap-x-3 gap-y-2 text-xs">
              <dt className="min-w-0 text-muted-foreground">Tagihan sebelum refund</dt>
              <dd className="whitespace-nowrap text-right font-medium tabular-nums text-foreground">
                <CurrencyDisplay value={totalReceipts + totalRefund} />
              </dd>
              <dt className="min-w-0 text-muted-foreground">Refund</dt>
              <dd className="whitespace-nowrap text-right font-medium tabular-nums text-red-500">
                - <CurrencyDisplay value={totalRefund} />
              </dd>
              <dt className="min-w-0 text-muted-foreground">Penerimaan pelanggan</dt>
              <dd className="whitespace-nowrap text-right font-medium tabular-nums text-foreground">
                <CurrencyDisplay value={totalReceipts} />
              </dd>
              <dt className="min-w-0 text-muted-foreground">Pajak (tidak masuk laba)</dt>
              <dd className="whitespace-nowrap text-right font-medium tabular-nums text-muted-foreground">
                <CurrencyDisplay value={totalTax} />
              </dd>
              <dt className="min-w-0 text-muted-foreground">Service (tidak masuk laba)</dt>
              <dd className="whitespace-nowrap text-right font-medium tabular-nums text-muted-foreground">
                <CurrencyDisplay value={totalServiceCharge} />
              </dd>
              <dt className="min-w-0 text-muted-foreground">Pendapatan Bersih</dt>
              <dd className="whitespace-nowrap text-right font-medium tabular-nums text-foreground">
                <CurrencyDisplay value={netRevenue} />
              </dd>
              <dt className="min-w-0 text-muted-foreground">HPP</dt>
              <dd className="whitespace-nowrap text-right font-medium tabular-nums text-red-500">
                - <CurrencyDisplay value={totalHpp} />
              </dd>
              <dt className="min-w-0 text-muted-foreground">Pengeluaran</dt>
              <dd className="whitespace-nowrap text-right font-medium tabular-nums text-red-500">
                - <CurrencyDisplay value={totalExpenses} />
              </dd>
              <dt className="min-w-0 border-t pt-2 font-semibold text-foreground">Laba Bersih</dt>
              <dd className={cn(
                'whitespace-nowrap border-t pt-2 text-right font-bold tabular-nums',
                labaBersih >= 0 ? 'text-emerald-600' : 'text-red-500'
              )}>
                <CurrencyDisplay value={labaBersih} />
              </dd>
            </dl>
          </div>
        </div>

        <div className="border-t" />

        {/* Chart */}
        <div className="px-5 py-4">
          <div className="flex items-center justify-between mb-3">
            <p className="text-sm font-semibold">
              Penjualan <span className="font-normal text-muted-foreground">{label}</span>
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

        <MiniCard title="Metode Pembayaran (Tanggal Bayar)" viewHref="/admin/reports" loading={loadingPayments}>
          {paymentRows.length === 0
            ? <EmptyCard text="Belum ada pembayaran" />
            : <DataList rows={paymentRows} />}
        </MiniCard>

        <MiniCard title="Tipe Pesanan Aktif" viewHref="/admin/orders" loading={loadingOrderSummary}>
          {orderTypeRows.length === 0
            ? <EmptyCard text="Belum ada transaksi" />
            : <DataList rows={orderTypeRows} />}
        </MiniCard>

        <MiniCard title="Penjualan per Kategori" viewHref="/admin/sales-breakdown/kategori">
          {categoryRows.length === 0
            ? <EmptyCard text="Belum ada transaksi" />
            : <DataList rows={categoryRows} />}
        </MiniCard>

        <MiniCard title="Produk Terlaris" viewHref="/admin/menu" loading={loadingTop}>
          {topItems.length === 0
            ? <EmptyCard text="Belum ada transaksi" />
            : <DataList rows={topItems.slice(0, 5).map((i) => ({
                label: i.menu_item_name,
                value: `${i.qty_sold}x`,
              }))} />}
        </MiniCard>

        <MiniCard title="Pesanan Aktif" viewHref="/admin/orders" loading={loadingOrders}>
          {activeOrders.length === 0
            ? <EmptyCard text="Belum ada transaksi" />
            : <DataList rows={activeOrders.slice(0, 5).map((o) => ({
                label: o.order_number,
                value: <StatusBadge status={o.status} />,
              }))} />}
        </MiniCard>

        <MiniCard title="Penjualan per Kasir" viewHref="/admin/reports">
          {kasirRows.length === 0
            ? <EmptyCard text="Belum ada transaksi" />
            : <DataList rows={kasirRows} />}
        </MiniCard>

        <PeakHoursCard outletId={activeOutletId} />

        <MiniCard title="Status Meja" viewHref="/admin/tables">
          {tables.length === 0
            ? <EmptyCard text="Belum ada meja" />
            : <DataList rows={[
                { label: 'Terisi', value: `${tables.filter((t) => t.status === 'occupied').length}` },
                { label: 'Tersedia', value: `${tables.filter((t) => t.status === 'available').length}` },
                { label: 'Reservasi', value: `${tables.filter((t) => t.status === 'reserved').length}` },
                { label: 'Kotor', value: `${tables.filter((t) => t.status === 'dirty').length}` },
              ].filter((r) => Number(r.value) > 0)} />}
        </MiniCard>

        <MiniCard title="Stok Terendah" viewHref="/admin/stock" loading={loadingStock}>
          {lowStock.length === 0
            ? <EmptyCard text="Belum ada transaksi" />
            : <DataList rows={lowStock.slice(0, 5).map((i) => ({
                label: i.name,
                value: <StatusBadge status={i.status} />,
              }))} />}
        </MiniCard>

      </div>
    </div>
  )
}
