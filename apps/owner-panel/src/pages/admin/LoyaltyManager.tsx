import { useState } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { format } from 'date-fns'
import { id } from 'date-fns/locale'
import { Search, Plus, Pencil, Gift, ChevronRight, Trash2 } from 'lucide-react'
import { useOutlet } from '@/hooks/useOutlet'
import {
  useLoyaltyMembers,
  useLoyaltySummary,
  useLoyaltyTransactions,
  useCreateLoyaltyMember,
  useUpdateLoyaltyMember,
  useDeleteLoyaltyMember,
  useAdjustPoints,
} from '@/hooks/queries/useLoyalty'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { DataTable } from '@/components/ui/DataTable'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { Skeleton } from '@/components/ui/skeleton'
import { Separator } from '@/components/ui/separator'
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Sheet, SheetContent, SheetHeader, SheetTitle } from '@/components/ui/sheet'
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from '@/components/ui/form'
import { Switch } from '@/components/ui/switch'
import { useToast } from '@/hooks/use-toast'
import { humanizeError } from '@/lib/errorMessage'
import type { LoyaltyMember, LoyaltyTier } from '@/types/database'

const TIER_CONFIG: Record<LoyaltyTier, { label: string; className: string }> = {
  bronze:   { label: 'Bronze',   className: 'bg-orange-100 text-orange-700 border-orange-200' },
  silver:   { label: 'Silver',   className: 'bg-slate-100 text-slate-600 border-slate-200' },
  gold:     { label: 'Gold',     className: 'bg-yellow-100 text-yellow-700 border-yellow-200' },
  platinum: { label: 'Platinum', className: 'bg-purple-100 text-purple-700 border-purple-200' },
}

function TierBadge({ tier }: { tier: LoyaltyTier }) {
  const cfg = TIER_CONFIG[tier]
  return (
    <span className={`inline-flex rounded-full px-2 py-0.5 text-xs font-semibold border ${cfg.className}`}>
      {cfg.label}
    </span>
  )
}

const memberSchema = z.object({
  phone: z.string()
    .min(8, 'Nomor HP minimal 8 digit')
    .regex(/^\+?[\d\s-]{8,}$/, 'Format nomor HP tidak valid'),
  name: z.string().min(1, 'Nama wajib diisi'),
})
type MemberValues = z.infer<typeof memberSchema>

const editSchema = z.object({
  name: z.string().min(1, 'Nama wajib diisi'),
  is_active: z.boolean(),
})
type EditValues = z.infer<typeof editSchema>

const adjustSchema = z.object({
  points: z.string().min(1, 'Wajib diisi'),
  description: z.string().min(1, 'Keterangan wajib diisi'),
})
type AdjustValues = z.infer<typeof adjustSchema>

