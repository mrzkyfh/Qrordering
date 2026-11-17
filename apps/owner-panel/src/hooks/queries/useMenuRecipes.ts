import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { MenuRecipe } from '@/types/database'

export function useMenuRecipes(menuItemId: string | undefined) {
  return useQuery({
    queryKey: ['menu-recipes', menuItemId],
    queryFn: async () => {
      // menu_recipes belum ada di tipe Supabase ter-generate → cast diperlukan
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase as any)
        .from('menu_recipes')
        .select('*, ingredients(name, unit)')
        .eq('menu_item_id', menuItemId)
        .order('created_at')
      if (error) throw error
      return data as MenuRecipe[]
    },
    enabled: !!menuItemId,
  })
}

export function useUpsertRecipe() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({
      menu_item_id,
      ingredient_id,
      qty_per_portion,
    }: {
      menu_item_id: string
      ingredient_id: string
      qty_per_portion: number
    }) => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { error } = await (supabase as any)
        .from('menu_recipes')
        .upsert({ menu_item_id, ingredient_id, qty_per_portion }, { onConflict: 'menu_item_id,ingredient_id' })
      if (error) throw error
    },
    onSuccess: (_: unknown, vars: { menu_item_id: string; ingredient_id: string; qty_per_portion: number }) => {
      qc.invalidateQueries({ queryKey: ['menu-recipes', vars.menu_item_id] })
    },
  })
}

export function useDeleteRecipe() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({ id }: { id: string; menu_item_id: string }) => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { error } = await (supabase as any)
        .from('menu_recipes')
        .delete()
        .eq('id', id)
      if (error) throw error
    },
    onSuccess: (_: unknown, vars: { id: string; menu_item_id: string }) => {
      qc.invalidateQueries({ queryKey: ['menu-recipes', vars.menu_item_id] })
    },
  })
}
