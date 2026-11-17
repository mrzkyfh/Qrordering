import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { Shift } from '@/types/database'
import { normalizeShiftCloseReport } from '@/lib/shiftCloseReport'

export interface ShiftWithKasir extends Shift {
  kasir_name: string | null
  outlet_name: string | null
  cash_received: number
  non_cash_received: number
  paid_orders: number
}

// Baris mentah hasil query shifts (join staff & outlets).
type RawShiftRow = Shift & {
  staff?: { full_name: string | null } | null
  outlets?: { name: string | null } | null
}

export function useShifts(
  outletId: string | null,
  dateFrom: string,
  dateTo: string,
) {
  return useQuery({
    queryKey: ['shifts', outletId, dateFrom, dateTo],
    queryFn: async () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase.from('shifts') as any)
        .select('*, staff:kasir_id(full_name), outlets(name)')
        .eq('outlet_id', outletId)
        .gte('start_time', dateFrom)
        .lte('start_time', dateTo)
        .order('start_time', { ascending: false })
      if (error) throw error

      const rows = (data ?? []) as RawShiftRow[]
      const shiftIds = rows.map((s) => s.id)
      let summaryMap = new Map<string, { cash_received: number; non_cash_received: number; paid_orders: number }>()
      if (shiftIds.length > 0) {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const { data: sumData } = await (supabase.from('v_shift_summary') as any)
          .select('shift_id, cash_received, non_cash_received, paid_orders')
          .in('shift_id', shiftIds)
        summaryMap = new Map(
          (sumData as { shift_id: string; cash_received: number; non_cash_received: number; paid_orders: number }[] | null ?? [])
            .map((s) => [s.shift_id, s]),
        )
      }

      return rows.map((s) => {
        const sum = summaryMap.get(s.id)
        return {
          ...s,
          kasir_name:        s.staff?.full_name   ?? null,
          outlet_name:       s.outlets?.name      ?? null,
          cash_received:     Number(sum?.cash_received     ?? 0),
          non_cash_received: Number(sum?.non_cash_received ?? 0),
          paid_orders:       Number(sum?.paid_orders       ?? 0),
        }
      }) as ShiftWithKasir[]
    },
    enabled: !!outletId,
    staleTime: 0,
  })
}

export function useActiveShifts(outletId: string | null) {
  return useQuery({
    queryKey: ['shifts_active', outletId],
    queryFn: async () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase.from('shifts') as any)
        .select('*, staff:kasir_id(full_name)')
        .eq('outlet_id', outletId)
        .is('end_time', null)
        .order('start_time', { ascending: false })
      if (error) throw error
      return ((data ?? []) as RawShiftRow[]).map((s) => ({
        ...s,
        kasir_name:        s.staff?.full_name ?? null,
        outlet_name:       null,
        cash_received:     0,
        non_cash_received: 0,
        paid_orders:       0,
      })) as ShiftWithKasir[]
    },
    enabled: !!outletId,
    staleTime: 0,
    refetchInterval: 30_000,
  })
}

export function useShiftCloseReport(shiftId: string | null) {
  return useQuery({
    queryKey: ['shift-close-report', shiftId],
    enabled: !!shiftId,
    staleTime: 30_000,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_shift_close_report', {
        p_shift_id: shiftId!,
      })
      if (error) throw error
      return normalizeShiftCloseReport(data)
    },
  })
}

export function useOpenShift(outletId: string | null) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (payload: { kasir_id: string; opening_cash: number }) => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase.from('shifts') as any)
        .insert({ outlet_id: outletId, ...payload })
        .select()
        .single()
      if (error) throw error
      return data as Shift
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['shifts', outletId] })
      qc.invalidateQueries({ queryKey: ['shifts_active', outletId] })
      qc.invalidateQueries({ queryKey: ['shift-close-report'] })
    },
  })
}

export function useCloseShift(outletId: string | null) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({
      shiftId,
      closingCash,
      notes,
    }: {
      shiftId: string
      closingCash: number
      notes: string
    }) => {
      const { error } = await supabase.rpc('close_shift', {
        p_shift_id: shiftId,
        p_closing_cash: closingCash,
        p_notes: notes || null,
      })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['shifts', outletId] })
      qc.invalidateQueries({ queryKey: ['shifts_active', outletId] })
    },
  })
}
