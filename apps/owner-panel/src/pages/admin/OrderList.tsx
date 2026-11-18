import { useState, useMemo, useEffect } from 'react'
import { format, startOfDay, endOfDay, subDays } from 'date-fns'
import { id } from 'date-fns/locale'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useOrdersPaged } from '@/hooks/queries/useOrders'
import { useStaff } from '@/hooks/queries/useStaff'
import { useOutlet } from '@/hooks/useOutlet'
import { useRealtimeOrders } from '@/hooks/useRealtimeOrders'
import { supabase } from '@/lib/supabase'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { DataTable } from '@/components/ui/DataTable'
import { StatusBadge } from '@/components/ui/StatusBadge'
import { CurrencyDisplay } from '@/components/ui/CurrencyDisplay'
import { DateRangePicker } from '@/components/ui/DateRangePicker'
import { Button } from '@/components/ui/button'
import { Sheet, SheetContent, SheetHeader, SheetTitle } from '@/components/ui/sheet'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from '@/components/ui/dialog'
import { Textarea } from '@/components/ui/textarea'
import { Separator } from '@/components/ui/separator'
import { Input } from '@/components/ui/input'
import { Search } from 'lucide-react'
import { useToast } from '@/hooks/use-toast'
import { humanizeError } from '@/lib/errorMessage'
import { cn } from '@/lib/utils'
import { useOrderAuditLog } from '@/hooks/queries/useOrderAuditLog'
import { Skeleton } from '@/components/ui/skeleton'
import type { Order, OrderStatus, OrderType } from '@/types/database'
import type { DateRange } from '@/components/ui/DateRangePicker'

const ORDER_TYPE_LABELS: Record<OrderType, string> = {
  dine_in: 'Makan di Tempat',
  takeaway: 'Bawa Pulang',
  self_order: 'Self Order',
}

const VOIDABLE_STATUSES: OrderStatus[] = ['draft', 'confirmed', 'preparing', 'ready', 'served']
const ORDER_TABS = [
  { label: 'Semua', value: 'all' }, { label: 'Perlu verifikasi', value: 'confirmed' },
  { label: 'Menunggu bayar', value: 'draft' }, { label: 'Diproses', value: 'preparing' },
  { label: 'Selesai', value: 'paid' }, { label: 'Dibatalkan', value: 'cancelled' },
] as const

