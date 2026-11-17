import { useState, useEffect } from 'react'
import { useOutlet } from '@/hooks/useOutlet'
import { useUpdateOutlet } from '@/hooks/queries/useOutlets'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { Switch } from '@/components/ui/switch'
import { Label } from '@/components/ui/label'
import { Separator } from '@/components/ui/separator'
import { Checkbox } from '@/components/ui/checkbox'
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Search, Pencil, Plus, Trash2 } from 'lucide-react'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { cn } from '@/lib/utils'
import { useToast } from '@/hooks/use-toast'
import type { TaxConfig } from '@/types/database'
import { humanizeError } from '@/lib/errorMessage'

const ORDER_TYPES = [
  { value: 'dine_in', label: 'Dine In' },
  { value: 'takeaway', label: 'Takeaway' },
  { value: 'self_order', label: 'Self Order' },
]

const CALC_OPTIONS = [
  {
    value: 'before_discount',
    label: 'Pajak Sebelum Diskon',
    desc: 'Pajak dihitung dari harga sebelum diskon diterapkan',
  },
  {
    value: 'after_discount',
    label: 'Pajak Sesudah Diskon',
    desc: 'Pajak dihitung dari harga setelah diskon diterapkan',
  },
]

const APPLY_OPTIONS = [
  {
    isInclusive: false,
    label: 'Ditambahkan ke total (Exclusive)',
    desc: 'Pajak dihitung dari harga jual, lalu ditambahkan ke total tagihan',
  },
  {
    isInclusive: true,
    label: 'Sudah termasuk dalam harga (Inclusive)',
    desc: 'Harga jual sudah termasuk pajak. Pajak diekstrak dari harga',
  },
]

function RadioRow({
  selected, onClick, label, desc, disabled,
}: {
  selected: boolean; onClick: () => void; label: string; desc: string; disabled?: boolean
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      aria-pressed={selected}
      className={cn(
        'w-full flex items-start gap-3 rounded-lg border px-4 py-3 text-left transition-colors disabled:opacity-50',
        selected ? 'border-primary bg-primary/5' : 'border-border hover:bg-muted/50'
      )}
    >
      <span className={cn(
        'flex h-4 w-4 items-center justify-center rounded-full border-2 mt-0.5 shrink-0',
        selected ? 'border-primary' : 'border-muted-foreground/40'
      )}>
        {selected && <span className="h-2 w-2 rounded-full bg-primary" />}
      </span>
      <div>
        <p className="text-sm font-medium">{label}</p>
        <p className="text-xs text-muted-foreground mt-0.5">{desc}</p>
      </div>
    </button>
  )
}

function emptyTax(): TaxConfig {
  return {
    id: crypto.randomUUID(),
    name: '',
    percent: 0,
    active: true,
    inclusive: false,
    calculation: 'before_discount',
    order_types: [],
  }
}

