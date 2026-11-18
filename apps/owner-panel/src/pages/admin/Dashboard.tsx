import { useMemo, useState } from 'react'
import { addDays, addMonths, addWeeks, eachDayOfInterval, endOfDay, endOfMonth, endOfWeek, format, startOfDay, startOfMonth, startOfWeek } from 'date-fns'
import { id } from 'date-fns/locale'
import { AlertTriangle, ChevronLeft, ChevronRight, Clock3 } from 'lucide-react'
import { Link } from 'react-router'
import { Bar, BarChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts'
import { useOutlet } from '@/hooks/useOutlet'
import { useDailySales, usePeakHours, useTopMenuItemsRange } from '@/hooks/queries/useSales'
import { useActiveOrderSummary } from '@/hooks/queries/useOrders'
import { useLowStock } from '@/hooks/queries/useIngredients'
import { useTables } from '@/hooks/queries/useOutlets'
import { usePaymentClaims } from '@/hooks/queries/usePaymentClaims'
import { useRealtimeOrders } from '@/hooks/useRealtimeOrders'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { CurrencyDisplay } from '@/components/ui/CurrencyDisplay'
import { Skeleton } from '@/components/ui/skeleton'
import { cn } from '@/lib/utils'
import { formatCurrency } from '@/lib/currency'
import { getJakartaNow } from '@/lib/businessDate'
import { summarizeDailySales } from '@/lib/dashboardMetrics'

type Period = 'daily' | 'weekly' | 'monthly'

function getRange(period: Period, offset: number) {
  const now = getJakartaNow()
  if (period === 'daily') {
    const date = addDays(now, offset)
    return { from: startOfDay(date), to: endOfDay(date), label: format(date, 'd MMM yy', { locale: id }) }
  }
  if (period === 'weekly') {
    const date = addWeeks(now, offset)
    const from = startOfWeek(date, { weekStartsOn: 1 })
    const to = endOfWeek(date, { weekStartsOn: 1 })
    return { from, to, label: `${format(from, 'd MMM')} – ${format(to, 'd MMM yy', { locale: id })}` }
  }
  const date = addMonths(now, offset)
  return { from: startOfMonth(date), to: endOfMonth(date), label: format(date, 'MMMM yyyy', { locale: id }) }
}

export default function AdminDashboard() {
  const { activeOutletId } = useOutlet()
  const [period, setPeriod] = useState<Period>('daily')
  const [offset, setOffset] = useState(0)
  const range = useMemo(() => getRange(period, offset), [period, offset])
  const fromKey = format(range.from, 'yyyy-MM-dd')
  const toKey = format(range.to, 'yyyy-MM-dd')
  const { data: sales = [], isLoading: loadingSales, dataUpdatedAt } = useDailySales(activeOutletId, { from: range.from, to: range.to })
  const { data: hourly = [], isLoading: loadingHourly } = usePeakHours(activeOutletId, fromKey, toKey)
  const { data: summary, isLoading: loadingOrders } = useActiveOrderSummary(activeOutletId ?? '')
  const { data: lowStock = [], isLoading: loadingStock } = useLowStock(activeOutletId ?? '')
  const { data: topItems = [], isLoading: loadingTop } = useTopMenuItemsRange(activeOutletId, fromKey, toKey)
  const { data: tables = [] } = useTables(activeOutletId ?? '')
  const { data: pendingClaims = [] } = usePaymentClaims(activeOutletId ?? '', ['PENDING', 'WAITING_VERIFICATION'])
  useRealtimeOrders(activeOutletId)

  const metrics = useMemo(() => summarizeDailySales(sales.filter((row) => row.sale_date >= fromKey && row.sale_date <= toKey)), [sales, fromKey, toKey])
  const average = metrics.totalOrders > 0 ? metrics.grossRevenue / metrics.totalOrders : 0
  const chartData = useMemo(() => {
    if (period === 'daily') {
      const totals = new Map<number, number>()
      hourly.forEach((row) => totals.set(Number(row.hour_of_day), (totals.get(Number(row.hour_of_day)) ?? 0) + Number(row.total_revenue)))
      const visibleHours = Array.from({ length: 10 }, (_, index) => index + 10)
      return visibleHours.map((hour) => ({ label: String(hour), value: totals.get(hour) ?? 0 }))
    }
    return eachDayOfInterval({ start: range.from, end: range.to }).map((date) => {
      const key = format(date, 'yyyy-MM-dd')
      return { label: format(date, period === 'monthly' ? 'd' : 'EEE', { locale: id }), value: Number(sales.find((row) => row.sale_date === key)?.gross_revenue ?? 0) }
    })
  }, [hourly, period, range.from, range.to, sales])
  const outOfStock = lowStock.filter((item) => item.status === 'out_of_stock').length
  const lowOnly = Math.max(0, lowStock.length - outOfStock)
  const occupied = tables.filter((table) => table.status === 'occupied').length

  if (!activeOutletId) return <NoOutlet />
  const kpis = [
    { label: 'Penjualan produk (kotor)', value: <CurrencyDisplay value={metrics.grossRevenue} />, note: 'Hanya pembayaran terverifikasi', loading: loadingSales },
    { label: 'Belum dibayar saat ini', value: <CurrencyDisplay value={summary?.totalAmount ?? 0} />, note: `${summary?.totalOrders ?? 0} pesanan menunggu`, loading: loadingOrders },
    { label: 'Transaksi', value: metrics.totalOrders.toLocaleString('id-ID'), note: `Pesanan aktif: ${summary?.totalOrders ?? 0}`, loading: loadingSales || loadingOrders },
    { label: 'Rata-rata per transaksi', value: <CurrencyDisplay value={average} />, note: `Meja terisi: ${occupied}/${tables.length}`, loading: loadingSales },
  ]

  return (
    <div className="space-y-3">
      <header className="flex flex-wrap items-start justify-between gap-4">
        <div><div className="flex items-center gap-2"><h1 className="text-[26px] font-bold leading-8 text-[#1F2328]">Dasbor Penjualan</h1></div><p className="mt-1 text-sm text-[#6B7280]">Terakhir diperbarui {dataUpdatedAt ? format(new Date(dataUpdatedAt), 'd MMM yyyy, HH:mm', { locale: id }) : '—'}</p></div>
        <div className="flex flex-wrap items-center gap-2">
          <div className="flex overflow-hidden rounded-xl border bg-white p-1">
            {(['daily', 'weekly', 'monthly'] as Period[]).map((item) => <button key={item} type="button" onClick={() => { setPeriod(item); setOffset(0) }} className={cn('min-h-10 rounded-lg px-5 text-sm font-semibold', period === item ? 'bg-[#C62828] text-white' : 'text-[#4B5563] hover:bg-gray-50')}>{item === 'daily' ? 'Harian' : item === 'weekly' ? 'Mingguan' : 'Bulanan'}</button>)}
          </div>
          <div className="flex min-h-12 items-center rounded-xl border bg-white px-2 text-sm font-semibold"><button type="button" aria-label="Periode sebelumnya" onClick={() => setOffset((value) => value - 1)} className="px-2"><ChevronLeft className="h-4 w-4" /></button><span className="min-w-24 text-center">{range.label}</span><button type="button" aria-label="Periode berikutnya" disabled={offset === 0} onClick={() => setOffset((value) => Math.min(value + 1, 0))} className="px-2 disabled:opacity-30"><ChevronRight className="h-4 w-4" /></button></div>
        </div>
      </header>

      <section className="grid gap-3 md:grid-cols-2 xl:grid-cols-4" aria-label="Ringkasan penjualan">
        {kpis.map((kpi) => <article key={kpi.label} className="admin-card min-h-[112px] p-4"><p className="text-xs font-medium text-[#6B7280]">{kpi.label}</p>{kpi.loading ? <Skeleton className="mt-2 h-7 w-28" /> : <p className="mt-1 text-[23px] font-bold leading-7 tracking-tight text-[#1F2328]">{kpi.value}</p>}<p className="mt-2 text-xs text-[#6B7280]">{kpi.note}</p></article>)}
      </section>

      <section className="grid gap-3 lg:grid-cols-2">
        <Link to="/admin/orders?filter=verification" className="flex min-h-[60px] items-center gap-3 rounded-2xl border border-amber-200 bg-[#FEF3C7] px-4 py-3 text-[#78350F] hover:border-amber-300"><Clock3 className="h-5 w-5 shrink-0" /><div className="flex-1"><p className="text-sm font-bold">{pendingClaims.length} klaim QRIS perlu verifikasi</p><p className="text-xs">Belum diperiksa petugas</p></div><span className="text-xs font-bold underline">Lihat</span></Link>
        <Link to="/admin/menu" className="flex min-h-[60px] items-center gap-3 rounded-2xl border border-amber-200 bg-[#FEF3C7] px-4 py-3 text-[#78350F] hover:border-amber-300"><AlertTriangle className="h-5 w-5 shrink-0" /><div className="flex-1">{loadingStock ? <Skeleton className="h-4 w-44" /> : <><p className="text-sm font-bold">{lowOnly} produk stok rendah, {outOfStock} habis</p><p className="line-clamp-1 text-xs">{lowStock.length ? lowStock.slice(0, 3).map((item) => item.name).join(', ') : 'Semua stok dalam kondisi aman'}</p></>}</div><span className="text-xs font-bold underline">Atur stok</span></Link>
      </section>

      <section className="grid gap-3 xl:grid-cols-[minmax(0,1.65fr)_minmax(280px,1fr)]">
        <article className="admin-card p-5"><h2 className="text-sm font-bold">Penjualan per {period === 'daily' ? 'jam' : 'hari'}</h2><p className="text-xs text-muted-foreground">Dalam Rupiah</p><div className="mt-4 h-[280px]">{loadingSales || loadingHourly ? <Skeleton className="h-full w-full" /> : <ResponsiveContainer width="100%" height="100%"><BarChart data={chartData} margin={{ top: 8, right: 4, left: -18, bottom: 0 }}><CartesianGrid stroke="#EEF0F2" vertical={false} /><XAxis dataKey="label" axisLine={false} tickLine={false} tick={{ fontSize: 11, fill: '#6B7280' }} /><YAxis axisLine={false} tickLine={false} tick={{ fontSize: 10, fill: '#6B7280' }} tickFormatter={(value) => value === 0 ? '0' : `${Math.round(value / 1000)}rb`} /><Tooltip formatter={(value) => typeof value === 'number' ? formatCurrency(value) : value} cursor={{ fill: '#FDECEC' }} contentStyle={{ borderRadius: 12, borderColor: '#E5E7EB' }} /><Bar dataKey="value" name="Penjualan" fill="#C62828" radius={[5, 5, 0, 0]} maxBarSize={34} /></BarChart></ResponsiveContainer>}</div></article>
        <article className="admin-card overflow-hidden"><div className="border-b px-5 py-4"><h2 className="text-sm font-bold">Produk terlaris</h2></div>{loadingTop ? <div className="space-y-3 p-5"><Skeleton className="h-8 w-full" /><Skeleton className="h-8 w-full" /><Skeleton className="h-8 w-full" /></div> : topItems.length === 0 ? <div className="flex min-h-[280px] items-center justify-center px-5 text-sm text-muted-foreground">Belum ada produk terjual pada periode ini.</div> : <ol className="divide-y px-5">{topItems.slice(0, 4).map((item, index) => <li key={item.menu_item_name} className="grid grid-cols-[24px_1fr_auto] items-center gap-2 py-4 text-sm"><span className="font-bold text-[#C62828]">{index + 1}</span><span className="font-semibold">{item.menu_item_name}</span><span className="text-xs text-muted-foreground">{item.qty_sold} porsi</span></li>)}</ol>}</article>
      </section>
    </div>
  )
}
