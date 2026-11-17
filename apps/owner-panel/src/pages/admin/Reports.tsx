import { useState, useMemo, useEffect } from 'react'
import { useQuery } from '@tanstack/react-query'
import { subDays, startOfDay, endOfDay, format } from 'date-fns'
import { id as localeId } from 'date-fns/locale'
import { FileText, Search } from 'lucide-react'
import { useOutlet } from '@/hooks/useOutlet'
import { exportReportExcel, exportReportPDF } from '@/utils/exportReport'
import { useOrders, useOrdersPaged, fetchAllOrders } from '@/hooks/queries/useOrders'
import { useDailySales } from '@/hooks/queries/useSales'
import { useStaff } from '@/hooks/queries/useStaff'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { DataTable } from '@/components/ui/DataTable'
import { DateRangePicker } from '@/components/ui/DateRangePicker'
import { CurrencyDisplay } from '@/components/ui/CurrencyDisplay'
import { formatCurrency } from '@/lib/currency'
import { totalReceivables } from '@/lib/orderReceivables'
import { useRealtimeOrders } from '@/hooks/useRealtimeOrders'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { Input } from '@/components/ui/input'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { useToast } from '@/hooks/use-toast'
import type { DateRange } from '@/components/ui/DateRangePicker'
import type { OrderType, Order } from '@/types/database'

// ─── Constants ────────────────────────────────────────────────────────────────

const PAYMENT_LABEL: Record<string, string> = {
  cash: 'Tunai', qris: 'QRIS', debit: 'Debit',
  credit: 'Kredit', ewallet: 'E-Wallet', transfer: 'Transfer',
}

const ORDER_TYPE_LABEL: Record<OrderType, string> = {
  dine_in: 'Dine In', takeaway: 'Takeaway', self_order: 'Self Order',
}

const ACCENT = ['#00B69B', '#3B82F6', '#8B5CF6', '#F59E0B', '#EF4444', '#EC4899'] as const

function sortedPayments(order: Order) {
  return [...(order.payments ?? [])].sort((a, b) =>
    new Date(a.paid_at ?? 0).getTime() - new Date(b.paid_at ?? 0).getTime(),
  )
}

function latestPaymentTime(order: Order) {
  const paidAt = sortedPayments(order).at(-1)?.paid_at
  return paidAt ? new Date(paidAt) : null
}

function paymentEntries(order: Order) {
  const grouped = new Map<string, number>()
  for (const payment of sortedPayments(order)) {
    grouped.set(payment.method, (grouped.get(payment.method) ?? 0) + Number(payment.amount ?? 0))
  }
  return [...grouped.entries()].map(([method, amount]) => ({
    method: PAYMENT_LABEL[method] ?? method,
    amount,
  }))
}

function paymentSummary(order: Order) {
  const entries = paymentEntries(order)
  if (!entries.length) return '—'
  return entries
    .map(({ method, amount }) => `${method} ${formatCurrency(amount)}`)
    .join(' + ')
}

function PaymentBreakdown({ order }: { order: Order }) {
  const entries = paymentEntries(order)
  if (!entries.length) return <span>—</span>

  return (
    <>
      <span className="hidden whitespace-nowrap md:inline">{paymentSummary(order)}</span>
      <span className="flex min-w-0 max-w-full flex-col items-end gap-1 md:hidden">
        {entries.map(({ method, amount }) => (
          <span
            key={`${method}-${amount}`}
            className="flex min-w-0 max-w-full flex-wrap items-baseline justify-end gap-x-1.5 rounded-md bg-gray-50 px-2 py-1 text-xs leading-snug"
          >
            <span className="min-w-0 break-words text-gray-500">{method}</span>
            <span className="whitespace-nowrap font-semibold text-gray-900">{formatCurrency(amount)}</span>
          </span>
        ))}
      </span>
    </>
  )
}

// ─── UI Components ────────────────────────────────────────────────────────────

