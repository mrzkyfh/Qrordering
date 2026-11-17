import {
  endOfDay,
  endOfMonth,
  endOfWeek,
  startOfDay,
  startOfMonth,
  startOfWeek,
  subDays,
  subMonths,
  subWeeks,
} from 'date-fns'

export interface DateRange {
  from: Date
  to: Date
}

export type PresetKey =
  | 'today'
  | 'yesterday'
  | '7d'
  | 'thisWeek'
  | 'lastWeek'
  | '30d'
  | 'month'
  | 'lastMonth'

export function getPresetRange(key: PresetKey | string): DateRange {
  const now = new Date()
  switch (key as PresetKey) {
    case 'today':
      return { from: startOfDay(now), to: endOfDay(now) }
    case 'yesterday':
      return {
        from: startOfDay(subDays(now, 1)),
        to: endOfDay(subDays(now, 1)),
      }
    case '7d':
      return { from: startOfDay(subDays(now, 6)), to: endOfDay(now) }
    case 'thisWeek':
      return {
        from: startOfWeek(now, { weekStartsOn: 0 }),
        to: endOfWeek(now, { weekStartsOn: 0 }),
      }
    case 'lastWeek': {
      const lastWeek = subWeeks(now, 1)
      return {
        from: startOfWeek(lastWeek, { weekStartsOn: 0 }),
        to: endOfWeek(lastWeek, { weekStartsOn: 0 }),
      }
    }
    case '30d':
      return { from: startOfDay(subDays(now, 29)), to: endOfDay(now) }
    case 'month':
      return { from: startOfMonth(now), to: endOfMonth(now) }
    case 'lastMonth':
      return {
        from: startOfMonth(subMonths(now, 1)),
        to: endOfMonth(subMonths(now, 1)),
      }
    default:
      return { from: startOfDay(subDays(now, 29)), to: endOfDay(now) }
  }
}
