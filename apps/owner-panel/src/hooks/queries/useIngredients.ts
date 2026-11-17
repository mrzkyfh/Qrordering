import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { Ingredient, LowStockItem, StockTransaction, StockTransactionType } from '@/types/database'

export function useIngredients(outletId: string) {
  return useQuery({
    queryKey: ['ingredients', outletId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('ingredients')
        .select('*')
        .eq('outlet_id', outletId)
        .eq('is_active', true)
        .order('name')
      if (error) throw error
      return data as Ingredient[]
    },
    enabled: !!outletId,
  })
}

export function useLowStock(outletId: string) {
  return useQuery({
    queryKey: ['low-stock', outletId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('v_low_stock')
        .select('*')
        .eq('outlet_id', outletId)
        .order('stock_qty')
      if (error) throw error
      return data as LowStockItem[]
    },
    enabled: !!outletId,
  })
}

export function useStockTransactions(outletId: string, ingredientId?: string) {
  return useQuery({
    queryKey: ['stock-transactions', outletId, ingredientId],
    queryFn: async () => {
      let query = supabase
        .from('stock_transactions')
        .select('*, ingredients(name, unit)')
        .eq('outlet_id', outletId)
        .order('created_at', { ascending: false })
        .limit(100)

      if (ingredientId) query = query.eq('ingredient_id', ingredientId)

      const { data, error } = await query
      if (error) throw error
      return data as StockTransaction[]
    },
    enabled: !!outletId,
  })
}

interface CreateIngredientInput {
  outlet_id: string
  name: string
  unit: string
  initial_qty: number
  cost_per_unit: number
  min_stock_qty: number
  created_by?: string
}

export function useCreateIngredient() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: CreateIngredientInput) => {
      const { data, error } = await supabase
        .from('ingredients')
        .insert({
          outlet_id: input.outlet_id,
          name: input.name,
          unit: input.unit,
          stock_qty: 0,
          cost_per_unit: input.cost_per_unit,
          min_stock_qty: input.min_stock_qty,
          is_active: true,
        })
        .select('id')
        .single()
      if (error) throw error

      if (input.initial_qty > 0) {
        // Migration 142 mencabut INSERT langsung ke stock_transactions.
        // Gunakan RPC agar stok awal dan ledger diterapkan atomik oleh server.
        const { error: txError } = await supabase.rpc('adjust_stock', {
          p_outlet_id: input.outlet_id,
          p_ingredient_id: data.id,
          p_type: 'purchase',
          p_qty: input.initial_qty,
          p_cost_per_unit: input.cost_per_unit || null,
          p_notes: 'Stok awal',
          p_created_by: input.created_by ?? null,
          p_supplier_id: null,
          p_reason: null,
        })
        if (txError) throw txError
      }
    },
    onSuccess: (_, vars) => {
      qc.invalidateQueries({ queryKey: ['ingredients', vars.outlet_id] })
      qc.invalidateQueries({ queryKey: ['stock-transactions', vars.outlet_id] })
      qc.invalidateQueries({ queryKey: ['low-stock', vars.outlet_id] })
    },
  })
}

export function useUpdateIngredient() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: {
      id: string
      outlet_id: string
      name: string
      unit: string
      cost_per_unit: number
      min_stock_qty: number
    }) => {
      const { error } = await supabase
        .from('ingredients')
        .update({
          name: input.name,
          unit: input.unit,
          cost_per_unit: input.cost_per_unit,
          min_stock_qty: input.min_stock_qty,
        })
        .eq('id', input.id)
      if (error) throw error
    },
    onSuccess: (_, vars) => {
      qc.invalidateQueries({ queryKey: ['ingredients', vars.outlet_id] })
    },
  })
}

// Smart delete bahan baku: hard delete kalau belum ada stock_transactions,
// soft delete (is_active=false) kalau sudah ada history transaksi stok.
export type IngredientDeleteResult = {
  status: 'deleted' | 'archived' | 'not_found'
  reason?: string
}

export function useDeleteIngredient() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({ id }: { id: string; outlet_id: string }): Promise<IngredientDeleteResult> => {
      const { data, error } = await supabase.rpc('delete_ingredient_smart', { p_id: id })
      if (error) throw new Error(error.message)
      return data as IngredientDeleteResult
    },
    onSuccess: (_, vars) => {
      qc.invalidateQueries({ queryKey: ['ingredients', vars.outlet_id] })
    },
  })
}

interface StockAdjustmentInput {
  outlet_id: string
  ingredient_id: string
  type: StockTransactionType
  qty: number
  cost_per_unit?: number
  notes?: string
  created_by?: string
  supplier_id?: string | null
  reason?: string | null
}

export function useStockAdjustment() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: StockAdjustmentInput) => {
      const { error } = await supabase.rpc('adjust_stock', {
        p_outlet_id: input.outlet_id,
        p_ingredient_id: input.ingredient_id,
        p_type: input.type,
        p_qty: input.qty,
        p_cost_per_unit: input.cost_per_unit ?? null,
        p_notes: input.notes ?? null,
        p_created_by: input.created_by ?? null,
        p_supplier_id: input.supplier_id ?? null,
        p_reason: input.reason ?? null,
      })
      if (error) throw error
    },
    onSuccess: (_, variables) => {
      qc.invalidateQueries({ queryKey: ['ingredients', variables.outlet_id] })
      qc.invalidateQueries({ queryKey: ['stock-transactions', variables.outlet_id] })
      qc.invalidateQueries({ queryKey: ['low-stock', variables.outlet_id] })
    },
  })
}
