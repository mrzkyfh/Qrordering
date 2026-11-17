import { useState, useMemo } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { Plus, Trash2 } from 'lucide-react'
import { useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useOutlet } from '@/hooks/useOutlet'
import { useTables } from '@/hooks/queries/useOutlets'
import { useRealtimeTables } from '@/hooks/useRealtimeOrders'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { StatusBadge } from '@/components/ui/StatusBadge'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from '@/components/ui/form'
import { Input } from '@/components/ui/input'
import { Checkbox } from '@/components/ui/checkbox'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { useToast } from '@/hooks/use-toast'
import { humanizeError } from '@/lib/errorMessage'
import type { RestaurantTable, TableStatus } from '@/types/database'

const tableSchema = z.object({
  table_number: z.string().min(1, 'Nomor meja wajib diisi'),
  area: z.string().optional(),
  capacity: z.string().refine(
    (value) => Number.isInteger(Number(value)) && Number(value) >= 1,
    'Kapasitas harus bilangan bulat minimal 1',
  ),
  is_active: z.boolean(),
})
type TableValues = z.infer<typeof tableSchema>

const STATUS_COLORS: Record<TableStatus, string> = {
  available: 'bg-green-100 border-green-300 text-green-800',
  occupied:  'bg-red-100 border-red-300 text-red-800',
  reserved:  'bg-yellow-100 border-yellow-300 text-yellow-800',
  dirty:     'bg-gray-100 border-gray-300 text-gray-600',
}

function TableCard({ table, onEdit }: { table: RestaurantTable; onEdit: (t: RestaurantTable) => void }) {
  return (
    <button
      type="button"
      onClick={() => onEdit(table)}
      className={`rounded-xl border-2 p-4 text-left transition-shadow hover:shadow-md ${STATUS_COLORS[table.status]}`}
    >
      <p className="text-lg font-bold">Meja {table.table_number}</p>
      {table.area && <p className="text-xs opacity-70">{table.area}</p>}
      <p className="text-xs mt-1">Kapasitas: {table.capacity}</p>
      <div className="mt-2"><StatusBadge status={table.status} /></div>
    </button>
  )
}

