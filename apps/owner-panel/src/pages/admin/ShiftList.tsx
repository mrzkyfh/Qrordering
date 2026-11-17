import { useState, useMemo } from 'react'
import type { ReactNode } from 'react'
import {
  format, startOfDay, endOfDay,
  addDays, addWeeks, addMonths,
  startOfWeek, endOfWeek, startOfMonth, endOfMonth,
} from 'date-fns'
import { id } from 'date-fns/locale'
import { Plus, Clock, AlertCircle, ChevronLeft, ChevronRight, Eye, FileText } from 'lucide-react'
import { useShifts, useActiveShifts, useOpenShift, useCloseShift, useShiftCloseReport } from '@/hooks/queries/useShifts'
import { useCashMovements } from '@/hooks/queries/useCashMovements'
import { useStaff } from '@/hooks/queries/useStaff'
import { useOutlet } from '@/hooks/useOutlet'
import { cn } from '@/lib/utils'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { DataTable } from '@/components/ui/DataTable'
import { CurrencyDisplay } from '@/components/ui/CurrencyDisplay'
import { Button } from '@/components/ui/button'
import { exportReportExcel, exportReportPDF } from '@/utils/exportReport'
import { Input } from '@/components/ui/input'
import { Sheet, SheetContent, SheetHeader, SheetTitle } from '@/components/ui/sheet'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from '@/components/ui/dialog'
import { Separator } from '@/components/ui/separator'
import { Badge } from '@/components/ui/badge'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Textarea } from '@/components/ui/textarea'
import { useToast } from '@/hooks/use-toast'
import { humanizeError } from '@/lib/errorMessage'
import type { ShiftWithKasir } from '@/hooks/queries/useShifts'

type Period = 'daily' | 'weekly' | 'monthly'

function getRange(period: Period, offset: number) {
  const base = new Date()
  if (period === 'daily') {
    const d = addDays(base, offset)
    return {
      from: startOfDay(d),
      to: endOfDay(d),
      label: format(d, 'd MMM yy', { locale: id }),
    }
  }
  if (period === 'weekly') {
    const w = addWeeks(base, offset)
    const from = startOfWeek(w, { weekStartsOn: 1 })
    const to = endOfWeek(w, { weekStartsOn: 1 })
    return {
      from,
      to,
      label: `${format(from, 'd MMM')} – ${format(to, 'd MMM yy', { locale: id })}`,
    }
  }
  const m = addMonths(base, offset)
  return {
    from: startOfMonth(m),
    to: endOfMonth(m),
    label: format(m, 'MMMM yyyy', { locale: id }),
  }
}

function ShiftStatusBadge({ shift }: { shift: ShiftWithKasir }) {
  if (!shift.end_time) {
    return <Badge variant="secondary" className="text-amber-600 bg-amber-50">Sedang Berjalan</Badge>
  }
  const diff = shift.cash_difference ?? 0
  if (diff < 0) return <Badge variant="destructive">Kurang {formatCurrency(Math.abs(diff))}</Badge>
  if (diff > 0) return <Badge className="bg-green-100 text-green-700 hover:bg-green-100">Lebih {formatCurrency(diff)}</Badge>
  return <Badge variant="outline" className="text-green-600">Sesuai</Badge>
}

function formatCurrency(n: number) {
  return new Intl.NumberFormat('id-ID', { style: 'currency', currency: 'IDR', minimumFractionDigits: 0 }).format(n)
}

function parseCash(raw: string): number {
  return parseFloat(raw.replace(/\./g, '').replace(/\D/g, '')) || 0
}

function CashInput({ value, onChange, placeholder }: { value: string; onChange: (v: string) => void; placeholder?: string }) {
  return (
    <Input
      inputMode="numeric"
      placeholder={placeholder ?? '0'}
      value={value ? Number(value.replace(/\./g, '')).toLocaleString('id-ID') : ''}
      onChange={(e) => onChange(e.target.value.replace(/\./g, '').replace(/\D/g, ''))}
    />
  )
}

