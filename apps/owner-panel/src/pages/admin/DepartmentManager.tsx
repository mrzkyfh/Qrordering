import { useState, useMemo } from 'react'
import { useNavigate } from 'react-router'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { Plus, Search, MoreHorizontal, Pencil, Trash2, ChevronLeft, ChevronRight } from 'lucide-react'
import { useOutlet } from '@/hooks/useOutlet'
import { useDepartments, useCreateDepartment, useUpdateDepartment, useDeleteDepartment } from '@/hooks/queries/useDepartments'
import { useMenuCategories, useSyncDepartmentCategories } from '@/hooks/queries/useMenuItems'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Form, FormControl, FormField, FormItem, FormMessage } from '@/components/ui/form'
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from '@/components/ui/dropdown-menu'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { Checkbox } from '@/components/ui/checkbox'
import { useToast } from '@/hooks/use-toast'
import { humanizeError } from '@/lib/errorMessage'
import type { MenuDepartment, MenuCategory } from '@/types/database'

const PER_PAGE = 10

const schema = z.object({
  name: z.string().min(1, 'Nama wajib diisi'),
  sort_order: z.string().refine(
    (value) => Number.isInteger(Number(value)) && Number(value) >= 1,
    'Urutan harus bilangan bulat minimal 1',
  ),
})
type Values = z.infer<typeof schema>

function DepartmentForm({
  outletId,
  department,
  allCategories,
  onClose,
}: {
  outletId: string
  department?: MenuDepartment
  allCategories: MenuCategory[]
  onClose: () => void
}) {
  const { toast } = useToast()
  const create = useCreateDepartment()
  const update = useUpdateDepartment()
  const syncCategories = useSyncDepartmentCategories()

  const initialSelected = allCategories
    .filter((c) => c.department_id === department?.id)
    .map((c) => c.id)

  const [selectedCategoryIds, setSelectedCategoryIds] = useState<string[]>(initialSelected)
  const [categorySearch, setCategorySearch] = useState('')

  const filteredCategories = allCategories.filter((c) =>
    c.name.toLowerCase().includes(categorySearch.toLowerCase())
  )

  function toggleCategory(id: string) {
    setSelectedCategoryIds((prev) =>
      prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]
    )
  }

  const form = useForm<Values>({
    resolver: zodResolver(schema),
    defaultValues: {
      name: department?.name ?? '',
      sort_order: String(department?.sort_order ?? 1),
    },
  })

  async function onSubmit(values: Values) {
    const payload = {
      outlet_id: outletId,
      name: values.name,
      color: department?.color ?? '#3b82f6',
      sort_order: Number(values.sort_order) || 0,
    }
    try {
      let deptId = department?.id
      if (department) {
        await update.mutateAsync({ id: department.id, ...payload })
      } else {
        deptId = await create.mutateAsync(payload)
      }
      if (deptId) {
        await syncCategories.mutateAsync({ departmentId: deptId, selectedIds: selectedCategoryIds })
      }
      toast({ title: department ? 'Departemen diperbarui' : 'Departemen ditambahkan' })
      onClose()
    } catch (err) {
      toast({ title: 'Gagal menyimpan', description: humanizeError(err), variant: 'destructive' })
    }
  }

  const isPending = create.isPending || update.isPending || syncCategories.isPending

  return (
    <Form {...form}>
      <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-0">
        <div className="rounded-xl border bg-white p-6 space-y-5">
          <p className="font-semibold text-base">Informasi Departemen</p>

          <div className="grid grid-cols-1 items-start gap-4 sm:grid-cols-[180px_1fr]">
            <label className="text-sm font-medium pt-2">
              Nama Departemen <span className="text-destructive">*</span>
            </label>
            <FormField control={form.control} name="name" render={({ field }) => (
              <FormItem className="space-y-1">
                <FormControl>
                  <Input placeholder="Contoh: Food and Beverages" {...field} />
                </FormControl>
                <FormMessage />
              </FormItem>
            )} />

            <label className="text-sm font-medium pt-2">
              Urutan Tampil <span className="text-destructive">*</span>
            </label>
            <FormField control={form.control} name="sort_order" render={({ field }) => (
              <FormItem className="space-y-1">
                <FormControl>
                  <Input type="number" min={1} placeholder="Contoh: 1" {...field} />
                </FormControl>
                <FormMessage />
              </FormItem>
            )} />

            <div className="pt-2">
              <p className="text-sm font-medium">Daftar Kategori</p>
              <p className="text-xs text-muted-foreground mt-0.5">
                Pilih kategori yang masuk departemen ini
              </p>
            </div>
            <div className="space-y-2">
              {/* Search */}
              <div className="relative">
                <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground" />
                <Input
                  placeholder="Cari..."
                  className="pl-9"
                  value={categorySearch}
                  onChange={(e) => setCategorySearch(e.target.value)}
                />
              </div>
              {/* Category list */}
              <div className="rounded-lg border min-h-[80px] max-h-48 overflow-y-auto">
                {filteredCategories.length === 0 ? (
                  <div className="flex items-center justify-center h-20 text-sm text-muted-foreground">
                    Tidak ada data
                  </div>
                ) : (
                  <div className="divide-y">
                    {filteredCategories.map((cat) => (
                      <label
                        key={cat.id}
                        className="flex items-center gap-3 px-3 py-2.5 cursor-pointer hover:bg-muted/50 transition-colors"
                      >
                        <Checkbox
                          checked={selectedCategoryIds.includes(cat.id)}
                          onCheckedChange={() => toggleCategory(cat.id)}
                        />
                        <span className="text-lg">{cat.icon || '📂'}</span>
                        <span className="text-sm">{cat.name}</span>
                      </label>
                    ))}
                  </div>
                )}
              </div>
              {selectedCategoryIds.length > 0 && (
                <p className="text-xs text-primary">{selectedCategoryIds.length} kategori dipilih</p>
              )}
            </div>
          </div>
        </div>

        <div className="flex justify-end gap-2 pt-4">
          <Button type="button" variant="outline" onClick={onClose}>Batal</Button>
          <Button type="submit" disabled={isPending}>
            {isPending ? 'Menyimpan...' : 'Simpan'}
          </Button>
        </div>
      </form>
    </Form>
  )
}

