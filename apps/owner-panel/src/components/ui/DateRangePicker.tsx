import { useState } from 'react'
import {
  format, startOfDay, endOfDay, addMonths, subMonths, isSameDay,
  isWithinInterval, getDay, getDaysInMonth, isBefore, setHours, setMinutes,
} from 'date-fns'
import { id } from 'date-fns/locale'
import { CalendarIcon, ChevronLeft, ChevronRight, Clock } from 'lucide-react'
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover'
import { Button } from '@/components/ui/button'
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from '@/components/ui/select'
import { cn } from '@/lib/utils'
import {
  getPresetRange,
  type DateRange,
  type PresetKey,
} from '@/lib/dateRange'

export type { DateRange } from '@/lib/dateRange'

const PRESETS: { key: PresetKey; label: string }[] = [
  { key: 'today',     label: 'Hari Ini'       },
  { key: 'yesterday', label: 'Kemarin'        },
  { key: '7d',        label: '7 Hari Terakhir'},
  { key: 'thisWeek',  label: 'Minggu Ini'     },
  { key: 'lastWeek',  label: 'Minggu Lalu'    },
  { key: '30d',       label: '30 Hari Terakhir'},
  { key: 'month',     label: 'Bulan Ini'      },
  { key: 'lastMonth', label: 'Bulan Lalu'     },
]

const DAY_NAMES = ['Min', 'Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab']

function matchPreset(from: Date, to: Date): PresetKey | null {
  for (const p of PRESETS) {
    const r = getPresetRange(p.key)
    if (isSameDay(from, r.from) && isSameDay(to, r.to)) return p.key
  }
  return null
}

function buildWeeks(year: number, month: number): (Date | null)[][] {
  const first = new Date(year, month, 1)
  const startDow = getDay(first)
  const days = getDaysInMonth(first)
  const cells: (Date | null)[] = []
  for (let i = 0; i < startDow; i++) cells.push(null)
  for (let d = 1; d <= days; d++) cells.push(new Date(year, month, d))
  while (cells.length % 7 !== 0) cells.push(null)
  const weeks: (Date | null)[][] = []
  for (let i = 0; i < cells.length; i += 7) weeks.push(cells.slice(i, i + 7))
  return weeks
}

function fmtTime(d: Date) { return format(d, 'HH:mm') }
function applyTime(date: Date, timeStr: string): Date {
  const [h, m] = timeStr.split(':').map(Number)
  return setMinutes(setHours(date, h || 0), m || 0)
}

// ─── Calendar Grid ────────────────────────────────────────────────────────────

function CalendarGrid({
  year, month, draftFrom, draftTo, hoverDate, isSelectingEnd, onDayClick, onDayHover,
}: {
  year: number
  month: number
  draftFrom: Date | null
  draftTo: Date | null
  hoverDate: Date | null
  isSelectingEnd: boolean
  onDayClick: (d: Date) => void
  onDayHover: (d: Date | null) => void
}) {
  const weeks = buildWeeks(year, month)
  const today = new Date()
  const rangeEnd = draftTo ?? (isSelectingEnd && hoverDate ? hoverDate : null)

  function isStart(d: Date) { return draftFrom ? isSameDay(d, draftFrom) : false }
  function isEnd(d: Date)   { return draftTo   ? isSameDay(d, draftTo)   : false }
  function inRange(d: Date) {
    if (!draftFrom || !rangeEnd) return false
    const [lo, hi] = isBefore(draftFrom, rangeEnd) ? [draftFrom, rangeEnd] : [rangeEnd, draftFrom]
    return isWithinInterval(startOfDay(d), { start: startOfDay(lo), end: startOfDay(hi) })
  }

  return (
    <div className="w-[188px]">
      <div className="text-center text-xs font-semibold text-gray-800 mb-1.5 capitalize">
        {format(new Date(year, month, 1), 'MMMM yyyy', { locale: id })}
      </div>
      <div className="grid grid-cols-7">
        {DAY_NAMES.map((n) => (
          <div key={n} className="text-center text-[10px] text-gray-400 font-medium py-0.5">{n}</div>
        ))}
      </div>
      {weeks.map((week, wi) => (
        <div key={wi} className="grid grid-cols-7">
          {week.map((day, di) => {
            if (!day) return <div key={di} className="h-7" />
            const start = isStart(day)
            const end   = isEnd(day)
            const range = inRange(day)
            const isT   = isSameDay(day, today)
            return (
              <button
                type="button"
                key={di}
                aria-label={format(day, 'd MMMM yyyy', { locale: id })}
                aria-pressed={start || end}
                className={cn(
                  'relative flex h-7 items-center justify-center border-0 bg-transparent p-0 select-none',
                  range && !start && !end && 'bg-primary/10',
                  start && (draftTo || (isSelectingEnd && hoverDate)) && 'bg-primary/10 rounded-l-full',
                  end && draftFrom && 'bg-primary/10 rounded-r-full',
                )}
                onClick={() => onDayClick(day)}
                onMouseEnter={() => onDayHover(day)}
                onMouseLeave={() => onDayHover(null)}
              >
                <span className={cn(
                  'flex items-center justify-center w-6 h-6 rounded-full text-xs transition-colors',
                  (start || end) && 'bg-primary text-primary-foreground font-semibold',
                  !start && !end && isT && 'border border-primary text-primary font-medium',
                  !start && !end && !isT && range && 'text-gray-700',
                  !start && !end && !isT && !range && 'text-gray-700 hover:bg-gray-100',
                )}>
                  {format(day, 'd')}
                </span>
              </button>
            )
          })}
        </div>
      ))}
    </div>
  )
}

