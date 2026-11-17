import { useMemo, useState } from 'react'
import { format, startOfMonth, endOfDay } from 'date-fns'
import { id } from 'date-fns/locale'
import { Clock } from 'lucide-react'
import { useOutlet } from '@/hooks/useOutlet'
import { useAttendance, type AttendanceRow } from '@/hooks/queries/useAttendance'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { DataTable } from '@/components/ui/DataTable'
import { DateRangePicker, type DateRange } from '@/components/ui/DateRangePicker'
import { Badge } from '@/components/ui/badge'

const ROLE_LABELS: Record<string, string> = {
  owner: 'Owner', admin: 'Admin', manajer: 'Manajer', kasir: 'Kasir', pelanggan: 'Pelanggan',
}
const fmtHours = (h: number) => `${Number(h).toLocaleString('id-ID', { maximumFractionDigits: 1 })} jam`

export default function AttendanceReport() {
  const { activeOutletId } = useOutlet()

  const [dateRange, setDateRange] = useState<DateRange>({
    from: startOfMonth(new Date()),
    to: endOfDay(new Date()),
  })
  const dateFrom = format(dateRange.from, 'yyyy-MM-dd')
  const dateTo = format(dateRange.to, 'yyyy-MM-dd')

  const { data: rows = [], isLoading } = useAttendance(activeOutletId ?? null, dateFrom, dateTo)

  const perStaff = useMemo(() => {
    const map: Record<string, { name: string; role: string; hours: number; sessions: number }> = {}
    for (const r of rows) {
      const k = r.staff_id
      if (!map[k]) map[k] = { name: r.staff_name, role: r.staff_role, hours: 0, sessions: 0 }
      map[k].hours += Number(r.hours || 0)
      map[k].sessions += 1
    }
    return Object.entries(map)
      .map(([staff_id, v]) => ({ staff_id, ...v }))
      .sort((a, b) => b.hours - a.hours)
  }, [rows])

  if (!activeOutletId) return <NoOutlet />

  return (
    <div className="space-y-4">
      <PageHeader title="Absensi Karyawan" subtitle="Jam kerja staf per periode (masuk/pulang)">
        <DateRangePicker value={dateRange} onChange={setDateRange} />
      </PageHeader>

      {/* Rekap per staf */}
      <div className="rounded-xl border">
        <div className="px-4 py-2 text-sm font-medium text-muted-foreground border-b flex items-center gap-2">
          <Clock className="h-4 w-4" /> Total Jam per Karyawan
        </div>
        <DataTable
          data={perStaff}
          loading={isLoading}
          getRowKey={(r) => r.staff_id}
          emptyMessage="Belum ada absensi."
          columns={[
            { key: 'name', header: 'Karyawan', cell: (r) => <span className="font-medium">{r.name}</span> },
            { key: 'role', header: 'Peran', cell: (r) => <Badge variant="outline">{ROLE_LABELS[r.role] ?? r.role}</Badge> },
            { key: 'sessions', header: 'Sesi', className: 'text-right', cell: (r) => r.sessions },
            { key: 'hours', header: 'Total Jam', className: 'text-right', cell: (r) => <span className="font-medium tabular-nums">{fmtHours(r.hours)}</span> },
          ]}
        />
      </div>

      {/* Detail sesi */}
      <DataTable
        data={rows}
        loading={isLoading}
        getRowKey={(r) => r.id}
        emptyMessage="Belum ada absensi."
        columns={[
          { key: 'name', header: 'Karyawan', cell: (r: AttendanceRow) => <span className="font-medium">{r.staff_name}</span> },
          { key: 'in', header: 'Masuk', cell: (r) => format(new Date(r.clock_in), 'dd MMM HH:mm', { locale: id }) },
          { key: 'out', header: 'Pulang', cell: (r) => r.clock_out ? format(new Date(r.clock_out), 'dd MMM HH:mm', { locale: id }) : <Badge className="bg-green-100 text-green-800 border-0">Aktif</Badge> },
          { key: 'hours', header: 'Durasi', className: 'text-right', cell: (r) => <span className="tabular-nums">{fmtHours(r.hours)}</span> },
          { key: 'note', header: 'Catatan', cell: (r) => <span className="text-muted-foreground">{r.note ?? '—'}</span> },
        ]}
      />
    </div>
  )
}
