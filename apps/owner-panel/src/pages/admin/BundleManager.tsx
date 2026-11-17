import { useEffect, useState } from 'react'
import { Plus, Pencil, Trash2, Package, X } from 'lucide-react'
import { useOutlet } from '@/hooks/useOutlet'
import { useMenuCategories } from '@/hooks/queries/useMenuItems'
import {
  useBundles, useNonBundleItems, useBundleComponents, useUpsertBundle, useDeleteBundle,
  type ComponentInput,
} from '@/hooks/queries/useBundles'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { DataTable } from '@/components/ui/DataTable'
import { CurrencyDisplay } from '@/components/ui/CurrencyDisplay'
import { Button } from '@/components/ui/button'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { Input } from '@/components/ui/input'
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter,
} from '@/components/ui/dialog'
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from '@/components/ui/select'
import { useToast } from '@/hooks/use-toast'
import { humanizeError } from '@/lib/errorMessage'
import type { MenuItem } from '@/types/database'

export default function BundleManager() {
  const { activeOutletId } = useOutlet()
  const { toast } = useToast()
  const outletId = activeOutletId ?? ''

  const { data: bundles = [], isLoading } = useBundles(outletId)
  const { data: items = [] } = useNonBundleItems(outletId)
  const { data: categories = [] } = useMenuCategories(outletId)
  const upsert = useUpsertBundle()
  const del = useDeleteBundle()

  const [open, setOpen] = useState(false)
  const [editing, setEditing] = useState<MenuItem | null>(null)

  if (!activeOutletId) return <NoOutlet />

  function openCreate() { setEditing(null); setOpen(true) }
  function openEdit(b: MenuItem) { setEditing(b); setOpen(true) }

  async function remove(b: MenuItem) {
    try {
      await del.mutateAsync({ id: b.id, outlet_id: outletId })
      toast({ title: 'Paket dinonaktifkan' })
    } catch (e) {
      toast({ title: 'Gagal', description: humanizeError(e), variant: 'destructive' })
    }
  }

  return (
    <div className="space-y-4">
      <PageHeader
        title="Paket / Bundling"
        subtitle="Jual kombinasi beberapa menu sebagai satu paket berharga sendiri. Stok komponen otomatis terpotong saat terjual."
      >
        <Button onClick={openCreate}><Plus className="h-4 w-4 mr-1" /> Buat Paket</Button>
      </PageHeader>

      <DataTable
        data={bundles}
        loading={isLoading}
        getRowKey={(r) => r.id}
        emptyMessage="Belum ada paket."
        columns={[
          { key: 'name', header: 'Nama Paket', cell: (r) => <span className="font-medium">{r.name}</span> },
          { key: 'category', header: 'Kategori', cell: (r) => r.menu_categories?.name ?? '—' },
          { key: 'price', header: 'Harga', cell: (r) => <CurrencyDisplay value={r.price} /> },
          {
            key: 'actions', header: '', className: 'text-right',
            cell: (r) => (
              <div className="flex justify-end gap-1">
                <Button variant="ghost" size="icon-sm" onClick={() => openEdit(r)} aria-label={`Edit paket ${r.name}`}>
                  <Pencil className="h-4 w-4" />
                </Button>
                <ConfirmDialog
                  title={`Nonaktifkan paket "${r.name}"?`}
                  description="Paket tidak lagi ditawarkan, tetapi riwayat transaksi tetap tersimpan."
                  confirmLabel="Nonaktifkan"
                  destructive
                  onConfirm={() => remove(r)}
                  trigger={
                    <Button variant="ghost" size="icon-sm" aria-label={`Nonaktifkan paket ${r.name}`}>
                      <Trash2 className="h-4 w-4 text-destructive" />
                    </Button>
                  }
                />
              </div>
            ),
          },
        ]}
      />

      {open && (
        <BundleDialog
          key={editing?.id ?? 'new'}
          bundle={editing}
          outletId={outletId}
          items={items}
          categories={categories}
          onClose={() => setOpen(false)}
          onSaved={() => { setOpen(false); toast({ title: editing ? 'Paket diperbarui' : 'Paket dibuat' }) }}
          upsert={upsert}
        />
      )}
    </div>
  )
}

