import { useState, useMemo } from 'react'
import { useQuery } from '@tanstack/react-query'
import { subDays, startOfDay, endOfDay, format } from 'date-fns'
import { id as localeId } from 'date-fns/locale'
import { AlertTriangle, FileText, HelpCircle } from 'lucide-react'
import { useOutlet } from '@/hooks/useOutlet'
import { fetchAllOrders } from '@/hooks/queries/useOrders'
import { supabase } from '@/lib/supabase'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { DateRangePicker } from '@/components/ui/DateRangePicker'
import { CurrencyDisplay } from '@/components/ui/CurrencyDisplay'
import { formatCurrency } from '@/lib/currency'
import { Button } from '@/components/ui/button'
import { Popover, PopoverTrigger, PopoverContent } from '@/components/ui/popover'
import { Skeleton } from '@/components/ui/skeleton'
import { useToast } from '@/hooks/use-toast'
import { exportReportExcel, exportReportPDF } from '@/utils/exportReport'
import type { DateRange } from '@/components/ui/DateRangePicker'

// ─── Helpers ──────────────────────────────────────────────────────────────────

const ACCENT = {
  green:  '#10B981',
  yellow: '#F59E0B',
  blue:   '#3B82F6',
  sky:    '#0EA5E9',
  purple: '#8B5CF6',
  red:    '#EF4444',
} as const

function HintIcon({ text, size = 'sm' }: { text: string; size?: 'sm' | 'md' }) {
  const cls = size === 'md' ? 'h-4 w-4' : 'h-3 w-3'
  return (
    <Popover>
      <PopoverTrigger asChild>
        <Button
          type="button"
          variant="ghost"
          size="icon-xs"
          aria-label="Lihat penjelasan"
          className="rounded-full text-muted-foreground hover:text-gray-700"
          onClick={(e) => e.stopPropagation()}
        >
          <HelpCircle className={cls} />
        </Button>
      </PopoverTrigger>
      <PopoverContent side="top" className="w-64 text-xs leading-relaxed text-gray-700">
        {text}
      </PopoverContent>
    </Popover>
  )
}

function fmtRange(from: Date, to: Date) {
  const f = format(from, 'd MMM yyyy', { locale: localeId })
  const t = format(to,   'd MMM yyyy', { locale: localeId })
  return f === t ? f : `${f} - ${t}`
}

function StatCard({ label, value, accent, hint, loading }: {
  label: string
  value: React.ReactNode
  accent: string
  hint?: string
  loading?: boolean
}) {
  return (
    <div className="bg-white rounded-xl border border-gray-100 shadow-sm overflow-hidden">
      <div className="px-5 py-4">
        <div className="flex items-center gap-1.5 mb-1">
          <p className="text-xs text-muted-foreground truncate">{label}</p>
          {hint && <HintIcon text={hint} />}
        </div>
        {loading
          ? <Skeleton className="h-6 w-32 mt-1" />
          : <p className="text-xl font-bold text-gray-900 truncate">{value}</p>}
      </div>
      <div className="h-1 w-full" style={{ backgroundColor: accent }} />
    </div>
  )
}

type Row = { label: string; value: number; negative?: boolean; bold?: boolean; hint?: string }