export default function OrderList() {
  const { activeOutletId } = useOutlet()
  useRealtimeOrders(activeOutletId)
  const { toast } = useToast()
  const qc = useQueryClient()

  const [dateRange, setDateRange] = useState<DateRange>({
    from: startOfDay(subDays(new Date(), 6)),
    to: endOfDay(new Date()),
  })
  const [statusFilter, setStatusFilter] = useState<string>('all')
  const typeFilter = 'all'
  const [search, setSearch] = useState('')

  const [selectedOrder, setSelectedOrder] = useState<Order | null>(null)
  const [sheetOpen, setSheetOpen] = useState(false)
  const [voidDialogOpen, setVoidDialogOpen] = useState(false)
  const [voidReason, setVoidReason] = useState('')
  const [loadingArchiveDetail, setLoadingArchiveDetail] = useState(false)
  const [page, setPage] = useState(1)
  const PAGE_SIZE = 50

  const dateFrom = dateRange.from.toISOString()
  const dateTo = dateRange.to.toISOString()
  const { data: pageData, isLoading } = useOrdersPaged(activeOutletId ?? '', {
    dateFrom,
    dateTo,
    page,
    pageSize: PAGE_SIZE,
    ...(statusFilter !== 'all' && { status: statusFilter as OrderStatus }),
    ...(typeFilter !== 'all' && { orderType: typeFilter as OrderType }),
  })
  const rawOrders = pageData?.rows ?? []
  const orders = rawOrders.filter((order) => {
    const term = search.trim().toLowerCase()
    if (!term) return true
    return order.order_number.toLowerCase().includes(term) || order.restaurant_tables?.table_number?.toLowerCase().includes(term)
  })
  const totalCount = pageData?.totalCount ?? 0

  // Filter berubah → kembali ke halaman pertama.
  // eslint-disable-next-line react-hooks/set-state-in-effect
  useEffect(() => { setPage(1) }, [activeOutletId, dateFrom, dateTo, statusFilter, typeFilter])

  const { data: staff = [] } = useStaff(activeOutletId, { enabled: !!activeOutletId })
  const { data: auditLog = [], isLoading: loadingAudit } = useOrderAuditLog(
    selectedOrder?.archived ? null : (selectedOrder?.id ?? null)
  )

  const staffMap = useMemo(
    () => Object.fromEntries(staff.map((s) => [s.id, s.full_name])),
    [staff]
  )

  const voidMutation = useMutation({
    mutationFn: async ({ id, reason }: { id: string; reason: string }) => {
      const { error } = await supabase.rpc('owner_panel_void_order', {
        p_order_id: id,
        p_reason: reason || null,
      })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['orders-paged', activeOutletId] })
      toast({ title: 'Order di-void' })
      setVoidDialogOpen(false)
      setSheetOpen(false)
      setVoidReason('')
    },
    onError: (err) => {
      toast({ title: 'Gagal void order', description: humanizeError(err), variant: 'destructive' })
    },
  })

  async function openDetail(order: Order) {
    setSelectedOrder(order)
    setSheetOpen(true)
    if (!order.archived) return

    setLoadingArchiveDetail(true)
    try {
      const { data, error } = await supabase.functions.invoke('transaction-archive', {
        body: { order_id: order.id },
      })
      if (error) throw error
      if (!data?.order) throw new Error('Detail transaksi tidak ditemukan')
      setSelectedOrder(data.order as Order)
    } catch (error) {
      toast({
        title: 'Gagal membuka transaksi lama',
        description: humanizeError(error),
        variant: 'destructive',
      })
    } finally {
      setLoadingArchiveDetail(false)
    }
  }

  function openVoidDialog() {
    setVoidReason('')
    setVoidDialogOpen(true)
  }

  if (!activeOutletId) return <NoOutlet />

  const canVoid = selectedOrder && VOIDABLE_STATUSES.includes(selectedOrder.status)

  return (
    <div className="space-y-4">
      <PageHeader title="Pesanan" subtitle="Pantau pembayaran dan proses dapur setiap pesanan outlet." />

      {/* Filters */}
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="relative min-w-[240px] flex-1"><Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" /><Input className="pl-9" value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Cari nomor pesanan atau meja" aria-label="Cari pesanan" /></div>
        <DateRangePicker value={dateRange} onChange={setDateRange} />
        <span className="text-sm text-muted-foreground ml-auto">{totalCount} pesanan</span>
      </div>
      <div className="flex gap-2 overflow-x-auto pb-1" aria-label="Filter status pesanan">{ORDER_TABS.map((tab) => <button key={tab.value} type="button" onClick={() => setStatusFilter(tab.value)} className={cn('min-h-11 whitespace-nowrap rounded-full border px-4 text-sm font-semibold', statusFilter === tab.value ? 'border-[#C62828] bg-[#C62828] text-white' : 'bg-white text-[#374151] hover:bg-gray-50')}>{tab.label}</button>)}</div>

      <DataTable
        data={orders}
        loading={isLoading}
        page={page}
        pageSize={PAGE_SIZE}
        totalCount={totalCount}
        onPageChange={setPage}
        getRowKey={(r) => r.id}
        emptyMessage="Tidak ada pesanan dalam periode ini."
        columns={[
          {
            key: 'order_number',
            header: 'No. Pesanan',
            cell: (r) => (
              <Button
                variant="link"
                className="h-auto justify-start p-0 text-left font-mono font-medium"
                onClick={() => openDetail(r)}
              >
                {r.order_number}
              </Button>
            ),
          },
          {
            key: 'date',
            header: 'Waktu',
            cell: (r) => format(new Date(r.created_at), 'HH:mm', { locale: id }),
          },
          {
            key: 'items',
            header: 'Item',
            cell: (r) => r.order_items?.length ? r.order_items.map((item) => `${item.quantity}× ${item.menu_items?.name ?? 'Item'}`).join(', ') : '—',
          },
          {
            key: 'payment',
            header: 'Pembayaran',
            cell: (r) => r.payments?.length ? <span className="rounded-full bg-green-100 px-2.5 py-1 text-xs font-semibold text-green-800">PAID</span> : <span className="rounded-full bg-amber-100 px-2.5 py-1 text-xs font-semibold text-amber-900">PENDING</span>,
          },
          {
            key: 'kitchen',
            header: 'Dapur',
            cell: (r) => <StatusBadge status={r.status} />,
          },
          {
            key: 'total',
            header: 'Total',
            cell: (r) => <CurrencyDisplay value={r.total_amount} className="font-medium" />,
          },
          {
            key: 'table',
            header: 'Meja',
            cell: (r) =>
              r.restaurant_tables
                ? `${r.restaurant_tables.table_number}${r.restaurant_tables.area ? ` (${r.restaurant_tables.area})` : ''}`
                : '—',
          },
          {
            key: 'actions',
            header: '',
            className: 'text-right',
            cell: (r) => (
              <Button variant="ghost" size="sm" onClick={() => openDetail(r)}>
                Detail
              </Button>
            ),
          },
        ]}
      />

      {/* ── Order Detail Sheet ── */}
      <Sheet open={sheetOpen} onOpenChange={setSheetOpen}>
        <SheetContent className="w-full sm:max-w-lg overflow-y-auto">
          {selectedOrder && (
            <>
              <SheetHeader className="mb-4">
                <SheetTitle className="font-mono">{selectedOrder.order_number}</SheetTitle>
                <div className="flex items-center gap-2 mt-1">
                  <StatusBadge status={selectedOrder.status} />
                  {selectedOrder.archived && (
                    <span className="rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-800">
                      Arsip
                    </span>
                  )}
                  <span className="text-sm text-muted-foreground">
                    {ORDER_TYPE_LABELS[selectedOrder.order_type]}
                  </span>
                  {selectedOrder.restaurant_tables && (
                    <span className="text-sm text-muted-foreground">
                      · Meja {selectedOrder.restaurant_tables.table_number}
                    </span>
                  )}
                </div>
              </SheetHeader>

              <div className="space-y-5">
                {/* Meta info */}
                <div className="grid grid-cols-2 gap-2 text-sm">
                  <div>
                    <p className="text-muted-foreground">Tanggal</p>
                    <p>{format(new Date(selectedOrder.created_at), 'd MMM yyyy, HH:mm', { locale: id })}</p>
                  </div>
                  <div>
                    <p className="text-muted-foreground">Kasir</p>
                    <p>{selectedOrder.archived_cashier_name ?? staffMap[selectedOrder.created_by ?? ''] ?? '—'}</p>
                  </div>
                  {selectedOrder.customer_name && (
                    <div>
                      <p className="text-muted-foreground">Pelanggan</p>
                      <p>{selectedOrder.customer_name}</p>
                    </div>
                  )}
                </div>

                <Separator />

                {/* Items */}
                <div>
                  <p className="text-sm font-semibold mb-2">Item Pesanan</p>
                  {loadingArchiveDetail ? (
                    <div className="space-y-2">
                      <Skeleton className="h-8 w-full" />
                      <Skeleton className="h-8 w-4/5" />
                    </div>
                  ) : (
                    <div className="space-y-2">
                      {selectedOrder.order_items?.map((item) => (
                      <div key={item.id} className="flex justify-between text-sm">
                        <div>
                          <span>{item.menu_items?.name ?? '—'}</span>
                          <span className="text-muted-foreground"> ×{item.quantity}</span>
                          {item.notes && (
                            <p className="text-xs text-muted-foreground">{item.notes}</p>
                          )}
                        </div>
                        <CurrencyDisplay value={item.subtotal} />
                      </div>
                      ))}
                    </div>
                  )}
                </div>

                <Separator />

                {/* Price breakdown */}
                <div className="space-y-1.5 text-sm">
                  <div className="flex justify-between">
                    <span className="text-muted-foreground">Subtotal</span>
                    <CurrencyDisplay value={selectedOrder.subtotal} />
                  </div>
                  {selectedOrder.discount_amount > 0 && (
                    <div className="flex justify-between text-green-600">
                      <span>Diskon</span>
                      <span>−<CurrencyDisplay value={selectedOrder.discount_amount} /></span>
                    </div>
                  )}
                  {selectedOrder.tax_amount > 0 && (
                    <div className="flex justify-between">
                      <span className="text-muted-foreground">Pajak</span>
                      <CurrencyDisplay value={selectedOrder.tax_amount} />
                    </div>
                  )}
                  {selectedOrder.service_charge > 0 && (
                    <div className="flex justify-between">
                      <span className="text-muted-foreground">Service</span>
                      <CurrencyDisplay value={selectedOrder.service_charge} />
                    </div>
                  )}
                  <Separator />
                  <div className="flex justify-between font-bold text-base">
                    <span>Total</span>
                    <CurrencyDisplay value={selectedOrder.total_amount} />
                  </div>
                </div>

                {/* Payment */}
                {selectedOrder.payments && selectedOrder.payments.length > 0 && (
                  <>
                    <Separator />
                    <div>
                      <p className="text-sm font-semibold mb-2">Pembayaran</p>
                      <div className="space-y-1.5">
                        {selectedOrder.payments.map((pay) => (
                          <div key={pay.id} className="flex justify-between text-sm">
                            <span className="capitalize">{pay.method}</span>
                            <CurrencyDisplay value={pay.amount} />
                          </div>
                        ))}
                      </div>
                    </div>
                  </>
                )}

                {/* Void action */}
                {canVoid && (
                  <>
                    <Separator />
                    <Button
                      variant="destructive"
                      className="w-full"
                      onClick={openVoidDialog}
                    >
                      Void Order
                    </Button>
                  </>
                )}

                {/* Audit trail */}
                <Separator />
                <div>
                  <p className="text-sm font-semibold mb-3">Riwayat Aksi</p>
                  {selectedOrder.archived ? (
                    <p className="text-sm text-muted-foreground">
                      Transaksi ini tersimpan aman di arsip privat. Detail pesanan dan pembayaran tetap dapat dilihat.
                    </p>
                  ) : loadingAudit ? (
                    <div className="space-y-2">
                      <Skeleton className="h-8 w-full" />
                      <Skeleton className="h-8 w-full" />
                    </div>
                  ) : auditLog.length === 0 ? (
                    <p className="text-sm text-muted-foreground">Belum ada riwayat aksi.</p>
                  ) : (
                    <div className="space-y-0">
                      {auditLog.map((log, idx) => (
                        <div key={log.id} className="flex gap-3 text-sm">
                          <div className="flex flex-col items-center pt-1.5">
                            <div className="h-2 w-2 rounded-full bg-primary shrink-0" />
                            {idx < auditLog.length - 1 && (
                              <div className="flex-1 w-px bg-border mt-1" />
                            )}
                          </div>
                          <div className="pb-4 flex-1 min-w-0">
                            <div className="flex items-center justify-between gap-2 flex-wrap">
                              <span className="font-medium text-xs">{log.actor_name ?? '—'}</span>
                              <span className="text-xs text-muted-foreground shrink-0">
                                {format(new Date(log.created_at), 'd MMM, HH:mm', { locale: id })}
                              </span>
                            </div>
                            <p className="text-xs text-muted-foreground">{log.action}</p>
                            {log.notes && (
                              <p className="text-xs mt-0.5 text-foreground/70">{log.notes}</p>
                            )}
                          </div>
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              </div>
            </>
          )}
        </SheetContent>
      </Sheet>

      {/* ── Void Confirmation Dialog ── */}
      <Dialog open={voidDialogOpen} onOpenChange={setVoidDialogOpen}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Void Order {selectedOrder?.order_number}?</DialogTitle>
          </DialogHeader>
          <div className="space-y-3 py-2">
            <p className="text-sm text-muted-foreground">
              Order yang di-void tidak bisa dikembalikan. Masukkan alasan void (opsional).
            </p>
            <Textarea
              rows={3}
              placeholder="Alasan void..."
              value={voidReason}
              onChange={(e) => setVoidReason(e.target.value)}
            />
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setVoidDialogOpen(false)}>
              Batal
            </Button>
            <Button
              variant="destructive"
              disabled={voidMutation.isPending}
              onClick={() => selectedOrder && voidMutation.mutate({ id: selectedOrder.id, reason: voidReason })}
            >
              {voidMutation.isPending ? 'Memproses...' : 'Void Order'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