function StatCard({ label, value, accent, loading, hint }: {
  label: string; value: React.ReactNode; accent: string; loading?: boolean; hint?: string
}) {
  return (
    <div className="bg-white rounded-xl border border-gray-100 shadow-sm overflow-hidden flex flex-col h-full">
      <div className="px-5 py-4 flex-1">
        <p className="text-xs text-muted-foreground mb-1 truncate">{label}</p>
        {loading ? <Skeleton className="h-6 w-32 mt-1" /> : <p className="text-xl font-bold text-gray-900 truncate">{value}</p>}
        {hint && !loading && <p className="text-[11px] text-muted-foreground mt-1 leading-tight">{hint}</p>}
      </div>
      <div className="h-1 w-full" style={{ backgroundColor: accent }} />
    </div>
  )
}

function ExportBar({ onExcel, onPDF, disabled }: { onExcel?: () => unknown; onPDF?: () => unknown; disabled?: boolean }) {
  return (
    <div className="inline-flex items-center gap-0.5 rounded-lg border bg-white px-1.5 py-1 shadow-sm">
      <span className="text-[11px] font-medium text-muted-foreground px-1.5">Ekspor</span>
      <div className="w-px h-4 bg-border mx-0.5" />
      {onExcel && (
        <Button variant="ghost" size="sm" className="h-7 px-2.5 text-xs gap-1.5 rounded-md" onClick={onExcel} disabled={disabled}>
          <FileText className="h-3.5 w-3.5" /> Excel
        </Button>
      )}
      {onPDF && (
        <Button variant="ghost" size="sm" className="h-7 px-2.5 text-xs gap-1.5 rounded-md" onClick={onPDF} disabled={disabled}>
          <FileText className="h-3.5 w-3.5" /> PDF
        </Button>
      )}
    </div>
  )
}

function SectionTitle({ children }: { children: React.ReactNode }) {
  return (
    <h2 className="text-sm font-semibold text-gray-700 mb-3 flex items-center gap-2">
      <span className="h-3.5 w-1 rounded-full bg-primary inline-block" />
      {children}
    </h2>
  )
}

function fmtRange(from: Date, to: Date) {
  const f = format(from, 'd MMM yyyy', { locale: localeId })
  const t = format(to,   'd MMM yyyy', { locale: localeId })
  return f === t ? f : `${f} – ${t}`
}

// ─── Main Page ────────────────────────────────────────────────────────────────