export default function DepartmentManager() {
  const { activeOutletId } = useOutlet()
  const navigate = useNavigate()
  const { data: departments = [], isLoading } = useDepartments(activeOutletId ?? '')
  const { data: allCategories = [] } = useMenuCategories(activeOutletId ?? '')
  const deleteDepartment = useDeleteDepartment()
  const [dialogOpen, setDialogOpen] = useState(false)
  const [editItem, setEditItem] = useState<MenuDepartment | undefined>()
  const [search, setSearch] = useState('')
  const [page, setPage] = useState(1)
  const { toast } = useToast()

  const filtered = useMemo(
    () => departments.filter((d) => d.name.toLowerCase().includes(search.toLowerCase())),
    [departments, search]
  )
  const totalPages = Math.max(1, Math.ceil(filtered.length / PER_PAGE))
  const paginated = filtered.slice((page - 1) * PER_PAGE, page * PER_PAGE)

  function categoryCountFor(deptId: string) {
    return allCategories.filter((c) => c.department_id === deptId).length
  }

  function openAdd() { setEditItem(undefined); setDialogOpen(true) }
  function openEdit(dep: MenuDepartment) { setEditItem(dep); setDialogOpen(true) }

  if (!activeOutletId) return <NoOutlet />

  return (
    <div className="space-y-4">
      <PageHeader title="Departemen" subtitle="Kelola departemen untuk mengelompokkan kategori menu">
        <Button onClick={openAdd}>
          <Plus className="mr-2 h-4 w-4" /> Tambah Departemen
        </Button>
      </PageHeader>

      <div className="rounded-xl border bg-white shadow-sm">
        {/* Search */}
        <div className="px-5 pt-5 pb-4">
          <div className="relative max-w-xs">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground" />
            <Input
              placeholder="Cari..."
              className="pl-9"
              value={search}
              onChange={(e) => { setSearch(e.target.value); setPage(1) }}
            />
          </div>
        </div>

        {/* Table */}
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-y bg-muted/20">
                <th className="text-left px-5 py-3 font-semibold text-xs text-muted-foreground uppercase tracking-wide">Departemen</th>
                <th className="text-left px-5 py-3 font-semibold text-xs text-muted-foreground uppercase tracking-wide">Urutan Tampil</th>
                <th className="text-left px-5 py-3 font-semibold text-xs text-muted-foreground uppercase tracking-wide">Jumlah Kategori</th>
                <th className="px-5 py-3 w-12" />
              </tr>
            </thead>
            <tbody>
              {isLoading ? (
                Array.from({ length: 4 }).map((_, i) => (
                  <tr key={i} className="border-b">
                    <td className="px-5 py-4"><div className="h-4 w-36 bg-muted rounded animate-pulse" /></td>
                    <td className="px-5 py-4"><div className="h-4 w-8 bg-muted rounded animate-pulse" /></td>
                    <td className="px-5 py-4"><div className="h-4 w-8 bg-muted rounded animate-pulse" /></td>
                    <td className="px-5 py-4" />
                  </tr>
                ))
              ) : paginated.length === 0 ? (
                <tr>
                  <td colSpan={4} className="px-5 py-16 text-center text-muted-foreground text-sm">
                    {search ? 'Tidak ditemukan.' : 'Belum ada departemen.'}
                  </td>
                </tr>
              ) : (
                paginated.map((dep) => {
                  const catCount = categoryCountFor(dep.id)
                  return (
                    <tr key={dep.id} className="border-b hover:bg-muted/20 transition-colors">
                      <td className="px-5 py-4">
                        <span className="font-medium">{dep.name}</span>
                      </td>
                      <td className="px-5 py-4 text-muted-foreground">{dep.sort_order}</td>
                      <td className="px-5 py-4">
                        <Button
                          variant="link"
                          className="h-auto p-0 font-medium"
                          onClick={() => navigate(`/admin/categories?dept=${dep.id}`)}
                        >
                          {catCount}
                        </Button>
                      </td>
                      <td className="px-5 py-4">
                        <DropdownMenu>
                          <DropdownMenuTrigger asChild>
                            <Button variant="ghost" size="icon-sm" aria-label={`Aksi departemen ${dep.name}`}>
                              <MoreHorizontal className="h-4 w-4" />
                            </Button>
                          </DropdownMenuTrigger>
                          <DropdownMenuContent align="end">
                            <DropdownMenuItem onClick={() => openEdit(dep)}>
                              <Pencil className="h-3.5 w-3.5 mr-2" /> Edit
                            </DropdownMenuItem>
                            <ConfirmDialog
                              title={`Hapus "${dep.name}"?`}
                              description="Departemen ini akan dihapus. Kategori yang terhubung tidak terpengaruh."
                              confirmLabel="Hapus"
                              destructive
                              onConfirm={() =>
                                deleteDepartment.mutateAsync(dep.id, {
                                  onSuccess: () => toast({ title: `"${dep.name}" dihapus` }),
                                  onError: (e) => toast({ title: 'Gagal', description: humanizeError(e), variant: 'destructive' }),
                                })
                              }
                              trigger={
                                <DropdownMenuItem
                                  className="text-destructive focus:text-destructive"
                                  onSelect={(e) => e.preventDefault()}
                                >
                                  <Trash2 className="h-3.5 w-3.5 mr-2" /> Hapus
                                </DropdownMenuItem>
                              }
                            />
                          </DropdownMenuContent>
                        </DropdownMenu>
                      </td>
                    </tr>
                  )
                })
              )}
            </tbody>
          </table>
        </div>

        {/* Pagination */}
        {filtered.length > 0 && (
          <div className="flex items-center justify-between px-5 py-4 border-t text-sm text-muted-foreground">
            <span>
              Ditampilkan {Math.min((page - 1) * PER_PAGE + 1, filtered.length)}–{Math.min(page * PER_PAGE, filtered.length)} dari {filtered.length} data
            </span>
            <div className="flex items-center gap-1">
              <Button
                variant="ghost"
                size="icon-sm"
                disabled={page === 1}
                onClick={() => setPage((p) => p - 1)}
                aria-label="Halaman sebelumnya"
              >
                <ChevronLeft className="h-4 w-4" />
              </Button>
              {Array.from({ length: totalPages }).map((_, i) => (
                <Button
                  key={i}
                  variant={page === i + 1 ? 'default' : 'ghost'}
                  size="icon-sm"
                  onClick={() => setPage(i + 1)}
                  aria-label={`Halaman ${i + 1}`}
                  aria-current={page === i + 1 ? 'page' : undefined}
                >
                  {i + 1}
                </Button>
              ))}
              <Button
                variant="ghost"
                size="icon-sm"
                disabled={page === totalPages}
                onClick={() => setPage((p) => p + 1)}
                aria-label="Halaman berikutnya"
              >
                <ChevronRight className="h-4 w-4" />
              </Button>
            </div>
          </div>
        )}
      </div>

      <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>
        <DialogContent className="max-w-2xl">
          <DialogHeader>
            <DialogTitle>{editItem ? 'Edit Departemen' : 'Tambah Departemen'}</DialogTitle>
          </DialogHeader>
          <DepartmentForm
            outletId={activeOutletId}
            department={editItem}
            allCategories={allCategories}
            onClose={() => setDialogOpen(false)}
          />
        </DialogContent>
      </Dialog>
    </div>
  )
}
