import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

export interface Supplier {
  id: string
  outlet_id: string
  name: string
  phone: string | null
  note: string | null
  is_active: boolean
  created_at: string
}

export function useSuppliers(outletId: string) {
  return useQuery({
    queryKey: ['suppliers', outletId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('suppliers')
        .select('*')
        .eq('outlet_id', outletId)
        .eq('is_active', true)
        .order('name')
      if (error) throw error
      return data as Supplier[]
    },
    enabled: !!outletId,
  })
}

export function useUpsertSupplier() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: {
      id?: string
      outlet_id: string
      name: string
      phone?: string | null
      note?: string | null
    }) => {
      if (input.id) {
        const { error } = await supabase
          .from('suppliers')
          .update({ name: input.name, phone: input.phone ?? null, note: input.note ?? null })
          .eq('id', input.id)
        if (error) throw error
      } else {
        const { error } = await supabase.from('suppliers').insert({
          outlet_id: input.outlet_id,
          name: input.name,
          phone: input.phone ?? null,
          note: input.note ?? null,
        })
        if (error) throw error
      }
    },
    onSuccess: (_, vars) => {
      qc.invalidateQueries({ queryKey: ['suppliers', vars.outlet_id] })
    },
  })
}

export function useDeleteSupplier() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({ id }: { id: string; outlet_id: string }) => {
      // Soft delete — supplier mungkin sudah terpakai di transaksi stok.
      const { error } = await supabase
        .from('suppliers')
        .update({ is_active: false })
        .eq('id', id)
      if (error) throw error
    },
    onSuccess: (_, vars) => {
      qc.invalidateQueries({ queryKey: ['suppliers', vars.outlet_id] })
    },
  })
}
