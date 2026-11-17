import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

export interface StockOpname {
  id: string
  outlet_id: string
  note: string | null
  status: 'draft' | 'final'
  created_by: string | null
  finalized_by: string | null
  created_at: string
  finalized_at: string | null
}

export interface StockOpnameItem {
  id: string
  opname_id: string
  ingredient_id: string
  system_qty: number
  physical_qty: number | null
  diff: number | null
  note: string | null
  ingredients?: { name: string; unit: string } | null
}

export function useStockOpnames(outletId: string) {
  return useQuery({
    queryKey: ['stock-opnames', outletId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('stock_opnames')
        .select('*')
        .eq('outlet_id', outletId)
        .order('created_at', { ascending: false })
      if (error) throw error
      return data as StockOpname[]
    },
    enabled: !!outletId,
  })
}

export function useStockOpnameItems(opnameId: string | null) {
  return useQuery({
    queryKey: ['stock-opname-items', opnameId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('stock_opname_items')
        .select('*, ingredients(name, unit)')
        .eq('opname_id', opnameId!)
        .order('id')
      if (error) throw error
      return data as StockOpnameItem[]
    },
    enabled: !!opnameId,
  })
}

export function useCreateStockOpname() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: { outlet_id: string; note?: string }) => {
      const { data, error } = await supabase.rpc('create_stock_opname', {
        p_outlet_id: input.outlet_id,
        p_note: input.note ?? null,
      })
      if (error) throw error
      return data as string // opname id
    },
    onSuccess: (_, vars) => {
      qc.invalidateQueries({ queryKey: ['stock-opnames', vars.outlet_id] })
    },
  })
}

export function useUpdateOpnameItem() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: {
      id: string
      opname_id: string
      physical_qty: number | null
      note?: string | null
    }) => {
      const { error } = await supabase
        .from('stock_opname_items')
        .update({ physical_qty: input.physical_qty, note: input.note ?? null })
        .eq('id', input.id)
      if (error) throw error
    },
    onSuccess: (_, vars) => {
      qc.invalidateQueries({ queryKey: ['stock-opname-items', vars.opname_id] })
    },
  })
}

export function useFinalizeStockOpname() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: { opname_id: string; outlet_id: string }) => {
      const { error } = await supabase.rpc('finalize_stock_opname', {
        p_opname_id: input.opname_id,
      })
      if (error) throw error
    },
    onSuccess: (_, vars) => {
      qc.invalidateQueries({ queryKey: ['stock-opnames', vars.outlet_id] })
      qc.invalidateQueries({ queryKey: ['stock-opname-items', vars.opname_id] })
      qc.invalidateQueries({ queryKey: ['ingredients', vars.outlet_id] })
      qc.invalidateQueries({ queryKey: ['stock-transactions', vars.outlet_id] })
      qc.invalidateQueries({ queryKey: ['low-stock', vars.outlet_id] })
    },
  })
}
