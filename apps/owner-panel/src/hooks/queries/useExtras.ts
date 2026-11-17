import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { MenuExtra, MenuExtraOption, ExtraType, ExtraSelectionType } from '@/types/database'

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const table = () => (supabase as any).from('menu_extras')
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const optionsTable = () => (supabase as any).from('menu_extra_options')

export function useExtras(outletId: string) {
  return useQuery({
    queryKey: ['menu-extras', outletId],
    queryFn: async () => {
      const { data, error } = await table()
        .select('*, menu_extra_options(*)')
        .eq('outlet_id', outletId)
        .order('sort_order')
      if (error) return [] // table may not exist yet
      return data as MenuExtra[]
    },
    enabled: !!outletId,
  })
}

export function useExtraProductCount(outletId: string) {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const junctionTable = () => (supabase as any).from('menu_item_extras')
  return useQuery({
    queryKey: ['extra-product-count', outletId],
    queryFn: async () => {
      const extraIds = await table()
        .select('id')
        .eq('outlet_id', outletId)
        .then((r: { data: { id: string }[] | null }) => r.data?.map((x) => x.id) ?? [])
      if (extraIds.length === 0) return {}
      const { data, error } = await junctionTable().select('extra_id').in('extra_id', extraIds)
      if (error) return {}
      const counts: Record<string, number> = {}
      for (const row of data as { extra_id: string }[]) {
        counts[row.extra_id] = (counts[row.extra_id] ?? 0) + 1
      }
      return counts
    },
    enabled: !!outletId,
  })
}

type ExtraPayload = {
  outlet_id: string
  name: string
  type: ExtraType
  selection_type: ExtraSelectionType
  sort_order: number
}

type SubExtraInput = { name: string; price: number }

export function useCreateExtra() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({ payload, options }: { payload: ExtraPayload; options: SubExtraInput[] }) => {
      const { data, error } = await table().insert({ ...payload, is_active: true }).select('id').single()
      if (error) throw error
      const extraId = (data as { id: string }).id
      if (options.length > 0) {
        const rows = options.map((o, i) => ({ extra_id: extraId, name: o.name, price: o.price, sort_order: i }))
        const { error: optErr } = await optionsTable().insert(rows)
        if (optErr) throw optErr
      }
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['menu-extras'] }),
  })
}

export function useUpdateExtra() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({
      id,
      payload,
      options,
    }: {
      id: string
      payload: Omit<ExtraPayload, 'outlet_id'>
      options: SubExtraInput[]
    }) => {
      const { error } = await table().update(payload).eq('id', id)
      if (error) throw error
      // Sync options: delete all then re-insert
      await optionsTable().delete().eq('extra_id', id)
      if (options.length > 0) {
        const rows = options.map((o, i) => ({ extra_id: id, name: o.name, price: o.price, sort_order: i }))
        const { error: optErr } = await optionsTable().insert(rows)
        if (optErr) throw optErr
      }
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['menu-extras'] }),
  })
}

export function useToggleExtra() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({ id, is_active }: { id: string; is_active: boolean }) => {
      const { error } = await table().update({ is_active }).eq('id', id)
      if (error) throw error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['menu-extras'] }),
  })
}

export function useDeleteExtra() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (id: string) => {
      const { error } = await table().delete().eq('id', id)
      if (error) throw error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['menu-extras'] }),
  })
}

export type { MenuExtraOption }
