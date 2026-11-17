import { useEffect, useState } from 'react'
import { Plus, ClipboardCheck, ArrowLeft, CheckCircle2 } from 'lucide-react'
import { useOutlet } from '@/hooks/useOutlet'
import {
  useStockOpnames, useStockOpnameItems, useCreateStockOpname,
  useUpdateOpnameItem, useFinalizeStockOpname,
  type StockOpname, type StockOpnameItem,
} from '@/hooks/queries/useStockOpname'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { DataTable } from '@/components/ui/DataTable'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter,
} from '@/components/ui/dialog'
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from '@/components/ui/alert-dialog'
import { useToast } from '@/hooks/use-toast'
import { humanizeError } from '@/lib/errorMessage'
import { format } from 'date-fns'
import { id } from 'date-fns/locale'

const fmtQty = (n: number) => Number(n).toLocaleString('id-ID', { maximumFractionDigits: 3 })

export default function StockOpname() {
  const { activeOutletId } = useOutlet()
  const { toast } = useToast()
  const outletId = activeOutletId ?? ''

  const { data: opnames = [], isLoading } = useStockOpnames(outletId)
  const createOpname = useCreateStockOpname()

  const [detailId, setDetailId] = useState<string | null>(null)
  const [createOpen, setCreateOpen] = useState(false)
  const [newNote, setNewNote] = useState('')

  if (!activeOutletId) return <NoOutlet />

  const detailOpname = opnames.find((o) => o.id === detailId) ?? null

  async function doCreate() {
    try {
      const newId = await createOpname.mutateAsync({ outlet_id: outletId, note: newNote.trim() || undefined })
      setCreateOpen(false)
      setNewNote('')
      setDetailId(newId)
      toast({ title: 'Opname dibuat', description: 'Isi jumlah fisik lalu finalisasi.' })
    } catch (e) {
      toast({ title: 'Gagal', description: humanizeError(e), variant: 'destructive' })
    }
  }

  return (
    <div className="space-y-4">
      <PageHeader
        title="Stok Opname"
        subtitle="Hitung stok fisik vs sistem. Finalisasi menyesuaikan stok otomatis sesuai hitungan fisik."
      >
        <Button onClick={() => { setNewNote(''); setCreateOpen(true) }}>
          <Plus className="h-4 w-4 mr-1" /> Buat Opname
        </Button>
      </PageHeader>

      <DataTable
        data={opnames}
        loading={isLoading}
        getRowKey={(r) => r.id}
        emptyMessage="Belum ada opname."
        columns={[
          {
            key: 'created_at', header: 'Tanggal',
            cell: (r: StockOpname) => format(new Date(r.created_at), 'dd MMM yyyy HH:mm', { locale: id }),
          },
          { key: 'note', header: 'Catatan', cell: (r) => <span className="text-muted-foreground">{r.note ?? '—'}</span> },
          {
            key: 'status', header: 'Status',
            cell: (r) => (
              <Badge className={r.status === 'final' ? 'bg-green-100 text-green-800 border-0' : 'bg-yellow-100 text-yellow-800 border-0'}>
                {r.status === 'final' ? 'Final' : 'Draft'}
              </Badge>
            ),
          },
          {
            key: 'actions', header: '', className: 'text-right',
            cell: (r) => (
              <Button variant="outline" size="sm" onClick={() => setDetailId(r.id)}>
                {r.status === 'final' ? 'Lihat' : 'Isi / Finalisasi'}
              </Button>
            ),
          },
        ]}
      />

      {/* Dialog buat opname */}
      <Dialog open={createOpen} onOpenChange={setCreateOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Buat Opname Baru</DialogTitle>
          </DialogHeader>
          <p className="text-sm text-muted-foreground">
            Sistem akan memotret stok semua bahan aktif saat ini. Anda tinggal mengisi jumlah fisik hasil hitung.
          </p>
          <div>
            <label className="text-sm font-medium">Catatan (opsional)</label>
            <Textarea value={newNote} onChange={(e) => setNewNote(e.target.value)} rows={2} placeholder="mis. Opname akhir bulan" />
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setCreateOpen(false)}>Batal</Button>
            <Button onClick={doCreate} disabled={createOpname.isPending}>
              {createOpname.isPending ? 'Membuat…' : 'Buat & Mulai'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {detailOpname && (
        <OpnameDetail
          key={detailOpname.id}
          opname={detailOpname}
          outletId={outletId}
          onClose={() => setDetailId(null)}
        />
      )}
    </div>
  )
}

// ── Detail opname: isi fisik + finalisasi ─────────────────────────────────────

function OpnameDetail({ opname, outletId, onClose }: {
  opname: StockOpname; outletId: string; onClose: () => void
}) {
  const { toast } = useToast()
  const { data: items = [], isLoading } = useStockOpnameItems(opname.id)
  const updateItem = useUpdateOpnameItem()
  const finalize = useFinalizeStockOpname()

  const readOnly = opname.status === 'final'
  const [physical, setPhysical] = useState<Record<string, string>>({})
  const [confirmOpen, setConfirmOpen] = useState(false)

  // Seed input lokal dari data server sekali saat items termuat.
  useEffect(() => {
    const seed: Record<string, string> = {}
    for (const it of items) seed[it.id] = it.physical_qty == null ? '' : String(it.physical_qty)
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setPhysical(seed)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [items.length])

  const diffOf = (it: StockOpnameItem): number | null => {
    const raw = physical[it.id]
    if (raw == null || raw === '') return null
    const v = parseFloat(raw)
    if (Number.isNaN(v)) return null
    return v - Number(it.system_qty)
  }

  const changedCount = items.filter((it) => {
    const raw = physical[it.id] ?? ''
    const orig = it.physical_qty == null ? '' : String(it.physical_qty)
    return raw !== orig
  }).length

  const diffItems = items.filter((it) => {
    const d = diffOf(it)
    return d != null && d !== 0
  })

  async function saveCounts() {
    try {
      const changed = items.filter((it) => {
        const raw = physical[it.id] ?? ''
        const orig = it.physical_qty == null ? '' : String(it.physical_qty)
        return raw !== orig
      })
      await Promise.all(changed.map((it) => {
        const raw = physical[it.id] ?? ''
        const val = raw === '' ? null : parseFloat(raw)
        return updateItem.mutateAsync({ id: it.id, opname_id: opname.id, physical_qty: Number.isNaN(val as number) ? null : val })
      }))
      toast({ title: 'Perhitungan disimpan' })
      return true
    } catch (e) {
      toast({ title: 'Gagal simpan', description: humanizeError(e), variant: 'destructive' })
      return false
    }
  }

  async function doFinalize() {
    try {
      if (changedCount > 0 && !(await saveCounts())) return
      await finalize.mutateAsync({ opname_id: opname.id, outlet_id: outletId })
      setConfirmOpen(false)
      toast({ title: 'Opname difinalisasi', description: 'Stok sistem disesuaikan ke hitungan fisik.' })
      onClose()
    } catch (e) {
      toast({ title: 'Gagal finalisasi', description: humanizeError(e), variant: 'destructive' })
    }
  }

  return (
    <Dialog open onOpenChange={(o) => { if (!o) onClose() }}>
      <DialogContent className="max-w-3xl max-h-[90vh] flex flex-col">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <ClipboardCheck className="h-5 w-5" />
            {readOnly ? 'Detail Opname (Final)' : 'Isi Stok Opname'}
          </DialogTitle>
        </DialogHeader>

        <div className="overflow-auto flex-1 -mx-2 px-2">
          <table className="w-full text-sm">
            <thead className="sticky top-0 bg-background">
              <tr className="border-b text-left text-muted-foreground">
                <th className="py-2 pr-2">Bahan</th>
                <th className="py-2 px-2 text-right">Sistem</th>
                <th className="py-2 px-2 text-right">Fisik</th>
                <th className="py-2 pl-2 text-right">Selisih</th>
              </tr>
            </thead>
            <tbody>
              {isLoading && <tr><td colSpan={4} className="py-6 text-center text-muted-foreground">Memuat…</td></tr>}
              {!isLoading && items.length === 0 && (
                <tr><td colSpan={4} className="py-6 text-center text-muted-foreground">Tidak ada bahan aktif.</td></tr>
              )}
              {items.map((it) => {
                const d = readOnly ? it.diff : diffOf(it)
                const unit = it.ingredients?.unit ?? ''
                return (
                  <tr key={it.id} className="border-b last:border-0">
                    <td className="py-2 pr-2 font-medium">{it.ingredients?.name ?? '—'}</td>
                    <td className="py-2 px-2 text-right tabular-nums text-muted-foreground">{fmtQty(it.system_qty)} {unit}</td>
                    <td className="py-2 px-2 text-right">
                      {readOnly ? (
                        <span className="tabular-nums">{it.physical_qty == null ? '—' : `${fmtQty(it.physical_qty)} ${unit}`}</span>
                      ) : (
                        <Input
                          type="number" inputMode="decimal" step="any"
                          className="h-8 w-28 ml-auto text-right"
                          value={physical[it.id] ?? ''}
                          onChange={(e) => setPhysical((p) => ({ ...p, [it.id]: e.target.value }))}
                          placeholder="—"
                        />
                      )}
                    </td>
                    <td className="py-2 pl-2 text-right tabular-nums">
                      {d == null ? <span className="text-muted-foreground">—</span> : (
                        <span className={d === 0 ? 'text-muted-foreground' : d > 0 ? 'text-emerald-600' : 'text-destructive'}>
                          {d > 0 ? '+' : ''}{fmtQty(d)} {unit}
                        </span>
                      )}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>

        <DialogFooter className="flex-col sm:flex-row sm:justify-between gap-2 border-t pt-3">
          <Button variant="ghost" onClick={onClose}>
            <ArrowLeft className="h-4 w-4 mr-1" /> Tutup
          </Button>
          {!readOnly && (
            <div className="flex gap-2">
              <Button variant="outline" onClick={saveCounts} disabled={changedCount === 0 || updateItem.isPending}>
                Simpan{changedCount > 0 ? ` (${changedCount})` : ''}
              </Button>
              <Button onClick={() => setConfirmOpen(true)} disabled={finalize.isPending || updateItem.isPending}>
                <CheckCircle2 className="h-4 w-4 mr-1" /> Finalisasi
              </Button>
            </div>
          )}
        </DialogFooter>
      </DialogContent>

      <AlertDialog
        open={confirmOpen}
        onOpenChange={(open) => {
          if (!finalize.isPending && !updateItem.isPending) setConfirmOpen(open)
        }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Finalisasi opname?</AlertDialogTitle>
            <AlertDialogDescription asChild>
              <div className="space-y-2">
                <p>
                  {diffItems.length === 0
                    ? 'Tidak ada selisih. Stok tidak berubah.'
                    : `${diffItems.length} bahan akan disesuaikan stoknya ke hitungan fisik:`}
                </p>
                {diffItems.length > 0 && (
                  <ul className="max-h-40 overflow-auto text-sm border rounded-md p-2 space-y-1">
                    {diffItems.map((it) => {
                      const d = diffOf(it)!
                      return (
                        <li key={it.id} className="flex justify-between gap-4">
                          <span>{it.ingredients?.name}</span>
                          <span className={d > 0 ? 'text-emerald-600' : 'text-destructive'}>
                            {d > 0 ? '+' : ''}{fmtQty(d)} {it.ingredients?.unit ?? ''}
                          </span>
                        </li>
                      )
                    })}
                  </ul>
                )}
                <p className="text-xs text-muted-foreground">Tindakan ini tidak bisa dibatalkan.</p>
              </div>
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={finalize.isPending || updateItem.isPending}>Batal</AlertDialogCancel>
            <AlertDialogAction
              onClick={(event) => {
                event.preventDefault()
                void doFinalize()
              }}
              disabled={finalize.isPending || updateItem.isPending}
            >
              {finalize.isPending || updateItem.isPending ? 'Memproses…' : 'Ya, Finalisasi'}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </Dialog>
  )
}
