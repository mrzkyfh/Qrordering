import { useState, useMemo, useEffect } from 'react'
import { startOfDay, endOfDay, format } from 'date-fns'
import { id as localeId } from 'date-fns/locale'
import { FileText, Search, HelpCircle } from 'lucide-react'
import { useOutlet } from '@/hooks/useOutlet'
import {
  useOrderStatusReportPaged,
  fetchAllOrderStatusRows,
  type OrderStatusReportType,
} from '@/hooks/queries/useOrderStatusReport'
import { exportReportExcel, exportReportPDF } from '@/utils/exportReport'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { DataTable } from '@/components/ui/DataTable'
import { DateRangePicker } from '@/components/ui/DateRangePicker'
import { CurrencyDisplay } from '@/components/ui/CurrencyDisplay'
import { formatCurrency } from '@/lib/currency'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { Input } from '@/components/ui/input'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { useToast } from '@/hooks/use-toast'
import type { DateRange } from '@/components/ui/DateRangePicker'

const ORDER_TYPE_LABEL: Record<string, string> = {
  dine_in: 'Dine In', takeaway: 'Takeaway', self_order: 'Self Order',
}

function fmtRange(from: Date, to: Date) {
  const f = format(from, 'd MMM yyyy', { locale: localeId })
  const t = format(to,   'd MMM yyyy', { locale: localeId })
  return f === t ? f : `${f} - ${t}`
}

function StatCard({ label, value, accent, loading }: {
  label: string; value: React.ReactNode; accent: string; loading?: boolean
}) {
  return (
    <div className="bg-white rounded-xl border border-gray-100 shadow-sm overflow-hidden">
      <div className="px-5 py-4">
        <p className="text-xs text-muted-foreground mb-1 truncate">{label}</p>
        {loading
          ? <Skeleton className="h-6 w-32 mt-1" />
          : <p className="text-xl font-bold text-gray-900 truncate">{value}</p>}
      </div>
      <div className="h-1 w-full" style={{ backgroundColor: accent }} />
    </div>
  )
}

function ExportBar({ onExcel, onPDF, disabled }: {
  onExcel: () => void; onPDF: () => void; disabled?: boolean
}) {
  return (
    <div className="inline-flex items-center gap-0.5 rounded-lg border bg-white px-1.5 py-1 shadow-sm">
      <span className="text-[11px] font-medium text-muted-foreground px-1.5">Ekspor</span>
      <div className="w-px h-4 bg-border mx-0.5" />
      <Button variant="ghost" size="sm" className="h-7 px-2.5 text-xs gap-1.5 rounded-md" onClick={onExcel} disabled={disabled}>
        <FileText className="h-3.5 w-3.5" /> Excel
      </Button>
      <Button variant="ghost" size="sm" className="h-7 px-2.5 text-xs gap-1.5 rounded-md" onClick={onPDF} disabled={disabled}>
        <FileText className="h-3.5 w-3.5" /> PDF
      </Button>
    </div>
  )
}

interface Props {
  type: OrderStatusReportType
  pageTitle: string
  totalLabel: string
  statAccent: string
}