// ─── DateRangePicker ──────────────────────────────────────────────────────────

export function DateRangePicker({
  value, onChange, className,
}: {
  value: DateRange
  onChange: (range: DateRange) => void
  className?: string
}) {
  const [open, setOpen] = useState(false)

  const [draftFrom, setDraftFrom] = useState<Date>(value.from)
  const [draftTo,   setDraftTo]   = useState<Date>(value.to)
  const [fromTime,  setFromTime]  = useState(fmtTime(value.from))
  const [toTime,    setToTime]    = useState(fmtTime(value.to))
  const [firstClick, setFirstClick] = useState<Date | null>(null)
  const [hoverDate,  setHoverDate]  = useState<Date | null>(null)
  const [leftYear,   setLeftYear]   = useState(value.from.getFullYear())
  const [leftMonth,  setLeftMonth]  = useState(value.from.getMonth())

  const rightYear  = leftMonth === 11 ? leftYear + 1 : leftYear
  const rightMonth = (leftMonth + 1) % 12

  function openPicker() {
    setDraftFrom(value.from)
    setDraftTo(value.to)
    setFromTime(fmtTime(value.from))
    setToTime(fmtTime(value.to))
    setFirstClick(null)
    setHoverDate(null)
    setLeftYear(value.from.getFullYear())
    setLeftMonth(value.from.getMonth())
    setOpen(true)
  }

  function handleDayClick(day: Date) {
    if (firstClick === null) {
      setFirstClick(day)
      setDraftFrom(startOfDay(day))
      setDraftTo(endOfDay(day))
    } else {
      const [lo, hi] = isBefore(day, firstClick) ? [day, firstClick] : [firstClick, day]
      setDraftFrom(startOfDay(lo))
      setDraftTo(endOfDay(hi))
      setFirstClick(null)
      setHoverDate(null)
    }
  }

  function applyPreset(key: PresetKey) {
    const r = getPresetRange(key)
    setDraftFrom(r.from)
    setDraftTo(r.to)
    setFromTime(fmtTime(r.from))
    setToTime(fmtTime(r.to))
    setFirstClick(null)
    setHoverDate(null)
    setLeftYear(r.from.getFullYear())
    setLeftMonth(r.from.getMonth())
  }

  function prevMonth() {
    const p = subMonths(new Date(leftYear, leftMonth, 1), 1)
    setLeftYear(p.getFullYear()); setLeftMonth(p.getMonth())
  }
  function nextMonth() {
    const n = addMonths(new Date(leftYear, leftMonth, 1), 1)
    setLeftYear(n.getFullYear()); setLeftMonth(n.getMonth())
  }

  function handleApply() {
    onChange({ from: applyTime(draftFrom, fromTime), to: applyTime(draftTo, toTime) })
    setOpen(false)
  }

  const activePreset = matchPreset(draftFrom, draftTo)
  const isSelectingEnd = firstClick !== null

  // While selecting end: show firstClick as start, hover as end for preview
  const previewFrom = isSelectingEnd ? firstClick : draftFrom
  const previewTo   = isSelectingEnd ? (hoverDate ?? firstClick) : draftTo

  const label = `${format(value.from, 'd MMM yyyy', { locale: id })} – ${format(value.to, 'd MMM yyyy', { locale: id })}`

  return (
    <Popover open={open} onOpenChange={(o) => { if (o) openPicker(); else setOpen(false) }}>
      <PopoverTrigger asChild>
        <Button variant="outline" size="sm" className={cn('gap-2 font-normal', className)}>
          <CalendarIcon className="h-4 w-4" />
          {label}
        </Button>
      </PopoverTrigger>
      <PopoverContent align="start" className="w-auto p-0 shadow-xl border-gray-200 max-w-[calc(100vw-16px)] overflow-x-auto" sideOffset={6}>
        <div className="flex min-w-max">
          {/* Left: Presets */}
          <div className="w-36 border-r border-gray-100 py-2 px-1.5 space-y-0.5">
            {PRESETS.map((p) => (
              <button
                type="button"
                key={p.key}
                onClick={() => applyPreset(p.key)}
                className={cn(
                  'w-full text-left px-2.5 py-1.5 rounded-md text-xs transition-colors',
                  activePreset === p.key
                    ? 'bg-primary text-primary-foreground font-medium'
                    : 'text-gray-700 hover:bg-gray-100',
                )}
              >
                {p.label}
              </button>
            ))}
          </div>

          {/* Middle: Calendar */}
          <div className="px-3 py-3">
            <div className="flex items-center mb-2">
              <button
                type="button"
                onClick={prevMonth}
                aria-label="Bulan sebelumnya"
                className="p-0.5 rounded hover:bg-gray-100 text-gray-500 transition-colors"
              >
                <ChevronLeft className="h-3.5 w-3.5" />
              </button>
              <div className="flex-1" />
              <button
                type="button"
                onClick={nextMonth}
                aria-label="Bulan berikutnya"
                className="p-0.5 rounded hover:bg-gray-100 text-gray-500 transition-colors"
              >
                <ChevronRight className="h-3.5 w-3.5" />
              </button>
            </div>
            <div className="flex gap-4">
              <CalendarGrid
                year={leftYear} month={leftMonth}
                draftFrom={previewFrom} draftTo={previewTo}
                hoverDate={hoverDate} isSelectingEnd={isSelectingEnd}
                onDayClick={handleDayClick} onDayHover={setHoverDate}
              />
              <div className="w-px bg-gray-100 self-stretch" />
              <CalendarGrid
                year={rightYear} month={rightMonth}
                draftFrom={previewFrom} draftTo={previewTo}
                hoverDate={hoverDate} isSelectingEnd={isSelectingEnd}
                onDayClick={handleDayClick} onDayHover={setHoverDate}
              />
            </div>
          </div>

          {/* Right: Date + Time inputs */}
          <div className="w-44 border-l border-gray-100 py-3 px-3 space-y-3">
            <div>
              <p className="text-[10px] text-gray-400 mb-0.5">Dari Tanggal</p>
              <p className="text-xs font-medium text-gray-800">
                {format(draftFrom, 'd MMMM yyyy', { locale: id })}
              </p>
            </div>
            <div>
              <p className="text-[10px] text-gray-400 mb-0.5">Dari Pukul</p>
              <div className="flex items-center gap-1.5 border border-gray-200 rounded-lg px-2 py-1.5">
                <Clock className="h-3 w-3 text-gray-400 shrink-0" />
                <input
                  type="time"
                  value={fromTime}
                  onChange={(e) => setFromTime(e.target.value)}
                  className="text-xs bg-transparent outline-none w-full"
                />
              </div>
            </div>
            <div>
              <p className="text-[10px] text-gray-400 mb-0.5">Hingga Tanggal</p>
              <p className="text-xs font-medium text-gray-800">
                {format(draftTo, 'd MMMM yyyy', { locale: id })}
              </p>
            </div>
            <div>
              <p className="text-[10px] text-gray-400 mb-0.5">Hingga Pukul</p>
              <div className="flex items-center gap-1.5 border border-gray-200 rounded-lg px-2 py-1.5">
                <Clock className="h-3 w-3 text-gray-400 shrink-0" />
                <input
                  type="time"
                  value={toTime}
                  onChange={(e) => setToTime(e.target.value)}
                  className="text-xs bg-transparent outline-none w-full"
                />
              </div>
            </div>
          </div>
        </div>

        {/* Bottom bar */}
        <div className="border-t border-gray-100 px-3 py-2 flex items-center justify-between bg-gray-50/50">
          <p className="text-xs text-gray-600 font-medium">
            {format(draftFrom, 'd MMM yyyy', { locale: id })} – {format(draftTo, 'd MMM yyyy', { locale: id })}
          </p>
          <div className="flex gap-1.5">
            <Button
              variant="ghost" size="sm"
              className="h-7 px-3 text-xs text-primary hover:text-primary hover:bg-primary/10"
              onClick={() => setOpen(false)}
            >
              Batal
            </Button>
            <Button
              size="sm"
              className="h-7 px-3 text-xs bg-primary hover:bg-primary/90 text-primary-foreground"
              onClick={handleApply}
            >
              Proses
            </Button>
          </div>
        </div>
      </PopoverContent>
    </Popover>
  )
}