function SummaryTable({ title, accent, rows, loading }: {
  title: string
  accent: string
  rows: Row[]
  loading?: boolean
}) {
  return (
    <div className="bg-white rounded-xl border border-gray-100 shadow-sm overflow-hidden">
      <div className="px-5 py-3 text-xs font-semibold uppercase tracking-wider"
           style={{ backgroundColor: accent, color: '#374151' }}>
        {title}
      </div>
      <table className="w-full text-sm">
        <tbody>
          {rows.map((r, i) => (
            <tr key={i} className="border-b last:border-0 hover:bg-gray-50/60">
              <td className={`px-5 py-3 ${r.bold ? 'font-bold text-gray-900' : 'text-gray-700'}`}>
                <span className="inline-flex items-center gap-1.5">
                  {r.label}
                  {r.hint && <HintIcon text={r.hint} />}
                </span>
              </td>
              <td className={`px-5 py-3 text-right whitespace-nowrap ${r.bold ? 'font-bold text-gray-900' : 'text-gray-700'}`}>
                {loading
                  ? <Skeleton className="h-4 w-24 ml-auto" />
                  : r.negative
                    ? <span>( <CurrencyDisplay value={r.value} /> )</span>
                    : <CurrencyDisplay value={r.value} />
                }
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

// ─── Main Page ────────────────────────────────────────────────────────────────

export default function SalesSummary() {
  const { activeOutletId, activeOutlet } = useOutlet()
  const { toast } = useToast()
  const today = useMemo(() => new Date(), [])

  const [range, setRange] = useState<DateRange>({
    from: startOfDay(subDays(today, 6)),
    to:   endOfDay(today),
  })
  const [isExporting, setIsExporting] = useState(false)

  const dateFromIso = range.from.toISOString()
  const dateToIso = range.to.toISOString()

  // list_orders_unified menggabungkan order aktif dan arsip serta dipaginasi
  // sampai habis. Query langsung ke tabel orders sebelumnya bisa memotong data.
  const {
    data: paidOrders = [],
    isLoading,
    isError: isOrdersError,
    error: ordersError,
  } = useQuery({
    queryKey: ['sales-summary-paid-orders', activeOutletId, dateFromIso, dateToIso],
    enabled: !!activeOutletId,
    queryFn: () => fetchAllOrders(activeOutletId!, {
      dateFrom: dateFromIso,
      dateTo: dateToIso,
      status: 'paid',
    }),
  })

  // ── HPP per order (via v_order_hpp view) ──────────────────────────────────
  const paidOrderIds = useMemo(() => paidOrders.map((o) => o.id), [paidOrders])

  const {
    data: hppRows = [],
    isLoading: isHppLoading,
    isError: isHppError,
    error: hppError,
  } = useQuery({
    queryKey: ['order-hpp-unified', activeOutletId, dateFromIso, dateToIso],
    enabled: !!activeOutletId && paidOrderIds.length > 0,
    queryFn: async () => {
      const rows: { order_id: string; hpp_total: number }[] = []
      const batchSize = 1000
      for (let offset = 0; ; offset += batchSize) {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const { data, error } = await (supabase.from('v_order_hpp_unified') as any)
          .select('order_id, hpp_total')
          .eq('outlet_id', activeOutletId)
          .eq('status', 'paid')
          .gte('created_at', dateFromIso)
          .lte('created_at', dateToIso)
          .range(offset, offset + batchSize - 1)
        if (error) throw error
        const batch = (data ?? []) as { order_id: string; hpp_total: number }[]
        rows.push(...batch)
        if (batch.length < batchSize) break
      }
      return rows
    },
  })

  // Refund dihitung berdasarkan tanggal refund dan memakai view aktif + arsip.
  const {
    data: refundRows = [],
    isLoading: isRefundLoading,
    isError: isRefundError,
    error: refundError,
  } = useQuery({
    queryKey: ['refund-summary-unified', activeOutletId, dateFromIso, dateToIso],
    enabled: !!activeOutletId,
    queryFn: async () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase.from('v_partial_refund_summary') as any)
        .select('refund_date, total_amount')
        .eq('outlet_id', activeOutletId)
        .gte('refund_date', format(range.from, 'yyyy-MM-dd'))
        .lte('refund_date', format(range.to, 'yyyy-MM-dd'))
      if (error) throw error
      return data as { refund_date: string; total_amount: number }[]
    },
  })

  // ── Expenses pada rentang waktu ───────────────────────────────────────────
  const dateFrom = format(range.from, 'yyyy-MM-dd')
  const dateTo   = format(range.to,   'yyyy-MM-dd')

  const {
    data: expenses = [],
    isLoading: isExpenseLoading,
    isError: isExpenseError,
    error: expenseError,
  } = useQuery({
    queryKey: ['expenses-range', activeOutletId, dateFrom, dateTo],
    enabled: !!activeOutletId,
    queryFn: async () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase.from('expenses') as any)
        .select('amount, expense_date, category')
        .eq('outlet_id', activeOutletId)
        // Pengeluaran bahan baku sudah tercermin pada HPP snapshot. Memasukkannya
        // lagi sebagai biaya operasional akan menghitung biaya dua kali.
        .neq('category', 'bahan_baku')
        .gte('expense_date', dateFrom)
        .lte('expense_date', dateTo)
      if (error) throw error
      return data as { amount: number; expense_date: string; category: string }[]
    },
  })

  // ── Aggregations (Rupiah) ──────────────────────────────────────────────────
  // Nilai NUMERIC Postgres dapat diterima sebagai string oleh klien. Seluruh
  // agregasi dinormalisasi agar tidak terjadi concatenation string/NaN.
  const penjualanKotor    = useMemo(() => paidOrders.reduce((s, o) => s + (Number(o.subtotal) || 0), 0),         [paidOrders])
  const biayaPelayanan    = useMemo(() => paidOrders.reduce((s, o) => s + (Number(o.service_charge) || 0), 0),   [paidOrders])
  const totalPajak        = useMemo(() => paidOrders.reduce((s, o) => s + (Number(o.tax_amount) || 0), 0),       [paidOrders])
  const totalDiskon       = useMemo(() => paidOrders.reduce((s, o) => s + (Number(o.discount_amount) || 0), 0),  [paidOrders])
  const totalRedeem       = useMemo(() => paidOrders.reduce((s, o) => s + (Number(o.loyalty_discount) || 0), 0), [paidOrders])
  const totalTagihan      = useMemo(() => paidOrders.reduce((s, o) => s + (Number(o.total_amount) || 0), 0),     [paidOrders])
  const totalRefund = useMemo(
    () => refundRows.reduce((s, r) => s + (Number(r.total_amount) || 0), 0), [refundRows])
  const totalHpp          = useMemo(() => hppRows.reduce((s, r) => s + (Number(r.hpp_total) || 0), 0),   [hppRows])
  const totalExpenses     = useMemo(() => expenses.reduce((s, e) => s + (Number(e.amount) || 0), 0),     [expenses])

  // ── Derived totals ─────────────────────────────────────────────────────────
  // Total penerimaan adalah uang yang benar-benar dibayar pelanggan. Pendapatan
  // bersih untuk perhitungan laba tidak memasukkan pajak dan service charge.
  // Mengurangkannya dari total_amount konsisten untuk pajak inclusive/exclusive.
  const totalPenerimaan       = totalTagihan - totalRefund
  const totalPendapatanBersih = totalPenerimaan - totalPajak - biayaPelayanan
  const totalLabaKotor        = totalPendapatanBersih - totalHpp
  const totalLabaBersih      = totalLabaKotor - totalExpenses

  const loading = isLoading || isHppLoading || isExpenseLoading || isRefundLoading
  const queryError = ordersError ?? hppError ?? refundError ?? expenseError
  const hasQueryError = isOrdersError || isHppError || isRefundError || isExpenseError

  if (!activeOutletId) return <NoOutlet />

  const outletName = activeOutlet?.name ?? 'Semua Outlet'
  const period     = fmtRange(range.from, range.to)

  // ── Export ─────────────────────────────────────────────────────────────────
  const noDataToast = () =>
    toast({ title: 'Tidak ada data', description: 'Tidak ada transaksi paid untuk diekspor.', variant: 'destructive' })

  const buildExportConfig = (ext: 'xls' | 'pdf') => {
    const rows: (string | number)[][] = [
      ['PENERIMAAN PELANGGAN', ''],
      ['Subtotal Produk', formatCurrency(penjualanKotor)],
      ['Diskon Promo / Voucher', `( ${formatCurrency(totalDiskon)} )`],
      ['Tukar Poin Loyalty', `( ${formatCurrency(totalRedeem)} )`],
      ['Pajak Pelanggan', formatCurrency(totalPajak)],
      ['Service Charge', formatCurrency(biayaPelayanan)],
      ['Total Tagihan Sebelum Refund', formatCurrency(totalTagihan)],
      ['Refund Tercatat', `( ${formatCurrency(totalRefund)} )`],
      ['Total Penerimaan Pelanggan', formatCurrency(totalPenerimaan)],
      ['', ''],
      ['BIAYA PROMOSI & LOYALTY', ''],
      ['Diskon Promo / Voucher', `( ${formatCurrency(totalDiskon)} )`],
      ['Tukar Poin Loyalty',     `( ${formatCurrency(totalRedeem)} )`],
      ['Total Potongan',         `( ${formatCurrency(totalDiskon + totalRedeem)} )`],
      ['', ''],
      ['PENDAPATAN BERSIH', ''],
      ['Total Penerimaan Pelanggan', formatCurrency(totalPenerimaan)],
      ['Pajak (tidak masuk laba)', `( ${formatCurrency(totalPajak)} )`],
      ['Service Charge (tidak masuk laba)', `( ${formatCurrency(biayaPelayanan)} )`],
      ['Pendapatan Bersih', formatCurrency(totalPendapatanBersih)],
      ['', ''],
      ['LABA KOTOR', ''],
      ['Pendapatan Bersih', formatCurrency(totalPendapatanBersih)],
      ['HPP',              `( ${formatCurrency(totalHpp)} )`],
      ['Total Laba Kotor', formatCurrency(totalLabaKotor)],
      ['', ''],
      ['LABA BERSIH', ''],
      ['Laba Kotor',          formatCurrency(totalLabaKotor)],
      ['Biaya Operasional',   `( ${formatCurrency(totalExpenses)} )`],
      ['Total Laba Bersih',   formatCurrency(totalLabaBersih)],
    ]
    return {
      title: 'Ringkasan Penjualan',
      outletName,
      period,
      summaryStats: [
        { label: 'Total Penerimaan',  value: formatCurrency(totalPenerimaan)  },
        { label: 'Biaya Promosi',     value: formatCurrency(totalDiskon + totalRedeem) },
        { label: 'Pendapatan Bersih', value: formatCurrency(totalPendapatanBersih) },
        { label: 'Laba Kotor',        value: formatCurrency(totalLabaKotor)   },
        { label: 'Laba Bersih',       value: formatCurrency(totalLabaBersih)  },
      ],
      tableHeaders: ['Keterangan', 'Nilai'],
      tableRows: rows,
      filename: `ringkasan-penjualan-${format(range.from, 'yyyyMMdd')}-${format(range.to, 'yyyyMMdd')}.${ext}`,
    }
  }

  const handleExcel = async () => {
    if (paidOrders.length === 0) { noDataToast(); return }
    setIsExporting(true)
    try { exportReportExcel(buildExportConfig('xls')) }
    finally { setIsExporting(false) }
  }
  const handlePDF = async () => {
    if (paidOrders.length === 0) { noDataToast(); return }
    setIsExporting(true)
    try { await exportReportPDF(buildExportConfig('pdf')) }
    finally { setIsExporting(false) }
  }

  return (
    <div className="min-h-screen bg-gray-50/50">
      {/* ── Header ───────────────────────────────────────────────── */}
      <div className="bg-white border-b border-gray-100 px-6 py-4 mb-5">
        <div className="flex flex-wrap items-start justify-between gap-y-3">
          <div>
            <h1 className="text-xl font-bold text-gray-900 flex items-center gap-2">
              Ringkasan Penjualan
              <HintIcon size="md" text="Rekap pendapatan, biaya, dan laba bersih pada periode terpilih" />
            </h1>
            <p className="text-sm text-muted-foreground mt-0.5">{period}</p>
          </div>
          <div className="inline-flex items-center gap-0.5 rounded-lg border bg-white px-1.5 py-1 shadow-sm">
            <span className="text-[11px] font-medium text-muted-foreground px-1.5">Ekspor</span>
            <div className="w-px h-4 bg-border mx-0.5" />
            <Button variant="ghost" size="sm" className="h-7 px-2.5 text-xs gap-1.5 rounded-md" onClick={handleExcel} disabled={isExporting}>
              <FileText className="h-3.5 w-3.5" /> Excel
            </Button>
            <Button variant="ghost" size="sm" className="h-7 px-2.5 text-xs gap-1.5 rounded-md" onClick={handlePDF} disabled={isExporting}>
              <FileText className="h-3.5 w-3.5" /> PDF
            </Button>
          </div>
        </div>
        <div className="flex flex-wrap items-center gap-3 mt-4">
          <DateRangePicker value={range} onChange={setRange} />
        </div>
      </div>

      {/* ── Content ──────────────────────────────────────────────── */}
      <div className="px-6 pb-8 space-y-6">
        {hasQueryError && (
          <div className="flex items-start gap-3 rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800" role="alert">
            <AlertTriangle className="h-5 w-5 shrink-0 mt-0.5" />
            <div>
              <p className="font-semibold">Sebagian data laporan gagal dimuat</p>
              <p className="text-xs mt-0.5">{queryError instanceof Error ? queryError.message : 'Muat ulang halaman atau periksa koneksi server.'}</p>
            </div>
          </div>
        )}
        {!loading && penjualanKotor > 0 && totalHpp > penjualanKotor && (
          <div className="flex items-start gap-3 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900" role="status">
            <AlertTriangle className="h-5 w-5 shrink-0 mt-0.5" />
            <div>
              <p className="font-semibold">HPP lebih besar dari penjualan kotor</p>
              <p className="text-xs mt-0.5">Periksa satuan resep, jumlah per porsi, dan harga per satuan bahan. Nilai tidak diubah otomatis agar audit tetap transparan.</p>
            </div>
          </div>
        )}
        {/* Stat Cards */}
        <div className="grid grid-cols-2 sm:grid-cols-3 xl:grid-cols-5 gap-3">
          <StatCard
            label="Total Penerimaan Pelanggan"
            value={<CurrencyDisplay value={totalPenerimaan} />}
            accent={ACCENT.green}
            loading={loading}
            hint="Uang dibayar pelanggan setelah refund, termasuk pajak dan service"
          />
          <StatCard
            label="Biaya Promosi"
            value={<CurrencyDisplay value={totalDiskon + totalRedeem} />}
            accent={ACCENT.yellow}
            loading={loading}
            hint="Diskon promo/voucher + tukar poin loyalty"
          />
          <StatCard
            label="Pendapatan Bersih"
            value={<CurrencyDisplay value={totalPendapatanBersih} />}
            accent={ACCENT.sky}
            loading={loading}
            hint="Penerimaan setelah refund dikurangi pajak dan service charge"
          />
          <StatCard
            label="Laba Kotor"
            value={<CurrencyDisplay value={totalLabaKotor} />}
            accent={ACCENT.purple}
            loading={loading}
            hint="Penjualan bersih - HPP"
          />
          <StatCard
            label="Laba Bersih"
            value={<CurrencyDisplay value={totalLabaBersih} />}
            accent={totalLabaBersih >= 0 ? ACCENT.blue : ACCENT.red}
            loading={loading}
            hint="Laba kotor - biaya operasional"
          />
        </div>

        <h2 className="text-base font-semibold text-gray-800">Rincian Ringkasan Penjualan</h2>

        <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
          {/* Penerimaan pelanggan */}
          <SummaryTable
            title="Penerimaan Pelanggan"
            accent="#D1FAE5"
            loading={loading}
            rows={[
              { label: 'Subtotal Produk', value: penjualanKotor },
              { label: 'Pajak Pelanggan', value: totalPajak },
              { label: 'Service Charge', value: biayaPelayanan },
              {
                label: 'Refund Tercatat',
                value: totalRefund,
                negative: true,
                hint: 'Refund yang benar-benar tercatat pada periode refund.',
              },
              { label: 'TOTAL PENERIMAAN', value: totalPenerimaan, bold: true },
            ]}
          />

          <div className="space-y-4">
            <SummaryTable
              title="Biaya Promosi & Loyalty"
              accent="#FEF3C7"
              loading={loading}
              rows={[
                { label: 'Diskon Promo / Voucher', value: totalDiskon, negative: true },
                { label: 'Tukar Poin Loyalty',     value: totalRedeem, negative: true, hint: 'Total nilai poin loyalty yang ditukar pelanggan menjadi diskon (orders.loyalty_discount)' },
                { label: 'TOTAL POTONGAN',         value: totalDiskon + totalRedeem, negative: true, bold: true },
              ]}
            />

            <SummaryTable
              title="Pendapatan Bersih"
              accent="#DBEAFE"
              loading={loading}
              rows={[
                { label: 'Total Penerimaan Pelanggan', value: totalPenerimaan },
                {
                  label: 'Pajak (tidak masuk laba)',
                  value: totalPajak,
                  negative: true,
                  hint: 'Pajak pelanggan dilaporkan terpisah dan tidak menjadi laba usaha.',
                },
                { label: 'Service Charge (tidak masuk laba)', value: biayaPelayanan, negative: true },
                { label: 'TOTAL PENDAPATAN BERSIH', value: totalPendapatanBersih, bold: true },
              ]}
            />
          </div>
        </div>

        {/* Laba Kotor & Bersih */}
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
          <SummaryTable
            title="Laba Kotor"
            accent="#EDE9FE"
            loading={loading}
            rows={[
              { label: 'Pendapatan Bersih', value: totalPendapatanBersih },
              {
                label: 'HPP',
                value: totalHpp,
                negative: true,
                hint: 'Dihitung dari menu_recipes × ingredients.cost_per_unit. Item tanpa resep tidak punya HPP.',
              },
              { label: 'TOTAL LABA KOTOR',  value: totalLabaKotor, bold: true },
            ]}
          />

          <SummaryTable
            title="Laba Bersih"
            accent="#FEE2E2"
            loading={loading}
            rows={[
              { label: 'Laba Kotor',          value: totalLabaKotor },
              {
                label: 'Biaya Operasional',
                value: totalExpenses,
                negative: true,
                hint: 'Total pengeluaran (expenses) pada periode terpilih',
              },
              { label: 'TOTAL LABA BERSIH',  value: totalLabaBersih, bold: true },
            ]}
          />
        </div>
      </div>
    </div>
  )
}
