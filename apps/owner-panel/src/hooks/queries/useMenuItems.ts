import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { MenuItem, MenuCategory, MenuExtra } from '@/types/database'

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const anyTable = (name: string) => (supabase as any).from(name)

export function useMenuCategories(outletId: string, departmentId?: string | null) {
  return useQuery({
    queryKey: ['menu-categories', outletId, departmentId],
    queryFn: async () => {
      // Try with department join first; fall back to plain select if column doesn't exist yet
      let q = supabase
        .from('menu_categories')
        .select('*, menu_departments(*)')
        .eq('outlet_id', outletId)
        .eq('is_active', true)
        .order('sort_order')
        .order('name')
      if (departmentId) {
        q = q.eq('department_id', departmentId)
      }
      const { data, error } = await q
      if (error) {
        // department_id column may not exist yet — retry without join
        const fallback = await supabase
          .from('menu_categories')
          .select('*')
          .eq('outlet_id', outletId)
          .eq('is_active', true)
          .order('sort_order')
          .order('name')
        if (fallback.error) throw fallback.error
        return fallback.data as MenuCategory[]
      }
      return data as MenuCategory[]
    },
    enabled: !!outletId,
  })
}

export function useMenuItems(outletId: string, categoryId?: string) {
  return useQuery({
    queryKey: ['menu-items', outletId, categoryId],
    queryFn: async () => {
      let query = supabase
        .from('menu_items')
        .select('*, menu_categories(name, id)')
        .eq('outlet_id', outletId)
        .eq('is_active', true)
        .order('is_featured', { ascending: false })
        .order('sort_order')
        .order('name')
      if (categoryId) {
        query = query.eq('category_id', categoryId)
      }
      const { data, error } = await query
      if (error) throw error
      return data as MenuItem[]
    },
    enabled: !!outletId,
  })
}

export function useItemExtras(itemId: string | undefined) {
  return useQuery({
    queryKey: ['item-extras', itemId],
    queryFn: async () => {
      const { data, error } = await anyTable('menu_item_extras')
        .select('extra_id')
        .eq('menu_item_id', itemId)
      if (error) return [] // table may not exist yet
      return (data as { extra_id: string }[]).map((r) => r.extra_id)
    },
    enabled: !!itemId,
  })
}

export function useItemExtrasFull(itemId: string | undefined) {
  return useQuery({
    queryKey: ['item-extras-full', itemId],
    queryFn: async () => {
      const { data, error } = await anyTable('menu_item_extras')
        .select('*, menu_extras(*)')
        .eq('menu_item_id', itemId)
      if (error) return [] // table may not exist yet
      return data as { extra_id: string; menu_extras: MenuExtra }[]
    },
    enabled: !!itemId,
  })
}

export function useSyncItemExtras() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({ itemId, extraIds }: { itemId: string; extraIds: string[] }) => {
      const { data, error: fetchError } = await anyTable('menu_item_extras')
        .select('extra_id')
        .eq('menu_item_id', itemId)
      if (fetchError) throw fetchError

      const existingIds = (data as { extra_id: string }[]).map((r) => r.extra_id)
      const toAdd = extraIds.filter((id) => !existingIds.includes(id))
      const toDelete = existingIds.filter((id) => !extraIds.includes(id))

      if (toAdd.length > 0) {
        const rows = toAdd.map((extra_id) => ({ menu_item_id: itemId, extra_id }))
        const { error: insError } = await anyTable('menu_item_extras').insert(rows)
        if (insError) throw insError
      }

      if (toDelete.length > 0) {
        const { error: delError } = await anyTable('menu_item_extras')
          .delete()
          .eq('menu_item_id', itemId)
          .in('extra_id', toDelete)
        if (delError) throw delError
      }
    },
    onSuccess: (_data, { itemId }) => {
      qc.invalidateQueries({ queryKey: ['item-extras', itemId] })
      qc.invalidateQueries({ queryKey: ['item-extras-full', itemId] })
      qc.invalidateQueries({ queryKey: ['extra-product-count'] })
    },
  })
}

export function useSyncDepartmentCategories() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({ departmentId, selectedIds }: { departmentId: string; selectedIds: string[] }) => {
      // Clear all current assignments for this department
      const { error: clearErr } = await supabase
        .from('menu_categories')
        .update({ department_id: null })
        .eq('department_id', departmentId)
      if (clearErr) throw clearErr
      // Re-assign selected categories
      if (selectedIds.length > 0) {
        const { error: assignErr } = await supabase
          .from('menu_categories')
          .update({ department_id: departmentId })
          .in('id', selectedIds)
        if (assignErr) throw assignErr
      }
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['menu-categories'] }),
  })
}

export function useCreateCategory() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (payload: {
      outlet_id: string
      name: string
      icon: string | null
      sort_order: number
      department_id: string | null
    }) => {
      const { error } = await supabase.from('menu_categories').insert({ ...payload, is_active: true })
      if (error) throw error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['menu-categories'] }),
  })
}

export function useUpdateCategory() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({
      id,
      ...payload
    }: {
      id: string
      name: string
      icon: string | null
      sort_order: number
      department_id: string | null
    }) => {
      const { error } = await supabase.from('menu_categories').update(payload).eq('id', id)
      if (error) throw error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['menu-categories'] }),
  })
}

export function useReorderCategories() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({
      outletId,
      categoryIds,
    }: {
      outletId: string
      categoryIds: string[]
    }) => {
      const updates = categoryIds.map((id, index) =>
        supabase
          .from('menu_categories')
          .update({ sort_order: index + 1 })
          .eq('id', id)
          .eq('outlet_id', outletId),
      )

      const results = await Promise.all(updates)
      const failed = results.find((result) => result.error)
      if (failed?.error) throw failed.error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['menu-categories'] }),
  })
}

// Hard delete kategori — menu_items.category_id auto-NULL via FK ON DELETE SET NULL.
export function useDeleteCategory() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('menu_categories').delete().eq('id', id)
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['menu-categories'] })
      qc.invalidateQueries({ queryKey: ['menu-items'] })
    },
  })
}

// Smart delete menu: hard delete kalau belum pernah dipesan, soft delete (archive)
// kalau sudah punya order_items. Return { status, reason? } untuk toast UI.
export type DeleteResult = {
  status: 'deleted' | 'archived' | 'not_found'
  reason?: string
}

export function useDeleteMenuItem() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (id: string): Promise<DeleteResult> => {
      const { data, error } = await supabase.rpc('delete_menu_item_smart', { p_id: id })
      if (error) throw new Error(error.message)
      return data as DeleteResult
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['menu-items'] })
    },
  })
}