export function OrderStatusReportView({ type, pageTitle, totalLabel, statAccent }: Props) {
  const { activeOutletId, activeOutlet } = useOutlet()
  const { toast } = useToast()
  const today = useMemo(() => new Date(), [])

  const [range, setRange] = useState<DateRange>({ from: startOfDay(today), to: endOfDay(today) })
  const [search, setSearch] = useState('')
  const [orderType, setOrderType] = useState<string>('all')
  const [isExporting, setIsExporting] = useState(false)
  const [page, setPage] = useState(1)
  const PAGE_SIZE = 25   // jumlah NOTA per halaman

  const dateFromIso = range.from.toISOString()
  const dateToIso   = range.to.toISOString()
  const filters = { dateFrom: dateFromIso, dateTo: dateToIso, orderType, search }

  const { data: pageData, isLoading } = useOrderStatusReportPaged(
    activeOutletId ?? null,
    type,
    { ...filters, page, pageSize: PAGE_SIZE },
  )
  const filtered       = pageData?.rows ?? []
  const totalAmount    = pageData?.totalAmount ?? 0
  const totalTransaksi = pageData?.totalOrders ?? 0
  const totalRows      = pageData?.totalRows ?? 0

  // Reset ke halaman 1 saat filter berubah
  // eslint-disable-next-line react-hooks/set-state-in-effect
  useEffect(() => { setPage(1) }, [dateFromIso, dateToIso, orderType, search])

  if (!activeOutletId) return <NoOutlet />

  const outletName = activeOutlet?.name ?? 'Semua Outlet'
  const period     = fmtRange(range.from, range.to)

  // ── Export ───────────────────────────────────────────────────
  const TABLE_HEADERS = [
    'No Nota', 'Tanggal Void/Refund', 'Tanggal Order', 'Kasir', 'Otorisasi',
    'Produk', 'Qty', 'Subtotal', 'Jenis Order', 'Nama Meja',
  ]

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const buildRows = (rows: any[]): (string | number)[][] => rows.map((r) => [
    r.order_number,
    r.status_at ? format(new Date(r.status_at), 'd MMM yyyy, HH:mm', { locale: localeId }) : '—',
    format(new Date(r.order_at), 'd MMM yyyy, HH:mm', { locale: localeId }),
    r.kasir_name ?? '—',
    r.otorisasi_name ?? '—',
    r.product_name ?? '—',
    r.quantity,
    formatCurrency(r.subtotal),
    ORDER_TYPE_LABEL[r.order_type] ?? r.order_type,
    r.table_number ?? '—',
  ])

  const summaryStats = [
    { label: totalLabel,      value: formatCurrency(totalAmount) },
    { label: 'Total Transaksi', value: totalTransaksi.toLocaleString('id-ID') },
  ]

  const noDataToast = () =>
    toast({ title: 'Tidak ada data', description: 'Tidak ada data untuk diekspor pada periode ini.', variant: 'destructive' })

  // Ekspor mengambil SELURUH baris sesuai filter (bukan hanya halaman aktif)
  const fileBase = `${pageTitle.toLowerCase().replace(/\s+/g, '-')}-${format(range.from, 'yyyyMMdd')}`
  const handleExcel = async () => {
    setIsExporting(true)
    try {
      const all = await fetchAllOrderStatusRows(activeOutletId, type, filters)
      if (!all.length) { noDataToast(); return }
      exportReportExcel({ title: pageTitle, outletName, period, summaryStats, tableHeaders: TABLE_HEADERS, tableRows: buildRows(all), filename: `${fileBase}.xls` })
    } finally { setIsExporting(false) }
  }
  const handlePDF = async () => {
    setIsExporting(true)
    try {
      const all = await fetchAllOrderStatusRows(activeOutletId, type, filters)
      if (!all.length) { noDataToast(); return }
      await exportReportPDF({ title: pageTitle, outletName, period, summaryStats, tableHeaders: TABLE_HEADERS, tableRows: buildRows(all), filename: `${fileBase}.pdf` })
    } finally { setIsExporting(false) }
  }

  return (
    <div className="min-h-screen bg-gray-50/50">
      {/* ── Header ───────────────────────────────────────────────── */}
      <div className="bg-white border-b border-gray-100 px-6 py-4 mb-5">
        <div className="flex flex-wrap items-start justify-between gap-y-3">
          <div>
            <h1 className="text-xl font-bold text-gray-900 flex items-center gap-2">
              {pageTitle}
              <span
                title={
                  type === 'void'
                    ? 'Laporan Void menampilkan item yang di-void sebagian dan transaksi yang di-void seluruhnya. Ditampilkan 1 baris per produk agar detail item terlihat. Kolom Otorisasi diisi dari akun yang menyetujui void.'
                    : 'Laporan Refund menampilkan order yang dibatalkan (cancelled) sebelum atau sesudah pembayaran. Ditampilkan 1 baris per produk. Kolom Otorisasi diisi dari akun yang melakukan pembatalan.'
                }
                className="cursor-help text-muted-foreground"
              >
                <HelpCircle className="h-4 w-4" />
              </span>
            </h1>
            <p className="text-sm text-muted-foreground mt-0.5">{period}</p>
          </div>
          <ExportBar onExcel={handleExcel} onPDF={handlePDF} disabled={isExporting} />
        </div>

        {/* Filter bar */}
        <div className="flex flex-wrap items-center gap-3 mt-4">
          <div className="relative w-full sm:w-64">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground pointer-events-none" />
            <Input className="pl-9 h-9 w-full bg-white" placeholder="Cari ..." value={search} onChange={(e) => setSearch(e.target.value)} />
          </div>
          <DateRangePicker value={range} onChange={setRange} />
          <Select value={orderType} onValueChange={setOrderType}>
            <SelectTrigger className="h-9 w-44 bg-white">
              <SelectValue placeholder="Semua Jenis Order" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">Semua Jenis Order</SelectItem>
              <SelectItem value="dine_in">Dine In</SelectItem>
              <SelectItem value="takeaway">Takeaway</SelectItem>
              <SelectItem value="self_order">Self Order</SelectItem>
            </SelectContent>
          </Select>
        </div>
      </div>

      {/* ── Content ──────────────────────────────────────────────── */}
      <div className="px-6 pb-8 space-y-5">
        {/* Stat Cards */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 max-w-3xl">
          <StatCard label={totalLabel} value={<CurrencyDisplay value={totalAmount} />} accent={statAccent} loading={isLoading} />
          <StatCard label="Total Transaksi" value={totalTransaksi.toLocaleString('id-ID')} accent="#10B981" loading={isLoading} />
        </div>

        {/* Table */}
        <DataTable
          data={filtered}
          loading={isLoading}
          getRowKey={(r) => r.row_id}
          emptyMessage={`Tidak ada data ${type === 'void' ? 'void' : 'refund'} pada periode ini.`}
          page={page}
          pageSize={PAGE_SIZE}
          totalCount={totalRows}
          onPageChange={setPage}
          columns={[
            {
              key: 'no_nota',
              header: 'No Nota',
              cell: (r) => <span className="font-mono text-xs font-semibold">{r.order_number}</span>,
            },
            {
              key: 'tgl_status',
              header: type === 'void' ? 'Tanggal Void' : 'Tanggal Refund',
              cell: (r) => r.status_at
                ? format(new Date(r.status_at), 'd MMM yyyy, HH:mm', { locale: localeId })
                : <span className="text-muted-foreground">—</span>,
            },
            {
              key: 'tgl_order',
              header: 'Tanggal Order',
              cell: (r) => format(new Date(r.order_at), 'd MMM yyyy, HH:mm', { locale: localeId }),
            },
            { key: 'kasir',     header: 'Kasir',      cell: (r) => r.kasir_name ?? '—' },
            { key: 'otorisasi', header: 'Otorisasi',  cell: (r) => r.otorisasi_name ?? '—' },
            { key: 'produk',    header: 'Produk',     cell: (r) => r.product_name ?? '—' },
            {
              key: 'subtotal',
              header: type === 'void' ? 'Subtotal Void' : 'Subtotal Refund',
              cell: (r) => <CurrencyDisplay value={r.subtotal} />,
            },
            {
              key: 'jenis',
              header: 'Jenis Order',
              cell: (r) => ORDER_TYPE_LABEL[r.order_type] ?? r.order_type,
            },
            { key: 'meja', header: 'Nama Meja', cell: (r) => r.table_number ?? '—' },
          ]}
        />
      </div>
    </div>
  )
}
