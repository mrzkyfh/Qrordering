import { useMemo, useState } from 'react'
import { format, startOfMonth, endOfDay } from 'date-fns'
import { id } from 'date-fns/locale'
import { Trash2 } from 'lucide-react'
import { useOutlet } from '@/hooks/useOutlet'
import { useWaste } from '@/hooks/queries/useWaste'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { DataTable } from '@/components/ui/DataTable'
import { DateRangePicker, type DateRange } from '@/components/ui/DateRangePicker'
import { CurrencyDisplay } from '@/components/ui/CurrencyDisplay'
import { Badge } from '@/components/ui/badge'
import type { WasteRow } from '@/hooks/queries/useWaste'

const REASON_LABELS: Record<string, string> = {
  expired: 'Kedaluwarsa', rusak: 'Rusak', tumpah: 'Tumpah/Jatuh', lain: 'Lainnya',
}
const reasonLabel = (r: string | null) => (r ? REASON_LABELS[r] ?? r : '—')
const fmtQty = (n: number) => Number(n).toLocaleString('id-ID', { maximumFractionDigits: 3 })

export default function WasteReport() {
  const { activeOutletId } = useOutlet()

  const [dateRange, setDateRange] = useState<DateRange>({
    from: startOfMonth(new Date()),
    to: endOfDay(new Date()),
  })
  const dateFrom = format(dateRange.from, 'yyyy-MM-dd')
  const dateTo = format(dateRange.to, 'yyyy-MM-dd')

  const { data: rows = [], isLoading } = useWaste(activeOutletId ?? null, dateFrom, dateTo)

  const totalLoss = useMemo(() => rows.reduce((s, r) => s + Number(r.loss_value || 0), 0), [rows])

  const byReason = useMemo(() => {
    const map: Record<string, number> = {}
    for (const r of rows) {
      const k = r.reason ?? 'lain'
      map[k] = (map[k] ?? 0) + Number(r.loss_value || 0)
    }
    return Object.entries(map).sort((a, b) => b[1] - a[1])
  }, [rows])

  if (!activeOutletId) return <NoOutlet />

  return (
    <div className="space-y-4">
      <PageHeader title="Laporan Waste" subtitle="Kerugian bahan baku terbuang per periode">
        <DateRangePicker value={dateRange} onChange={setDateRange} />
      </PageHeader>

      <div className="grid gap-3 sm:grid-cols-3">
        <div className="rounded-xl border p-4">
          <div className="flex items-center gap-2 text-muted-foreground text-sm">
            <Trash2 className="h-4 w-4" /> Total Kerugian
          </div>
          <div className="mt-1 text-2xl font-bold text-destructive">
            <CurrencyDisplay value={totalLoss} />
          </div>
        </div>
        <div className="rounded-xl border p-4">
          <div className="text-sm text-muted-foreground">Jumlah Kejadian</div>
          <div className="mt-1 text-2xl font-bold">{rows.length}</div>
        </div>
        <div className="rounded-xl border p-4">
          <div className="text-sm text-muted-foreground mb-2">Per Alasan</div>
          {byReason.length === 0 ? (
            <span className="text-sm text-muted-foreground">—</span>
          ) : (
            <div className="space-y-1">
              {byReason.map(([k, v]) => (
                <div key={k} className="flex justify-between text-sm">
                  <span>{reasonLabel(k)}</span>
                  <span className="font-medium"><CurrencyDisplay value={v} /></span>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      <DataTable
        data={rows}
        loading={isLoading}
        getRowKey={(r) => r.id}
        emptyMessage="Tidak ada waste pada periode ini."
        columns={[
          {
            key: 'created_at', header: 'Tanggal',
            cell: (r: WasteRow) => format(new Date(r.created_at), 'dd MMM yyyy HH:mm', { locale: id }),
          },
          { key: 'ingredient', header: 'Bahan', cell: (r) => <span className="font-medium">{r.ingredient_name}</span> },
          { key: 'qty', header: 'Jumlah', className: 'text-right', cell: (r) => <span className="tabular-nums">{fmtQty(r.qty)} {r.unit}</span> },
          { key: 'reason', header: 'Alasan', cell: (r) => <Badge variant="outline">{reasonLabel(r.reason)}</Badge> },
          { key: 'loss', header: 'Kerugian', className: 'text-right', cell: (r) => <span className="text-destructive"><CurrencyDisplay value={Number(r.loss_value || 0)} /></span> },
          { key: 'notes', header: 'Catatan', cell: (r) => <span className="text-muted-foreground">{r.notes ?? '—'}</span> },
        ]}
      />
    </div>
  )
}