export default function TableManager() {
  const { activeOutletId } = useOutlet()
  const { data: tables = [], isLoading } = useTables(activeOutletId ?? '')
  const [dialogOpen, setDialogOpen] = useState(false)
  const [editTable, setEditTable] = useState<RestaurantTable | undefined>()
  const qc = useQueryClient()
  const { toast } = useToast()

  useRealtimeTables(activeOutletId)

  const form = useForm<TableValues>({
    resolver: zodResolver(tableSchema),
    defaultValues: { table_number: '', area: '', capacity: '4', is_active: true },
  })

  function openEdit(table: RestaurantTable) {
    setEditTable(table)
    form.reset({ table_number: table.table_number, area: table.area ?? '', capacity: String(table.capacity), is_active: table.is_active })
    setDialogOpen(true)
  }

  function openAdd() {
    setEditTable(undefined)
    form.reset({ table_number: '', area: '', capacity: '4', is_active: true })
    setDialogOpen(true)
  }

  async function onSubmit(values: TableValues) {
    if (!activeOutletId) return
    const isDuplicate = tables.some(
      (t) => String(t.table_number) === values.table_number.trim() && t.id !== editTable?.id
    )
    if (isDuplicate) {
      form.setError('table_number', { message: 'Nomor meja sudah ada' })
      return
    }
    const payload = {
      outlet_id: activeOutletId,
      table_number: values.table_number,
      area: values.area || null,
      capacity: parseInt(values.capacity),
      is_active: values.is_active,
      status: (editTable?.status ?? 'available') as TableStatus,
    }
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const tbl = supabase.from('restaurant_tables') as any
    if (editTable) {
      const { error } = await tbl.update(payload).eq('id', editTable.id)
      if (error) { toast({ title: 'Gagal', description: humanizeError(error), variant: 'destructive' }); return }
    } else {
      const { error } = await tbl.insert(payload)
      if (error) { toast({ title: 'Gagal', description: humanizeError(error), variant: 'destructive' }); return }
    }
    qc.invalidateQueries({ queryKey: ['tables', activeOutletId] })
    toast({ title: editTable ? 'Meja diperbarui' : 'Meja ditambahkan' })
    setDialogOpen(false)
  }

  async function handleDelete(tableId: string, tableNumber: string) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const { error } = await (supabase.from('restaurant_tables') as any).delete().eq('id', tableId)
    if (error) {
      toast({ title: 'Gagal menghapus', description: humanizeError(error), variant: 'destructive' })
      return
    }
    qc.invalidateQueries({ queryKey: ['tables', activeOutletId] })
    toast({ title: `Meja ${tableNumber} dihapus` })
    setDialogOpen(false)
  }

  const groupedTables = useMemo(() => {
    const groups: Record<string, RestaurantTable[]> = {}
    tables.forEach((t) => {
      const areaName = t.area || 'Tanpa Area'
      if (!groups[areaName]) {
        groups[areaName] = []
      }
      groups[areaName].push(t)
    })
    return groups
  }, [tables])

  const hasMultipleAreas = useMemo(() => {
    const keys = Object.keys(groupedTables)
    return keys.length > 1 || (keys.length === 1 && !groupedTables['Tanpa Area'])
  }, [groupedTables])

  if (!activeOutletId) return <NoOutlet />

  return (
    <div className="space-y-4">
      <PageHeader title="Kelola Meja" subtitle={`${tables.filter((t) => t.is_active).length} meja aktif`}>
        <Button onClick={openAdd}><Plus className="mr-2 h-4 w-4" /> Tambah Meja</Button>
      </PageHeader>

      {isLoading ? (
        <div className="grid gap-3 grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-6">
          {Array.from({ length: 8 }).map((_, i) => <div key={i} className="h-28 rounded-xl bg-muted animate-pulse" />)}
        </div>
      ) : tables.length === 0 ? (
        <div className="flex h-64 items-center justify-center text-muted-foreground">Belum ada meja. Tambahkan meja baru.</div>
      ) : (
        <div className="space-y-4">
          {Object.entries(groupedTables).map(([area, areaTables]) => (
            <div key={area}>
              {hasMultipleAreas && <h3 className="text-sm font-medium text-muted-foreground mb-2">{area}</h3>}
              <div className="grid gap-3 grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-6 mb-6">
                {areaTables.map((t) => <TableCard key={t.id} table={t} onEdit={openEdit} />)}
              </div>
            </div>
          ))}
        </div>
      )}

      <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>
        <DialogContent className="max-w-sm">
          <DialogHeader><DialogTitle>{editTable ? `Edit Meja ${editTable.table_number}` : 'Tambah Meja Baru'}</DialogTitle></DialogHeader>
          <Form {...form}>
            <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-4">
              <FormField control={form.control} name="table_number" render={({ field }) => (
                <FormItem><FormLabel>Nomor Meja</FormLabel><FormControl><Input placeholder="1" {...field} /></FormControl><FormMessage /></FormItem>
              )} />
              <FormField control={form.control} name="area" render={({ field }) => (
                <FormItem><FormLabel>Area (opsional)</FormLabel><FormControl><Input placeholder="Indoor, Outdoor, VIP..." {...field} /></FormControl><FormMessage /></FormItem>
              )} />
              <FormField control={form.control} name="capacity" render={({ field }) => (
                <FormItem><FormLabel>Kapasitas</FormLabel><FormControl><Input type="number" min={1} {...field} /></FormControl><FormMessage /></FormItem>
              )} />
              <FormField control={form.control} name="is_active" render={({ field }) => (
                <FormItem className="flex items-center gap-2 space-y-0">
                  <FormControl><Checkbox checked={field.value} onCheckedChange={field.onChange} /></FormControl>
                  <FormLabel className="font-normal">Aktif</FormLabel>
                </FormItem>
              )} />
              <div className="flex justify-between gap-2">
                <div>
                  {editTable && (
                    <ConfirmDialog
                      title={`Hapus Meja ${editTable.table_number}?`}
                      description="Meja ini akan dihapus permanen dan tidak dapat dikembalikan."
                      confirmLabel="Hapus"
                      destructive
                      onConfirm={() => handleDelete(editTable.id, editTable.table_number)}
                      trigger={
                        <Button type="button" variant="destructive" size="sm">
                          <Trash2 className="mr-2 h-4 w-4" /> Hapus
                        </Button>
                      }
                    />
                  )}
                </div>
                <div className="flex gap-2">
                  <Button type="button" variant="outline" onClick={() => setDialogOpen(false)}>Batal</Button>
                  <Button type="submit" disabled={form.formState.isSubmitting}>{form.formState.isSubmitting ? 'Menyimpan...' : 'Simpan'}</Button>
                </div>
              </div>
            </form>
          </Form>
        </DialogContent>
      </Dialog>
    </div>
  )
}