export default function TaxSettings() {
  const { activeOutlet, activeOutletId } = useOutlet()
  const update = useUpdateOutlet()
  const { toast } = useToast()

  const [search, setSearch] = useState('')
  const [taxes, setTaxes] = useState<TaxConfig[]>([])
  const [editTax, setEditTax] = useState<TaxConfig | null>(null)
  const [isNew, setIsNew] = useState(false)

  // Local form state for dialog
  const [form, setForm] = useState<TaxConfig>(emptyTax())

  // Sinkronisasi pengaturan outlet (context) → state form lokal + migrasi pajak legacy
  /* eslint-disable react-hooks/set-state-in-effect */
  useEffect(() => {
    if (!activeOutlet) return
    const s = activeOutlet.settings
    if (s?.taxes && s.taxes.length > 0) {
      setTaxes(s.taxes)
    } else if (s?.tax_percent !== undefined) {
      // Migrate legacy single-tax to array
      setTaxes([{
        id: crypto.randomUUID(),
        name: s.tax_name ?? 'PPN',
        percent: s.tax_percent ?? 0,
        active: s.tax_active ?? true,
        inclusive: s.tax_inclusive ?? false,
        calculation: s.tax_calculation ?? 'before_discount',
        order_types: s.tax_order_types ?? [],
      }])
    }
  }, [activeOutlet])
  /* eslint-enable react-hooks/set-state-in-effect */

  function openAdd() {
    const t = emptyTax()
    setForm(t)
    setEditTax(t)
    setIsNew(true)
  }

  function openEdit(tax: TaxConfig) {
    setForm({ ...tax })
    setEditTax(tax)
    setIsNew(false)
  }

  function closeDialog() {
    setEditTax(null)
    setIsNew(false)
  }

  async function handleSave() {
    if (!activeOutletId || !activeOutlet) return
    if (!form.name.trim()) {
      toast({ title: 'Nama pajak wajib diisi', variant: 'destructive' }); return
    }
    if (form.percent < 0 || form.percent > 100) {
      toast({ title: 'Persentase pajak harus antara 0 dan 100', variant: 'destructive' }); return
    }

    const next = isNew
      ? [...taxes, form]
      : taxes.map((t) => (t.id === form.id ? form : t))

    try {
      await update.mutateAsync({
        id: activeOutletId,
        updates: {
          settings: {
            ...activeOutlet.settings,
            taxes: next,
            // Sync legacy fields ke pajak pertama yang aktif
            tax_active: next[0]?.active ?? false,
            tax_name: next[0]?.name ?? '',
            tax_percent: next[0]?.percent ?? 0,
            tax_inclusive: next[0]?.inclusive ?? false,
            tax_calculation: next[0]?.calculation ?? 'before_discount',
            tax_order_types: next[0]?.order_types ?? [],
          },
        },
      })
      setTaxes(next)
      toast({ title: isNew ? 'Pajak ditambahkan' : 'Pajak diperbarui' })
      closeDialog()
    } catch (error) {
      toast({
        title: 'Gagal menyimpan pajak',
        description: humanizeError(error),
        variant: 'destructive',
      })
    }
  }

  async function handleDelete(id: string) {
    if (!activeOutletId || !activeOutlet) return
    const next = taxes.filter((t) => t.id !== id)
    try {
      await update.mutateAsync({
        id: activeOutletId,
        updates: {
          settings: {
            ...activeOutlet.settings,
            taxes: next,
            tax_active: next[0]?.active ?? false,
            tax_name: next[0]?.name ?? '',
            tax_percent: next[0]?.percent ?? 0,
          },
        },
      })
      setTaxes(next)
      toast({ title: 'Pajak dihapus' })
    } catch (error) {
      toast({
        title: 'Gagal menghapus pajak',
        description: humanizeError(error),
        variant: 'destructive',
      })
    }
  }

  if (!activeOutletId || !activeOutlet) return <NoOutlet />

  const filtered = taxes.filter((t) =>
    !search || t.name.toLowerCase().includes(search.toLowerCase())
  )

  return (
    <div className="space-y-4">
      <div className="rounded-xl border bg-white shadow-sm overflow-hidden">
        {/* Header */}
        <div className="px-5 pt-5 pb-4 flex items-center justify-between gap-3">
          <h1 className="font-semibold text-base shrink-0">Pajak</h1>
          <div className="flex items-center gap-2 ml-auto">
            <div className="relative w-52">
              <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground" />
              <Input
                placeholder="Cari pajak..."
                className="pl-9"
                value={search}
                onChange={(e) => setSearch(e.target.value)}
              />
            </div>
            <Button size="sm" onClick={openAdd}>
              <Plus className="h-4 w-4 mr-1" /> Tambah Pajak
            </Button>
          </div>
        </div>

        {/* Table */}
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-y bg-muted/20">
                {['Nama Pajak', 'Persentase', 'Perhitungan', 'Cara Penerapan', 'Jenis Order', 'Status', ''].map((h) => (
                  <th key={h} className="text-left px-5 py-3 font-semibold text-xs text-muted-foreground uppercase tracking-wide">
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {filtered.length === 0 ? (
                <tr>
                  <td colSpan={7} className="px-5 py-12 text-center text-muted-foreground text-sm">
                    {taxes.length === 0 ? 'Belum ada pajak. Klik "Tambah Pajak" untuk membuat.' : 'Tidak ditemukan.'}
                  </td>
                </tr>
              ) : filtered.map((tax) => (
                <tr key={tax.id} className="border-b hover:bg-muted/20 transition-colors">
                  <td className="px-5 py-4 font-medium">{tax.name}</td>
                  <td className="px-5 py-4 text-muted-foreground">{tax.percent}%</td>
                  <td className="px-5 py-4 text-muted-foreground text-sm">
                    {tax.calculation === 'before_discount' ? 'Sebelum Diskon' : 'Sesudah Diskon'}
                  </td>
                  <td className="px-5 py-4 text-muted-foreground text-sm">
                    {tax.inclusive ? 'Inclusive' : 'Exclusive'}
                  </td>
                  <td className="px-5 py-4 text-muted-foreground text-sm">
                    {tax.order_types.length === 0
                      ? 'Semua'
                      : tax.order_types.map((v) => ORDER_TYPES.find((o) => o.value === v)?.label ?? v).join(', ')}
                  </td>
                  <td className="px-5 py-4">
                    <Badge variant={tax.active ? 'default' : 'secondary'}>
                      {tax.active ? 'Aktif' : 'Nonaktif'}
                    </Badge>
                  </td>
                  <td className="px-5 py-4">
                    <div className="flex items-center gap-1 justify-end">
                      <Button variant="ghost" size="icon-sm" onClick={() => openEdit(tax)} aria-label={`Edit pajak ${tax.name}`}>
                        <Pencil className="h-3.5 w-3.5" />
                      </Button>
                      <ConfirmDialog
                        title={`Hapus pajak "${tax.name}"?`}
                        description="Pajak ini akan dihapus permanen."
                        confirmLabel="Hapus"
                        destructive
                        onConfirm={() => handleDelete(tax.id)}
                        trigger={
                          <Button variant="ghost" size="icon-sm" className="text-destructive hover:text-destructive" aria-label={`Hapus pajak ${tax.name}`}>
                            <Trash2 className="h-3.5 w-3.5" />
                          </Button>
                        }
                      />
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        {/* Footer */}
        <div className="flex items-center justify-between px-5 py-3 border-t text-xs text-muted-foreground">
          <span>Ditampilkan {filtered.length} dari {taxes.length} pajak</span>
        </div>
      </div>

      {/* Add / Edit Dialog */}
      <Dialog open={!!editTax} onOpenChange={(o) => !o && closeDialog()}>
        <DialogContent className="max-w-lg max-h-[85vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle>{isNew ? 'Tambah Pajak Baru' : `Edit Pajak — ${editTax?.name}`}</DialogTitle>
          </DialogHeader>

          <div className="space-y-5 pt-1">
            {/* Active toggle */}
            <div className="flex items-center justify-between">
              <div>
                <p className="text-sm font-medium">Aktifkan Pajak</p>
                <p className="text-xs text-muted-foreground">Pajak akan dikenakan pada transaksi</p>
              </div>
              <Switch aria-label="Aktifkan pajak" checked={form.active} onCheckedChange={(v) => setForm((f) => ({ ...f, active: v }))} />
            </div>

            <Separator />

            {/* Name + Percent */}
            <div className="grid grid-cols-2 gap-4">
              <div className="space-y-2">
                <Label>Nama Pajak</Label>
                <Input
                  value={form.name}
                  onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))}
                  placeholder="PPN, PPH, dll"
                  disabled={!form.active}
                />
              </div>
              <div className="space-y-2">
                <Label>Persentase (%)</Label>
                <div className="flex items-center gap-2">
                  <Input
                    type="number"
                    min={0}
                    max={100}
                    step={0.1}
                    value={form.percent}
                    onChange={(e) => setForm((f) => ({ ...f, percent: Number(e.target.value) }))}
                    disabled={!form.active}
                  />
                  <span className="text-sm font-medium shrink-0">%</span>
                </div>
              </div>
            </div>

            {/* Calculation */}
            <div className="space-y-2">
              <Label>Perhitungan Pajak</Label>
              <div className="space-y-2">
                {CALC_OPTIONS.map((opt) => (
                  <RadioRow
                    key={opt.value}
                    selected={form.calculation === opt.value}
                    onClick={() => setForm((f) => ({ ...f, calculation: opt.value as TaxConfig['calculation'] }))}
                    label={opt.label}
                    desc={opt.desc}
                    disabled={!form.active}
                  />
                ))}
              </div>
            </div>

            {/* Inclusive / Exclusive */}
            <div className="space-y-2">
              <Label>Cara Penerapan Pajak</Label>
              <div className="space-y-2">
                {APPLY_OPTIONS.map((opt) => (
                  <RadioRow
                    key={String(opt.isInclusive)}
                    selected={form.inclusive === opt.isInclusive}
                    onClick={() => setForm((f) => ({ ...f, inclusive: opt.isInclusive }))}
                    label={opt.label}
                    desc={opt.desc}
                    disabled={!form.active}
                  />
                ))}
              </div>
            </div>

            {/* Order types */}
            <div className="space-y-3">
              <div>
                <Label>Jenis Order yang Dikenakan Pajak</Label>
                <p className="text-xs text-muted-foreground mt-0.5">Kosongkan untuk semua jenis order</p>
              </div>
              <div className="space-y-2">
                {ORDER_TYPES.map((ot) => (
                  <label key={ot.value} className="flex items-center gap-3 cursor-pointer">
                    <Checkbox
                      checked={form.order_types.includes(ot.value)}
                      onCheckedChange={() =>
                        setForm((f) => ({
                          ...f,
                          order_types: f.order_types.includes(ot.value)
                            ? f.order_types.filter((x) => x !== ot.value)
                            : [...f.order_types, ot.value],
                        }))
                      }
                      disabled={!form.active}
                    />
                    <span className="text-sm">{ot.label}</span>
                  </label>
                ))}
              </div>
            </div>

            <div className="flex justify-end gap-2 pt-2">
              <Button variant="outline" onClick={closeDialog}>Batal</Button>
              <Button onClick={handleSave} disabled={update.isPending}>
                {update.isPending ? 'Menyimpan...' : isNew ? 'Tambah' : 'Simpan Perubahan'}
              </Button>
            </div>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  )
}
