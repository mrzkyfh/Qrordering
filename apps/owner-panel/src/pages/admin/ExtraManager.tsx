import { useState } from 'react'
import { useForm, useWatch } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { Plus, Pencil, Trash2, X } from 'lucide-react'
import { cn } from '@/lib/utils'
import { useOutlet } from '@/hooks/useOutlet'
import {
  useExtras,
  useExtraProductCount,
  useCreateExtra,
  useUpdateExtra,
  useToggleExtra,
  useDeleteExtra,
} from '@/hooks/queries/useExtras'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { Switch } from '@/components/ui/switch'
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from '@/components/ui/form'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { useToast } from '@/hooks/use-toast'
import { humanizeError } from '@/lib/errorMessage'
import type { MenuExtra, ExtraType, ExtraSelectionType } from '@/types/database'

const schema = z.object({
  name: z.string().min(1, 'Nama wajib diisi').max(50, 'Maksimal 50 karakter'),
  type: z.enum(['optional', 'required']),
  selection_type: z.enum(['single', 'multiple']),
  sort_order: z.string().refine(
    (value) => Number.isInteger(Number(value)) && Number(value) >= 0,
    'Urutan harus bilangan bulat minimal 0',
  ),
})
type Values = z.infer<typeof schema>

type SubExtraRow = { name: string; price: string }

function RadioCard({
  selected,
  onClick,
  title,
  description,
}: {
  selected: boolean
  onClick: () => void
  title: string
  description: string
}) {
  return (
    <button
      type="button"
      aria-pressed={selected}
      className={cn(
        'flex w-full items-start gap-3 rounded-lg border-2 p-3 text-left transition-colors',
        selected ? 'border-primary bg-primary/5' : 'border-input hover:border-muted-foreground/30'
      )}
      onClick={onClick}
    >
      <div
        className={cn(
          'h-4 w-4 rounded-full border-2 mt-0.5 shrink-0 flex items-center justify-center',
          selected ? 'border-primary' : 'border-muted-foreground/50'
        )}
      >
        {selected && <div className="h-2 w-2 rounded-full bg-primary" />}
      </div>
      <div>
        <p className="text-sm font-medium leading-tight">{title}</p>
        <p className="text-xs text-muted-foreground mt-0.5">{description}</p>
      </div>
    </button>
  )
}

