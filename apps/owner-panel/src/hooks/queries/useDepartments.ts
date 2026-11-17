import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { MenuDepartment } from '@/types/database'

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const table = () => (supabase as any).from('menu_departments')

export function useDepartments(outletId: string) {
  return useQuery({
    queryKey: ['menu-departments', outletId],
    queryFn: async () => {
      const { data, error } = await table()
        .select('*')
        .eq('outlet_id', outletId)
        .eq('is_active', true)
        .order('sort_order')
      if (error) return [] // table may not exist yet
      return data as MenuDepartment[]
    },
    enabled: !!outletId,
  })
}

export function useCreateDepartment() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (payload: { outlet_id: string; name: string; color: string | null; sort_order: number }): Promise<string> => {
      const { data, error } = await table().insert({ ...payload, is_active: true }).select('id').single()
      if (error) throw error
      return (data as { id: string }).id
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['menu-departments'] }),
  })
}

export function useUpdateDepartment() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({ id, ...payload }: { id: string; name: string; color: string | null; sort_order: number }) => {
      const { error } = await table().update(payload).eq('id', id)
      if (error) throw error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['menu-departments'] }),
  })
}

export function useDeleteDepartment() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (id: string) => {
      const { error } = await table().update({ is_active: false }).eq('id', id)
      if (error) throw error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['menu-departments'] }),
  })
}