function DetailRow({ label, value }: { label: string; value: ReactNode }) {
  return (
    <div className="flex justify-between items-center py-2">
      <span className="text-sm text-muted-foreground">{label}</span>
      <span className="text-sm font-medium">{value}</span>
    </div>
  )
}

/** Rincian kas masuk/keluar selama shift (petty cash), diisi dari mobile. */
function CashMovementsSection({ shiftId }: { shiftId: string }) {
  const { data: movements = [], isLoading } = useCashMovements(shiftId)
  if (isLoading || movements.length === 0) return null
  const net = movements.reduce((s, m) => s + (m.type === 'in' ? m.amount : -m.amount), 0)
  return (
    <>
      <Separator />
      <div>
        <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wider mb-2">
          Kas Masuk / Keluar
        </p>
        <div className="space-y-1">
          {movements.map((m) => (
            <div key={m.id} className="flex justify-between items-center py-1 text-sm">
              <span className="flex items-center gap-2 min-w-0">
                <span className={cn('font-medium', m.type === 'in' ? 'text-green-600' : 'text-red-600')}>
                  {m.type === 'in' ? 'Masuk' : 'Keluar'}
                </span>
                <span className="text-muted-foreground truncate">
                  {m.note || '—'}
                </span>
              </span>
              <span className={cn('font-medium shrink-0', m.type === 'in' ? 'text-green-600' : 'text-red-600')}>
                {(m.type === 'in' ? '+' : '−') + formatCurrency(m.amount)}
              </span>
            </div>
          ))}
        </div>
        <div className="flex justify-between items-center pt-2 mt-1 border-t text-sm font-semibold">
          <span>Net</span>
          <span className={cn(net < 0 ? 'text-red-600' : 'text-green-600')}>
            {(net >= 0 ? '+' : '−') + formatCurrency(Math.abs(net))}
          </span>
        </div>
      </div>
    </>
  )
}

const PAYMENT_METHOD_LABELS: Record<string, string> = {
  cash: 'Tunai',
  qris: 'QRIS',
  debit: 'Debit',
  credit: 'Kartu Kredit',
  ewallet: 'E-Wallet',
  transfer: 'Transfer',
}

function ReportSectionTitle({ children }: { children: ReactNode }) {
  return (
    <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wider mb-2">
      {children}
    </p>
  )
}

