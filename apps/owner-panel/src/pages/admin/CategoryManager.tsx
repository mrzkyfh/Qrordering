import { useState } from 'react'
import { useSearchParams } from 'react-router'
import { useForm, useWatch } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { Plus, Pencil, Trash2 } from 'lucide-react'
import { useOutlet } from '@/hooks/useOutlet'
import {
  useMenuCategories,
  useCreateCategory,
  useUpdateCategory,
  useDeleteCategory,
  useReorderCategories,
} from '@/hooks/queries/useMenuItems'
import { useDepartments } from '@/hooks/queries/useDepartments'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from '@/components/ui/form'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { useToast } from '@/hooks/use-toast'
import { humanizeError } from '@/lib/errorMessage'
import type { MenuCategory, MenuDepartment } from '@/types/database'

const ICON_SUGGESTIONS = ['🍽️', '🍜', '🍖', '🥗', '🍰', '☕', '🥤', '🍹', '🍱', '🔥', '⭐', '🌟', '🥩', '🦐', '🥘', '🫕']

const schema = z.object({
  name: z.string().min(1, 'Nama wajib diisi'),
  icon: z.string().optional(),
  department_id: z.string().optional(),
})
type Values = z.infer<typeof schema>

function CategoryForm({
  outletId,
  category,
  departments,
  defaultDepartmentId,
  defaultSortOrder,
  onClose,
}: {
  outletId: string
  category?: MenuCategory
  departments: MenuDepartment[]
  defaultDepartmentId?: string
  defaultSortOrder: number
  onClose: () => void
}) {
  const { toast } = useToast()
  const create = useCreateCategory()
  const update = useUpdateCategory()

  const form = useForm<Values>({
    resolver: zodResolver(schema),
    defaultValues: {
      name: category?.name ?? '',
      icon: category?.icon ?? '',
      department_id: category?.department_id ?? defaultDepartmentId ?? '',
    },
  })

  const watchedIcon = useWatch({ control: form.control, name: 'icon' })

  async function onSubmit(values: Values) {
    const payload = {
      outlet_id: outletId,
      name: values.name,
      icon: values.icon || null,
      sort_order: category?.sort_order ?? defaultSortOrder,
      department_id: values.department_id || null,
    }
    try {
      if (category) {
        await update.mutateAsync({ id: category.id, ...payload })
        toast({ title: 'Kategori diperbarui' })
      } else {
        await create.mutateAsync(payload)
        toast({ title: 'Kategori ditambahkan' })
      }
      onClose()
    } catch (err) {
      toast({ title: 'Gagal menyimpan', description: humanizeError(err), variant: 'destructive' })
    }
  }

  const isPending = create.isPending || update.isPending

  return (
    <Form {...form}>
      <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-4">
        <FormField control={form.control} name="name" render={({ field }) => (
          <FormItem>
            <FormLabel>Nama Kategori</FormLabel>
            <FormControl><Input placeholder="Makanan Utama" {...field} /></FormControl>
            <FormMessage />
          </FormItem>
        )} />

        {departments.length > 0 && (
          <FormField control={form.control} name="department_id" render={({ field }) => (
            <FormItem>
              <FormLabel>Departemen</FormLabel>
              <Select onValueChange={field.onChange} value={field.value ?? ''}>
                <FormControl>
                  <SelectTrigger>
                    <SelectValue placeholder="Pilih departemen (opsional)" />
                  </SelectTrigger>
                </FormControl>
                <SelectContent>
                  {departments.map((d) => (
                    <SelectItem key={d.id} value={d.id}>
                      {d.name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <FormMessage />
            </FormItem>
          )} />
        )}

        <FormField control={form.control} name="icon" render={({ field }) => (
          <FormItem>
            <FormLabel>Ikon (emoji)</FormLabel>
            <FormControl>
              <div className="space-y-2">
                <div className="flex items-center gap-2">
                  <div className="flex h-10 w-10 items-center justify-center rounded-lg border text-xl bg-muted shrink-0">
                    {watchedIcon || '?'}
                  </div>
                  <Input placeholder="Ketik emoji atau pilih di bawah" {...field} />
                </div>
                <div className="flex flex-wrap gap-1.5">
                  {ICON_SUGGESTIONS.map((emoji) => (
                    <button
                      key={emoji}
                      type="button"
                      onClick={() => form.setValue('icon', emoji)}
                      aria-label={`Pilih ikon ${emoji}`}
                      className="h-9 w-9 text-lg rounded-lg border hover:bg-muted transition-colors flex items-center justify-center"
                    >
                      {emoji}
                    </button>
                  ))}
                </div>
              </div>
            </FormControl>
            <FormMessage />
          </FormItem>
        )} />

        <div className="flex justify-end gap-2 pt-2">
          <Button type="button" variant="outline" onClick={onClose}>Batal</Button>
          <Button type="submit" disabled={isPending}>
            {isPending ? 'Menyimpan...' : category ? 'Perbarui' : 'Tambah'}
          </Button>
        </div>
      </form>
    </Form>
  )
}

export default function CategoryManager() {
  const { activeOutletId } = useOutlet()
  const [searchParams, setSearchParams] = useSearchParams()
  const deptFilter = searchParams.get('dept')

  const { data: departments = [] } = useDepartments(activeOutletId ?? '')
  const { data: allCategories = [], isLoading } = useMenuCategories(activeOutletId ?? '')
  const categories = deptFilter
    ? allCategories.filter((category) => category.department_id === deptFilter)
    : allCategories
  const deleteCategory = useDeleteCategory()
  const reorderCategories = useReorderCategories()
  const [dialogOpen, setDialogOpen] = useState(false)
  const [editItem, setEditItem] = useState<MenuCategory | undefined>()
  const { toast } = useToast()

  function openAdd() { setEditItem(undefined); setDialogOpen(true) }
  function openEdit(cat: MenuCategory) { setEditItem(cat); setDialogOpen(true) }

  function setDeptFilter(id: string | null) {
    if (id) setSearchParams({ dept: id })
    else setSearchParams({})
  }

  const activeDept = departments.find((d) => d.id === deptFilter)

  async function moveCategory(categoryId: string, position: number) {
    if (!activeOutletId) return
    const currentIndex = allCategories.findIndex((category) => category.id === categoryId)
    const nextIndex = position - 1
    if (currentIndex < 0 || nextIndex < 0 || nextIndex >= allCategories.length || currentIndex === nextIndex) return

    const reordered = [...allCategories]
    const [moved] = reordered.splice(currentIndex, 1)
    reordered.splice(nextIndex, 0, moved)

    try {
      await reorderCategories.mutateAsync({
        outletId: activeOutletId,
        categoryIds: reordered.map((category) => category.id),
      })
      toast({ title: 'Urutan kategori disimpan' })
    } catch (err) {
      toast({ title: 'Gagal mengubah urutan', description: humanizeError(err), variant: 'destructive' })
    }
  }

  if (!activeOutletId) return <NoOutlet />

  return (
    <div className="space-y-4">
      <PageHeader
        title="Kategori"
        subtitle={activeDept ? `Departemen: ${activeDept.name}` : 'Kelola kategori produk menu'}
      >
        <Button onClick={openAdd}>
          <Plus className="mr-2 h-4 w-4" /> Tambah Kategori
        </Button>
      </PageHeader>

      {/* Department filter tabs */}
      {departments.length > 0 && (
        <div className="flex gap-2 flex-wrap">
          <Button
            variant={!deptFilter ? 'default' : 'outline'}
            size="sm"
            onClick={() => setDeptFilter(null)}
          >
            Semua
          </Button>
          {departments.map((d) => (
            <Button
              key={d.id}
              variant={deptFilter === d.id ? 'default' : 'outline'}
              size="sm"
              onClick={() => setDeptFilter(d.id)}
            >
              {d.name}
            </Button>
          ))}
        </div>
      )}

      <div className="rounded-xl border bg-white shadow-sm overflow-hidden">
        {isLoading ? (
          <div className="divide-y">
            {Array.from({ length: 4 }).map((_, i) => (
              <div key={i} className="flex items-center gap-4 px-4 py-3.5">
                <div className="h-9 w-9 bg-muted rounded-lg animate-pulse" />
                <div className="h-4 w-36 bg-muted rounded animate-pulse" />
              </div>
            ))}
          </div>
        ) : categories.length === 0 ? (
          <div className="py-16 text-center text-muted-foreground text-sm">
            Belum ada kategori{deptFilter ? ' di departemen ini' : ''}.{' '}
            <Button variant="link" className="h-auto p-0" onClick={openAdd}>Tambahkan sekarang</Button>
          </div>
        ) : (
          <div className="overflow-x-auto"><table className="w-full text-sm min-w-[560px]">
            <thead className="border-b bg-muted/30">
              <tr>
                <th className="text-left px-4 py-3 font-medium text-muted-foreground">Nama Kategori</th>
                <th className="text-left px-4 py-3 font-medium text-muted-foreground">Departemen</th>
                <th className="text-center px-4 py-3 font-medium text-muted-foreground w-32">Urutan Menu</th>
                <th className="text-right px-4 py-3 font-medium text-muted-foreground w-28">Aksi</th>
              </tr>
            </thead>
            <tbody className="divide-y">
              {categories.map((cat) => {
                const dept = cat.menu_departments ?? departments.find((d) => d.id === cat.department_id)
                const globalPosition = allCategories.findIndex((category) => category.id === cat.id) + 1
                return (
                  <tr key={cat.id} className="hover:bg-muted/20 transition-colors">
                    <td className="px-4 py-3.5">
                      <div className="flex items-center gap-3">
                        <div className="flex h-9 w-9 items-center justify-center rounded-lg bg-muted text-lg shrink-0">
                          {cat.icon || '📂'}
                        </div>
                        <span className="font-medium">{cat.name}</span>
                      </div>
                    </td>
                    <td className="px-4 py-3.5">
                      {dept ? (
                        <Badge variant="outline">{dept.name}</Badge>
                      ) : (
                        <span className="text-muted-foreground text-xs">—</span>
                      )}
                    </td>
                    <td className="px-4 py-3.5">
                      <Select
                        value={String(globalPosition)}
                        onValueChange={(value) => moveCategory(cat.id, Number(value))}
                        disabled={reorderCategories.isPending}
                      >
                        <SelectTrigger
                          className="mx-auto h-9 w-20"
                          aria-label={`Urutan kategori ${cat.name}`}
                        >
                          <SelectValue />
                        </SelectTrigger>
                        <SelectContent>
                          {allCategories.map((_, index) => (
                            <SelectItem key={index + 1} value={String(index + 1)}>
                              {index + 1}
                            </SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                    </td>
                    <td className="px-4 py-3.5">
                      <div className="flex items-center justify-end gap-1">
                        <Button variant="ghost" size="icon-sm" onClick={() => openEdit(cat)} aria-label={`Edit kategori ${cat.name}`}>
                          <Pencil className="h-3.5 w-3.5" />
                        </Button>
                        <ConfirmDialog
                          title={`Hapus "${cat.name}"?`}
                          description="Kategori dinonaktifkan. Produk yang terhubung tidak terpengaruh."
                          confirmLabel="Hapus"
                          destructive
                          onConfirm={() =>
                            deleteCategory.mutateAsync(cat.id, {
                              onSuccess: () => toast({ title: `"${cat.name}" dihapus` }),
                              onError: (e) => toast({ title: 'Gagal', description: humanizeError(e), variant: 'destructive' }),
                            })
                          }
                          trigger={
                            <Button variant="ghost" size="icon-sm" className="text-destructive hover:text-destructive" aria-label={`Hapus kategori ${cat.name}`}>
                              <Trash2 className="h-3.5 w-3.5" />
                            </Button>
                          }
                        />
                      </div>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table></div>
        )}
      </div>

      <p className="text-xs text-muted-foreground px-1">
        {categories.length} kategori{deptFilter ? ' di departemen ini' : ' aktif'}. Pilih nomor urutan untuk mengatur posisi kategori pada menu pelanggan.
      </p>

      <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>{editItem ? 'Edit Kategori' : 'Tambah Kategori'}</DialogTitle>
          </DialogHeader>
          <CategoryForm
            outletId={activeOutletId}
            category={editItem}
            departments={departments}
            defaultDepartmentId={deptFilter ?? undefined}
            defaultSortOrder={allCategories.length + 1}
            onClose={() => setDialogOpen(false)}
          />
        </DialogContent>
      </Dialog>
    </div>
  )
}
