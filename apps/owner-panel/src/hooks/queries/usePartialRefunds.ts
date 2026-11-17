import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

export interface PartialRefundItem {
  qty: number
  amount: number
  menu_name: string
}

export interface PartialRefund {
  id: string
  amount: number
  method: string
  reason: string | null
  created_at: string
  order_number: string | null
  approver_name: string | null
  items: PartialRefundItem[]
}

/** Refund sebagian (order tetap paid) untuk satu bulan (YYYY-MM). */
export function usePartialRefunds(outletId: string | null, month: string) {
  return useQuery({
    queryKey: ['partial-refunds', outletId, month],
    queryFn: async () => {
      const from = `${month}-01T00:00:00`
      // Akhir bulan: tambah 1 bulan, ambil hari 0.
      const [y, m] = month.split('-').map(Number)
      const to = new Date(y, m, 1).toISOString()
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase.from('refunds') as any)
        .select(
          'id, amount, method, reason, created_at, ' +
            'orders(order_number), approver:approved_by(full_name), ' +
            // Inner join membedakan refund per-item dari refund penuh. Refund
            // penuh tetap ada di tabel refunds untuk dashboard dan arus kas,
            // tetapi tidak mempunyai baris refund_items.
            'refund_items!inner(qty, amount, order_items(menu_items(name)))',
        )
        .eq('outlet_id', outletId)
        .gte('created_at', from)
        .lt('created_at', to)
        .order('created_at', { ascending: false })
      if (error) throw error
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      return ((data ?? []) as any[]).map((r) => ({
        id: r.id,
        amount: Number(r.amount ?? 0),
        method: r.method ?? 'cash',
        reason: r.reason ?? null,
        created_at: r.created_at,
        order_number: r.orders?.order_number ?? null,
        approver_name: r.approver?.full_name ?? null,
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        items: ((r.refund_items ?? []) as any[]).map((it) => ({
          qty: Number(it.qty ?? 0),
          amount: Number(it.amount ?? 0),
          menu_name: it.order_items?.menu_items?.name ?? 'Item',
        })),
      })) as PartialRefund[]
    },
    enabled: !!outletId,
  })
}