function ShiftCloseReportDetails({ shiftId }: { shiftId: string }) {
  const { data: report, isLoading, error, refetch } = useShiftCloseReport(shiftId)

  if (isLoading) {
    return (
      <div className="space-y-3" aria-label="Memuat laporan tutup kasir">
        {[80, 64, 72, 56].map((width) => (
          <div key={width} className="h-10 animate-pulse rounded-md bg-muted" style={{ width: `${width}%` }} />
        ))}
      </div>
    )
  }

  if (error || !report) {
    return (
      <div className="rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-700">
        <p className="font-semibold">Laporan tutup kasir belum dapat dimuat.</p>
        <p className="mt-1 text-xs">{error ? humanizeError(error) : 'Data laporan tidak tersedia.'}</p>
        <Button type="button" variant="outline" size="sm" className="mt-3" onClick={() => void refetch()}>
          Muat Ulang
        </Button>
      </div>
    )
  }

  const differenceClass = report.cash_difference < 0
    ? 'text-red-600 font-bold'
    : report.cash_difference > 0
      ? 'text-green-600 font-bold'
      : 'font-medium'

  return (
    <div className="space-y-5">
      <div>
        <ReportSectionTitle>Info Tutup Kasir</ReportSectionTitle>
        <DetailRow label="Kasir" value={report.cashier_name} />
        <DetailRow label="Outlet" value={report.outlet.name || '—'} />
        <DetailRow
          label="Waktu Buka"
          value={format(new Date(report.opened_at), 'HH:mm, d MMM yyyy', { locale: id })}
        />
        <DetailRow
          label="Waktu Tutup"
          value={format(new Date(report.closed_at), 'HH:mm, d MMM yyyy', { locale: id })}
        />
      </div>

      <Separator />
      <div>
        <ReportSectionTitle>Penerimaan</ReportSectionTitle>
        <DetailRow label="Modal Awal" value={<CurrencyDisplay value={report.opening_cash} />} />
        <DetailRow label="Penerimaan Tunai" value={<CurrencyDisplay value={report.cash_received} />} />
        <DetailRow label="Penerimaan Nontunai" value={<CurrencyDisplay value={report.non_cash_received} />} />
        <DetailRow label="Total Penerimaan" value={<CurrencyDisplay value={report.total_receipts} className="font-bold" />} />
        {report.cash_in !== 0 && <DetailRow label="Kas Masuk" value={<CurrencyDisplay value={report.cash_in} />} />}
        {report.cash_out !== 0 && <DetailRow label="Kas Keluar" value={<span className="text-red-600">−{formatCurrency(report.cash_out)}</span>} />}
      </div>

      <Separator />
      <div>
        <ReportSectionTitle>Rekonsiliasi Kas</ReportSectionTitle>
        <DetailRow label="Saldo Seharusnya" value={<CurrencyDisplay value={report.expected_cash} />} />
        <DetailRow label="Kas Fisik" value={<CurrencyDisplay value={report.closing_cash} />} />
        <DetailRow
          label="Selisih Kas"
          value={
            <span className={differenceClass}>
              {report.cash_difference > 0 ? '+' : ''}{formatCurrency(report.cash_difference)}
            </span>
          }
        />
      </div>

      <Separator />
      <div>
        <ReportSectionTitle>Ringkasan Transaksi</ReportSectionTitle>
        <div className="grid grid-cols-2 gap-2">
          {[
            ['Transaksi selesai', report.completed_transactions],
            ['Belum terbayar', report.unpaid_transactions],
            ['Produk terjual', report.product_quantity],
            ['Item di-void', report.void_item_quantity],
          ].map(([label, value]) => (
            <div key={String(label)} className="rounded-lg border bg-muted/30 p-3">
              <p className="text-[11px] text-muted-foreground">{label}</p>
              <p className="mt-1 text-lg font-bold">{value}</p>
            </div>
          ))}
        </div>
        <div className="mt-2">
          <DetailRow label="Pajak" value={<CurrencyDisplay value={report.tax_total} />} />
          <DetailRow label="Service Charge" value={<CurrencyDisplay value={report.service_charge_total} />} />
          <DetailRow label="Diskon" value={<CurrencyDisplay value={report.discount_total} />} />
          <DetailRow label="Refund" value={<CurrencyDisplay value={report.refund_total} />} />
          {report.void_item_amount > 0 && (
            <DetailRow label="Nilai Item Void" value={<CurrencyDisplay value={report.void_item_amount} />} />
          )}
        </div>
      </div>

      <Separator />
      <div>
        <ReportSectionTitle>Metode Pembayaran</ReportSectionTitle>
        {report.payment_methods.length === 0 ? (
          <p className="text-sm text-muted-foreground">Tidak ada pembayaran.</p>
        ) : report.payment_methods.map((payment) => (
          <DetailRow
            key={payment.method}
            label={PAYMENT_METHOD_LABELS[payment.method] ?? payment.method}
            value={<CurrencyDisplay value={payment.amount} />}
          />
        ))}
      </div>

      {report.expenses.length > 0 && (
        <>
          <Separator />
          <div>
            <ReportSectionTitle>Pengeluaran Kasir</ReportSectionTitle>
            <div className="space-y-2">
              {report.expenses.map((expense) => (
                <div key={expense.id} className="rounded-lg border p-3 text-sm">
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <p className="font-medium break-words">{expense.description}</p>
                      <p className="mt-0.5 text-xs capitalize text-muted-foreground">
                        {expense.category.replaceAll('_', ' ')}
                        {expense.created_at && ` · ${format(new Date(expense.created_at), 'HH:mm')}`}
                      </p>
                    </div>
                    <span className="shrink-0 font-semibold text-red-600">−{formatCurrency(expense.amount)}</span>
                  </div>
                </div>
              ))}
            </div>
          </div>
        </>
      )}

      <Separator />
      <div>
        <ReportSectionTitle>Produk Terjual</ReportSectionTitle>
        {report.products.length === 0 ? (
          <p className="text-sm text-muted-foreground">Tidak ada produk terjual.</p>
        ) : (
          <div className="divide-y rounded-lg border">
            {report.products.map((product) => (
              <div key={product.name} className="flex items-center justify-between gap-3 px-3 py-2.5 text-sm">
                <div className="min-w-0">
                  <p className="font-medium break-words">{product.name}</p>
                  <p className="text-xs text-muted-foreground">{product.quantity} produk</p>
                </div>
                <CurrencyDisplay value={product.amount} className="shrink-0 font-medium" />
              </div>
            ))}
          </div>
        )}
      </div>

      {report.notes && (
        <>
          <Separator />
          <div>
            <ReportSectionTitle>Catatan</ReportSectionTitle>
            <p className="whitespace-pre-wrap text-sm">{report.notes}</p>
          </div>
        </>
      )}
    </div>
  )
}