function BundleDialog({ bundle, outletId, items, categories, onClose, onSaved, upsert }: {
  bundle: MenuItem | null
  outletId: string
  items: { id: string; name: string; price: number }[]
  categories: { id: string; name: string }[]
  onClose: () => void
  onSaved: () => void
  upsert: ReturnType<typeof useUpsertBundle>
}) {
  const { toast } = useToast()
  const { data: existing = [] } = useBundleComponents(bundle?.id ?? null)

  const [name, setName] = useState(bundle?.name ?? '')
  const [price, setPrice] = useState(bundle ? String(bundle.price) : '')
  const [categoryId, setCategoryId] = useState<string>(bundle?.category_id ?? '')
  const [components, setComponents] = useState<ComponentInput[]>([])

  // Seed komponen saat data existing termuat (mode edit).
  useEffect(() => {
    if (bundle && existing.length > 0) {
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setComponents(existing.map((c) => ({ component_id: c.component_id, qty: Number(c.qty) })))
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [existing.length])

  const itemPrice = (id: string) => items.find((i) => i.id === id)?.price ?? 0
  const normalTotal = components.reduce((s, c) => s + itemPrice(c.component_id) * c.qty, 0)
  // Harga disimpan sbg digit polos; ditampilkan berformat ribuan (id-ID).
  const priceNum = Number(price) || 0
  const saving = priceNum > 0 ? normalTotal - priceNum : 0

  function addComponent() {
    const firstFree = items.find((i) => !components.some((c) => c.component_id === i.id))
    if (!firstFree) { toast({ title: 'Semua menu sudah dipakai' }); return }
    setComponents((cs) => [...cs, { component_id: firstFree.id, qty: 1 }])
  }
  function updateComponent(idx: number, patch: Partial<ComponentInput>) {
    setComponents((cs) => cs.map((c, i) => (i === idx ? { ...c, ...patch } : c)))
  }
  function removeComponent(idx: number) {
    setComponents((cs) => cs.filter((_, i) => i !== idx))
  }

  async function save() {
    if (!name.trim()) { toast({ title: 'Nama wajib diisi', variant: 'destructive' }); return }
    if (priceNum <= 0) { toast({ title: 'Harga harus lebih dari 0', variant: 'destructive' }); return }
    if (components.length === 0) { toast({ title: 'Tambahkan minimal 1 komponen', variant: 'destructive' }); return }
    try {
      await upsert.mutateAsync({
        id: bundle?.id,
        outlet_id: outletId,
        name: name.trim(),
        price: priceNum,
        category_id: categoryId || null,
        components,
      })
      onSaved()
    } catch (e) {
      toast({ title: 'Gagal simpan', description: humanizeError(e), variant: 'destructive' })
    }
  }

  return (
    <Dialog open onOpenChange={(o) => { if (!o) onClose() }}>
      <DialogContent className="max-w-lg max-h-[90vh] flex flex-col">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <Package className="h-5 w-5" /> {bundle ? 'Edit Paket' : 'Buat Paket'}
          </DialogTitle>
        </DialogHeader>

        <div className="space-y-3 overflow-auto flex-1">
          <div>
            <label className="text-sm font-medium">Nama Paket *</label>
            <Input value={name} onChange={(e) => setName(e.target.value)} placeholder="mis. Paket Hemat Kopi + Roti" />
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="text-sm font-medium">Harga Paket *</label>
              <Input
                inputMode="numeric"
                placeholder="0"
                value={price ? Number(price).toLocaleString('id-ID') : ''}
                onChange={(e) => setPrice(e.target.value.replace(/\D/g, ''))}
              />
            </div>
            <div>
              <label className="text-sm font-medium">Kategori</label>
              <Select value={categoryId} onValueChange={setCategoryId}>
                <SelectTrigger><SelectValue placeholder="Pilih kategori" /></SelectTrigger>
                <SelectContent>
                  {categories.map((c) => <SelectItem key={c.id} value={c.id}>{c.name}</SelectItem>)}
                </SelectContent>
              </Select>
            </div>
          </div>

          <div>
            <div className="flex items-center justify-between mb-1">
              <label className="text-sm font-medium">Komponen</label>
              <Button type="button" variant="outline" size="sm" onClick={addComponent}>
                <Plus className="h-3.5 w-3.5 mr-1" /> Tambah
              </Button>
            </div>
            <div className="space-y-2">
              {components.length === 0 && <p className="text-sm text-muted-foreground">Belum ada komponen.</p>}
              {components.map((c, idx) => (
                <div key={idx} className="flex items-center gap-2">
                  <Select value={c.component_id} onValueChange={(v) => updateComponent(idx, { component_id: v })}>
                    <SelectTrigger className="flex-1"><SelectValue /></SelectTrigger>
                    <SelectContent>
                      {items
                        .filter((i) => i.id === c.component_id || !components.some((x) => x.component_id === i.id))
                        .map((i) => <SelectItem key={i.id} value={i.id}>{i.name}</SelectItem>)}
                    </SelectContent>
                  </Select>
                  <Input
                    type="number" min={1} step="1" className="w-20"
                    value={c.qty}
                    onChange={(e) => updateComponent(idx, { qty: Math.max(1, parseInt(e.target.value) || 1) })}
                  />
                  <Button type="button" variant="ghost" size="icon-sm" onClick={() => removeComponent(idx)} aria-label={`Hapus komponen ${idx + 1}`}>
                    <X className="h-4 w-4" />
                  </Button>
                </div>
              ))}
            </div>
          </div>

          {components.length > 0 && (
            <div className="rounded-lg bg-muted/50 p-3 text-sm space-y-1">
              <div className="flex justify-between">
                <span className="text-muted-foreground">Total harga normal komponen</span>
                <CurrencyDisplay value={normalTotal} />
              </div>
              <div className="flex justify-between font-medium">
                <span>Hemat</span>
                <span className={saving > 0 ? 'text-emerald-600' : saving < 0 ? 'text-destructive' : ''}>
                  <CurrencyDisplay value={saving} />
                </span>
              </div>
            </div>
          )}
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={onClose}>Batal</Button>
          <Button onClick={save} disabled={upsert.isPending}>
            {upsert.isPending ? 'Menyimpan…' : 'Simpan'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
