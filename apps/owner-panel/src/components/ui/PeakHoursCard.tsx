import { useState, useMemo } from 'react'
import { subDays, format } from 'date-fns'
import { id as localeId } from 'date-fns/locale'
import { BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, Cell } from 'recharts'
import { usePeakHours } from '@/hooks/queries/useSales'
import { Skeleton } from '@/components/ui/skeleton'
import { cn } from '@/lib/utils'

type PeakFilter = 'today' | '7d' | '30d'

const FILTER_LABELS: Record<PeakFilter, string> = {
  today: 'Hari Ini',
  '7d': '7 Hari',
  '30d': '30 Hari',
}

export function PeakHoursCard({ outletId }: { outletId: string | null }) {
  const [filter, setFilter] = useState<PeakFilter>('7d')

  const { dateFrom, dateTo } = useMemo(() => {
    const now = new Date()
    const today = format(now, 'yyyy-MM-dd')
    if (filter === 'today') return { dateFrom: today, dateTo: today }
    if (filter === '7d') return { dateFrom: format(subDays(now, 6), 'yyyy-MM-dd'), dateTo: today }
    return { dateFrom: format(subDays(now, 29), 'yyyy-MM-dd'), dateTo: today }
  }, [filter])

  const periodLabel = useMemo(() => {
    const f = new Date(dateFrom), t = new Date(dateTo)
    return filter === 'today'
      ? format(t, 'EEEE, d MMM yyyy', { locale: localeId })
      : `${format(f, 'd MMM', { locale: localeId })} – ${format(t, 'd MMM yyyy', { locale: localeId })}`
  }, [filter, dateFrom, dateTo])

  const { data: peakData = [], isLoading } = usePeakHours(outletId, dateFrom, dateTo)

  const chartData = useMemo(() => {
    const map: Record<number, number> = {}
    peakData.forEach((d) => { map[d.hour_of_day] = (map[d.hour_of_day] ?? 0) + d.total_orders })
    return Array.from({ length: 24 }, (_, h) => ({
      hour: h,
      label: `${h.toString().padStart(2, '0')}`,
      orders: map[h] ?? 0,
    }))
  }, [peakData])

  const top3 = useMemo(
    () => [...chartData].sort((a, b) => b.orders - a.orders).slice(0, 3).map((d) => d.hour),
    [chartData]
  )

  const hasData = chartData.some((d) => d.orders > 0)

  return (
    <div className="rounded-xl border bg-white shadow-sm flex flex-col col-span-2">
      <div className="px-4 pt-4 pb-2 flex items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="font-bold text-sm">Jam Ramai</p>
          <p className="text-[11px] text-muted-foreground truncate">{periodLabel}</p>
        </div>
        <div className="flex border rounded-md overflow-hidden text-xs shrink-0">
          {(Object.keys(FILTER_LABELS) as PeakFilter[]).map((f) => (
              <button
                key={f}
                type="button"
                onClick={() => setFilter(f)}
                aria-pressed={filter === f}
              className={cn(
                'px-2.5 py-1 font-medium transition-colors',
                filter === f ? 'bg-primary text-white' : 'text-muted-foreground hover:bg-muted'
              )}
            >
              {FILTER_LABELS[f]}
            </button>
          ))}
        </div>
      </div>

      <div className="flex-1 px-4 pb-1">
        {isLoading ? (
          <Skeleton className="h-28 w-full" />
        ) : !hasData ? (
          <div className="h-28 flex items-center justify-center">
            <p className="text-xs text-muted-foreground">Belum ada data transaksi</p>
          </div>
        ) : (
          <ResponsiveContainer width="100%" height={112}>
            <BarChart data={chartData} margin={{ left: -20, right: 4, top: 4 }} barSize={8}>
              <XAxis
                dataKey="label"
                tick={{ fontSize: 9 }}
                axisLine={false}
                tickLine={false}
                interval={3}
              />
              <YAxis hide />
              <Tooltip
                formatter={(v) => [`${v} pesanan`, 'Pesanan']}
                contentStyle={{ fontSize: 11, borderRadius: 6 }}
                labelFormatter={(l) => `Jam ${l}:00`}
              />
              <Bar dataKey="orders" radius={[2, 2, 0, 0]}>
                {chartData.map((entry) => (
                  <Cell
                    key={entry.hour}
                    fill={top3.includes(entry.hour) ? 'hsl(var(--primary))' : '#e2e8f0'}
                  />
                ))}
              </Bar>
            </BarChart>
          </ResponsiveContainer>
        )}
        {hasData && !isLoading && (
          <p className="text-xs text-muted-foreground mt-0.5">
            Jam tersibuk:{' '}
            {top3
              .sort((a, b) => a - b)
              .map((h) => `${h.toString().padStart(2, '0')}:00`)
              .join(', ')}
          </p>
        )}
      </div>
    </div>
  )
}