export default function LoyaltyManager() {
  const { activeOutletId } = useOutlet()
  const { toast } = useToast()

  const [search, setSearch] = useState('')
  const [addOpen, setAddOpen] = useState(false)
  const [editMember, setEditMember] = useState<LoyaltyMember | null>(null)
  const [detailMember, setDetailMember] = useState<LoyaltyMember | null>(null)
  const [adjustMember, setAdjustMember] = useState<LoyaltyMember | null>(null)

  const { data: members = [], isLoading } = useLoyaltyMembers(activeOutletId, search)
  const { data: summary = [] } = useLoyaltySummary(activeOutletId)
  const { data: transactions = [], isLoading: loadingTx } = useLoyaltyTransactions(detailMember?.id ?? null)

  const createMember = useCreateLoyaltyMember(activeOutletId)
  const updateMember = useUpdateLoyaltyMember(activeOutletId)
  const deleteMember = useDeleteLoyaltyMember(activeOutletId)
  const adjustPoints = useAdjustPoints(activeOutletId)

  const totalMembers = summary.reduce((s, r) => s + r.member_count, 0)
  const totalPoints  = summary.reduce((s, r) => s + r.total_points_outstanding, 0)
  const activeMembers = summary.reduce((s, r) => s + r.active_members, 0)

  // ── Add form ──────────────────────────────────────────────
  const addForm = useForm<MemberValues>({
    resolver: zodResolver(memberSchema),
    defaultValues: { phone: '', name: '' },
  })

  async function onAddSubmit(values: MemberValues) {
    try {
      await createMember.mutateAsync(values)
      toast({ title: 'Member ditambahkan' })
      addForm.reset()
      setAddOpen(false)
    } catch (err: unknown) {
      const msg = humanizeError(err)
      const isDuplicate = msg.includes('duplicate') || msg.includes('unique')
      toast({
        title: 'Gagal',
        description: isDuplicate ? 'Nomor HP sudah terdaftar di outlet ini.' : msg,
        variant: 'destructive',
      })
    }
  }

  // ── Edit form ─────────────────────────────────────────────
  const editForm = useForm<EditValues>({
    resolver: zodResolver(editSchema),
  })

  function openEdit(member: LoyaltyMember) {
    editForm.reset({ name: member.name, is_active: member.is_active })
    setEditMember(member)
  }

  async function onEditSubmit(values: EditValues) {
    if (!editMember) return
    try {
      await updateMember.mutateAsync({ id: editMember.id, ...values })
      toast({ title: 'Member diperbarui' })
      setEditMember(null)
    } catch (err) {
      toast({ title: 'Gagal', description: humanizeError(err), variant: 'destructive' })
    }
  }

  // ── Adjust points form ────────────────────────────────────
  const adjustForm = useForm<AdjustValues>({
    resolver: zodResolver(adjustSchema),
    defaultValues: { points: '', description: '' },
  })

  function openAdjust(member: LoyaltyMember) {
    adjustForm.reset({ points: '', description: '' })
    setAdjustMember(member)
  }

  async function onAdjustSubmit(values: AdjustValues) {
    if (!adjustMember) return
    const pts = parseInt(values.points.trim(), 10)
    if (isNaN(pts) || pts === 0) return
    try {
      await adjustPoints.mutateAsync({
        member: adjustMember,
        points: pts,
        description: values.description,
      })
      toast({ title: `Poin disesuaikan: ${pts > 0 ? '+' : ''}${pts}` })
      setAdjustMember(null)
      setDetailMember(null)
    } catch (err) {
      const msg = humanizeError(err)
      toast({ title: 'Gagal', description: msg, variant: 'destructive' })
    }
  }

  if (!activeOutletId) return <NoOutlet />

  return (
    <div className="space-y-4">
      <PageHeader title="Program Loyalty" subtitle="Kelola member dan poin reward pelanggan">
        <Button onClick={() => setAddOpen(true)}>
          <Plus className="mr-2 h-4 w-4" /> Tambah Member
        </Button>
      </PageHeader>

      {/* Summary cards */}
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <div className="rounded-lg border bg-card p-4">
          <p className="text-xs text-muted-foreground">Total Member</p>
          <p className="mt-1 text-2xl font-bold">{totalMembers}</p>
        </div>
        <div className="rounded-lg border bg-card p-4">
          <p className="text-xs text-muted-foreground">Member Aktif</p>
          <p className="mt-1 text-2xl font-bold text-green-600">{activeMembers}</p>
        </div>
        <div className="rounded-lg border bg-card p-4">
          <p className="text-xs text-muted-foreground">Total Poin Beredar</p>
          <p className="mt-1 text-2xl font-bold">{totalPoints.toLocaleString('id-ID')}</p>
        </div>
        <div className="rounded-lg border bg-card p-4">
          <p className="text-xs text-muted-foreground">Distribusi Tier</p>
          <div className="mt-1 flex flex-wrap gap-1">
            {summary.map((s) => (
              <span key={s.tier} className="text-xs">
                <TierBadge tier={s.tier as LoyaltyTier} /> {s.member_count}
              </span>
            ))}
            {summary.length === 0 && <span className="text-muted-foreground text-sm">—</span>}
          </div>
        </div>
      </div>

      {/* Search */}
      <div className="relative max-w-xs">
        <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground" />
        <Input
          placeholder="Cari nama atau nomor HP..."
          className="pl-9"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
        />
      </div>

      <DataTable
        data={members}
        loading={isLoading}
        getRowKey={(r) => r.id}
        emptyMessage={search ? 'Member tidak ditemukan.' : 'Belum ada member terdaftar.'}
        columns={[
          {
            key: 'name',
            header: 'Nama',
            cell: (r) => (
              <Button
                variant="link"
                className="h-auto justify-start p-0 text-left font-medium"
                onClick={() => setDetailMember(r)}
              >
                {r.name || '—'}
              </Button>
            ),
          },
          {
            key: 'phone',
            header: 'No. HP',
            cell: (r) => <span className="font-mono text-sm">{r.phone}</span>,
          },
          {
            key: 'tier',
            header: 'Tier',
            cell: (r) => <TierBadge tier={r.tier} />,
          },
          {
            key: 'points',
            header: 'Poin',
            cell: (r) => (
              <span className="font-semibold">{r.points.toLocaleString('id-ID')}</span>
            ),
          },
          {
            key: 'status',
            header: 'Status',
            cell: (r) => (
              <Badge variant={r.is_active ? 'default' : 'secondary'}>
                {r.is_active ? 'Aktif' : 'Nonaktif'}
              </Badge>
            ),
          },
          {
            key: 'joined',
            header: 'Bergabung',
            cell: (r) => format(new Date(r.created_at), 'd MMM yyyy', { locale: id }),
          },
          {
            key: 'actions',
            header: '',
            className: 'text-right',
            cell: (r) => (
              <div className="flex gap-1 justify-end">
                <Button variant="ghost" size="sm" onClick={() => openAdjust(r)} aria-label={`Sesuaikan poin ${r.name || r.phone}`}>
                  <Gift className="h-4 w-4" />
                </Button>
                <Button variant="ghost" size="sm" onClick={() => openEdit(r)} aria-label={`Edit member ${r.name || r.phone}`}>
                  <Pencil className="h-4 w-4" />
                </Button>
                <Button variant="ghost" size="sm" onClick={() => setDetailMember(r)} aria-label={`Detail member ${r.name || r.phone}`}>
                  <ChevronRight className="h-4 w-4" />
                </Button>
                <ConfirmDialog
                  title={`Hapus member "${r.name || r.phone}"?`}
                  description="Member & riwayat poinnya dihapus permanen. Order yang pernah memakainya tetap tersimpan (relasi member dilepas)."
                  confirmLabel="Hapus"
                  destructive
                  onConfirm={() =>
                    deleteMember.mutateAsync(r.id, {
                      onSuccess: () => toast({ title: 'Member dihapus' }),
                      onError: (e) =>
                        toast({ title: 'Gagal hapus member', description: humanizeError(e), variant: 'destructive' }),
                    })
                  }
                  trigger={
                    <Button variant="ghost" size="sm" className="text-destructive hover:text-destructive" aria-label={`Hapus member ${r.name || r.phone}`}>
                      <Trash2 className="h-4 w-4" />
                    </Button>
                  }
                />
              </div>
            ),
          },
        ]}
      />

      {/* ── Add Member Dialog ── */}
      <Dialog open={addOpen} onOpenChange={setAddOpen}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Tambah Member Baru</DialogTitle>
          </DialogHeader>
          <Form {...addForm}>
            <form onSubmit={addForm.handleSubmit(onAddSubmit)} className="space-y-4">
              <FormField
                control={addForm.control}
                name="phone"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Nomor HP</FormLabel>
                    <FormControl>
                      <Input inputMode="tel" placeholder="08xxxxxxxxxx" {...field} />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />
              <FormField
                control={addForm.control}
                name="name"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Nama</FormLabel>
                    <FormControl>
                      <Input placeholder="Nama pelanggan" {...field} />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />
              <div className="flex justify-end gap-2">
                <Button type="button" variant="outline" onClick={() => setAddOpen(false)}>
                  Batal
                </Button>
                <Button type="submit" disabled={addForm.formState.isSubmitting}>
                  {addForm.formState.isSubmitting ? 'Menyimpan...' : 'Simpan'}
                </Button>
              </div>
            </form>
          </Form>
        </DialogContent>
      </Dialog>

      {/* ── Edit Member Dialog ── */}
      <Dialog open={!!editMember} onOpenChange={(open) => { if (!open) setEditMember(null) }}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Edit Member</DialogTitle>
          </DialogHeader>
          <Form {...editForm}>
            <form onSubmit={editForm.handleSubmit(onEditSubmit)} className="space-y-4">
              <FormField
                control={editForm.control}
                name="name"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Nama</FormLabel>
                    <FormControl>
                      <Input {...field} />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />
              <FormField
                control={editForm.control}
                name="is_active"
                render={({ field }) => (
                  <FormItem className="flex items-center justify-between rounded-lg border p-3">
                    <FormLabel className="mb-0">Member Aktif</FormLabel>
                    <FormControl>
                      <Switch aria-label="Status member aktif" checked={field.value} onCheckedChange={field.onChange} />
                    </FormControl>
                  </FormItem>
                )}
              />
              <div className="flex justify-end gap-2">
                <Button type="button" variant="outline" onClick={() => setEditMember(null)}>
                  Batal
                </Button>
                <Button type="submit" disabled={editForm.formState.isSubmitting}>
                  {editForm.formState.isSubmitting ? 'Menyimpan...' : 'Simpan'}
                </Button>
              </div>
            </form>
          </Form>
        </DialogContent>
      </Dialog>

      {/* ── Adjust Points Dialog ── */}
      <Dialog open={!!adjustMember} onOpenChange={(open) => { if (!open) setAdjustMember(null) }}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Sesuaikan Poin — {adjustMember?.name}</DialogTitle>
          </DialogHeader>
          <p className="text-sm text-muted-foreground -mt-2">
            Poin saat ini: <span className="font-semibold text-foreground">{adjustMember?.points.toLocaleString('id-ID')}</span>
          </p>
          <Form {...adjustForm}>
            <form onSubmit={adjustForm.handleSubmit(onAdjustSubmit)} className="space-y-4">
              <FormField
                control={adjustForm.control}
                name="points"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Jumlah Poin <span className="text-muted-foreground text-xs">(gunakan minus untuk kurangi, contoh: -100)</span></FormLabel>
                    <FormControl>
                      <Input
                        inputMode="numeric"
                        placeholder="contoh: 500 atau -200"
                        {...field}
                      />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />
              <FormField
                control={adjustForm.control}
                name="description"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Keterangan</FormLabel>
                    <FormControl>
                      <Input placeholder="Alasan penyesuaian poin..." {...field} />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />
              <div className="flex justify-end gap-2">
                <Button type="button" variant="outline" onClick={() => setAdjustMember(null)}>
                  Batal
                </Button>
                <Button type="submit" disabled={adjustForm.formState.isSubmitting}>
                  {adjustForm.formState.isSubmitting ? 'Menyimpan...' : 'Terapkan'}
                </Button>
              </div>
            </form>
          </Form>
        </DialogContent>
      </Dialog>

      {/* ── Member Detail Sheet ── */}
      <Sheet open={!!detailMember} onOpenChange={(open) => { if (!open) setDetailMember(null) }}>
        <SheetContent className="w-full sm:max-w-md overflow-y-auto">
          {detailMember && (
            <>
              <SheetHeader className="mb-4">
                <SheetTitle>{detailMember.name || 'Member'}</SheetTitle>
                <div className="flex items-center gap-2">
                  <TierBadge tier={detailMember.tier} />
                  <Badge variant={detailMember.is_active ? 'default' : 'secondary'}>
                    {detailMember.is_active ? 'Aktif' : 'Nonaktif'}
                  </Badge>
                </div>
              </SheetHeader>

              <div className="space-y-5">
                <div className="grid grid-cols-2 gap-3 text-sm">
                  <div>
                    <p className="text-muted-foreground">No. HP</p>
                    <p className="font-mono font-medium">{detailMember.phone}</p>
                  </div>
                  <div>
                    <p className="text-muted-foreground">Poin</p>
                    <p className="font-bold text-lg">{detailMember.points.toLocaleString('id-ID')}</p>
                  </div>
                  <div>
                    <p className="text-muted-foreground">Bergabung</p>
                    <p>{format(new Date(detailMember.created_at), 'd MMM yyyy', { locale: id })}</p>
                  </div>
                </div>

                <Separator />

                <div>
                  <p className="text-sm font-semibold mb-3">Riwayat Poin</p>
                  {loadingTx ? (
                    <div className="space-y-2">
                      <Skeleton className="h-8 w-full" />
                      <Skeleton className="h-8 w-full" />
                    </div>
                  ) : transactions.length === 0 ? (
                    <p className="text-sm text-muted-foreground">Belum ada riwayat transaksi poin.</p>
                  ) : (
                    <div className="space-y-2">
                      {transactions.map((tx) => (
                        <div key={tx.id} className="flex items-start justify-between text-sm py-1.5 border-b last:border-0">
                          <div>
                            <p className="font-medium capitalize text-xs text-muted-foreground">{tx.type}</p>
                            <p>{tx.description || '—'}</p>
                            <p className="text-xs text-muted-foreground">
                              {format(new Date(tx.created_at), 'd MMM yyyy, HH:mm', { locale: id })}
                            </p>
                          </div>
                          <span className={`font-bold shrink-0 ml-3 ${tx.points >= 0 ? 'text-green-600' : 'text-red-600'}`}>
                            {tx.points >= 0 ? '+' : ''}{tx.points.toLocaleString('id-ID')}
                          </span>
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              </div>
            </>
          )}
        </SheetContent>
      </Sheet>
    </div>
  )
}