export default function ShiftList() {
  const { activeOutletId, activeOutlet } = useOutlet()
  const { toast } = useToast()

  const [period, setPeriod] = useState<Period>('daily')
  const [offset, setOffset] = useState(0)
  const { from, to, label } = useMemo(() => getRange(period, offset), [period, offset])
  const [selected, setSelected] = useState<ShiftWithKasir | null>(null)
  const [sheetOpen, setSheetOpen] = useState(false)

  // Buka shift dialog
  const [openShiftDialog, setOpenShiftDialog] = useState(false)
  const [selectedKasirId, setSelectedKasirId] = useState('')
  const [openingCash, setOpeningCash] = useState('')

  // Tutup shift dialog
  const [closeShiftDialog, setCloseShiftDialog] = useState(false)
  const [closingShift, setClosingShift] = useState<ShiftWithKasir | null>(null)
  const [closingCash, setClosingCash] = useState('')
  const [closingNotes, setClosingNotes] = useState('')

  const { data: shifts = [], isLoading } = useShifts(
    activeOutletId ?? null,
    from.toISOString(),
    to.toISOString(),
  )
  const { data: activeShifts = [] } = useActiveShifts(activeOutletId ?? null)
  const { data: staff = [] } = useStaff(activeOutletId, { enabled: !!activeOutletId })

  const kasirList = staff.filter((s) => s.role === 'kasir' && s.outlet_id === activeOutletId && s.is_active)

  const openShift = useOpenShift(activeOutletId)
  const closeShift = useCloseShift(activeOutletId)
  const [isExporting, setIsExporting] = useState(false)

  // ── Export handlers ──────────────────────────────────────
  const buildExportConfig = (ext: 'xls' | 'pdf') => {
    const closedShifts = shifts.filter((s) => !!s.end_time)
    return {
      title: 'Laporan Tutup Kasir',
      outletName: activeOutlet?.name ?? 'Semua Outlet',
      period: label,
      summaryStats: [
        { label: 'Total Shift', value: closedShifts.length.toLocaleString('id-ID') },
        { label: 'Total Tunai',     value: formatCurrency(closedShifts.reduce((s, r) => s + r.cash_received,     0)) },
        { label: 'Total Non Tunai', value: formatCurrency(closedShifts.reduce((s, r) => s + r.non_cash_received, 0)) },
      ],
      tableHeaders: [
        'No', 'Buka', 'Tutup', 'Kasir', 'Outlet',
        'Modal Awal (Rp)', 'Saldo Akhir (Rp)',
        'Total Tunai Aktual (Rp)', 'Total Penerimaan Non Tunai (Rp)',
      ],
      tableRows: closedShifts.map((r, i) => [
        i + 1,
        format(new Date(r.start_time), 'd MMM yyyy, HH:mm', { locale: id }),
        r.end_time ? format(new Date(r.end_time), 'd MMM yyyy, HH:mm', { locale: id }) : '—',
        r.kasir_name ?? '—',
        r.outlet_name ?? '—',
        formatCurrency(r.opening_cash),
        r.closing_cash != null ? formatCurrency(r.closing_cash) : '—',
        formatCurrency(r.cash_received),
        formatCurrency(r.non_cash_received),
      ]) as (string | number)[][],
      filename: `laporan-tutup-kasir-${format(from, 'yyyyMMdd')}.${ext}`,
    }
  }
  const noDataToast = () =>
    toast({ title: 'Tidak ada data', description: 'Tidak ada shift tutup pada periode ini.', variant: 'destructive' })
  const handleExcel = async () => {
    if (shifts.filter((s) => !!s.end_time).length === 0) { noDataToast(); return }
    setIsExporting(true)
    try { exportReportExcel(buildExportConfig('xls')) } finally { setIsExporting(false) }
  }
  const handlePDF = async () => {
    if (shifts.filter((s) => !!s.end_time).length === 0) { noDataToast(); return }
    setIsExporting(true)
    try { await exportReportPDF(buildExportConfig('pdf')) } finally { setIsExporting(false) }
  }

  // ── Buka shift ───────────────────────────────────────────
  async function handleOpenShift() {
    if (activeShifts.length > 0) {
      toast({ title: 'Tutup shift yang sedang berjalan terlebih dahulu', variant: 'destructive' })
      return
    }
    if (!selectedKasirId) {
      toast({ title: 'Pilih kasir terlebih dahulu', variant: 'destructive' })
      return
    }
    try {
      await openShift.mutateAsync({
        kasir_id: selectedKasirId,
        opening_cash: parseCash(openingCash),
      })
      toast({ title: 'Shift berhasil dibuka' })
      setOpenShiftDialog(false)
      setSelectedKasirId('')
      setOpeningCash('')
    } catch (err: unknown) {
      const msg = humanizeError(err)
      toast({ title: 'Gagal buka shift', description: msg, variant: 'destructive' })
    }
  }

  // ── Tutup shift ──────────────────────────────────────────
  function openCloseDialog(shift: ShiftWithKasir) {
    setClosingShift(shift)
    setClosingCash('')
    setClosingNotes('')
    setCloseShiftDialog(true)
    setSheetOpen(false)
  }

  async function handleCloseShift() {
    if (!closingShift) return
    try {
      await closeShift.mutateAsync({
        shiftId: closingShift.id,
        closingCash: parseCash(closingCash),
        notes: closingNotes,
      })
      toast({ title: 'Shift berhasil ditutup' })
      setCloseShiftDialog(false)
      setClosingShift(null)
    } catch (err: unknown) {
      const msg = humanizeError(err)
      toast({ title: 'Gagal tutup shift', description: msg, variant: 'destructive' })
    }
  }

  function openDetail(shift: ShiftWithKasir) {
    setSelected(shift)
    setSheetOpen(true)
  }

  if (!activeOutletId) return <NoOutlet />

  const openCount = shifts.filter(s => !s.end_time).length
  const closedCount = shifts.filter(s => !!s.end_time).length

  return (
    <div className="space-y-4">
      <PageHeader title="Laporan Tutup Kasir" subtitle="Riwayat & audit sesi shift kasir per periode">
        <div className="flex items-center gap-2">
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
          <Button
            onClick={() => setOpenShiftDialog(true)}
            disabled={activeShifts.length > 0}
            title={activeShifts.length > 0 ? 'Tutup shift yang berjalan terlebih dahulu' : undefined}
          >
            <Plus className="mr-2 h-4 w-4" /> Buka Shift
          </Button>
        </div>
      </PageHeader>

      {/* Banner shift aktif */}
      {activeShifts.length > 0 && (
        <div className="rounded-lg border border-amber-200 bg-amber-50 p-4 space-y-2">
          <div className="flex items-center gap-2 text-amber-700 font-medium text-sm">
            <Clock className="h-4 w-4" />
            {activeShifts.length} shift sedang berjalan
          </div>
          <div className="space-y-2">
            {activeShifts.map((shift) => (
              <div key={shift.id} className="flex items-center justify-between bg-white rounded-md border border-amber-200 px-3 py-2">
                <div className="text-sm">
                  <span className="font-medium">{shift.kasir_name ?? '—'}</span>
                  <span className="text-muted-foreground ml-2">
                    mulai {format(new Date(shift.start_time), 'HH:mm, d MMM', { locale: id })}
                  </span>
                  <span className="text-muted-foreground ml-2">
                    · Kas awal: <CurrencyDisplay value={shift.opening_cash} />
                  </span>
                </div>
                <Button
                  size="sm"
                  variant="outline"
                  className="border-amber-300 text-amber-700 hover:bg-amber-100"
                  onClick={() => openCloseDialog(shift)}
                >
                  Tutup Shift
                </Button>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Period selector */}
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
        <span className="text-sm text-muted-foreground ml-auto">
          {closedCount} selesai
          {openCount > 0 && <>, <span className="text-amber-600">{openCount} aktif</span></>}
        </span>
      </div>

      <DataTable
        data={shifts}
        loading={isLoading}
        getRowKey={(r) => r.id}
        emptyMessage="Tidak ada data shift dalam periode ini."
        columns={[
          {
            key: 'period',
            header: 'Waktu Buka / Tutup Kasir',
            cell: (r) => (
              <div className="text-sm leading-snug">
                <div>
                  <span className="font-semibold">Buka:</span>{' '}
                  {format(new Date(r.start_time), 'd MMM yyyy, HH:mm', { locale: id })}
                </div>
                <div>
                  <span className="font-semibold">Tutup:</span>{' '}
                  {r.end_time
                    ? format(new Date(r.end_time), 'd MMM yyyy, HH:mm', { locale: id })
                    : <span className="text-amber-600 font-medium">Belum tutup</span>}
                </div>
              </div>
            ),
          },
          {
            key: 'kasir',
            header: 'Kasir',
            cell: (r) => r.kasir_name ?? '—',
          },
          {
            key: 'outlet',
            header: 'Outlet',
            cell: (r) => r.outlet_name ?? '—',
          },
          {
            key: 'opening_cash',
            header: 'Modal Awal (Rp)',
            cell: (r) => <CurrencyDisplay value={r.opening_cash} />,
          },
          {
            key: 'closing_cash',
            header: 'Saldo Akhir (Rp)',
            cell: (r) =>
              r.closing_cash != null
                ? <CurrencyDisplay value={r.closing_cash} />
                : <span className="text-muted-foreground">—</span>,
          },
          {
            key: 'cash_received',
            header: 'Total Tunai Aktual (Rp)',
            cell: (r) => <CurrencyDisplay value={r.cash_received} />,
          },
          {
            key: 'non_cash_received',
            header: 'Total Penerimaan Non Tunai (Rp)',
            cell: (r) => <CurrencyDisplay value={r.non_cash_received} />,
          },
          {
            key: 'actions',
            header: '',
            className: 'text-right',
            cell: (r) => (
              <div className="flex gap-1 justify-end">
                {!r.end_time && (
                  <Button
                    variant="outline"
                    size="sm"
                    className="text-amber-600 border-amber-200 hover:bg-amber-50"
                    onClick={() => openCloseDialog(r)}
                  >
                    Tutup
                  </Button>
                )}
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  className="text-muted-foreground hover:text-foreground"
                  onClick={() => openDetail(r)}
                  aria-label={r.end_time ? 'Lihat laporan tutup kasir' : 'Lihat detail shift'}
                >
                  {r.end_time ? <FileText className="mr-1.5 h-4 w-4" /> : <Eye className="mr-1.5 h-4 w-4" />}
                  {r.end_time ? 'Laporan' : 'Detail'}
                </Button>
              </div>
            ),
          },
        ]}
      />

      {/* ── Buka Shift Dialog ── */}
      <Dialog open={openShiftDialog} onOpenChange={(o) => { if (!o) { setSelectedKasirId(''); setOpeningCash('') } setOpenShiftDialog(o) }}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Buka Shift Baru</DialogTitle>
          </DialogHeader>
          <div className="space-y-4 py-2">
            <div className="space-y-1.5">
              <label className="text-sm font-medium">Kasir</label>
              <Select value={selectedKasirId} onValueChange={setSelectedKasirId}>
                <SelectTrigger>
                  <SelectValue placeholder="Pilih kasir..." />
                </SelectTrigger>
                <SelectContent>
                  {kasirList.length === 0 ? (
                    <SelectItem value="__none" disabled>Tidak ada kasir aktif</SelectItem>
                  ) : (
                    kasirList.map((s) => (
                      <SelectItem key={s.id} value={s.id}>{s.full_name}</SelectItem>
                    ))
                  )}
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-1.5">
              <label className="text-sm font-medium">Kas Awal (Rp)</label>
              <CashInput value={openingCash} onChange={setOpeningCash} placeholder="Jumlah uang tunai di laci" />
            </div>
            {kasirList.length === 0 && (
              <div className="flex gap-2 rounded-md border border-yellow-200 bg-yellow-50 p-3 text-xs text-yellow-700">
                <AlertCircle className="h-4 w-4 shrink-0 mt-0.5" />
                <span>Tidak ada kasir aktif di outlet ini. Tambah kasir lewat menu Staff terlebih dahulu.</span>
              </div>
            )}
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setOpenShiftDialog(false)}>Batal</Button>
            <Button
              onClick={handleOpenShift}
              disabled={openShift.isPending || !selectedKasirId}
            >
              {openShift.isPending ? 'Membuka...' : 'Buka Shift'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* ── Tutup Shift Dialog ── */}
      <Dialog open={closeShiftDialog} onOpenChange={setCloseShiftDialog}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Tutup Shift — {closingShift?.kasir_name}</DialogTitle>
          </DialogHeader>
          <div className="space-y-4 py-2">
            <div className="rounded-md bg-muted/50 p-3 text-sm space-y-1">
              <div className="flex justify-between">
                <span className="text-muted-foreground">Mulai shift</span>
                <span>{closingShift && format(new Date(closingShift.start_time), 'HH:mm, d MMM yyyy', { locale: id })}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-muted-foreground">Kas awal</span>
                <span className="font-medium">
                  {closingShift && <CurrencyDisplay value={closingShift.opening_cash} />}
                </span>
              </div>
            </div>
            <div className="space-y-1.5">
              <label className="text-sm font-medium">Kas Akhir (Rp)</label>
              <p className="text-xs text-muted-foreground">Jumlah uang tunai aktual di laci sekarang</p>
              <CashInput value={closingCash} onChange={setClosingCash} placeholder="Hitung dulu uang di laci..." />
            </div>
            {closingCash && (
              <div className="rounded-md bg-muted/50 p-3 text-sm text-muted-foreground">
                Selisih kas akan dihitung otomatis setelah shift ditutup (kas awal + total pembayaran cash − kas akhir).
              </div>
            )}
            <div className="space-y-1.5">
              <label className="text-sm font-medium">Catatan <span className="text-muted-foreground text-xs">(opsional)</span></label>
              <Textarea
                rows={2}
                placeholder="Keterangan tambahan..."
                value={closingNotes}
                onChange={(e) => setClosingNotes(e.target.value)}
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setCloseShiftDialog(false)}>Batal</Button>
            <Button
              onClick={handleCloseShift}
              disabled={closeShift.isPending || !closingCash}
            >
              {closeShift.isPending ? 'Menutup...' : 'Tutup Shift'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* ── Detail Sheet ── */}
      <Sheet open={sheetOpen} onOpenChange={setSheetOpen}>
        <SheetContent className="w-full sm:max-w-lg overflow-y-auto">
          {selected && (
            <>
              <SheetHeader className="mb-4">
                <SheetTitle>{selected.end_time ? 'Laporan Tutup Kasir' : 'Detail Shift'}</SheetTitle>
                <p className="text-sm text-muted-foreground">
                  {format(new Date(selected.start_time), 'd MMMM yyyy', { locale: id })}
                </p>
              </SheetHeader>

              {selected.end_time ? (
                <ShiftCloseReportDetails shiftId={selected.id} />
              ) : (
                <div className="space-y-4">
                <div>
                  <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wider mb-2">Info Shift</p>
                  <DetailRow label="Kasir" value={selected.kasir_name ?? '—'} />
                  <DetailRow
                    label="Waktu Mulai"
                    value={format(new Date(selected.start_time), 'HH:mm, d MMM yyyy', { locale: id })}
                  />
                  <DetailRow
                    label="Waktu Tutup"
                    value={
                      selected.end_time
                        ? format(new Date(selected.end_time), 'HH:mm, d MMM yyyy', { locale: id })
                        : <span className="text-amber-600">Shift masih berjalan</span>
                    }
                  />
                  <DetailRow label="Status" value={<ShiftStatusBadge shift={selected} />} />
                </div>

                <Separator />

                <div>
                  <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wider mb-2">Rekap Kas</p>
                  <DetailRow label="Kas Awal" value={<CurrencyDisplay value={selected.opening_cash} className="font-medium" />} />
                  <DetailRow
                    label="Kas Akhir (Aktual)"
                    value={selected.closing_cash != null ? <CurrencyDisplay value={selected.closing_cash} className="font-medium" /> : '—'}
                  />
                  <DetailRow
                    label="Kas Seharusnya"
                    value={selected.expected_cash != null ? <CurrencyDisplay value={selected.expected_cash} className="font-medium" /> : '—'}
                  />
                  {selected.cash_difference != null && (
                    <>
                      <Separator className="my-2" />
                      <DetailRow
                        label="Selisih Kas"
                        value={
                          <span className={
                            selected.cash_difference < 0 ? 'text-red-600 font-bold'
                            : selected.cash_difference > 0 ? 'text-green-600 font-bold'
                            : 'font-medium'
                          }>
                            {selected.cash_difference === 0
                              ? 'Sesuai (Rp 0)'
                              : (selected.cash_difference > 0 ? '+' : '') + formatCurrency(selected.cash_difference)}
                          </span>
                        }
                      />
                    </>
                  )}
                </div>

                <CashMovementsSection shiftId={selected.id} />

                {selected.notes && (
                  <>
                    <Separator />
                    <div>
                      <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wider mb-2">Catatan</p>
                      <p className="text-sm whitespace-pre-wrap">{selected.notes}</p>
                    </div>
                  </>
                )}

                  <Separator />
                  <Button
                    className="w-full"
                    variant="outline"
                    onClick={() => openCloseDialog(selected)}
                  >
                    Tutup Shift Ini
                  </Button>
                </div>
              )}
            </>
          )}
        </SheetContent>
      </Sheet>
    </div>
  )
}