// ─── MonthPicker ──────────────────────────────────────────────────────────────

export function MonthPicker({
  value, onChange, className,
}: {
  value: string
  onChange: (month: string) => void
  className?: string
}) {
  const months = Array.from({ length: 12 }, (_, i) => {
    const d = new Date(2024, i, 1)
    return { value: String(i + 1).padStart(2, '0'), label: format(d, 'MMMM', { locale: id }) }
  })
  const years = [new Date().getFullYear() - 1, new Date().getFullYear()]
  const [year, month] = value.split('-')

  return (
    <div className={cn('flex gap-2', className)}>
      <Select value={month} onValueChange={(m) => onChange(`${year}-${m}`)}>
        <SelectTrigger className="w-32"><SelectValue /></SelectTrigger>
        <SelectContent>
          {months.map((m) => <SelectItem key={m.value} value={m.value}>{m.label}</SelectItem>)}
        </SelectContent>
      </Select>
      <Select value={year} onValueChange={(y) => onChange(`${y}-${month}`)}>
        <SelectTrigger className="w-24"><SelectValue /></SelectTrigger>
        <SelectContent>
          {years.map((y) => <SelectItem key={y} value={String(y)}>{y}</SelectItem>)}
        </SelectContent>
      </Select>
    </div>
  )
}
