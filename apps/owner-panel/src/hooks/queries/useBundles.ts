import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { MenuItem } from '@/types/database'

export interface BundleComponent {
  id: string
  bundle_id: string
  component_id: string
  qty: number
  menu_items?: { id: string; name: string; price: number } | null
}

export interface ComponentInput {
  component_id: string
  qty: number
}

// Daftar bundle = menu_items dengan is_bundle = true
export function useBundles(outletId: string) {
  return useQuery({
    queryKey: ['bundles', outletId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('menu_items')
        .select('*, menu_categories(name, id)')
        .eq('outlet_id', outletId)
        .eq('is_active', true)
        .eq('is_bundle', true)
        .order('name')
      if (error) throw error
      return data as MenuItem[]
    },
    enabled: !!outletId,
  })
}

// Menu biasa (non-bundle) untuk dipilih sebagai komponen
export function useNonBundleItems(outletId: string) {
  return useQuery({
    queryKey: ['non-bundle-items', outletId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('menu_items')
        .select('id, name, price')
        .eq('outlet_id', outletId)
        .eq('is_active', true)
        .eq('is_bundle', false)
        .order('name')
      if (error) throw error
      return data as { id: string; name: string; price: number }[]
    },
    enabled: !!outletId,
  })
}

export function useBundleComponents(bundleId: string | null) {
  return useQuery({
    queryKey: ['bundle-components', bundleId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('bundle_items')
        .select('*, menu_items!bundle_items_component_id_fkey(id, name, price)')
        .eq('bundle_id', bundleId!)
      if (error) throw error
      return data as BundleComponent[]
    },
    enabled: !!bundleId,
  })
}

export function useUpsertBundle() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: {
      id?: string
      outlet_id: string
      name: string
      price: number
      category_id: string | null
      components: ComponentInput[]
    }) => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const table = supabase.from('menu_items') as any
      let bundleId = input.id
      const payload = {
        outlet_id: input.outlet_id,
        name: input.name,
        price: input.price,
        category_id: input.category_id,
        is_bundle: true,
        is_available: true,
        is_active: true,
      }
      if (bundleId) {
        const { error } = await table.update(payload).eq('id', bundleId)
        if (error) throw error
      } else {
        const { data, error } = await table.insert(payload).select('id').single()
        if (error) throw error
        bundleId = data.id
      }

      // Ganti total komponen (hapus lalu masukkan ulang).
      const { error: delErr } = await supabase.from('bundle_items').delete().eq('bundle_id', bundleId)
      if (delErr) throw delErr
      if (input.components.length > 0) {
        const rows = input.components.map((c) => ({
          bundle_id: bundleId, component_id: c.component_id, qty: c.qty,
        }))
        const { error: insErr } = await supabase.from('bundle_items').insert(rows)
        if (insErr) throw insErr
      }
      return bundleId as string
    },
    onSuccess: (_, vars) => {
      qc.invalidateQueries({ queryKey: ['bundles', vars.outlet_id] })
      qc.invalidateQueries({ queryKey: ['menu-items'] })
      if (vars.id) qc.invalidateQueries({ queryKey: ['bundle-components', vars.id] })
    },
  })
}

export function useDeleteBundle() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({ id }: { id: string; outlet_id: string }) => {
      // Soft delete: bundle tetap referensi order lama. bundle_items ikut terhapus
      // hanya jika hard delete; di sini cukup nonaktifkan.
      const { error } = await supabase.from('menu_items').update({ is_active: false }).eq('id', id)
      if (error) throw error
    },
    onSuccess: (_, vars) => {
      qc.invalidateQueries({ queryKey: ['bundles', vars.outlet_id] })
      qc.invalidateQueries({ queryKey: ['menu-items'] })
    },
  })
}
