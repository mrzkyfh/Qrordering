import { useState, useMemo } from 'react'
import { format } from 'date-fns'
import { id } from 'date-fns/locale'
import { useOutlet } from '@/hooks/useOutlet'
import { usePartialRefunds } from '@/hooks/queries/usePartialRefunds'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { DataTable } from '@/components/ui/DataTable'
import { CurrencyDisplay } from '@/components/ui/CurrencyDisplay'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'

const METHOD_LABEL: Record<string, string> = {
  cash: 'Tunai', qris: 'QRIS', debit: 'Debit',
  credit: 'Kredit', ewallet: 'E-Wallet', transfer: 'Transfer',
}

export default function PartialRefundReport() {
  const { activeOutletId } = useOutlet()
  const [month, setMonth] = useState(format(new Date(), 'yyyy-MM'))
  const { data: refunds = [], isLoading } = usePartialRefunds(activeOutletId ?? '', month)

  const total = useMemo(
    () => refunds.reduce((s, r) => s + r.amount, 0),
    [refunds],
  )

  if (!activeOutletId) return <NoOutlet />

  return (
    <div className="space-y-4">
      <PageHeader
        title="Refund Sebagian"
        subtitle="Refund per-item pada order lunas (order tetap tercatat lunas)."
      />

      <div className="flex flex-wrap items-center gap-3">
        <Input
          type="month"
          value={month}
          onChange={(e) => setMonth(e.target.value)}
          className="w-44"
        />
        <div className="ml-auto text-sm text-muted-foreground">
          Total refund:{' '}
          <span className="font-semibold text-foreground">
            <CurrencyDisplay value={total} />
          </span>
        </div>
      </div>

      <DataTable
        data={refunds}
        loading={isLoading}
        getRowKey={(r) => r.id}
        emptyMessage="Belum ada refund sebagian pada bulan ini."
        columns={[
          {
            key: 'time',
            header: 'Waktu',
            cell: (r) => format(new Date(r.created_at), 'd MMM yyyy HH:mm', { locale: id }),
          },
          {
            key: 'order',
            header: 'Order',
            cell: (r) => <span className="font-medium">#{r.order_number ?? '—'}</span>,
          },
          {
            key: 'items',
            header: 'Item Direfund',
            cell: (r) => (
              <div className="space-y-0.5">
                {r.items.map((it, i) => (
                  <div key={i} className="text-sm">
                    {it.qty}× {it.menu_name}
                  </div>
                ))}
              </div>
            ),
          },
          {
            key: 'method',
            header: 'Metode',
            cell: (r) => <Badge variant="outline">{METHOD_LABEL[r.method] ?? r.method}</Badge>,
          },
          {
            key: 'amount',
            header: 'Jumlah',
            cell: (r) => <CurrencyDisplay value={r.amount} className="font-semibold text-red-600" />,
          },
          {
            key: 'approver',
            header: 'Disetujui',
            cell: (r) => r.approver_name ?? '—',
          },
          {
            key: 'reason',
            header: 'Alasan',
            cell: (r) => <span className="text-muted-foreground">{r.reason || '—'}</span>,
          },
        ]}
      />
    </div>
  )
}
