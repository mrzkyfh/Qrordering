import { Fragment, useEffect, useMemo, useState } from 'react'
import { Navigate, useParams } from 'react-router'
import { format, startOfMonth, endOfMonth, startOfDay, endOfDay } from 'date-fns'
import { id as localeId } from 'date-fns/locale'
import {
  Search, FileText, Info, Receipt, Eye, ChevronDown, ChevronUp, ChevronLeft, ChevronRight,
} from 'lucide-react'
import { useOutlet } from '@/hooks/useOutlet'
import {
  useDepartmentFinancialReconciliation, useMenuSales, useTaxReport, useCategorySalesRange, useExtraOptionSales,
} from '@/hooks/queries/useSales'
import { useExtras } from '@/hooks/queries/useExtras'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { DateRangePicker } from '@/components/ui/DateRangePicker'
import { CurrencyDisplay } from '@/components/ui/CurrencyDisplay'
import { formatCurrency } from '@/lib/currency'
import { Input } from '@/components/ui/input'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { Accordion, AccordionContent, AccordionItem, AccordionTrigger } from '@/components/ui/accordion'
import { Tooltip, TooltipContent, TooltipPortal, TooltipProvider, TooltipTrigger } from '@/components/ui/tooltip'
import { exportReportExcel, exportReportPDF } from '@/utils/exportReport'
import type { DateRange } from '@/components/ui/DateRangePicker'
import type { MenuExtra, MenuSales } from '@/types/database'


// ── ExportBar ─────────────────────────────────────────────────────────────────

