import { useState } from 'react'
import { Plus, Pencil, Trash2 } from 'lucide-react'
import { useOutlet } from '@/hooks/useOutlet'
import {
  useSuppliers, useUpsertSupplier, useDeleteSupplier, type Supplier,
} from '@/hooks/queries/useSuppliers'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { DataTable } from '@/components/ui/DataTable'
import { Button } from '@/components/ui/button'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import { humanizeError } from '@/lib/errorMessage'

export default function SupplierManager() {
  const { activeOutletId } = useOutlet()
  const { toast } = useToast()
  const { data: suppliers = [], isLoading } = useSuppliers(activeOutletId ?? '')
  const upsert = useUpsertSupplier()
  const del = useDeleteSupplier()

  const [open, setOpen] = useState(false)
  const [editing, setEditing] = useState<Supplier | null>(null)
  const [name, setName] = useState('')
  const [phone, setPhone] = useState('')
  const [note, setNote] = useState('')

  if (!activeOutletId) return <NoOutlet />

  function openCreate() {
    setEditing(null); setName(''); setPhone(''); setNote(''); setOpen(true)
  }
  function openEdit(s: Supplier) {
    setEditing(s); setName(s.name); setPhone(s.phone ?? ''); setNote(s.note ?? ''); setOpen(true)
  }

  async function save() {
    if (!name.trim()) return
    try {
      await upsert.mutateAsync({
        id: editing?.id,
        outlet_id: activeOutletId!,
        name: name.trim(),
        phone: phone.trim() || null,
        note: note.trim() || null,
      })
      setOpen(false)
      toast({ title: editing ? 'Supplier diperbarui' : 'Supplier ditambahkan' })
    } catch (e) {
      toast({ title: 'Gagal', description: humanizeError(e), variant: 'destructive' })
    }
  }

  async function remove(s: Supplier) {
    try {
      await del.mutateAsync({ id: s.id, outlet_id: activeOutletId! })
      toast({ title: 'Supplier dihapus' })
    } catch (e) {
      toast({ title: 'Gagal', description: humanizeError(e), variant: 'destructive' })
    }
  }

  return (
    <div className="space-y-4">
      <PageHeader
        title="Supplier / Pemasok"
        subtitle="Kelola pemasok bahan baku (dipakai saat mencatat pembelian stok)."
      >
        <Button onClick={openCreate}>
          <Plus className="h-4 w-4 mr-1" /> Tambah Supplier
        </Button>
      </PageHeader>

      <DataTable
        data={suppliers}
        loading={isLoading}
        getRowKey={(r) => r.id}
        emptyMessage="Belum ada supplier."
        columns={[
          { key: 'name', header: 'Nama', cell: (r) => <span className="font-medium">{r.name}</span> },
          { key: 'phone', header: 'Telepon', cell: (r) => r.phone ?? '—' },
          { key: 'note', header: 'Catatan', cell: (r) => <span className="text-muted-foreground">{r.note ?? '—'}</span> },
          {
            key: 'actions', header: '', className: 'text-right',
            cell: (r) => (
              <div className="flex justify-end gap-1">
                <Button variant="ghost" size="icon-sm" onClick={() => openEdit(r)} aria-label={`Edit supplier ${r.name}`}>
                  <Pencil className="h-4 w-4" />
                </Button>
                <ConfirmDialog
                  title={`Hapus supplier "${r.name}"?`}
                  description="Supplier akan dihapus dari daftar pemasok."
                  confirmLabel="Hapus"
                  destructive
                  onConfirm={() => remove(r)}
                  trigger={
                    <Button variant="ghost" size="icon-sm" aria-label={`Hapus supplier ${r.name}`}>
                      <Trash2 className="h-4 w-4 text-destructive" />
                    </Button>
                  }
                />
              </div>
            ),
          },
        ]}
      />

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{editing ? 'Edit Supplier' : 'Tambah Supplier'}</DialogTitle>
          </DialogHeader>
          <div className="space-y-3">
            <div>
              <label className="text-sm font-medium">Nama *</label>
              <Input value={name} onChange={(e) => setName(e.target.value)} placeholder="Nama supplier" />
            </div>
            <div>
              <label className="text-sm font-medium">Telepon</label>
              <Input value={phone} onChange={(e) => setPhone(e.target.value)} placeholder="08…" />
            </div>
            <div>
              <label className="text-sm font-medium">Catatan</label>
              <Textarea value={note} onChange={(e) => setNote(e.target.value)} rows={2} />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)}>Batal</Button>
            <Button onClick={save} disabled={!name.trim() || upsert.isPending}>
              {upsert.isPending ? 'Menyimpan…' : 'Simpan'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
