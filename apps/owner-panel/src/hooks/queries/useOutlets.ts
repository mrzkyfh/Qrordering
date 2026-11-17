import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { cleanupOutletImageAssets } from '@/lib/imageStorage'
import type { Outlet, RestaurantTable } from '@/types/database'

export function useOutlets() {
  return useQuery({
    queryKey: ['outlets'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('outlets')
        .select('*')
        .order('name')
      if (error) throw error
      return data as Outlet[]
    },
  })
}

export function useTables(outletId: string) {
  return useQuery({
    queryKey: ['tables', outletId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('restaurant_tables')
        .select('*')
        .eq('outlet_id', outletId)
        .order('table_number')
      if (error) throw error
      return (data as RestaurantTable[]).sort((a, b) =>
        a.table_number.localeCompare(b.table_number, undefined, { numeric: true, sensitivity: 'base' })
      )
    },
    enabled: !!outletId,
  })
}

export function useCreateOutlet() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (data: {
      name: string
      address?: string | null
      phone?: string | null
      city?: string | null
      is_active: boolean
      settings: { tax_percent: number; service_charge_percent: number; currency: string; receipt_footer: string }
    }) => {
      const { error } = await supabase.from('outlets').insert(data)
      if (error) throw error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['outlets'] }),
  })
}

export function useDeleteOutlet() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (id: string): Promise<{ staff_deleted: number }> => {
      // RPC menghapus: akun Kasir cabang ini (dari auth.users) +
      // outlet (cascade ke seluruh data transaksi via migrasi 050). Atomik.
      // Lihat 051_delete_outlet_cascade_rpc.sql.
      const { data, error } = await supabase.rpc('delete_outlet_cascade', { p_outlet_id: id })
      if (error) throw error
      const res = (data ?? {}) as { status?: string; staff_deleted?: number }
      if (res.status === 'not_found') throw new Error('Outlet tidak ditemukan')

      // Bersihkan file gambar menu milik outlet ini dari storage (best-effort,
      // non-blocking). Gambar disimpan di bucket menu-images dgn prefix {outletId}/.
      try {
        const handledByR2 = await cleanupOutletImageAssets(id)
        if (!handledByR2) {
          const { data: files } = await supabase.storage.from('menu-images').list(id)
          if (files && files.length > 0) {
            await supabase.storage.from('menu-images').remove(files.map((f) => `${id}/${f.name}`))
          }
        }
      } catch {
        // abaikan — kebersihan storage tidak boleh menggagalkan penghapusan outlet
      }

      return { staff_deleted: res.staff_deleted ?? 0 }
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['outlets'] }),
  })
}

export function useUpdateOutlet() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({
      id,
      updates,
    }: {
      id: string
      updates: Partial<Omit<Outlet, 'id' | 'created_at' | 'updated_at'>>
    }) => {
      const { error } = await supabase
        .from('outlets')
        .update(updates)
        .eq('id', id)
      if (error) throw error
    },
    onSuccess: (_data, { id }) => {
      qc.invalidateQueries({ queryKey: ['outlets'] })
      qc.invalidateQueries({ queryKey: ['outlet', id] })
    },
  })
}
