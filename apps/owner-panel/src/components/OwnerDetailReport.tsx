import { useNavigate } from 'react-router'
import { format } from 'date-fns'
import { id as localeId } from 'date-fns/locale'
import { ArrowLeft, Download, FileText } from 'lucide-react'
import { PageHeader } from '@/components/ui/PageHeader'
import { Button } from '@/components/ui/button'
import { DateRangePicker, type DateRange } from '@/components/ui/DateRangePicker'
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from '@/components/ui/select'
import { Skeleton } from '@/components/ui/skeleton'
import { exportReportCSV, exportReportExcel, exportReportPDF } from '@/utils/exportReport'

export interface OwnerOutlet {
  id: string
  name: string
}

interface OwnerDetailReportProps {
  title: string
  subtitle?: string
  range: DateRange
  onRangeChange: (r: DateRange) => void
  outletId: string | null
  onOutletChange: (id: string | null) => void
  outlets: OwnerOutlet[]
  summaryStats: { label: string; value: string }[]
  headers: string[]
  rows: (string | number)[][]
  /** Index kolom yang rata-kanan (angka/mata uang). Default: semua kecuali kolom pertama. */
  numericCols?: number[]
  loading?: boolean
  filename: string
  emptyText?: string
}

function ExportBar({ onCSV, onExcel, onPDF, disabled }: {
  onCSV: () => void; onExcel: () => void; onPDF: () => void; disabled?: boolean
}) {
  return (
    <div className="inline-flex items-center gap-0.5 rounded-lg border bg-white px-1.5 py-1 shadow-sm">
      <span className="text-[11px] font-medium text-muted-foreground px-1.5">Ekspor</span>
      <div className="w-px h-4 bg-border mx-0.5" />
      <Button variant="ghost" size="sm" className="h-7 px-2.5 text-xs gap-1.5 rounded-md" onClick={onCSV} disabled={disabled}>
        <Download className="h-3.5 w-3.5" /> CSV
      </Button>
      <Button variant="ghost" size="sm" className="h-7 px-2.5 text-xs gap-1.5 rounded-md" onClick={onExcel} disabled={disabled}>
        <FileText className="h-3.5 w-3.5" /> Excel
      </Button>
      <Button variant="ghost" size="sm" className="h-7 px-2.5 text-xs gap-1.5 rounded-md" onClick={onPDF} disabled={disabled}>
        <FileText className="h-3.5 w-3.5" /> PDF
      </Button>
    </div>
  )
}

export function OwnerDetailReport({
  title, subtitle, range, onRangeChange, outletId, onOutletChange, outlets,
  summaryStats, headers, rows, numericCols, loading, filename, emptyText,
}: OwnerDetailReportProps) {
  const navigate = useNavigate()
  const fmt = (d: Date) => format(d, 'd MMM yyyy', { locale: localeId })
  const period = `${fmt(range.from)} – ${fmt(range.to)}`
  const outletName = outletId ? (outlets.find((o) => o.id === outletId)?.name ?? 'Outlet') : 'Semua Outlet'
  const isNumeric = (i: number) => numericCols ? numericCols.includes(i) : i > 0

  const exportCfg = () => ({
    title, outletName, period, summaryStats,
    tableHeaders: headers, tableRows: rows,
    filename: `${filename}-${format(range.from, 'yyyyMMdd')}`,
  })

  return (
    <div className="space-y-4">
      <PageHeader title={title} subtitle={subtitle}>
        <ExportBar
          onCSV={() => exportReportCSV(exportCfg())}
          onExcel={() => exportReportExcel(exportCfg())}
          onPDF={() => { void exportReportPDF(exportCfg()) }}
          disabled={loading || rows.length === 0}
        />
      </PageHeader>

      <div className="flex flex-wrap items-center gap-2">
        <Button variant="outline" size="sm" onClick={() => navigate(-1)} className="gap-1.5">
          <ArrowLeft className="h-3.5 w-3.5" /> Kembali
        </Button>
        <Select value={outletId ?? 'all'} onValueChange={(v) => onOutletChange(v === 'all' ? null : v)}>
          <SelectTrigger className="w-48"><SelectValue placeholder="Semua Outlet" /></SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Semua Outlet</SelectItem>
            {outlets.map((o) => <SelectItem key={o.id} value={o.id}>{o.name}</SelectItem>)}
          </SelectContent>
        </Select>
        <DateRangePicker value={range} onChange={onRangeChange} />
      </div>

      {summaryStats.length > 0 && (
        <div className="grid gap-3 grid-cols-2 sm:grid-cols-3 lg:grid-cols-4">
          {summaryStats.map((s) => (
            <div key={s.label} className="bg-white rounded-xl border border-gray-100 shadow-sm p-4">
              <p className="text-xs text-muted-foreground mb-1 truncate">{s.label}</p>
              {loading
                ? <Skeleton className="h-6 w-24 mt-1" />
                : <p className="text-xl font-bold text-gray-900 truncate">{s.value}</p>}
            </div>
          ))}
        </div>
      )}

      <div className="bg-white rounded-xl border border-gray-100 shadow-sm overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b bg-gray-50/60">
                {headers.map((h, i) => (
                  <th key={h} className={`px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider ${isNumeric(i) ? 'text-right' : 'text-left'}`}>
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {loading ? (
                Array.from({ length: 5 }).map((_, r) => (
                  <tr key={r} className="border-b last:border-0">
                    {headers.map((_, c) => (
                      <td key={c} className="px-5 py-3"><Skeleton className="h-4 w-20" /></td>
                    ))}
                  </tr>
                ))
              ) : rows.length === 0 ? (
                <tr>
                  <td colSpan={headers.length} className="px-5 py-16 text-center text-muted-foreground">
                    {emptyText ?? 'Tidak ada data untuk periode ini.'}
                  </td>
                </tr>
              ) : (
                rows.map((row, r) => (
                  <tr key={r} className="border-b last:border-0 hover:bg-gray-50/50">
                    {row.map((cell, c) => (
                      <td key={c} className={`px-5 py-3 ${isNumeric(c) ? 'text-right tabular-nums' : 'text-left'} ${c === 0 ? 'font-medium text-gray-900' : 'text-gray-700'}`}>
                        {cell}
                      </td>
                    ))}
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  )
}
