import { useEffect, useState } from 'react'
import { format } from 'date-fns'
import { id } from 'date-fns/locale'
import { Users, Search } from 'lucide-react'
import { useOutlet } from '@/hooks/useOutlet'
import {
  useCustomerSummary, useCustomerDetail, useCustomerOrders, useUpdateCustomerCrm,
  type CustomerSummary,
} from '@/hooks/queries/useCustomers'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { DataTable } from '@/components/ui/DataTable'
import { CurrencyDisplay } from '@/components/ui/CurrencyDisplay'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import { Badge } from '@/components/ui/badge'
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import { humanizeError } from '@/lib/errorMessage'

const TIER_COLORS: Record<string, string> = {
  bronze: 'bg-orange-100 text-orange-800', silver: 'bg-slate-200 text-slate-700',
  gold: 'bg-yellow-100 text-yellow-800', platinum: 'bg-indigo-100 text-indigo-800',
}

export default function CustomerManager() {
  const { activeOutletId } = useOutlet()
  const outletId = activeOutletId ?? ''

  const [search, setSearch] = useState('')
  const [detailId, setDetailId] = useState<string | null>(null)
  const { data: rows = [], isLoading } = useCustomerSummary(outletId, search)

  if (!activeOutletId) return <NoOutlet />

  return (
    <div className="space-y-4">
      <PageHeader title="Pelanggan (CRM)" subtitle="Database pelanggan, riwayat kunjungan, dan total belanja.">
        <div className="relative">
          <Search className="absolute left-2.5 top-2.5 h-4 w-4 text-muted-foreground" />
          <Input className="pl-8 w-64" placeholder="Cari nama / no. HP" value={search} onChange={(e) => setSearch(e.target.value)} />
        </div>
      </PageHeader>

      <DataTable
        data={rows}
        loading={isLoading}
        getRowKey={(r) => r.member_id}
        emptyMessage="Belum ada pelanggan."
        columns={[
          { key: 'name', header: 'Nama', cell: (r: CustomerSummary) => <span className="font-medium">{r.name || '(tanpa nama)'}</span> },
          { key: 'phone', header: 'No. HP', cell: (r) => r.phone },
          { key: 'tier', header: 'Tier', cell: (r) => <Badge className={`${TIER_COLORS[r.tier] ?? ''} border-0 capitalize`}>{r.tier}</Badge> },
          { key: 'orders', header: 'Kunjungan', className: 'text-right', cell: (r) => r.total_orders },
          { key: 'spent', header: 'Total Belanja', className: 'text-right', cell: (r) => <CurrencyDisplay value={Number(r.total_spent || 0)} /> },
          { key: 'last', header: 'Terakhir', cell: (r) => r.last_order_at ? format(new Date(r.last_order_at), 'dd MMM yyyy', { locale: id }) : '—' },
          {
            key: 'actions', header: '', className: 'text-right',
            cell: (r) => <Button variant="outline" size="sm" onClick={() => setDetailId(r.member_id)}>Detail</Button>,
          },
        ]}
      />

      {detailId && <CustomerDetailDialog memberId={detailId} onClose={() => setDetailId(null)} />}
    </div>
  )
}

function CustomerDetailDialog({ memberId, onClose }: { memberId: string; onClose: () => void }) {
  const { toast } = useToast()
  const { data: detail } = useCustomerDetail(memberId)
  const { data: orders = [] } = useCustomerOrders(memberId)
  const update = useUpdateCustomerCrm()

  const [name, setName] = useState('')
  const [address, setAddress] = useState('')
  const [birthday, setBirthday] = useState('')
  const [note, setNote] = useState('')

  useEffect(() => {
    if (detail) {
      /* eslint-disable react-hooks/set-state-in-effect */
      setName(detail.name ?? '')
      setAddress(detail.address ?? '')
      setBirthday(detail.birthday ?? '')
      setNote(detail.note ?? '')
      /* eslint-enable react-hooks/set-state-in-effect */
    }
  }, [detail])

  async function save() {
    try {
      await update.mutateAsync({
        id: memberId,
        name: name.trim() || null,
        address: address.trim() || null,
        birthday: birthday || null,
        note: note.trim() || null,
      })
      toast({ title: 'Data pelanggan disimpan' })
    } catch (e) {
      toast({ title: 'Gagal', description: humanizeError(e), variant: 'destructive' })
    }
  }

  return (
    <Dialog open onOpenChange={(o) => { if (!o) onClose() }}>
      <DialogContent className="max-w-2xl max-h-[90vh] flex flex-col">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2"><Users className="h-5 w-5" /> Detail Pelanggan</DialogTitle>
        </DialogHeader>

        <div className="grid md:grid-cols-2 gap-4 overflow-auto flex-1">
          {/* Profil / CRM */}
          <div className="space-y-3">
            <div className="text-sm text-muted-foreground">{detail?.phone} · <span className="capitalize">{detail?.tier}</span> · {detail?.points ?? 0} poin</div>
            <div>
              <label className="text-sm font-medium">Nama</label>
              <Input value={name} onChange={(e) => setName(e.target.value)} />
            </div>
            <div>
              <label className="text-sm font-medium">Alamat</label>
              <Textarea rows={2} value={address} onChange={(e) => setAddress(e.target.value)} />
            </div>
            <div>
              <label className="text-sm font-medium">Tanggal Lahir</label>
              <Input type="date" value={birthday} onChange={(e) => setBirthday(e.target.value)} />
            </div>
            <div>
              <label className="text-sm font-medium">Catatan</label>
              <Textarea rows={2} value={note} onChange={(e) => setNote(e.target.value)} placeholder="Preferensi, alergi, dll." />
            </div>
            <Button onClick={save} disabled={update.isPending}>{update.isPending ? 'Menyimpan…' : 'Simpan'}</Button>
          </div>

          {/* Riwayat order */}
          <div>
            <div className="text-sm font-medium mb-2">Riwayat Kunjungan</div>
            {orders.length === 0 ? (
              <p className="text-sm text-muted-foreground">Belum ada order.</p>
            ) : (
              <div className="space-y-2 max-h-[50vh] overflow-auto pr-1">
                {orders.map((o) => (
                  <div key={o.id} className="flex justify-between items-center rounded-lg border p-2 text-sm">
                    <div>
                      <div className="font-medium">#{o.order_number}</div>
                      <div className="text-muted-foreground text-xs">{format(new Date(o.created_at), 'dd MMM yyyy HH:mm', { locale: id })}</div>
                    </div>
                    <CurrencyDisplay value={Number(o.total_amount || 0)} />
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={onClose}>Tutup</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