function ExportBar({ onExcel, onPDF, disabled }: { onExcel?: ()=>void; onPDF?: ()=>void; disabled?: boolean }) {
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

type TabSlug = 'departemen' | 'kategori' | 'menu' | 'extra' | 'sub-extra' | 'pajak' | 'service'

const TAB_LABELS: Record<TabSlug, string> = {
  departemen:  'Departemen',
  kategori:    'Kategori',
  menu:        'Menu',
  extra:       'Extra',
  'sub-extra': 'Sub Extra',
  pajak:       'Pajak',
  service:     'Service Charge',
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function defaultRange(): DateRange {
  return { from: startOfMonth(new Date()), to: endOfMonth(new Date()) }
}
function fmtDate(d: string) {
  return format(new Date(d), 'd MMM yyyy', { locale: localeId })
}
function fmtRange(from: Date, to: Date) {
  const f = format(from, 'd MMM yyyy', { locale: localeId })
  const t = format(to,   'd MMM yyyy', { locale: localeId })
  return f === t ? f : `${f} – ${t}`
}

type ExtraOptionSaleInput = {
  option_id: string
  qty_selected: number
  qty_refunded?: number
  gross_revenue?: number
  refund_amount?: number
  total_revenue: number
}

type ExtraSalesOptionRow = {
  id: string
  name: string
  price: number
  qty: number
  revenue: number
  refundQty: number
  refundAmount: number
}

type ExtraSalesRow = {
  id: string
  name: string
  qty: number
  revenue: number
  grossProfit: number
  refundQty: number
  refundAmount: number
  options: ExtraSalesOptionRow[]
}

function buildExtraSalesRows(extras: MenuExtra[], salesRaw: ExtraOptionSaleInput[]): ExtraSalesRow[] {
  const salesMap = new Map<string, { qty: number; revenue: number; refundQty?: number; refundAmount?: number }>()
  for (const sale of salesRaw) {
    const current = salesMap.get(sale.option_id)
    const qty = Math.max(Number(sale.qty_selected) || 0, 0)
    const revenue = Math.max(Number(sale.total_revenue) || 0, 0)
    const refundQty = sale.qty_refunded == null ? undefined : Math.max(Number(sale.qty_refunded) || 0, 0)
    const refundAmount = sale.refund_amount == null ? undefined : Math.max(Number(sale.refund_amount) || 0, 0)
    if (current) {
      current.qty += qty
      current.revenue += revenue
      if (refundQty != null) current.refundQty = (current.refundQty ?? 0) + refundQty
      if (refundAmount != null) current.refundAmount = (current.refundAmount ?? 0) + refundAmount
    } else {
      salesMap.set(sale.option_id, { qty, revenue, refundQty, refundAmount })
    }
  }

  return extras.map((extra) => {
    const options = (extra.menu_extra_options ?? []).map((option) => {
      const sale = salesMap.get(option.id)
      const qty = sale?.qty ?? 0
      const revenue = sale?.revenue ?? 0
      // RPC penjualan extra mengembalikan omzet setelah refund. Harga katalog
      // dipakai untuk merekonstruksi nilai bruto dan nilai refund per pilihan.
      const grossRevenue = Math.max(Number(option.price) || 0, 0) * qty
      const refundAmount = sale?.refundAmount ?? Math.max(grossRevenue - revenue, 0)
      const refundQty = sale?.refundQty ?? (option.price > 0 ? Math.round(refundAmount / option.price) : 0)
      return {
        id: option.id,
        name: option.name,
        price: Number(option.price) || 0,
        qty,
        revenue,
        refundQty,
        refundAmount,
      }
    })

    const qty = options.reduce((sum, option) => sum + option.qty, 0)
    const revenue = options.reduce((sum, option) => sum + option.revenue, 0)
    const refundQty = options.reduce((sum, option) => sum + option.refundQty, 0)
    const refundAmount = options.reduce((sum, option) => sum + option.refundAmount, 0)
    return {
      id: extra.id,
      name: extra.name,
      qty,
      revenue,
      // Belum ada HPP khusus extra; secara laporan laba kotor extra sama dengan
      // penjualan bersih extra sampai biaya extra dicatat tersendiri.
      grossProfit: revenue,
      refundQty,
      refundAmount,
      options,
    }
  }).filter((row) => row.qty > 0 || row.revenue > 0 || row.refundQty > 0)
    .sort((a, b) => b.revenue - a.revenue || b.qty - a.qty || a.name.localeCompare(b.name))
}

// ── Stat Card ─────────────────────────────────────────────────────────────────

const ACCENT = ['#00B69B','#3B82F6','#8B5CF6','#F59E0B','#EF4444'] as const

function StatCard({
  label, value, accent, sub, tooltip, compact = false,
}: { label: string; value: string; accent: string; sub?: string; tooltip?: string; compact?: boolean }) {
  return (
    <div className="bg-white rounded-xl border border-gray-100 shadow-sm overflow-hidden flex h-full flex-col">
      <div className={`${compact ? 'px-4 py-3' : 'px-5 py-4'} flex flex-1 flex-col justify-center`}>
        <div className="mb-1 flex min-w-0 items-center gap-1.5">
          <p className="text-xs leading-tight text-muted-foreground">{label}</p>
          {tooltip && <InfoTooltip label={`Penjelasan ${label}`} content={tooltip} side="bottom" contentClassName="z-20" />}
        </div>
        <p className="text-lg font-bold text-gray-900 truncate">{value}</p>
        {sub && <p className="mt-0.5 truncate text-xs text-muted-foreground">{sub}</p>}
      </div>
      <div className="h-1 w-full" style={{ backgroundColor: accent }} />
    </div>
  )
}

function InfoTooltip({
  label, content, side = 'top', contentClassName,
}: {
  label: string
  content: string
  side?: 'top' | 'right' | 'bottom' | 'left'
  contentClassName?: string
}) {
  return (
    <TooltipProvider delayDuration={200}>
      <Tooltip>
        <TooltipTrigger asChild>
          <button
            type="button"
            aria-label={label}
            className="shrink-0 rounded-full text-muted-foreground transition-colors hover:text-gray-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary"
          >
            <Info className="h-3.5 w-3.5" />
          </button>
        </TooltipTrigger>
        <TooltipPortal>
          <TooltipContent className={`max-w-xs text-xs leading-relaxed ${contentClassName ?? ''}`} side={side}>
            {content}
          </TooltipContent>
        </TooltipPortal>
      </Tooltip>
    </TooltipProvider>
  )
}

function TableHeaderInfo({ shortLabel, fullLabel, description }: {
  shortLabel: string
  fullLabel: string
  description: string
}) {
  return (
    <span className="inline-flex items-center justify-end gap-1 whitespace-nowrap">
      <span>{shortLabel}</span>
      <InfoTooltip label={`Penjelasan ${fullLabel}`} content={`${fullLabel}. ${description}`} />
    </span>
  )
}

// ── Table Skeleton ────────────────────────────────────────────────────────────

function TableSkeleton({ cols = 4 }: { cols?: number }) {
  return (
    <div className="space-y-2 p-4">
      {Array.from({ length: 6 }).map((_, i) => (
        <div key={i} className="flex gap-3">
          {Array.from({ length: cols }).map((__, j) => (
            <Skeleton key={j} className="h-7 flex-1 rounded" />
          ))}
        </div>
      ))}
    </div>
  )
}

// ── Empty State ───────────────────────────────────────────────────────────────

function Empty() {
  return (
    <div className="flex flex-col items-center justify-center py-20 text-center">
      <div className="h-12 w-12 rounded-full bg-muted flex items-center justify-center mb-3">
        <Receipt className="h-5 w-5 text-muted-foreground" />
      </div>
      <p className="font-medium text-gray-700">Tidak ada data</p>
      <p className="text-sm text-muted-foreground mt-1">Coba ubah rentang tanggal</p>
    </div>
  )
}

// ── Tab: Departemen ───────────────────────────────────────────────────────────

function departmentDisplayName(name: string) {
  return name === 'Penyesuaian / Belum Terdistribusi'
    ? 'Belum Dialokasikan ke Departemen'
    : name
}

function DepartemenTab({
  outletId, dateFrom, dateTo, search, uniqueOrders,
}: { outletId: string; dateFrom: string; dateTo: string; search: string; uniqueOrders: number }) {
  const { data = [], isLoading } = useDepartmentFinancialReconciliation(outletId, dateFrom, dateTo)
  const [calculationNotes, setCalculationNotes] = useState<string | undefined>(undefined)

  const filtered = search
    ? data.filter(d => departmentDisplayName(d.department_name).toLowerCase().includes(search.toLowerCase()))
    : data

  const totals = data.reduce((sum, row) => ({
    subtotal: sum.subtotal + row.subtotal,
    discount: sum.discount + row.discount_amount,
    taxInclusive: sum.taxInclusive + row.tax_inclusive,
    taxExclusive: sum.taxExclusive + row.tax_exclusive,
    service: sum.service + row.service_charge,
    rounding: sum.rounding + row.rounding_amount,
    refund: sum.refund + row.refund_amount,
    adjustment: sum.adjustment + row.unallocated_adjustment,
    receipts: sum.receipts + row.net_receipts,
    qty: sum.qty + row.qty_sold,
  }), { subtotal: 0, discount: 0, taxInclusive: 0, taxExclusive: 0, service: 0, rounding: 0, refund: 0, adjustment: 0, receipts: 0, qty: 0 })

  return (
    <>
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-4">
        <StatCard compact label="Subtotal Penjualan" value={formatCurrency(totals.subtotal)} sub="Belum termasuk pajak tambahan & biaya layanan" tooltip="Nilai item sebelum diskon dan refund. Belum termasuk pajak tambahan pada tagihan dan biaya layanan. Jika harga menu sudah termasuk pajak, pajak itu tidak ditambahkan lagi dan hanya ditampilkan sebagai info (kolom Pajak (Info))." accent={ACCENT[0]} />
        <StatCard compact label="Total Penerimaan" value={formatCurrency(totals.receipts)} sub="Subtotal + pajak + biaya layanan − diskon − refund" tooltip="Uang yang diterima dari pelanggan: subtotal ditambah pajak tambahan dan biaya layanan, dikurangi diskon dan refund. Bukan laba usaha." accent={ACCENT[1]} />
        <StatCard compact label="Jumlah Transaksi" value={uniqueOrders.toLocaleString('id-ID')} sub="Termasuk yang dibatalkan" tooltip="Termasuk transaksi dibatalkan yang memiliki pembayaran." accent={ACCENT[2]} />
        <StatCard compact label="Total Refund" value={formatCurrency(totals.refund)} tooltip="Total refund yang tercatat untuk transaksi dalam periode laporan." accent={ACCENT[3]} />
      </div>

      <Accordion
        type="single"
        collapsible
        value={calculationNotes}
        onValueChange={setCalculationNotes}
        className="mb-4 scroll-mt-20 rounded-xl border border-blue-200 bg-blue-50 px-4 text-sm text-blue-900"
      >
        <AccordionItem value="calculation-notes" className="border-0">
          <AccordionTrigger className="py-3 text-left font-semibold hover:no-underline">
            <span className="flex items-center gap-2">
              <Info className="h-4 w-4 shrink-0" />
              Catatan perhitungan laporan
            </span>
          </AccordionTrigger>
          <AccordionContent className="pb-3 text-blue-800">
            <ul className="list-disc space-y-1.5 pl-5">
              <li>Diskon, pajak, dan biaya layanan dibagi sesuai proporsi subtotal item.</li>
              <li>Pajak tambahan pada tagihan menambah penerimaan, tidak masuk subtotal. Pajak dalam harga hanya informasi.</li>
              <li>Extra sudah termasuk subtotal, jangan ditambahkan lagi. Nilai yang belum bisa dibagi ke departemen tampil di baris “Belum Dialokasikan ke Departemen”.</li>
              <li>Berdasarkan tanggal transaksi (WIB). Refund mengikuti transaksi asal. Qty belum mencerminkan pembatalan penuh.</li>
            </ul>
          </AccordionContent>
        </AccordionItem>
      </Accordion>

      {isLoading ? <TableSkeleton cols={4} /> : filtered.length === 0 ? <Empty /> : (
        <div className="bg-white rounded-xl border border-gray-100 shadow-sm overflow-hidden">
          <div className="max-w-full overflow-x-auto">
          <table className="w-full min-w-[1380px] table-fixed text-sm">
            <colgroup>
              <col className="w-[190px]" />
              <col className="w-[80px]" />
              <col className="w-[120px]" />
              <col className="w-[135px]" />
              <col className="w-[120px]" />
              <col className="w-[140px]" />
              <col className="w-[125px]" />
              <col className="w-[125px]" />
              <col className="w-[120px]" />
              <col className="w-[135px]" />
              <col className="w-[180px]" />
            </colgroup>
            <thead>
              <tr className="border-b bg-gray-50">
                <th className="sticky left-0 z-10 w-[190px] min-w-[190px] whitespace-nowrap bg-gray-50 px-3 py-2 text-left text-xs font-semibold uppercase tracking-wider text-muted-foreground shadow-[1px_0_0_0_hsl(var(--border))]">Departemen</th>
                <th className="w-[80px] min-w-[80px] whitespace-nowrap px-3 py-2 text-right text-xs font-semibold uppercase tracking-wider text-muted-foreground"><TableHeaderInfo shortLabel="Qty" fullLabel="Qty Tercatat" description="Jumlah item setelah pengurangan qty refund yang tercatat; belum mencerminkan seluruh pembatalan penuh." /></th>
                <th className="min-w-[120px] whitespace-nowrap px-3 py-2 text-right text-xs font-semibold uppercase tracking-wider text-muted-foreground">Subtotal</th>
                <th className="min-w-[120px] whitespace-nowrap px-3 py-2 text-right text-xs font-semibold uppercase tracking-wider text-muted-foreground"><TableHeaderInfo shortLabel="Diskon & Poin" fullLabel="Diskon & Penukaran Poin" description="Total diskon transaksi dan potongan dari penukaran poin yang dialokasikan ke departemen." /></th>
                <th className="min-w-[120px] whitespace-nowrap px-3 py-2 text-right text-xs font-semibold uppercase tracking-wider text-muted-foreground"><TableHeaderInfo shortLabel="Pajak (Info)" fullLabel="Pajak dalam Harga (Informasi)" description="Pajak yang sudah terkandung dalam harga dan tidak ditambahkan lagi ke penerimaan." /></th>
                <th className="min-w-[120px] whitespace-nowrap px-3 py-2 text-right text-xs font-semibold uppercase tracking-wider text-muted-foreground"><TableHeaderInfo shortLabel="Pajak Tambahan" fullLabel="Pajak Tambahan pada Tagihan" description="Pajak di luar harga yang ditambahkan ke total tagihan pelanggan." /></th>
                <th className="min-w-[120px] whitespace-nowrap px-3 py-2 text-right text-xs font-semibold uppercase tracking-wider text-muted-foreground">Biaya Layanan</th>
                <th className="min-w-[120px] whitespace-nowrap px-3 py-2 text-right text-xs font-semibold uppercase tracking-wider text-muted-foreground">Selisih Tagihan</th>
                <th className="min-w-[120px] whitespace-nowrap px-3 py-2 text-right text-xs font-semibold uppercase tracking-wider text-muted-foreground">Refund</th>
                <th className="min-w-[120px] whitespace-nowrap px-3 py-2 text-right text-xs font-semibold uppercase tracking-wider text-muted-foreground">Penyesuaian Lain</th>
                <th className="min-w-[120px] whitespace-nowrap px-3 py-2 text-right text-xs font-semibold uppercase tracking-wider text-muted-foreground">Penerimaan dari Pelanggan</th>
              </tr>
            </thead>
            <tbody>
              {filtered.map((d, i) => (
                <tr key={`${d.department_id ?? 'adjustment'}-${d.department_name}`} className={`group border-b last:border-0 hover:bg-gray-50/60 transition-colors ${i % 2 === 0 ? 'bg-white' : 'bg-gray-50/30'}`}>
                  <td className={`sticky left-0 z-[1] whitespace-nowrap px-3 py-2 text-left font-medium text-gray-800 shadow-[1px_0_0_0_hsl(var(--border))] group-hover:bg-gray-50 ${i % 2 === 0 ? 'bg-white' : 'bg-gray-50'}`}>{departmentDisplayName(d.department_name)}</td>
                  <td className="px-3 py-2 text-right tabular-nums text-gray-600">{d.department_name === 'Penyesuaian / Belum Terdistribusi' ? '—' : d.qty_sold.toLocaleString('id-ID')}</td>
                  <td className="px-3 py-2 text-right tabular-nums"><CurrencyDisplay value={d.subtotal} /></td>
                  <td className="px-3 py-2 text-right tabular-nums"><CurrencyDisplay value={d.discount_amount} /></td>
                  <td className="px-3 py-2 text-right tabular-nums">{d.department_name === 'Penyesuaian / Belum Terdistribusi' ? '—' : <CurrencyDisplay value={d.tax_inclusive} />}</td>
                  <td className="px-3 py-2 text-right tabular-nums">{d.department_name === 'Penyesuaian / Belum Terdistribusi' ? '—' : <CurrencyDisplay value={d.tax_exclusive} />}</td>
                  <td className="px-3 py-2 text-right tabular-nums"><CurrencyDisplay value={d.service_charge} /></td>
                  <td className="px-3 py-2 text-right tabular-nums"><CurrencyDisplay value={d.rounding_amount} /></td>
                  <td className="px-3 py-2 text-right tabular-nums"><CurrencyDisplay value={d.refund_amount} /></td>
                  <td className="px-3 py-2 text-right tabular-nums"><CurrencyDisplay value={d.unallocated_adjustment} /></td>
                  <td className="px-3 py-2 text-right font-semibold tabular-nums text-gray-900"><CurrencyDisplay value={d.net_receipts} /></td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr className="border-t-2 border-gray-300 bg-gray-100 font-bold">
                <td className="sticky left-0 z-[1] whitespace-nowrap bg-gray-100 px-3 py-2 text-left text-gray-900 shadow-[1px_0_0_0_hsl(var(--border))]">
                  <span className="inline-flex items-center gap-1">Total <InfoTooltip label="Penjelasan baris total" content="Total seluruh departemen dan penyesuaian." /></span>
                </td>
                <td className="px-3 py-2 text-right tabular-nums text-gray-900">{totals.qty.toLocaleString('id-ID')}</td>
                <td className="px-3 py-2 text-right tabular-nums"><CurrencyDisplay value={totals.subtotal} /></td>
                <td className="px-3 py-2 text-right tabular-nums"><CurrencyDisplay value={totals.discount} /></td>
                <td className="px-3 py-2 text-right tabular-nums"><CurrencyDisplay value={totals.taxInclusive} /></td>
                <td className="px-3 py-2 text-right tabular-nums"><CurrencyDisplay value={totals.taxExclusive} /></td>
                <td className="px-3 py-2 text-right tabular-nums"><CurrencyDisplay value={totals.service} /></td>
                <td className="px-3 py-2 text-right tabular-nums"><CurrencyDisplay value={totals.rounding} /></td>
                <td className="px-3 py-2 text-right tabular-nums"><CurrencyDisplay value={totals.refund} /></td>
                <td className="px-3 py-2 text-right tabular-nums"><CurrencyDisplay value={totals.adjustment} /></td>
                <td className="px-3 py-2 text-right tabular-nums text-gray-900"><CurrencyDisplay value={totals.receipts} /></td>
              </tr>
            </tfoot>
          </table>
          </div>
        </div>
      )}
    </>
  )
}

// ── Tab: Kategori ─────────────────────────────────────────────────────────────

function KategoriTab({
  outletId, dateFrom, dateTo, search, uniqueOrders,
}: { outletId: string; dateFrom: string; dateTo: string; search: string; uniqueOrders: number }) {
  const { data = [], isLoading } = useCategorySalesRange(outletId, dateFrom, dateTo)

  const grouped = useMemo(() => {
    const map = new Map<string, { name: string; revenue: number; qty: number; orders: number }>()
    for (const r of data) {
      const key = r.category_name ?? 'Tanpa Kategori'
      const ex = map.get(key)
      const qty    = r.qty_sold ?? 0
      const orders = r.total_orders ?? 0
      if (ex) { ex.revenue += r.total_revenue; ex.qty += qty; ex.orders += orders }
      else map.set(key, { name: key, revenue: r.total_revenue, qty, orders })
    }
    return [...map.values()].sort((a, b) => b.revenue - a.revenue)
  }, [data])

  const display = search
    ? grouped.filter(d => d.name.toLowerCase().includes(search.toLowerCase()))
    : grouped

  const grandTotal  = grouped.reduce((s, d) => s + d.revenue, 0)
  const grandQty    = grouped.reduce((s, d) => s + d.qty, 0)

  return (
    <>
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-4">
        <StatCard label="Total Pendapatan"  value={formatCurrency(grandTotal)}          accent={ACCENT[0]} />
        <StatCard label="Item Terjual"      value={grandQty.toLocaleString('id-ID')}    accent={ACCENT[1]} />
        <StatCard label="Transaksi Unik"    value={uniqueOrders.toLocaleString('id-ID')} accent={ACCENT[2]} />
        <StatCard label="Jumlah Kategori"   value={grouped.length.toString()}            accent={ACCENT[3]} />
      </div>

      {isLoading ? <TableSkeleton cols={4} /> : display.length === 0 ? <Empty /> : (
        <div className="bg-white rounded-xl border border-gray-100 shadow-sm overflow-hidden">
          <div className="overflow-x-auto">
          <table className="w-full text-sm min-w-[560px]">
            <thead>
              <tr className="border-b bg-gray-50">
                <th className="text-left px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Kategori</th>
                <th className="text-right px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Item Terjual</th>
                <th className="text-right px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Transaksi pada grup</th>
                <th className="text-right px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Pendapatan</th>
              </tr>
            </thead>
            <tbody>
              {display.map((d, i) => (
                <tr key={d.name} className={`border-b last:border-0 hover:bg-gray-50/60 transition-colors ${i % 2 === 0 ? '' : 'bg-gray-50/30'}`}>
                  <td className="px-5 py-3.5 font-medium text-gray-800">{d.name}</td>
                  <td className="px-5 py-3.5 text-right text-gray-600">{d.qty.toLocaleString('id-ID')}</td>
                  <td className="px-5 py-3.5 text-right text-gray-600">{d.orders.toLocaleString('id-ID')}</td>
                  <td className="px-5 py-3.5 text-right font-semibold text-gray-900"><CurrencyDisplay value={d.revenue} /></td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr className="border-t-2 bg-gray-50">
                <td className="px-5 py-3 font-bold text-gray-900">Total</td>
                <td className="px-5 py-3 text-right font-bold text-gray-900">{grandQty.toLocaleString('id-ID')}</td>
                <td className="px-5 py-3 text-right font-bold text-gray-900">{uniqueOrders.toLocaleString('id-ID')}</td>
                <td className="px-5 py-3 text-right font-bold text-gray-900"><CurrencyDisplay value={grandTotal} /></td>
              </tr>
            </tfoot>
          </table>
          </div>
        </div>
      )}
    </>
  )
}

// ── Tab: Menu ─────────────────────────────────────────────────────────────────

function MenuTab({
  outletId, dateFrom, dateTo, search, uniqueOrders,
}: { outletId: string; dateFrom: string; dateTo: string; search: string; uniqueOrders: number }) {
  const { data = [], isLoading } = useMenuSales(outletId, dateFrom, dateTo)

  const grouped = useMemo(() => {
    const map = new Map<string, MenuSales & { totalQty: number; totalRev: number; totalOrders: number }>()
    for (const r of data) {
      const ex = map.get(r.menu_item_id)
      if (ex) { ex.totalQty += r.qty_sold; ex.totalRev += r.total_revenue; ex.totalOrders += r.order_count }
      else map.set(r.menu_item_id, { ...r, totalQty: r.qty_sold, totalRev: r.total_revenue, totalOrders: r.order_count })
    }
    return [...map.values()].sort((a, b) => b.totalRev - a.totalRev)
  }, [data])

  const display = search
    ? grouped.filter(d => d.menu_name.toLowerCase().includes(search.toLowerCase())
        || (d.category_name ?? '').toLowerCase().includes(search.toLowerCase()))
    : grouped

  const grandTotal  = grouped.reduce((s, d) => s + d.totalRev, 0)
  const grandQty    = grouped.reduce((s, d) => s + d.totalQty, 0)

  return (
    <>
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-4">
        <StatCard label="Total Pendapatan" value={formatCurrency(grandTotal)}          accent={ACCENT[0]} />
        <StatCard label="Item Terjual"     value={grandQty.toLocaleString('id-ID')}    accent={ACCENT[1]} />
        <StatCard label="Transaksi Unik"   value={uniqueOrders.toLocaleString('id-ID')} accent={ACCENT[2]} />
        <StatCard label="Jumlah Menu"      value={grouped.length.toString()}            accent={ACCENT[3]} />
      </div>

      {isLoading ? <TableSkeleton cols={6} /> : display.length === 0 ? <Empty /> : (
        <div className="bg-white rounded-xl border border-gray-100 shadow-sm overflow-hidden">
          <div className="overflow-x-auto">
          <table className="w-full text-sm min-w-[560px]">
            <thead>
              <tr className="border-b bg-gray-50">
                <th className="text-left px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider w-6">#</th>
                <th className="text-left px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Nama Menu</th>
                <th className="text-left px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Kategori</th>
                <th className="text-left px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Departemen</th>
                <th className="text-right px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Harga</th>
                <th className="text-right px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Terjual</th>
                <th className="text-right px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Total Penjualan</th>
              </tr>
            </thead>
            <tbody>
              {display.map((d, i) => (
                <tr key={d.menu_item_id} className={`border-b last:border-0 hover:bg-gray-50/60 transition-colors ${i % 2 === 0 ? '' : 'bg-gray-50/30'}`}>
                  <td className="px-5 py-3.5 text-muted-foreground text-xs">{i + 1}</td>
                  <td className="px-5 py-3.5 font-medium text-gray-800">{d.menu_name}</td>
                  <td className="px-5 py-3.5 text-gray-500">{d.category_name ?? '—'}</td>
                  <td className="px-5 py-3.5 text-gray-500">{d.department_name ?? '—'}</td>
                  <td className="px-5 py-3.5 text-right text-gray-600"><CurrencyDisplay value={d.price} /></td>
                  <td className="px-5 py-3.5 text-right text-gray-800 font-medium">{d.totalQty.toLocaleString('id-ID')}</td>
                  <td className="px-5 py-3.5 text-right font-semibold text-gray-900"><CurrencyDisplay value={d.totalRev} /></td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr className="border-t-2 bg-gray-50">
                <td colSpan={5} className="px-5 py-3 font-bold text-gray-900">Total</td>
                <td className="px-5 py-3 text-right font-bold text-gray-900">{grandQty.toLocaleString('id-ID')}</td>
                <td className="px-5 py-3 text-right font-bold text-gray-900"><CurrencyDisplay value={grandTotal} /></td>
              </tr>
            </tfoot>
          </table>
          </div>
        </div>
      )}
    </>
  )
}

// ── Tab: Extra (laporan penjualan per grup extra) ────────────────────────────

function ExtraTab({
  outletId, dateFrom, dateTo, search,
}: { outletId: string; dateFrom: string; dateTo: string; search: string }) {
  const { data: extras = [], isLoading: loadingExtras } = useExtras(outletId)
  const { data: salesRaw = [], isLoading: loadingSales } = useExtraOptionSales(outletId, dateFrom, dateTo)
  const [showChart, setShowChart] = useState(false)
  const [expandedId, setExpandedId] = useState<string | null>(null)
  const [page, setPage] = useState(1)
  const rowsPerPage = 10
  const isLoading = loadingExtras || loadingSales

  const rows = useMemo(() => buildExtraSalesRows(extras, salesRaw), [extras, salesRaw])
  const filtered = useMemo(() => {
    const query = search.trim().toLowerCase()
    if (!query) return rows
    return rows.filter((row) =>
      row.name.toLowerCase().includes(query) ||
      row.options.some((option) => option.name.toLowerCase().includes(query))
    )
  }, [rows, search])

  const totals = useMemo(() => ({
    extras: rows.length,
    qty: rows.reduce((sum, row) => sum + row.qty, 0),
    revenue: rows.reduce((sum, row) => sum + row.revenue, 0),
    refundQty: rows.reduce((sum, row) => sum + row.refundQty, 0),
    refundAmount: rows.reduce((sum, row) => sum + row.refundAmount, 0),
  }), [rows])

  const pageCount = Math.max(1, Math.ceil(filtered.length / rowsPerPage))
  const safePage = Math.min(page, pageCount)
  const pageRows = filtered.slice((safePage - 1) * rowsPerPage, safePage * rowsPerPage)
  const firstShown = filtered.length === 0 ? 0 : (safePage - 1) * rowsPerPage + 1
  const lastShown = Math.min(safePage * rowsPerPage, filtered.length)
  const chartRows = rows.slice(0, 8)
  const chartMax = Math.max(...chartRows.map((row) => row.revenue), 1)

  return (
    <>
      <div className="mb-4 overflow-hidden rounded-xl border border-gray-100 bg-white shadow-sm">
        <button
          type="button"
          className="flex w-full items-center justify-between px-5 py-4 text-left text-sm font-semibold text-gray-800 hover:bg-gray-50"
          onClick={() => setShowChart((current) => !current)}
          aria-expanded={showChart}
        >
          <span>Grafik Penjualan Extra</span>
          <span className="flex items-center gap-1.5 text-xs font-medium text-primary">
            {showChart ? 'Sembunyikan' : 'Tampilkan'}
            {showChart ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}
          </span>
        </button>
        {showChart && (
          <div className="border-t px-5 py-5">
            {chartRows.length === 0 ? (
              <p className="py-6 text-center text-sm text-muted-foreground">Belum ada penjualan extra pada periode ini.</p>
            ) : (
              <div className="space-y-3" aria-label="Grafik penjualan extra">
                {chartRows.map((row) => (
                  <div key={row.id} className="grid grid-cols-[minmax(100px,180px)_1fr_auto] items-center gap-3">
                    <span className="truncate text-xs font-medium text-gray-700" title={row.name}>{row.name}</span>
                    <div className="h-2.5 overflow-hidden rounded-full bg-gray-100">
                      <div
                        className="h-full rounded-full bg-primary transition-all"
                        style={{ width: `${Math.max((row.revenue / chartMax) * 100, 2)}%` }}
                      />
                    </div>
                    <span className="min-w-24 text-right text-xs font-semibold text-gray-800">{formatCurrency(row.revenue)}</span>
                  </div>
                ))}
              </div>
            )}
          </div>
        )}
      </div>

      <div className="grid grid-cols-2 gap-3 mb-4 lg:grid-cols-4">
        <StatCard label="Total Extra"             value={totals.extras.toLocaleString('id-ID')}       accent={ACCENT[0]} />
        <StatCard label="Total Item Extra"        value={totals.qty.toLocaleString('id-ID')}          accent={ACCENT[1]} />
        <StatCard label="Rincian Penjualan Extra" value={formatCurrency(totals.revenue)} sub="Sudah termasuk dalam pendapatan produk" accent={ACCENT[2]} />
        <StatCard label="Total Refund Extra"     value={formatCurrency(totals.refundAmount)}         accent={ACCENT[4]} sub={totals.refundQty > 0 ? `${totals.refundQty.toLocaleString('id-ID')} item` : undefined} />
      </div>

      <div className="mb-4 flex items-start gap-3 rounded-xl border border-blue-200 bg-blue-50 p-4 text-sm text-blue-900">
        <Info className="mt-0.5 h-4 w-4 shrink-0" />
        <div>
          <p className="font-semibold">Nilai extra ini merupakan bagian dari pendapatan produk.</p>
          <p className="mt-1 text-blue-800">
            Gunakan laporan ini untuk melihat rincian extra yang terjual, bukan untuk ditambahkan lagi ke Laporan Departemen atau Pendapatan Bersih.
          </p>
        </div>
      </div>

      {!isLoading && rows.length === 0 && (
        <div className="mb-4 flex items-start gap-3 rounded-xl border border-blue-200 bg-blue-50 p-4 text-sm text-blue-800">
          <Info className="mt-0.5 h-4 w-4 shrink-0" />
          <p>Belum ada penjualan extra pada rentang tanggal yang dipilih.</p>
        </div>
      )}

      {isLoading ? <TableSkeleton cols={9} /> : filtered.length === 0 ? <Empty /> : (
        <div className="overflow-hidden rounded-xl border border-gray-100 bg-white shadow-sm">
          <div className="overflow-x-auto">
            <table className="w-full min-w-[1180px] text-sm">
              <thead>
                <tr className="border-b bg-gray-50">
                  <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wider text-muted-foreground">Nama Extra</th>
                  <th className="px-4 py-3 text-right text-xs font-semibold uppercase tracking-wider text-muted-foreground">Jumlah</th>
                  <th className="px-4 py-3 text-right text-xs font-semibold uppercase tracking-wider text-muted-foreground">Jumlah (%)</th>
                  <th className="px-4 py-3 text-right text-xs font-semibold uppercase tracking-wider text-muted-foreground">Penjualan (Rp)</th>
                  <th className="px-4 py-3 text-right text-xs font-semibold uppercase tracking-wider text-muted-foreground">Penjualan (%)</th>
                  <th className="px-4 py-3 text-right text-xs font-semibold uppercase tracking-wider text-muted-foreground">Laba Kotor (Rp)</th>
                  <th className="px-4 py-3 text-right text-xs font-semibold uppercase tracking-wider text-muted-foreground">Laba Kotor (%)</th>
                  <th className="px-4 py-3 text-right text-xs font-semibold uppercase tracking-wider text-muted-foreground">Jumlah Refund</th>
                  <th className="px-4 py-3 text-right text-xs font-semibold uppercase tracking-wider text-muted-foreground">Refund (Rp)</th>
                  <th className="w-14 px-4 py-3 text-center text-xs font-semibold uppercase tracking-wider text-muted-foreground">Detail</th>
                </tr>
              </thead>
              <tbody>
                {pageRows.map((row, index) => {
                  const qtyPercentage = totals.qty > 0 ? row.qty / totals.qty * 100 : 0
                  const salesPercentage = totals.revenue > 0 ? row.revenue / totals.revenue * 100 : 0
                  const profitPercentage = totals.revenue > 0 ? row.grossProfit / totals.revenue * 100 : 0
                  const expanded = expandedId === row.id
                  return (
                    <Fragment key={row.id}>
                      <tr className={`border-b transition-colors hover:bg-gray-50/60 ${index % 2 !== 0 ? 'bg-gray-50/30' : ''}`}>
                        <td className="px-4 py-3.5 font-medium text-gray-800">{row.name}</td>
                        <td className="px-4 py-3.5 text-right text-gray-700">{row.qty.toLocaleString('id-ID')}</td>
                        <td className="px-4 py-3.5 text-right text-gray-500">{qtyPercentage.toLocaleString('id-ID', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}%</td>
                        <td className="px-4 py-3.5 text-right font-medium text-gray-900"><CurrencyDisplay value={row.revenue} /></td>
                        <td className="px-4 py-3.5 text-right text-gray-500">{salesPercentage.toLocaleString('id-ID', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}%</td>
                        <td className="px-4 py-3.5 text-right font-medium text-gray-900"><CurrencyDisplay value={row.grossProfit} /></td>
                        <td className="px-4 py-3.5 text-right text-gray-500">{profitPercentage.toLocaleString('id-ID', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}%</td>
                        <td className="px-4 py-3.5 text-right text-gray-700">{row.refundQty.toLocaleString('id-ID')}</td>
                        <td className="px-4 py-3.5 text-right text-gray-700"><CurrencyDisplay value={row.refundAmount} /></td>
                        <td className="px-4 py-3.5 text-center">
                          <button
                            type="button"
                            className="inline-flex h-8 w-8 items-center justify-center rounded-full text-gray-500 hover:bg-gray-100 hover:text-gray-900"
                            aria-label={`${expanded ? 'Tutup' : 'Lihat'} detail ${row.name}`}
                            aria-expanded={expanded}
                            onClick={() => setExpandedId(expanded ? null : row.id)}
                          >
                            <Eye className="h-4 w-4" />
                          </button>
                        </td>
                      </tr>
                      {expanded && (
                        <tr className="border-b bg-emerald-50/40">
                          <td colSpan={10} className="px-5 py-4">
                            <p className="mb-3 text-xs font-semibold uppercase tracking-wider text-gray-600">Rincian pilihan {row.name}</p>
                            <div className="grid gap-2 md:grid-cols-2 xl:grid-cols-3">
                              {row.options.filter((option) => option.qty > 0 || option.revenue > 0 || option.refundQty > 0).map((option) => (
                                <div key={option.id} className="rounded-lg border bg-white px-3 py-2.5 shadow-sm">
                                  <div className="flex items-start justify-between gap-3">
                                    <span className="font-medium text-gray-800">{option.name}</span>
                                    <span className="whitespace-nowrap text-xs text-muted-foreground">{option.qty.toLocaleString('id-ID')} item</span>
                                  </div>
                                  <div className="mt-1 flex items-center justify-between gap-3 text-xs text-gray-500">
                                    <span>{formatCurrency(option.price)} / item</span>
                                    <span className="font-semibold text-gray-800">{formatCurrency(option.revenue)}</span>
                                  </div>
                                  {option.refundAmount > 0 && (
                                    <p className="mt-1 text-xs text-red-600">Refund {option.refundQty.toLocaleString('id-ID')} item · {formatCurrency(option.refundAmount)}</p>
                                  )}
                                </div>
                              ))}
                            </div>
                          </td>
                        </tr>
                      )}
                    </Fragment>
                  )
                })}
              </tbody>
            </table>
          </div>

          <div className="flex flex-wrap items-center justify-between gap-3 border-t px-5 py-4 text-xs text-muted-foreground">
            <p>Ditampilkan {firstShown}–{lastShown} dari {filtered.length.toLocaleString('id-ID')} data</p>
            <div className="flex items-center gap-2">
              <Button
                type="button"
                variant="ghost"
                size="sm"
                className="h-8 gap-1 px-2 text-xs"
                disabled={safePage <= 1}
                onClick={() => setPage((current) => Math.max(1, current - 1))}
              >
                <ChevronLeft className="h-4 w-4" /> Sebelumnya
              </Button>
              <span className="inline-flex h-8 min-w-8 items-center justify-center rounded-md bg-primary px-2 font-semibold text-primary-foreground">{safePage}</span>
              <Button
                type="button"
                variant="ghost"
                size="sm"
                className="h-8 gap-1 px-2 text-xs"
                disabled={safePage >= pageCount}
                onClick={() => setPage((current) => Math.min(pageCount, current + 1))}
              >
                Selanjutnya <ChevronRight className="h-4 w-4" />
              </Button>
            </div>
          </div>
        </div>
      )}
    </>
  )
}

// ── Tab: Sub Extra (laporan penjualan per opsi) ───────────────────────────────

function SubExtraTab({
  outletId, dateFrom, dateTo, search,
}: { outletId: string; dateFrom: string; dateTo: string; search: string }) {
  const { data: extras = [], isLoading: loadingExtras } = useExtras(outletId)
  const { data: salesRaw = [], isLoading: loadingSales } = useExtraOptionSales(outletId, dateFrom, dateTo)
  const isLoading = loadingExtras || loadingSales

  // Buat lookup: option_id → total qty + revenue dalam date range
  const salesMap = useMemo(() => {
    const m = new Map<string, { qty: number; revenue: number }>()
    for (const s of salesRaw) {
      const ex = m.get(s.option_id)
      if (ex) { ex.qty += s.qty_selected; ex.revenue += Number(s.total_revenue) }
      else m.set(s.option_id, { qty: s.qty_selected, revenue: Number(s.total_revenue) })
    }
    return m
  }, [salesRaw])

  // Flatten extras → opsi dengan data penjualan, filter search
  const rows = useMemo(() => {
    const all = extras.flatMap(e =>
      (e.menu_extra_options ?? []).map(o => ({
        extra_id: e.id,
        extra_name: e.name,
        option_id: o.id,
        option_name: o.name,
        option_price: o.price,
        qty: salesMap.get(o.id)?.qty ?? 0,
        revenue: salesMap.get(o.id)?.revenue ?? 0,
      }))
    )
    if (!search.trim()) return all
    const q = search.toLowerCase()
    return all.filter(r =>
      r.extra_name.toLowerCase().includes(q) ||
      r.option_name.toLowerCase().includes(q)
    )
  }, [extras, salesMap, search])

  const totals = useMemo(() => ({
    options:  extras.reduce((s, e) => s + (e.menu_extra_options?.length ?? 0), 0),
    qty:      rows.reduce((s, r) => s + r.qty, 0),
    revenue:  rows.reduce((s, r) => s + r.revenue, 0),
  }), [extras, rows])

  const hasSalesData = totals.qty > 0

  return (
    <>
      {/* Stat cards */}
      <div className="grid grid-cols-2 sm:grid-cols-3 gap-3 mb-4">
        <StatCard label="Total Sub Extra"    value={totals.options.toLocaleString('id-ID')} accent={ACCENT[0]} />
        <StatCard label="Total Dipilih"      value={totals.qty.toLocaleString('id-ID')}    accent={ACCENT[1]} />
        <StatCard label="Total Penjualan"    value={formatCurrency(totals.revenue)}         accent={ACCENT[2]} />
      </div>

      {/* Info jika belum ada data transaksi */}
      {!hasSalesData && !isLoading && (
        <div className="flex items-start gap-3 rounded-xl border border-blue-200 bg-blue-50 p-4 text-sm text-blue-800 mb-4">
          <Info className="h-4 w-4 shrink-0 mt-0.5" />
          <p>
            <span className="font-semibold">Belum ada data penjualan sub extra.</span>{' '}
            Data akan muncul setelah pelanggan memilih opsi extra saat memesan.
            Tabel berikut menampilkan semua opsi yang dikonfigurasi.
          </p>
        </div>
      )}

      {isLoading ? <TableSkeleton cols={6} /> : rows.length === 0 ? <Empty /> : (
        <div className="bg-white rounded-xl border border-gray-100 shadow-sm overflow-hidden">
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b bg-gray-50">
                  <th className="text-left px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider whitespace-nowrap">Extra</th>
                  <th className="text-left px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider whitespace-nowrap">Sub Extra</th>
                  <th className="text-right px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider whitespace-nowrap">Harga</th>
                  <th className="text-right px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider whitespace-nowrap">Jumlah</th>
                  <th className="text-right px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider whitespace-nowrap">Jumlah %</th>
                  <th className="text-right px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider whitespace-nowrap">Penjualan (Rp)</th>
                  <th className="text-right px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider whitespace-nowrap">Penjualan %</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r, i) => {
                  const qtyPct  = totals.qty > 0 ? (r.qty / totals.qty * 100).toFixed(2) : '0.00'
                  const revPct  = totals.revenue > 0 ? (r.revenue / totals.revenue * 100).toFixed(2) : '0.00'
                  return (
                    <tr key={`${r.extra_id}-${r.option_id}`}
                        className={`border-b last:border-0 hover:bg-gray-50/60 transition-colors ${i % 2 !== 0 ? 'bg-gray-50/30' : ''}`}>
                      <td className="px-5 py-3.5 font-medium text-gray-800 whitespace-nowrap">{r.extra_name}</td>
                      <td className="px-5 py-3.5 text-gray-700 whitespace-nowrap">{r.option_name}</td>
                      <td className="px-5 py-3.5 text-right text-gray-500">
                        {r.option_price > 0 ? <CurrencyDisplay value={r.option_price} /> : '—'}
                      </td>
                      <td className="px-5 py-3.5 text-right font-medium text-gray-900">{r.qty.toLocaleString('id-ID')}</td>
                      <td className="px-5 py-3.5 text-right text-gray-500">{qtyPct}%</td>
                      <td className="px-5 py-3.5 text-right font-medium text-gray-900">
                        <CurrencyDisplay value={r.revenue} />
                      </td>
                      <td className="px-5 py-3.5 text-right text-gray-500">{revPct}%</td>
                    </tr>
                  )
                })}
              </tbody>
              <tfoot>
                <tr className="border-t-2 bg-gray-50">
                  <td colSpan={3} className="px-5 py-3 font-bold text-gray-900">Total</td>
                  <td className="px-5 py-3 text-right font-bold text-gray-900">{totals.qty.toLocaleString('id-ID')}</td>
                  <td className="px-5 py-3 text-right font-bold text-gray-900">100%</td>
                  <td className="px-5 py-3 text-right font-bold text-gray-900"><CurrencyDisplay value={totals.revenue} /></td>
                  <td className="px-5 py-3 text-right font-bold text-gray-900">100%</td>
                </tr>
              </tfoot>
            </table>
          </div>
        </div>
      )}
    </>
  )
}

// ── Shared helpers untuk Pajak + Service tabs ─────────────────────────────────

type PeriodMode = 'hari' | 'bulan' | 'tahun'

type GroupedTaxRow = {
  key: string; label: string
  total_orders: number; gross_revenue: number
  total_tax: number; total_service_charge: number; net_revenue: number
}

function groupTaxData(data: { sale_date: string; total_orders: number; gross_revenue: number; total_tax: number; total_service_charge: number; net_revenue: number }[], period: PeriodMode): GroupedTaxRow[] {
  if (period === 'hari') {
    return data.map((r) => ({ key: r.sale_date, label: fmtDate(r.sale_date), ...r }))
  }
  const map = new Map<string, GroupedTaxRow>()
  for (const r of data) {
    const key = period === 'bulan'
      ? format(new Date(r.sale_date), 'yyyy-MM')
      : format(new Date(r.sale_date), 'yyyy')
    const label = period === 'bulan'
      ? format(new Date(r.sale_date), 'MMMM yyyy', { locale: localeId })
      : format(new Date(r.sale_date), 'yyyy')
    const ex = map.get(key)
    if (ex) {
      ex.total_orders         += r.total_orders
      ex.gross_revenue        += r.gross_revenue
      ex.total_tax            += r.total_tax
      ex.total_service_charge += r.total_service_charge
      ex.net_revenue          += r.net_revenue
    } else {
      map.set(key, { key, label, ...r })
    }
  }
  return [...map.values()].sort((a, b) => b.key.localeCompare(a.key))
}

// ── Tab: Pajak ────────────────────────────────────────────────────────────────

function PajakTab({
  outletId, dateFrom, dateTo, period,
}: { outletId: string; dateFrom: string; dateTo: string; period: PeriodMode }) {
  const { data = [], isLoading } = useTaxReport(outletId, dateFrom, dateTo, period)
  const grouped = useMemo(() => groupTaxData(data, period), [data, period])

  const totals = useMemo(() => ({
    orders: data.reduce((s, r) => s + r.total_orders, 0),
    gross:  data.reduce((s, r) => s + r.gross_revenue, 0),
    tax:    data.reduce((s, r) => s + r.total_tax, 0),
  }), [data])

  return (
    <>
      <div className="grid grid-cols-2 sm:grid-cols-3 gap-3 mb-4">
        <StatCard label="Total Transaksi" value={totals.orders.toLocaleString('id-ID')} accent={ACCENT[0]} />
        <StatCard label="Total Penjualan" value={formatCurrency(totals.gross)}          accent={ACCENT[1]} />
        <StatCard label="Total Pajak"     value={formatCurrency(totals.tax)}            accent={ACCENT[2]} />
      </div>

      {isLoading ? <TableSkeleton cols={4} /> : grouped.length === 0 ? <Empty /> : (
        <div className="bg-white rounded-xl border border-gray-100 shadow-sm overflow-hidden">
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b bg-gray-50">
                  <th className="px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider text-left whitespace-nowrap">Tanggal</th>
                  <th className="px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider text-right whitespace-nowrap">Transaksi</th>
                  <th className="px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider text-right whitespace-nowrap">Penjualan (Rp)</th>
                  <th className="px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider text-right whitespace-nowrap">Pajak (Rp)</th>
                </tr>
              </thead>
              <tbody>
                {grouped.map((r, i) => (
                  <tr key={r.key} className={`border-b last:border-0 hover:bg-gray-50/60 transition-colors ${i % 2 !== 0 ? 'bg-gray-50/30' : ''}`}>
                    <td className="px-5 py-3.5 whitespace-nowrap font-medium text-gray-800">{r.label}</td>
                    <td className="px-5 py-3.5 text-right text-gray-600">{r.total_orders.toLocaleString('id-ID')}</td>
                    <td className="px-5 py-3.5 text-right text-gray-700"><CurrencyDisplay value={r.gross_revenue} /></td>
                    <td className="px-5 py-3.5 text-right font-semibold text-gray-900"><CurrencyDisplay value={r.total_tax} /></td>
                  </tr>
                ))}
              </tbody>
              <tfoot>
                <tr className="border-t-2 bg-gray-50">
                  <td className="px-5 py-3 font-bold text-gray-900">Total</td>
                  <td className="px-5 py-3 text-right font-bold text-gray-900">{totals.orders.toLocaleString('id-ID')}</td>
                  <td className="px-5 py-3 text-right font-bold text-gray-900"><CurrencyDisplay value={totals.gross} /></td>
                  <td className="px-5 py-3 text-right font-bold text-gray-900"><CurrencyDisplay value={totals.tax} /></td>
                </tr>
              </tfoot>
            </table>
          </div>
        </div>
      )}
    </>
  )
}

// ── Tab: Service Charge ───────────────────────────────────────────────────────

function ServiceChargeTab({
  outletId, dateFrom, dateTo, period,
}: { outletId: string; dateFrom: string; dateTo: string; period: PeriodMode }) {
  const { data = [], isLoading } = useTaxReport(outletId, dateFrom, dateTo, period)
  const grouped = useMemo(() => groupTaxData(data, period), [data, period])

  const totals = useMemo(() => ({
    orders:  data.reduce((s, r) => s + r.total_orders, 0),
    gross:   data.reduce((s, r) => s + r.gross_revenue, 0),
    service: data.reduce((s, r) => s + r.total_service_charge, 0),
  }), [data])

  return (
    <>
      <div className="grid grid-cols-2 sm:grid-cols-3 gap-3 mb-4">
        <StatCard label="Total Transaksi"      value={totals.orders.toLocaleString('id-ID')} accent={ACCENT[0]} />
        <StatCard label="Total Penjualan"      value={formatCurrency(totals.gross)}           accent={ACCENT[1]} />
        <StatCard label="Total Service Charge" value={formatCurrency(totals.service)}         accent={ACCENT[4]} />
      </div>

      {isLoading ? <TableSkeleton cols={4} /> : grouped.length === 0 ? <Empty /> : (
        <div className="bg-white rounded-xl border border-gray-100 shadow-sm overflow-hidden">
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b bg-gray-50">
                  <th className="px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider text-left whitespace-nowrap">Tanggal</th>
                  <th className="px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider text-right whitespace-nowrap">Transaksi</th>
                  <th className="px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider text-right whitespace-nowrap">Penjualan (Rp)</th>
                  <th className="px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider text-right whitespace-nowrap">Service Charge (Rp)</th>
                </tr>
              </thead>
              <tbody>
                {grouped.map((r, i) => (
                  <tr key={r.key} className={`border-b last:border-0 hover:bg-gray-50/60 transition-colors ${i % 2 !== 0 ? 'bg-gray-50/30' : ''}`}>
                    <td className="px-5 py-3.5 whitespace-nowrap font-medium text-gray-800">{r.label}</td>
                    <td className="px-5 py-3.5 text-right text-gray-600">{r.total_orders.toLocaleString('id-ID')}</td>
                    <td className="px-5 py-3.5 text-right text-gray-700"><CurrencyDisplay value={r.gross_revenue} /></td>
                    <td className="px-5 py-3.5 text-right font-semibold text-gray-900"><CurrencyDisplay value={r.total_service_charge} /></td>
                  </tr>
                ))}
              </tbody>
              <tfoot>
                <tr className="border-t-2 bg-gray-50">
                  <td className="px-5 py-3 font-bold text-gray-900">Total</td>
                  <td className="px-5 py-3 text-right font-bold text-gray-900">{totals.orders.toLocaleString('id-ID')}</td>
                  <td className="px-5 py-3 text-right font-bold text-gray-900"><CurrencyDisplay value={totals.gross} /></td>
                  <td className="px-5 py-3 text-right font-bold text-gray-900"><CurrencyDisplay value={totals.service} /></td>
                </tr>
              </tfoot>
            </table>
          </div>
        </div>
      )}
    </>
  )
}

// ── Main Page ─────────────────────────────────────────────────────────────────

export default function SalesBreakdownReport() {
  const { activeOutletId, activeOutlet } = useOutlet()
  const { tab = 'departemen' } = useParams<{ tab: TabSlug }>()
  const [range,  setRange]  = useState<DateRange>(defaultRange)
  const [search, setSearch] = useState('')
  const [period, setPeriod] = useState<PeriodMode>('hari')

  useEffect(() => {
    window.scrollTo({ top: 0, left: 0, behavior: 'auto' })
  }, [tab])

  const dateFrom = format(startOfDay(range.from), 'yyyy-MM-dd')
  const dateTo   = format(endOfDay(range.to),     'yyyy-MM-dd')

  // Fetch current tab data at page level — React Query caches so tabs don't double-fetch
  const { data: deptData   = [] } = useDepartmentFinancialReconciliation(tab === 'departemen' ? activeOutletId : null, dateFrom, dateTo)
  const { data: catData    = [] } = useCategorySalesRange(tab === 'kategori'   ? activeOutletId : null, dateFrom, dateTo)
  const { data: menuData   = [] } = useMenuSales(tab === 'menu'        ? activeOutletId : null, dateFrom, dateTo)
  const { data: taxData    = [] } = useTaxReport(
    (tab === 'pajak' || tab === 'service') ? activeOutletId : null, dateFrom, dateTo, period
  )
  const { data: uniqueOrderData = [] } = useTaxReport(
    (tab === 'departemen' || tab === 'kategori' || tab === 'menu') ? activeOutletId : null,
    dateFrom,
    dateTo,
    'hari',
  )
  const { data: extrasData = [] } = useExtras(
    tab === 'extra' || tab === 'sub-extra' ? (activeOutletId ?? '') : ''
  )
  const { data: extraSalesData = [] } = useExtraOptionSales(
    (tab === 'extra' || tab === 'sub-extra') ? activeOutletId : null, dateFrom, dateTo
  )

  if (!(tab in TAB_LABELS)) {
    return <Navigate to="/admin/sales-breakdown/departemen" replace />
  }
  if (!activeOutletId) return <NoOutlet />

  const tabLabel    = TAB_LABELS[tab as TabSlug] ?? 'Laporan'
  const outletName  = activeOutlet?.name ?? 'Semua Outlet'
  const periodLabel = fmtRange(range.from, range.to)
  const uniqueOrderCount = uniqueOrderData.reduce((sum, row) => sum + row.total_orders, 0)

  // ── Build export config per tab ───────────────────────────────────────────
  type ExportDef = { headers: string[]; rows: (string | number)[][]; stats: { label: string; value: string }[] }

  function buildExportDef(): ExportDef | null {
    if (tab === 'departemen' && deptData.length) {
      const total  = deptData.reduce((s, r) => s + r.net_receipts, 0)
      const subtotal = deptData.reduce((s, r) => s + r.subtotal, 0)
      const refund = deptData.reduce((s, r) => s + r.refund_amount, 0)
      const qty    = deptData.reduce((s, r) => s + r.qty_sold,     0)
      return {
        headers: ['Departemen', 'Transaksi pada Grup', 'Qty Tercatat', 'Subtotal', 'Diskon & Penukaran Poin', 'Pajak dalam Harga (Informasi)', 'Pajak Tambahan pada Tagihan', 'Biaya Layanan', 'Selisih Tagihan', 'Refund', 'Penyesuaian Lain', 'Penerimaan dari Pelanggan'],
        rows: deptData.map(r => [
          departmentDisplayName(r.department_name),
          r.department_name === 'Penyesuaian / Belum Terdistribusi' ? '—' : r.total_orders,
          r.department_name === 'Penyesuaian / Belum Terdistribusi' ? '—' : r.qty_sold,
          formatCurrency(r.subtotal), formatCurrency(r.discount_amount),
          r.department_name === 'Penyesuaian / Belum Terdistribusi' ? '—' : formatCurrency(r.tax_inclusive),
          r.department_name === 'Penyesuaian / Belum Terdistribusi' ? '—' : formatCurrency(r.tax_exclusive),
          formatCurrency(r.service_charge), formatCurrency(r.rounding_amount),
          formatCurrency(r.refund_amount), formatCurrency(r.unallocated_adjustment),
          formatCurrency(r.net_receipts),
        ]),
        stats: [
          { label: 'Subtotal Penjualan', value: formatCurrency(subtotal) },
          { label: 'Total Penerimaan', value: formatCurrency(total) },
          { label: 'Total Refund', value: formatCurrency(refund) },
          { label: 'Total Qty Tercatat (detail tersedia)', value: qty.toLocaleString('id-ID') },
          { label: 'Jumlah Transaksi', value: uniqueOrderCount.toLocaleString('id-ID') },
          { label: 'Dasar Periode', value: 'Tanggal transaksi (WIB); refund mengikuti transaksi asal.' },
          { label: 'Penerimaan', value: 'Termasuk pajak dan biaya layanan; bukan laba usaha.' },
          { label: 'Subtotal', value: 'Sebelum diskon dan refund; pajak dalam harga sudah tercakup.' },
          { label: 'Selisih Tagihan', value: 'Selisih total tersimpan dengan komponen, termasuk pembulatan bila ada.' },
          { label: 'Cakupan', value: 'Termasuk pembatalan yang memiliki pembayaran. Qty mengikuti pengurangan qty refund tercatat.' },
          { label: 'Penyesuaian Lain', value: 'Nilai historis yang belum dapat dirinci. Rincian qty dan pajak pada baris belum dialokasikan tidak tersedia.' },
        ],
      }
    }
    if (tab === 'kategori' && catData.length) {
      const total  = catData.reduce((s, r) => s + r.total_revenue, 0)
      const qty    = catData.reduce((s, r) => s + r.qty_sold,     0)
      return {
        headers: ['Kategori', 'Qty Terjual', 'Transaksi pada Grup', 'Revenue'],
        rows: catData.map(r => [r.category_name ?? '—', r.qty_sold, r.total_orders ?? 0, formatCurrency(r.total_revenue)]),
        stats: [
          { label: 'Total Pendapatan', value: formatCurrency(total) },
          { label: 'Item Terjual',     value: qty.toLocaleString('id-ID') },
          { label: 'Transaksi Unik',   value: uniqueOrderCount.toLocaleString('id-ID') },
        ],
      }
    }
    if (tab === 'menu' && menuData.length) {
      const total  = menuData.reduce((s, r) => s + r.total_revenue, 0)
      const qty    = menuData.reduce((s, r) => s + r.qty_sold,     0)
      return {
        headers: ['Menu', 'Kategori', 'Qty Terjual', 'Order pada Menu', 'Revenue'],
        rows: menuData.map(r => [r.menu_name, r.category_name ?? '—', r.qty_sold, r.order_count, formatCurrency(r.total_revenue)]),
        stats: [
          { label: 'Total Pendapatan', value: formatCurrency(total) },
          { label: 'Item Terjual',     value: qty.toLocaleString('id-ID') },
          { label: 'Transaksi Unik',   value: uniqueOrderCount.toLocaleString('id-ID') },
        ],
      }
    }
    if (tab === 'extra' && extrasData.length) {
      const rows = buildExtraSalesRows(extrasData, extraSalesData)
      const totalQty = rows.reduce((sum, row) => sum + row.qty, 0)
      const totalRevenue = rows.reduce((sum, row) => sum + row.revenue, 0)
      const totalRefund = rows.reduce((sum, row) => sum + row.refundAmount, 0)
      return {
        headers: ['Nama Extra', 'Jumlah', 'Jumlah (%)', 'Penjualan (Rp)', 'Penjualan (%)', 'Laba Kotor (Rp)', 'Laba Kotor (%)', 'Jumlah Refund', 'Refund (Rp)'],
        rows: rows.map((row) => [
          row.name,
          row.qty,
          `${totalQty > 0 ? (row.qty / totalQty * 100).toFixed(2) : '0.00'}%`,
          formatCurrency(row.revenue),
          `${totalRevenue > 0 ? (row.revenue / totalRevenue * 100).toFixed(2) : '0.00'}%`,
          formatCurrency(row.grossProfit),
          `${totalRevenue > 0 ? (row.grossProfit / totalRevenue * 100).toFixed(2) : '0.00'}%`,
          row.refundQty,
          formatCurrency(row.refundAmount),
        ]),
        stats: [
          { label: 'Total Extra', value: rows.length.toLocaleString('id-ID') },
          { label: 'Total Item Extra', value: totalQty.toLocaleString('id-ID') },
          { label: 'Rincian Extra (sudah termasuk dalam pendapatan produk)', value: formatCurrency(totalRevenue) },
          { label: 'Total Refund Extra', value: formatCurrency(totalRefund) },
        ],
      }
    }
    if (tab === 'sub-extra' && extrasData.length) {
      const salesMap = new Map<string, { qty: number; revenue: number }>()
      for (const sale of extraSalesData) {
        const current = salesMap.get(sale.option_id)
        if (current) {
          current.qty += sale.qty_selected
          current.revenue += Number(sale.total_revenue)
        } else {
          salesMap.set(sale.option_id, {
            qty: sale.qty_selected,
            revenue: Number(sale.total_revenue),
          })
        }
      }
      const rows = extrasData.flatMap((extra) =>
        (extra.menu_extra_options ?? []).map((option) => {
          const sale = salesMap.get(option.id)
          return [
            extra.name,
            option.name,
            formatCurrency(option.price),
            sale?.qty ?? 0,
            formatCurrency(sale?.revenue ?? 0),
          ]
        })
      )
      const totalQty = rows.reduce((sum, row) => sum + Number(row[3]), 0)
      const totalRevenue = [...salesMap.values()].reduce((sum, sale) => sum + sale.revenue, 0)
      return {
        headers: ['Extra', 'Sub Extra', 'Harga', 'Jumlah', 'Penjualan'],
        rows,
        stats: [
          { label: 'Total Sub Extra', value: rows.length.toLocaleString('id-ID') },
          { label: 'Total Dipilih', value: totalQty.toLocaleString('id-ID') },
          { label: 'Total Penjualan', value: formatCurrency(totalRevenue) },
        ],
      }
    }
    if (tab === 'pajak' && taxData.length) {
      const totalOrders = taxData.reduce((s, r) => s + r.total_orders, 0)
      const totalGross  = taxData.reduce((s, r) => s + r.gross_revenue, 0)
      const totalTax    = taxData.reduce((s, r) => s + r.total_tax, 0)
      return {
        headers: ['Tanggal', 'Transaksi', 'Total Penjualan (Rp)', 'Pajak (Rp)'],
        rows: taxData.map(r => [r.sale_date, r.total_orders, formatCurrency(r.gross_revenue), formatCurrency(r.total_tax)]),
        stats: [
          { label: 'Total Transaksi', value: totalOrders.toLocaleString('id-ID') },
          { label: 'Total Penjualan', value: formatCurrency(totalGross) },
          { label: 'Total Pajak',     value: formatCurrency(totalTax) },
        ],
      }
    }
    if (tab === 'service' && taxData.length) {
      const totalOrders  = taxData.reduce((s, r) => s + r.total_orders, 0)
      const totalGross   = taxData.reduce((s, r) => s + r.gross_revenue, 0)
      const totalService = taxData.reduce((s, r) => s + r.total_service_charge, 0)
      return {
        headers: ['Tanggal', 'Transaksi', 'Total Penjualan (Rp)', 'Service Charge (Rp)'],
        rows: taxData.map(r => [r.sale_date, r.total_orders, formatCurrency(r.gross_revenue), formatCurrency(r.total_service_charge)]),
        stats: [
          { label: 'Total Transaksi',      value: totalOrders.toLocaleString('id-ID') },
          { label: 'Total Penjualan',      value: formatCurrency(totalGross) },
          { label: 'Total Service Charge', value: formatCurrency(totalService) },
        ],
      }
    }
    return null
  }

  async function handleExcel() {
    const def = buildExportDef(); if (!def) return
    exportReportExcel({ title: `Laporan ${tabLabel}`, outletName, period: periodLabel, periodView: (tab === 'pajak' || tab === 'service') ? periodLabel : undefined, summaryStats: def.stats, tableHeaders: def.headers, tableRows: def.rows, filename: `laporan-${tab}-${dateFrom}.xls` })
  }

  async function handlePDF() {
    const def = buildExportDef(); if (!def) return
    await exportReportPDF({ title: `Laporan ${tabLabel}`, outletName, period: periodLabel, periodView: (tab === 'pajak' || tab === 'service') ? periodLabel : undefined, summaryStats: def.stats, tableHeaders: def.headers, tableRows: def.rows, filename: `laporan-${tab}-${dateFrom}.pdf` })
  }

  return (
    <div className="min-h-screen bg-gray-50/50">
      {/* ── Page Header ── */}
      <div className="bg-white border-b border-gray-100 px-4 sm:px-6 pt-4 pb-3">
        <div className="flex flex-wrap items-start justify-between gap-y-3">
          <div>
            <h1 className="text-xl font-bold text-gray-900">{tab === 'extra' ? 'Penjualan Extra' : `Laporan ${tabLabel}`}</h1>
            <p className="text-sm text-muted-foreground mt-0.5">
              {fmtRange(range.from, range.to)}
            </p>
          </div>
          <ExportBar
            onExcel={handleExcel}
            onPDF={handlePDF}
            disabled={buildExportDef() === null}
          />
        </div>

      </div>

      {/* Filter bar */}
      <div className={`${tab === 'departemen' ? 'sticky top-0 z-30 shadow-sm' : ''} mb-5 flex w-full flex-wrap items-center gap-3 border-b border-gray-200 bg-white px-4 py-3 sm:px-6`}>
          <div className="relative flex-1 max-w-xs">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground" />
            <Input
              className="pl-9 h-9 bg-gray-50 border-gray-200 text-sm"
              placeholder="Cari..."
              value={search}
              onChange={e => setSearch(e.target.value)}
            />
          </div>
          <DateRangePicker value={range} onChange={setRange} />
          {(tab === 'pajak' || tab === 'service') && (
            <div className="ml-auto flex rounded-lg overflow-hidden border border-gray-200 shrink-0">
              {(['hari', 'bulan', 'tahun'] as PeriodMode[]).map((p) => (
                <button
                  key={p}
                  type="button"
                  onClick={() => setPeriod(p)}
                  aria-pressed={period === p}
                  className={`px-4 py-2 text-sm font-medium capitalize transition-colors ${period === p ? 'bg-primary text-primary-foreground' : 'bg-white text-gray-600 hover:bg-gray-50'}`}
                >
                  {p.charAt(0).toUpperCase() + p.slice(1)}
                </button>
              ))}
            </div>
          )}
      </div>

      {/* ── Content ── */}
      <div className="scroll-mt-20 px-4 pt-1 pb-8 sm:px-6">
        {tab === 'departemen' && (
          <DepartemenTab outletId={activeOutletId} dateFrom={dateFrom} dateTo={dateTo} search={search} uniqueOrders={uniqueOrderCount} />
        )}
        {tab === 'kategori' && (
          <KategoriTab outletId={activeOutletId} dateFrom={dateFrom} dateTo={dateTo} search={search} uniqueOrders={uniqueOrderCount} />
        )}
        {tab === 'menu' && (
          <MenuTab outletId={activeOutletId} dateFrom={dateFrom} dateTo={dateTo} search={search} uniqueOrders={uniqueOrderCount} />
        )}
        {tab === 'extra' && (
          <ExtraTab outletId={activeOutletId} dateFrom={dateFrom} dateTo={dateTo} search={search} />
        )}
        {tab === 'sub-extra' && (
          <SubExtraTab outletId={activeOutletId} dateFrom={dateFrom} dateTo={dateTo} search={search} />
        )}
        {tab === 'pajak' && (
          <PajakTab outletId={activeOutletId} dateFrom={dateFrom} dateTo={dateTo} period={period} />
        )}
        {tab === 'service' && (
          <ServiceChargeTab outletId={activeOutletId} dateFrom={dateFrom} dateTo={dateTo} period={period} />
        )}
      </div>
    </div>
  )
}