export default function Reports() {
  const { activeOutletId, activeOutlet } = useOutlet()
  useRealtimeOrders(activeOutletId)
  const { toast } = useToast()
  const today = useMemo(() => new Date(), [])

  const [range, setRange] = useState<DateRange>({
    from: startOfDay(subDays(today, 29)),
    to: endOfDay(today),
  })
  const [search, setSearch] = useState('')
  const [kasirId, setKasirId] = useState<string | null>(null)
  const [isExporting, setIsExporting] = useState(false)

  const [page, setPage] = useState(1)
  const PAGE_SIZE = 20

  const dateFromIso = range.from.toISOString()
  const dateToIso   = range.to.toISOString()

  // Agregat + breakdown per-hari dari view (server-aggregated, akurat tanpa cap baris)
  const { data: dailySales = [], isLoading: isDailyLoading } = useDailySales(activeOutletId, range)
  const { data: staff = [] } = useStaff(activeOutletId)
  const staffMap = useMemo(() => new Map(staff.map((s) => [s.id, s.full_name])), [staff])
  // Hanya role yg bisa mengoperasikan kasir/POS yg relevan sbg filter penjualan.
  const kasirStaff = useMemo(
    () => staff.filter((s) => s.role === 'kasir' || s.role === 'manajer' || s.role === 'admin' || s.role === 'owner'),
    [staff],
  )

  const kasirSelected = !!kasirId

  // Piutang: order belum final dalam range (volume kecil, tidak kena cap praktis)
  const { data: unpaidOrders = [] } = useOrders(activeOutletId ?? '', {
    dateFrom: dateFromIso,
    dateTo: dateToIso,
    status: ['draft', 'confirmed', 'preparing', 'ready', 'served'],
    createdBy: kasirId ?? undefined,
  })

  // Order kasir terpilih (paid) — utk ringkasan & breakdown per-kasir.
  // Hanya di-fetch saat ada kasir dipilih (outletId '' => query disabled).
  const { data: kasirOrders = [], isLoading: isKasirLoading } = useQuery({
    queryKey: ['report-paid-orders-by-cashier', activeOutletId, dateFromIso, dateToIso, kasirId],
    enabled: !!activeOutletId && kasirSelected,
    queryFn: () => fetchAllOrders(activeOutletId!, {
      dateFrom: dateFromIso,
      dateTo: dateToIso,
      status: 'paid',
      createdBy: kasirId ?? undefined,
    }),
  })

  const isLoading = isDailyLoading || (kasirSelected && isKasirLoading)

  // Tabel transaksi: paginasi server-side (mengatasi cap diam 1000 baris)
  const { data: ordersPage, isLoading: loadingTable } = useOrdersPaged(activeOutletId ?? '', {
    dateFrom: dateFromIso,
    dateTo: dateToIso,
    status: 'paid',
    search,
    createdBy: kasirId ?? undefined,
    page,
    pageSize: PAGE_SIZE,
  })
  const tableRows  = ordersPage?.rows ?? []
  const totalCount = ordersPage?.totalCount ?? 0

  // Reset ke halaman 1 saat filter berubah
  // eslint-disable-next-line react-hooks/set-state-in-effect
  useEffect(() => { setPage(1) }, [dateFromIso, dateToIso, search, kasirId])

  // Agregat order kasir terpilih (dari tabel orders, karena view tdk punya dimensi kasir)
  const kasirAgg = useMemo(() => kasirOrders.reduce((a, o) => ({
    gross: a.gross + o.subtotal,
    trx: a.trx + 1,
    diskon: a.diskon + o.discount_amount,
    pajak: a.pajak + o.tax_amount,
    service: a.service + o.service_charge,
    net: a.net + o.total_amount,
  }), { gross: 0, trx: 0, diskon: 0, pajak: 0, service: 0, net: 0 }), [kasirOrders])

  // ── Aggregate stats: per-kasir dari orders, atau se-outlet dari view ───────────
  const totalPenjualan  = useMemo(() => kasirSelected ? kasirAgg.gross : dailySales.reduce((s, d) => s + d.gross_revenue, 0), [kasirSelected, kasirAgg, dailySales])
  const totalTransaksi  = useMemo(() => kasirSelected ? kasirAgg.trx   : dailySales.reduce((s, d) => s + d.total_orders, 0), [kasirSelected, kasirAgg, dailySales])
  const totalDiskon     = useMemo(() => kasirSelected ? kasirAgg.diskon : dailySales.reduce((s, d) => s + d.total_discount, 0), [kasirSelected, kasirAgg, dailySales])
  const totalPajak      = useMemo(() => kasirSelected ? kasirAgg.pajak : dailySales.reduce((s, d) => s + d.total_tax, 0), [kasirSelected, kasirAgg, dailySales])
  const totalService    = useMemo(() => kasirSelected ? kasirAgg.service : dailySales.reduce((s, d) => s + d.total_service_charge, 0), [kasirSelected, kasirAgg, dailySales])
  const penjualanBersih = useMemo(() => kasirSelected ? kasirAgg.net   : dailySales.reduce((s, d) => s + d.net_revenue, 0), [kasirSelected, kasirAgg, dailySales])
  const totalPiutang    = useMemo(() => totalReceivables(unpaidOrders), [unpaidOrders])

  // ── Per-day breakdown untuk tabel pajak & service ──────────────────────────────
  const dailyBreakdown = useMemo(() => {
    if (kasirSelected) {
      const map = new Map<string, { transaksi: number; pajak: number; service: number; diskon: number }>()
      kasirOrders.forEach((o) => {
        const date = format(new Date(o.created_at), 'yyyy-MM-dd')
        const cur = map.get(date) ?? { transaksi: 0, pajak: 0, service: 0, diskon: 0 }
        cur.transaksi += 1
        cur.pajak     += o.tax_amount
        cur.service   += o.service_charge
        cur.diskon    += o.discount_amount
        map.set(date, cur)
      })
      return Array.from(map.entries())
        .map(([date, v]) => ({ date, ...v }))
        .sort((a, b) => b.date.localeCompare(a.date))
    }
    return dailySales
      .map((d) => ({
        date: d.sale_date,
        transaksi: d.total_orders,
        pajak: d.total_tax,
        service: d.total_service_charge,
        diskon: d.total_discount,
      }))
      .sort((a, b) => b.date.localeCompare(a.date))
  }, [kasirSelected, kasirOrders, dailySales])

  if (!activeOutletId) return <NoOutlet />

  const outletName = activeOutlet?.name ?? 'Semua Outlet'
  const period     = fmtRange(range.from, range.to)

  function noDataToast() {
    toast({ title: 'Tidak ada data', description: 'Tidak ada data untuk diekspor pada periode ini.', variant: 'destructive' })
  }

  const TABLE_HEADERS = [
    'No Transaksi',
    'Waktu Order',
    'Waktu Bayar',
    'Jenis Order',
    'Subtotal (Rp)',
    'Diskon (Rp)',
    'Pajak (Rp)',
    'Service (Rp)',
    'Total (Rp)',
    'Pembayaran',
    'Kasir Order',
  ]

  const buildRows = (rows: Order[]) => rows.map((o) => [
    o.order_number,
    format(new Date(o.created_at), 'd MMM yyyy HH:mm', { locale: localeId }),
    latestPaymentTime(o) ? format(latestPaymentTime(o)!, 'd MMM yyyy HH:mm', { locale: localeId }) : '—',
    ORDER_TYPE_LABEL[o.order_type],
    formatCurrency(o.subtotal),
    formatCurrency(o.discount_amount),
    formatCurrency(o.tax_amount),
    formatCurrency(o.service_charge),
    formatCurrency(o.total_amount),
    paymentSummary(o),
    staffMap.get(o.created_by ?? '') ?? '—',
  ] as (string | number)[])

  // Ekspor mengambil SELURUH data sesuai filter (bukan hanya halaman aktif)
  async function fetchExportRows(): Promise<Order[]> {
    return fetchAllOrders(activeOutletId!, {
      dateFrom: dateFromIso,
      dateTo: dateToIso,
      status: 'paid',
      search,
      createdBy: kasirId ?? undefined,
    })
  }

  const summaryStats = [
    { label: 'Total Penjualan',   value: formatCurrency(totalPenjualan)  },
    { label: 'Total Transaksi',   value: totalTransaksi.toLocaleString('id-ID') },
    { label: 'Biaya Promosi',     value: formatCurrency(totalDiskon)     },
    { label: 'Total Pajak',       value: formatCurrency(totalPajak)      },
    { label: 'Service Charge',    value: formatCurrency(totalService)    },
    { label: 'Total Penerimaan',  value: formatCurrency(penjualanBersih) },
    { label: 'Total Piutang',     value: formatCurrency(totalPiutang)    },
  ]

  const handleExcel = async () => {
    setIsExporting(true)
    try {
      const all = await fetchExportRows()
      if (!all.length) { noDataToast(); return }
      exportReportExcel({ title: 'Detail Penjualan', outletName, period, summaryStats, tableHeaders: TABLE_HEADERS, tableRows: buildRows(all), filename: `transaksi-${format(range.from, 'yyyyMMdd')}.xls` })
    } catch (error) {
      toast({ title: 'Ekspor gagal', description: error instanceof Error ? error.message : 'Data transaksi tidak dapat dimuat.', variant: 'destructive' })
    } finally { setIsExporting(false) }
  }
  const handlePDF = async () => {
    setIsExporting(true)
    try {
      const all = await fetchExportRows()
      if (!all.length) { noDataToast(); return }
      await exportReportPDF({ title: 'Detail Penjualan', outletName, period, summaryStats, tableHeaders: TABLE_HEADERS, tableRows: buildRows(all), filename: `transaksi-${format(range.from, 'yyyyMMdd')}.pdf` })
    } catch (error) {
      toast({ title: 'Ekspor gagal', description: error instanceof Error ? error.message : 'Data transaksi tidak dapat dimuat.', variant: 'destructive' })
    } finally { setIsExporting(false) }
  }

  return (
    <div className="min-h-screen bg-gray-50/50">
      {/* ── Page Header ─────────────────────────────────────────────── */}
      <div className="mb-5 border-b border-gray-100 bg-white px-3 py-4 sm:px-6">
        <div className="flex flex-wrap items-start justify-between gap-y-3">
          <div>
            <h1 className="text-xl font-bold text-gray-900">Detail Penjualan</h1>
            <p className="text-sm text-muted-foreground mt-0.5">{fmtRange(range.from, range.to)} · berdasarkan waktu order</p>
          </div>
          <ExportBar onExcel={handleExcel} onPDF={handlePDF} disabled={isExporting} />
        </div>

        {/* Filter bar */}
        <div className="flex flex-wrap items-center gap-3 mt-4">
          <div className="relative w-full sm:w-64">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground pointer-events-none" />
            <Input
              className="pl-9 h-9 w-full bg-white"
              placeholder="Cari no transaksi atau nama..."
              value={search}
              onChange={(e) => setSearch(e.target.value)}
            />
          </div>
          <DateRangePicker value={range} onChange={setRange} />
          <Select value={kasirId ?? 'all'} onValueChange={(v) => setKasirId(v === 'all' ? null : v)}>
            <SelectTrigger className="h-9 w-48 bg-white"><SelectValue placeholder="Semua Kasir" /></SelectTrigger>
            <SelectContent>
              <SelectItem value="all">Semua Kasir</SelectItem>
              {kasirStaff.map((s) => <SelectItem key={s.id} value={s.id}>{s.full_name}</SelectItem>)}
            </SelectContent>
          </Select>
        </div>
      </div>

      {/* ── Content ─────────────────────────────────────────────────── */}
      <div className="space-y-8 px-3 pb-8 sm:px-6">

        {/* ── Section 1: Ringkasan Stat Cards ─────────────────────── */}
        <div>
          <SectionTitle>Ringkasan</SectionTitle>
          <div className="grid grid-cols-2 sm:grid-cols-3 xl:grid-cols-4 gap-3">
            <StatCard label="Total Penjualan"  value={<CurrencyDisplay value={totalPenjualan} />}  accent={ACCENT[0]} loading={isLoading} hint="Subtotal produk, sebelum pajak & service charge" />
            <StatCard label="Total Transaksi"  value={totalTransaksi.toLocaleString('id-ID')}       accent={ACCENT[1]} loading={isLoading} />
            <StatCard label="Total Penerimaan" value={<CurrencyDisplay value={penjualanBersih} />}  accent={ACCENT[2]} loading={isLoading} hint="Total dibayar pelanggan, termasuk pajak & service charge" />
            <StatCard label="Total Piutang"    value={<CurrencyDisplay value={totalPiutang} />}     accent={ACCENT[4]} loading={isLoading} hint="Order belum lunas dalam periode" />
          </div>
        </div>

        {/* ── Section 2: Biaya Promosi ─────────────────────────────── */}
        <div>
          <SectionTitle>Biaya Promosi</SectionTitle>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <StatCard
              label="Total Diskon / Promosi"
              value={<CurrencyDisplay value={totalDiskon} />}
              accent={ACCENT[5]}
              loading={isLoading}
            />
            <div className="bg-white rounded-xl border border-gray-100 shadow-sm p-5 flex items-center justify-between">
              <div>
                <p className="text-xs text-muted-foreground mb-1">Rata-rata Diskon per Transaksi</p>
                {isLoading
                  ? <Skeleton className="h-6 w-24 mt-1" />
                  : <p className="text-xl font-bold text-gray-900">
                      <CurrencyDisplay value={totalTransaksi > 0 ? totalDiskon / totalTransaksi : 0} />
                    </p>
                }
              </div>
              {!isLoading && totalPenjualan > 0 && (
                <div className="text-right">
                  <p className="text-xs text-muted-foreground">% dari penjualan</p>
                  <p className="text-lg font-bold text-pink-500">
                    {((totalDiskon / totalPenjualan) * 100).toFixed(1)}%
                  </p>
                </div>
              )}
            </div>
          </div>
        </div>

        {/* ── Section 3: Pajak & Service Charge ────────────────────── */}
        <div>
          <SectionTitle>Pajak &amp; Service Charge</SectionTitle>
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">

            {/* Pajak */}
            <div className="space-y-3">
              <div className="flex items-center justify-between">
                <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wider">Pajak</p>
                <span className="text-sm font-bold text-gray-900">
                  {isLoading ? <Skeleton className="h-4 w-20 inline-block" /> : <CurrencyDisplay value={totalPajak} />}
                </span>
              </div>
              <div className="bg-white rounded-xl border border-gray-100 shadow-sm overflow-hidden">
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-b bg-gray-50">
                        <th className="text-left px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Tanggal</th>
                        <th className="text-right px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Transaksi</th>
                        <th className="text-right px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Pajak (Rp)</th>
                      </tr>
                    </thead>
                    <tbody>
                      {isLoading ? (
                        Array.from({ length: 4 }).map((_, i) => (
                          <tr key={i} className="border-b">
                            <td className="px-4 py-2.5"><Skeleton className="h-4 w-24" /></td>
                            <td className="px-4 py-2.5 text-right"><Skeleton className="h-4 w-8 ml-auto" /></td>
                            <td className="px-4 py-2.5 text-right"><Skeleton className="h-4 w-20 ml-auto" /></td>
                          </tr>
                        ))
                      ) : dailyBreakdown.length === 0 ? (
                        <tr>
                          <td colSpan={3} className="px-4 py-8 text-center text-muted-foreground text-xs">
                            Tidak ada data pajak untuk periode ini
                          </td>
                        </tr>
                      ) : (
                        dailyBreakdown.map((row) => (
                          <tr key={row.date} className="border-b last:border-0 hover:bg-gray-50/60">
                            <td className="px-4 py-2.5 text-gray-700 whitespace-nowrap">
                              {format(new Date(row.date), 'd MMM yyyy', { locale: localeId })}
                            </td>
                            <td className="px-4 py-2.5 text-right text-gray-600">{row.transaksi}</td>
                            <td className="px-4 py-2.5 text-right font-medium text-gray-900">
                              <CurrencyDisplay value={row.pajak} />
                            </td>
                          </tr>
                        ))
                      )}
                    </tbody>
                    {dailyBreakdown.length > 0 && (
                      <tfoot>
                        <tr className="border-t-2 bg-gray-50">
                          <td className="px-4 py-2.5 font-bold text-gray-900">Total</td>
                          <td className="px-4 py-2.5 text-right font-bold text-gray-900">
                            {dailyBreakdown.reduce((s, r) => s + r.transaksi, 0)}
                          </td>
                          <td className="px-4 py-2.5 text-right font-bold text-gray-900">
                            <CurrencyDisplay value={totalPajak} />
                          </td>
                        </tr>
                      </tfoot>
                    )}
                  </table>
                </div>
              </div>
            </div>

            {/* Service Charge */}
            <div className="space-y-3">
              <div className="flex items-center justify-between">
                <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wider">Service Charge</p>
                <span className="text-sm font-bold text-gray-900">
                  {isLoading ? <Skeleton className="h-4 w-20 inline-block" /> : <CurrencyDisplay value={totalService} />}
                </span>
              </div>
              <div className="bg-white rounded-xl border border-gray-100 shadow-sm overflow-hidden">
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-b bg-gray-50">
                        <th className="text-left px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Tanggal</th>
                        <th className="text-right px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Transaksi</th>
                        <th className="text-right px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Service (Rp)</th>
                      </tr>
                    </thead>
                    <tbody>
                      {isLoading ? (
                        Array.from({ length: 4 }).map((_, i) => (
                          <tr key={i} className="border-b">
                            <td className="px-4 py-2.5"><Skeleton className="h-4 w-24" /></td>
                            <td className="px-4 py-2.5 text-right"><Skeleton className="h-4 w-8 ml-auto" /></td>
                            <td className="px-4 py-2.5 text-right"><Skeleton className="h-4 w-20 ml-auto" /></td>
                          </tr>
                        ))
                      ) : dailyBreakdown.length === 0 ? (
                        <tr>
                          <td colSpan={3} className="px-4 py-8 text-center text-muted-foreground text-xs">
                            Tidak ada data service charge untuk periode ini
                          </td>
                        </tr>
                      ) : (
                        dailyBreakdown.map((row) => (
                          <tr key={row.date} className="border-b last:border-0 hover:bg-gray-50/60">
                            <td className="px-4 py-2.5 text-gray-700 whitespace-nowrap">
                              {format(new Date(row.date), 'd MMM yyyy', { locale: localeId })}
                            </td>
                            <td className="px-4 py-2.5 text-right text-gray-600">{row.transaksi}</td>
                            <td className="px-4 py-2.5 text-right font-medium text-gray-900">
                              <CurrencyDisplay value={row.service} />
                            </td>
                          </tr>
                        ))
                      )}
                    </tbody>
                    {dailyBreakdown.length > 0 && (
                      <tfoot>
                        <tr className="border-t-2 bg-gray-50">
                          <td className="px-4 py-2.5 font-bold text-gray-900">Total</td>
                          <td className="px-4 py-2.5 text-right font-bold text-gray-900">
                            {dailyBreakdown.reduce((s, r) => s + r.transaksi, 0)}
                          </td>
                          <td className="px-4 py-2.5 text-right font-bold text-gray-900">
                            <CurrencyDisplay value={totalService} />
                          </td>
                        </tr>
                      </tfoot>
                    )}
                  </table>
                </div>
              </div>
            </div>
          </div>
        </div>

        {/* ── Section 4: Tabel Transaksi ───────────────────────────── */}
        <div>
          <SectionTitle>Daftar Transaksi</SectionTitle>
          <DataTable
            data={tableRows}
            loading={loadingTable}
            getRowKey={(r) => r.id}
            emptyMessage="Tidak ada transaksi untuk periode ini."
            page={page}
            pageSize={PAGE_SIZE}
            totalCount={totalCount}
            onPageChange={setPage}
            columns={[
              {
                key: 'number',
                header: 'No Transaksi',
                cell: (r) => <span className="font-mono text-xs font-semibold">{r.order_number}</span>,
              },
              {
                key: 'order_time',
                header: 'Waktu Order',
                cell: (r) => format(new Date(r.created_at), 'd MMM yyyy, HH:mm', { locale: localeId }),
              },
              {
                key: 'pay_time',
                header: 'Waktu Bayar',
                cell: (r) => {
                  const paidAt = latestPaymentTime(r)
                  return paidAt ? format(paidAt, 'd MMM yyyy, HH:mm', { locale: localeId }) : '—'
                },
              },
              {
                key: 'type',
                header: 'Jenis Order',
                cell: (r) => ORDER_TYPE_LABEL[r.order_type],
              },
              {
                key: 'subtotal',
                header: 'Subtotal',
                cell: (r) => <CurrencyDisplay value={r.subtotal} />,
              },
              {
                key: 'diskon',
                header: 'Diskon',
                cell: (r) => r.discount_amount > 0
                  ? <span className="text-red-500">-<CurrencyDisplay value={r.discount_amount} /></span>
                  : <span className="text-muted-foreground">—</span>,
              },
              {
                key: 'pajak',
                header: 'Pajak',
                cell: (r) => r.tax_amount > 0
                  ? <CurrencyDisplay value={r.tax_amount} />
                  : <span className="text-muted-foreground">—</span>,
              },
              {
                key: 'service',
                header: 'Service',
                cell: (r) => r.service_charge > 0
                  ? <CurrencyDisplay value={r.service_charge} />
                  : <span className="text-muted-foreground">—</span>,
              },
              {
                key: 'total',
                header: 'Total',
                cell: (r) => <CurrencyDisplay value={r.total_amount} className="font-semibold" />,
              },
              {
                key: 'method',
                header: 'Pembayaran',
                className: 'min-w-[14rem]',
                cell: (r) => <PaymentBreakdown order={r} />,
              },
              {
                key: 'bayar',
                header: 'Kasir',
                cell: (r) => staffMap.get(r.created_by ?? '') ?? '—',
              },
            ]}
          />
        </div>
      </div>
    </div>
  )
}