function ExtraForm({
  outletId,
  extra,
  onClose,
}: {
  outletId: string
  extra?: MenuExtra
  onClose: () => void
}) {
  const { toast } = useToast()
  const create = useCreateExtra()
  const update = useUpdateExtra()

  const initialSubs: SubExtraRow[] =
    extra?.menu_extra_options && extra.menu_extra_options.length > 0
      ? extra.menu_extra_options
          .slice()
          .sort((a, b) => a.sort_order - b.sort_order)
          .map((o) => ({ name: o.name, price: String(o.price) }))
      : [{ name: '', price: '0' }]

  const [subExtras, setSubExtras] = useState<SubExtraRow[]>(initialSubs)

  const form = useForm<Values>({
    resolver: zodResolver(schema),
    defaultValues: {
      name: extra?.name ?? '',
      type: (extra?.type ?? 'optional') as 'optional' | 'required',
      selection_type: (extra?.selection_type ?? 'single') as 'single' | 'multiple',
      sort_order: String(extra?.sort_order ?? 0),
    },
  })

  const watchedName = useWatch({ control: form.control, name: 'name' })

  function addSub() {
    setSubExtras((prev) => [...prev, { name: '', price: '0' }])
  }

  function removeSub(i: number) {
    setSubExtras((prev) => prev.filter((_, idx) => idx !== i))
  }

  function updateSub(i: number, field: keyof SubExtraRow, value: string) {
    setSubExtras((prev) => prev.map((row, idx) => (idx === i ? { ...row, [field]: value } : row)))
  }

  async function onSubmit(values: Values) {
    const invalidPrice = subExtras.some((s) => {
      const price = Number(s.price)
      return s.name.trim() !== '' && (!Number.isFinite(price) || price < 0)
    })
    if (invalidPrice) {
      toast({ title: 'Harga sub-ekstra harus angka minimal 0', variant: 'destructive' })
      return
    }

    const options = subExtras
      .filter((s) => s.name.trim())
      .map((s) => ({ name: s.name.trim(), price: Number(s.price) }))

    if (options.length === 0) {
      toast({ title: 'Tambahkan minimal satu sub-ekstra', variant: 'destructive' })
      return
    }

    try {
      if (extra) {
        await update.mutateAsync({
          id: extra.id,
          payload: {
            name: values.name,
            type: values.type as ExtraType,
            selection_type: values.selection_type as ExtraSelectionType,
            sort_order: Number(values.sort_order) || 0,
          },
          options,
        })
        toast({ title: 'Ekstra diperbarui' })
      } else {
        await create.mutateAsync({
          payload: {
            outlet_id: outletId,
            name: values.name,
            type: values.type as ExtraType,
            selection_type: values.selection_type as ExtraSelectionType,
            sort_order: Number(values.sort_order) || 0,
          },
          options,
        })
        toast({ title: 'Ekstra ditambahkan' })
      }
      onClose()
    } catch (err) {
      toast({ title: 'Gagal menyimpan', description: humanizeError(err), variant: 'destructive' })
    }
  }

  const isPending = create.isPending || update.isPending

  return (
    <Form {...form}>
      <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-5">
        {/* Nama */}
        <FormField
          control={form.control}
          name="name"
          render={({ field }) => (
            <FormItem>
              <div className="flex items-center justify-between">
                <FormLabel>
                  Nama Produk Tambahan <span className="text-destructive">*</span>
                </FormLabel>
                <span className="text-xs text-muted-foreground">{watchedName.length}/50</span>
              </div>
              <FormControl>
                <Input placeholder="Contoh: Level Pedas, Topping" maxLength={50} {...field} />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />

        {/* Tipe Tambahan */}
        <FormField
          control={form.control}
          name="type"
          render={({ field }) => (
            <FormItem>
              <FormLabel>
                Tipe Tambahan <span className="text-destructive">*</span>
              </FormLabel>
              <FormControl>
                <div className="grid grid-cols-2 gap-2">
                  <RadioCard
                    selected={field.value === 'optional'}
                    onClick={() => field.onChange('optional')}
                    title="Opsional"
                    description="Pelanggan bebas memilih atau tidak"
                  />
                  <RadioCard
                    selected={field.value === 'required'}
                    onClick={() => field.onChange('required')}
                    title="Wajib"
                    description="Pelanggan harus memilih salah satu opsi"
                  />
                </div>
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />

        {/* Cara Memilih */}
        <FormField
          control={form.control}
          name="selection_type"
          render={({ field }) => (
            <FormItem>
              <FormLabel>
                Cara Memilih <span className="text-destructive">*</span>
              </FormLabel>
              <FormControl>
                <div className="grid grid-cols-2 gap-2">
                  <RadioCard
                    selected={field.value === 'single'}
                    onClick={() => field.onChange('single')}
                    title="Pilih Salah Satu"
                    description="Pelanggan hanya bisa memilih satu opsi"
                  />
                  <RadioCard
                    selected={field.value === 'multiple'}
                    onClick={() => field.onChange('multiple')}
                    title="Pilih Beberapa"
                    description="Pelanggan bisa memilih lebih dari satu opsi"
                  />
                </div>
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />

        {/* Sub-Ekstra */}
        <div className="space-y-2">
          <p className="text-sm font-medium">
            Tambahkan Produk Tambahan <span className="text-destructive">*</span>
          </p>
          <div className="grid grid-cols-[1fr_100px_36px] gap-2 px-1 sm:grid-cols-[1fr_140px_36px]">
            <span className="text-xs text-muted-foreground">Nama Sub-Ekstra</span>
            <span className="text-xs text-muted-foreground">Harga Jual</span>
            <span />
          </div>
          {subExtras.map((sub, i) => (
            <div key={i} className="grid grid-cols-[1fr_100px_36px] gap-2 items-center sm:grid-cols-[1fr_140px_36px]">
              <Input
                placeholder="Contoh: Pedas Level 1"
                value={sub.name}
                onChange={(e) => updateSub(i, 'name', e.target.value)}
              />
              <Input
                inputMode="numeric"
                placeholder="0"
                value={sub.price ? Number(sub.price.toString().replace(/\./g, '')).toLocaleString('id-ID') : ''}
                onChange={(e) => {
                  const raw = e.target.value.replace(/\./g, '').replace(/\D/g, '')
                  updateSub(i, 'price', raw)
                }}
              />
              <Button
                type="button"
                variant="ghost"
                size="sm"
                className="w-9 px-0 text-muted-foreground hover:text-destructive"
                disabled={subExtras.length === 1}
                onClick={() => removeSub(i)}
                aria-label={`Hapus sub-ekstra ${i + 1}`}
              >
                <X className="h-4 w-4" />
              </Button>
            </div>
          ))}
          <Button type="button" variant="outline" className="w-full" onClick={addSub}>
            <Plus className="h-4 w-4 mr-2" /> Tambahkan Sub-Ekstra
          </Button>
        </div>

        <div className="flex justify-end gap-2 pt-1">
          <Button type="button" variant="outline" onClick={onClose}>
            Batal
          </Button>
          <Button type="submit" disabled={isPending}>
            {isPending ? 'Menyimpan...' : extra ? 'Perbarui' : 'Simpan'}
          </Button>
        </div>
      </form>
    </Form>
  )
}

const TYPE_LABEL: Record<ExtraType, string> = {
  optional: 'Opsional',
  required: 'Wajib',
}
const SELECTION_LABEL: Record<ExtraSelectionType, string> = {
  single: 'Salah Satu',
  multiple: 'Beberapa',
}

export default function ExtraManager() {
  const { activeOutletId } = useOutlet()
  const { data: extras = [], isLoading } = useExtras(activeOutletId ?? '')
  const { data: productCounts = {} } = useExtraProductCount(activeOutletId ?? '')
  const toggleExtra = useToggleExtra()
  const deleteExtra = useDeleteExtra()
  const [dialogOpen, setDialogOpen] = useState(false)
  const [editItem, setEditItem] = useState<MenuExtra | undefined>()
  const { toast } = useToast()

  function openAdd() {
    setEditItem(undefined)
    setDialogOpen(true)
  }
  function openEdit(ex: MenuExtra) {
    setEditItem(ex)
    setDialogOpen(true)
  }

  const activeCount = extras.filter((e) => e.is_active).length

  if (!activeOutletId) return <NoOutlet />

  return (
    <div className="space-y-4">
      <PageHeader title="Ekstra" subtitle="Kelola item tambahan / add-on yang dapat dipilih pelanggan">
        <Button onClick={openAdd}>
          <Plus className="mr-2 h-4 w-4" /> Tambah Ekstra
        </Button>
      </PageHeader>

      <div className="rounded-xl border bg-white shadow-sm overflow-hidden">
        {isLoading ? (
          <div className="divide-y">
            {Array.from({ length: 4 }).map((_, i) => (
              <div key={i} className="flex items-center justify-between px-4 py-3.5">
                <div className="h-4 w-40 bg-muted rounded animate-pulse" />
                <div className="h-4 w-20 bg-muted rounded animate-pulse" />
              </div>
            ))}
          </div>
        ) : extras.length === 0 ? (
          <div className="py-16 text-center text-muted-foreground text-sm">
            Belum ada item ekstra.{' '}
            <Button variant="link" className="h-auto p-0" onClick={openAdd}>
              Tambahkan sekarang
            </Button>
          </div>
        ) : (
          <div className="overflow-x-auto"><table className="w-full text-sm min-w-[560px]">
            <thead className="border-b bg-muted/30">
              <tr>
                <th className="text-left px-4 py-3 font-medium text-muted-foreground">Nama Ekstra</th>
                <th className="text-left px-4 py-3 font-medium text-muted-foreground w-28">Tipe</th>
                <th className="text-left px-4 py-3 font-medium text-muted-foreground w-32">Cara Memilih</th>
                <th className="text-center px-4 py-3 font-medium text-muted-foreground w-28">Sub Ekstra</th>
                <th className="text-center px-4 py-3 font-medium text-muted-foreground w-28">Produk</th>
                <th className="text-center px-4 py-3 font-medium text-muted-foreground w-24">Status</th>
                <th className="text-right px-4 py-3 font-medium text-muted-foreground w-24">Aksi</th>
              </tr>
            </thead>
            <tbody className="divide-y">
              {extras.map((ex) => (
                <tr key={ex.id} className="hover:bg-muted/20 transition-colors">
                  <td className="px-4 py-3.5">
                    <span className={ex.is_active ? 'font-medium' : 'font-medium text-muted-foreground'}>
                      {ex.name}
                    </span>
                  </td>
                  <td className="px-4 py-3.5">
                    <Badge
                      variant={ex.type === 'required' ? 'default' : 'secondary'}
                      className="text-xs"
                    >
                      {TYPE_LABEL[ex.type]}
                    </Badge>
                  </td>
                  <td className="px-4 py-3.5 text-muted-foreground text-xs">
                    {SELECTION_LABEL[ex.selection_type]}
                  </td>
                  <td className="px-4 py-3.5 text-center">
                    <span className="text-sm text-muted-foreground">
                      {ex.menu_extra_options?.length ?? 0}
                    </span>
                  </td>
                  <td className="px-4 py-3.5 text-center">
                    <Badge variant="secondary" className="text-xs">
                      {productCounts[ex.id] ?? 0} produk
                    </Badge>
                  </td>
                  <td className="px-4 py-3.5">
                    <div className="flex justify-center">
                      <Switch
                        aria-label={`${ex.is_active ? 'Nonaktifkan' : 'Aktifkan'} ekstra ${ex.name}`}
                        checked={ex.is_active}
                        disabled={toggleExtra.isPending}
                        onCheckedChange={(val) =>
                          toggleExtra.mutate(
                            { id: ex.id, is_active: val },
                            {
                              onError: (e) =>
                                toast({ title: 'Gagal', description: humanizeError(e), variant: 'destructive' }),
                            }
                          )
                        }
                      />
                    </div>
                  </td>
                  <td className="px-4 py-3.5">
                    <div className="flex items-center justify-end gap-1">
                      <Button
                        variant="ghost"
                        size="icon-sm"
                        onClick={() => openEdit(ex)}
                        aria-label={`Edit ekstra ${ex.name}`}
                      >
                        <Pencil className="h-3.5 w-3.5" />
                      </Button>
                      <ConfirmDialog
                        title={`Hapus "${ex.name}"?`}
                        description="Item ekstra ini akan dihapus permanen."
                        confirmLabel="Hapus"
                        destructive
                        onConfirm={() =>
                          deleteExtra.mutateAsync(ex.id, {
                            onSuccess: () => toast({ title: `"${ex.name}" dihapus` }),
                            onError: (e) =>
                              toast({ title: 'Gagal', description: humanizeError(e), variant: 'destructive' }),
                          })
                        }
                        trigger={
                          <Button
                            variant="ghost"
                            size="icon-sm"
                            className="text-destructive hover:text-destructive"
                            aria-label={`Hapus ekstra ${ex.name}`}
                          >
                            <Trash2 className="h-3.5 w-3.5" />
                          </Button>
                        }
                      />
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table></div>
        )}
      </div>

      <p className="text-xs text-muted-foreground px-1">
        {activeCount} dari {extras.length} ekstra aktif
      </p>

      <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>
        <DialogContent className="max-w-lg max-h-[90vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle>{editItem ? 'Edit Ekstra' : 'Tambah Ekstra'}</DialogTitle>
          </DialogHeader>
          <ExtraForm outletId={activeOutletId} extra={editItem} onClose={() => setDialogOpen(false)} />
        </DialogContent>
      </Dialog>
    </div>
  )
}
