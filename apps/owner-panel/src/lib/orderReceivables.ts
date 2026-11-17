interface PaymentAmount {
  amount?: number | string | null
}

interface ReceivableOrder {
  total_amount?: number | string | null
  payments?: PaymentAmount[] | null
}

function safeAmount(value: number | string | null | undefined) {
  const amount = Number(value ?? 0)
  return Number.isFinite(amount) ? amount : 0
}

/** Sisa tagihan order; pembayaran parsial tidak boleh dihitung lagi sebagai piutang. */
export function remainingReceivable(order: ReceivableOrder) {
  const total = Math.max(0, safeAmount(order.total_amount))
  const paid = (order.payments ?? []).reduce(
    (sum, payment) => sum + Math.max(0, safeAmount(payment.amount)),
    0,
  )
  return Math.max(0, total - paid)
}

export function totalReceivables(orders: ReceivableOrder[]) {
  return orders.reduce((sum, order) => sum + remainingReceivable(order), 0)
}
