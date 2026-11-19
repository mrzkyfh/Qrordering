import { useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { endOfDay, format, startOfDay, subDays } from 'date-fns'
import { id } from 'date-fns/locale'
import { Download } from 'lucide-react'
import { useOutlet } from '@/hooks/useOutlet'
import { fetchAllOrders, useOrders } from '@/hooks/queries/useOrders'
import { useDailySales, useTopMenuItemsRange } from '@/hooks/queries/useSales'
import { useLowStock } from '@/hooks/queries/useIngredients'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { DateRangePicker, type DateRange } from '@/components/ui/DateRangePicker'
import { Button } from '@/components/ui/button'
import { CurrencyDisplay } from '@/components/ui/CurrencyDisplay'
import { exportReportExcel } from '@/utils/exportReport'
import { formatCurrency } from '@/lib/currency'
import { cn } from '@/lib/utils'

type Tab = 'sales' | 'payment' | 'products' | 'closing' | 'stock'
const tabs: { value: Tab; label: string }[] = [
  { value: 'sales', label: 'Penjualan' }, { value: 'payment', label: 'Metode bayar' },
  { value: 'products', label: 'Produk terlaris' }, { value: 'closing', label: 'Tutup harian' },
  { value: 'stock', label: 'Stok' },
]

export default function Reports() {
  const { activeOutletId, activeOutlet } = useOutlet()
  const [tab, setTab] = useState<Tab>('closing')
  const [renderedAt] = useState(() => Date.now())
  const [range, setRange] = useState<DateRange>({ from: startOfDay(subDays(new Date(), 6)), to: endOfDay(new Date()) })
  const fromIso = range.from.toISOString(); const toIso = range.to.toISOString()
  const fromKey = format(range.from, 'yyyy-MM-dd'); const toKey = format(range.to, 'yyyy-MM-dd')
  const { data: daily = [], isLoading } = useDailySales(activeOutletId, range)
  const { data: top = [] } = useTopMenuItemsRange(activeOutletId, fromKey, toKey)
  const { data: low = [] } = useLowStock(activeOutletId ?? '')
  const { data: cancelled = [] } = useOrders(activeOutletId ?? '', { dateFrom: fromIso, dateTo: toIso, status: ['cancelled', 'void'] })
  const { data: draftOrders = [] } = useOrders(activeOutletId ?? '', { dateFrom: fromIso, dateTo: toIso, status: 'draft' })
  const { data: paid = [] } = useQuery({ queryKey: ['report-paid-all', activeOutletId, fromIso, toIso], enabled: !!activeOutletId, queryFn: () => fetchAllOrders(activeOutletId!, { dateFrom: fromIso, dateTo: toIso, status: 'paid' }) })
  const methods = useMemo(() => paid.reduce((map, order) => { order.payments?.forEach((payment) => { const current = map.get(payment.method) ?? { count: 0, amount: 0 }; current.count += 1; current.amount += Number(payment.amount); map.set(payment.method, current) }); return map }, new Map<string, { count: number; amount: number }>()), [paid])
  const total = daily.reduce((sum, row) => sum + Number(row.gross_revenue), 0)
  const transactions = daily.reduce((sum, row) => sum + Number(row.total_orders), 0)
  const expiredCount = draftOrders.filter((order) => renderedAt - new Date(order.created_at).getTime() > (activeOutlet?.settings.payment_timeout_minutes ?? 15) * 60_000).length

  if (!activeOutletId) return <NoOutlet />
  const methodLabel: Record<string, string> = { cash: 'Tunai (bayar ke petugas)', qris: 'QRIS terverifikasi', debit: 'Debit', credit: 'Kredit', ewallet: 'E-Wallet', transfer: 'Transfer' }
  function download() {
    const rows = paid.map((order) => [order.order_number, format(new Date(order.created_at), 'd MMM yyyy HH:mm', { locale: id }), order.restaurant_tables?.table_number ?? '—', order.total_amount, order.payments?.map((p) => methodLabel[p.method] ?? p.method).join(', ') ?? '—'])
    exportReportExcel({ title: 'Laporan Penjualan', outletName: activeOutlet?.name ?? 'Outlet', period: `${format(range.from, 'd MMM yyyy')} – ${format(range.to, 'd MMM yyyy')}`, summaryStats: [{ label: 'Total penjualan', value: formatCurrency(total) }, { label: 'Transaksi', value: String(transactions) }], tableHeaders: ['Pesanan','Waktu','Meja','Total','Pembayaran'], tableRows: rows, filename: `laporan-${fromKey}-${toKey}.xls` })
  }
  return <div className="space-y-4">
    <PageHeader title="Laporan" subtitle="Angka penjualan hanya menghitung pembayaran yang sudah dikonfirmasi petugas."><DateRangePicker value={range} onChange={setRange} /><Button variant="outline" onClick={download}><Download className="mr-2 h-4 w-4" />Unduh laporan</Button></PageHeader>
    <div className="flex gap-2 overflow-x-auto">{tabs.map((item) => <button key={item.value} type="button" onClick={() => setTab(item.value)} className={cn('min-h-11 whitespace-nowrap rounded-full border px-5 text-sm font-semibold', tab === item.value ? 'border-[#0F766E] bg-[#0F766E] text-white' : 'bg-white text-[#374151]')}>{item.label}</button>)}</div>
    <div className="grid items-start gap-4 xl:grid-cols-[minmax(0,1.6fr)_minmax(300px,.7fr)]">
      <section className="admin-card min-h-[520px] p-6"><h2 className="text-lg font-bold">{tab === 'closing' ? `Tutup harian · ${format(range.to, 'd MMM yyyy', { locale: id })}` : tabs.find((item) => item.value === tab)?.label}</h2><p className="text-sm text-muted-foreground">Untuk dicocokkan dengan uang tunai dan mutasi merchant.</p>
        {isLoading ? <p className="py-12 text-center text-muted-foreground">Memuat laporan...</p> : <>
          {(tab === 'closing' || tab === 'payment' || tab === 'sales') && <div className="mt-5 overflow-x-auto"><table className="w-full min-w-[560px] text-sm"><thead className="border-b text-left text-xs uppercase text-muted-foreground"><tr><th className="py-3">Metode</th><th className="py-3 text-right">Transaksi</th><th className="py-3 text-right">Jumlah</th></tr></thead><tbody>{methods.size === 0 ? <tr><td colSpan={3} className="py-10 text-center text-muted-foreground">Belum ada pembayaran terverifikasi.</td></tr> : Array.from(methods.entries()).map(([method, value]) => <tr key={method} className="border-b"><td className="py-4 font-medium">{methodLabel[method] ?? method}</td><td className="py-4 text-right">{value.count}</td><td className="py-4 text-right font-semibold"><CurrencyDisplay value={value.amount} /></td></tr>)}<tr className="border-t-2"><td className="py-4 font-bold">Total penjualan</td><td className="py-4 text-right font-bold">{transactions}</td><td className="py-4 text-right text-lg font-bold"><CurrencyDisplay value={total} /></td></tr></tbody></table></div>}
          {tab === 'products' && <SimpleList rows={top.map((item) => [item.menu_item_name, `${item.qty_sold} porsi`])} empty="Belum ada produk terjual." />}
          {tab === 'stock' && <SimpleList rows={low.map((item) => [item.name, item.status === 'out_of_stock' ? 'Habis' : `Sisa ${item.stock_qty}`])} empty="Tidak ada stok yang perlu diisi." />}
          {tab === 'closing' && <div className="mt-6"><h3 className="font-semibold">Perlu perhatian</h3><div className="mt-2 divide-y"><div className="flex justify-between py-3 text-sm"><span>Klaim QRIS belum terverifikasi</span><span className="rounded-full bg-amber-100 px-2.5 py-1 text-xs font-semibold text-amber-900">Lihat Pesanan</span></div><div className="flex justify-between py-3 text-sm"><span>Pesanan dibatalkan</span><span className="rounded-full bg-gray-200 px-2.5 py-1 text-xs font-semibold">{cancelled.length}</span></div><div className="flex justify-between py-3 text-sm"><span>Pesanan kedaluwarsa</span><span className="rounded-full bg-gray-200 px-2.5 py-1 text-xs font-semibold">{expiredCount}</span></div></div></div>}
        </>}
      </section>
      <aside className="space-y-4"><section className="admin-card p-5"><h2 className="font-bold">Produk terlaris</h2><SimpleList rows={top.slice(0,4).map((item) => [item.menu_item_name, `${item.qty_sold} porsi`])} empty="Belum ada penjualan." compact /></section><section className="admin-card p-5"><h2 className="font-bold">Stok perlu diisi</h2><SimpleList rows={low.slice(0,5).map((item) => [item.name, item.status === 'out_of_stock' ? 'Habis' : `Sisa ${item.stock_qty}`])} empty="Stok aman." compact /></section></aside>
    </div>
  </div>
}

function SimpleList({ rows, empty, compact = false }: { rows: (string | number)[][]; empty: string; compact?: boolean }) { return rows.length === 0 ? <p className="py-8 text-center text-sm text-muted-foreground">{empty}</p> : <div className={compact ? 'mt-3 divide-y' : 'mt-5 divide-y'}>{rows.map((row, index) => <div key={`${row[0]}-${index}`} className="flex items-center justify-between gap-4 py-3 text-sm"><span className="font-medium">{row[0]}</span><span className="text-muted-foreground">{row[1]}</span></div>)}</div> }
