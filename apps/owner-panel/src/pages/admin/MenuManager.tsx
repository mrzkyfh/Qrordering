import { useState, useEffect, useRef } from 'react'
import { useNavigate } from 'react-router'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { Plus, Pencil, Trash2, Search, ImageOff, Upload, X, FlaskConical } from 'lucide-react'
import { useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { removeImageAsset, uploadImageAsset } from '@/lib/imageStorage'
import { useOutlet } from '@/hooks/useOutlet'
import { useMenuCategories, useMenuItems, useDeleteMenuItem, useItemExtras, useSyncItemExtras } from '@/hooks/queries/useMenuItems'
import { useIngredients } from '@/hooks/queries/useIngredients'
import { useMenuRecipes, useUpsertRecipe, useDeleteRecipe } from '@/hooks/queries/useMenuRecipes'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { Card, CardContent } from '@/components/ui/card'
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from '@/components/ui/form'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Textarea } from '@/components/ui/textarea'
import { Checkbox } from '@/components/ui/checkbox'
import { Switch } from '@/components/ui/switch'
import { Separator } from '@/components/ui/separator'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { CurrencyDisplay } from '@/components/ui/CurrencyDisplay'
import { useToast } from '@/hooks/use-toast'
import { humanizeError } from '@/lib/errorMessage'
import type { MenuItem, MenuCategory, MenuExtra } from '@/types/database'

const menuSchema = z.object({
  name: z.string().min(2, 'Nama minimal 2 karakter'),
  category_id: z.string().optional(),
  price: z.string().min(1, 'Harga wajib diisi'),
  description: z.string().optional(),
  preparation_time: z.string().refine((value) => {
    if (!value) return true
    const minutes = Number(value)
    return Number.isInteger(minutes) && minutes > 0
  }, 'Waktu persiapan harus bilangan bulat minimal 1 menit').optional(),
  is_available: z.boolean(),
  is_featured: z.boolean(),
  allow_price_override: z.boolean(),
  show_in_qr_menu: z.boolean(),
  tags: z.string().optional(),
})

type MenuValues = z.infer<typeof menuSchema>

export function MenuItemForm({
  outletId,
  categories,
  extras,
  item,
  onClose,
}: {
  outletId: string
  categories: MenuCategory[]
  extras: MenuExtra[]
  item?: MenuItem
  onClose: () => void
}) {
  const { toast } = useToast()
  const qc = useQueryClient()
  const syncExtras = useSyncItemExtras()

  // Image upload
  const fileInputRef = useRef<HTMLInputElement>(null)
  const [imageUrl, setImageUrl] = useState<string | null>(item?.image_url ?? null)
  const [uploading, setUploading] = useState(false)
  const [removingImage, setRemovingImage] = useState(false)
  const savedImageUrlRef = useRef<string | null>(item?.image_url ?? null)
  const pendingImageUrlsRef = useRef(new Set<string>())

  // Upload dilakukan sebelum tombol Simpan ditekan. Bersihkan hanya file yang
  // belum pernah masuk database saat form ditutup/batal; gambar tersimpan tidak
  // boleh dihapus sampai update menu benar-benar berhasil.
  useEffect(() => () => {
    for (const url of pendingImageUrlsRef.current) {
      void removeImageAsset(url).catch(() => undefined)
    }
    pendingImageUrlsRef.current.clear()
  }, [])

  async function handleImageUpload(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (!file) return
    if (!file.type.startsWith('image/')) {
      toast({ title: 'File harus berupa gambar', variant: 'destructive' }); return
    }
    if (file.size > 5 * 1024 * 1024) {
      toast({ title: 'Ukuran file maksimal 5 MB', variant: 'destructive' }); return
    }
    setUploading(true)
    try {
      const uploadedUrl = await uploadImageAsset(file, outletId, 'menu')
      pendingImageUrlsRef.current.add(uploadedUrl)
      if (imageUrl && pendingImageUrlsRef.current.has(imageUrl)) {
        const supersededUrl = imageUrl
        void removeImageAsset(supersededUrl)
          .then(() => pendingImageUrlsRef.current.delete(supersededUrl))
          .catch(() => undefined)
      }
      setImageUrl(uploadedUrl)
    } catch (err) {
      toast({ title: 'Gagal upload foto', description: humanizeError(err), variant: 'destructive' })
    } finally {
      setUploading(false)
      if (fileInputRef.current) fileInputRef.current.value = ''
    }
  }

  async function handleRemoveImage() {
    setRemovingImage(true)
    try {
      // Gambar yang sudah tersimpan tetap dipertahankan sampai menu sukses
      // disimpan. Hanya upload sementara yang aman dihapus saat ini.
      if (imageUrl && pendingImageUrlsRef.current.has(imageUrl)) {
        await removeImageAsset(imageUrl)
        pendingImageUrlsRef.current.delete(imageUrl)
      }
      setImageUrl(null)
    } catch {
      // non-blocking: file yatim dapat dibersihkan pada upload berikutnya
      setImageUrl(null)
    } finally {
      setRemovingImage(false)
    }
  }

  // Load existing extras for this item (edit mode)
  const { data: existingExtraIds = [] } = useItemExtras(item?.id)
  const [selectedExtras, setSelectedExtras] = useState<string[]>([])

  // Use join() so the effect only runs when actual IDs change, not on every new [] reference
  // eslint-disable-next-line react-hooks/exhaustive-deps, react-hooks/set-state-in-effect
  useEffect(() => { setSelectedExtras(existingExtraIds) }, [existingExtraIds.join(',')])

  function toggleExtra(id: string) {
    setSelectedExtras((prev) =>
      prev.includes(id) ? prev.filter((e) => e !== id) : [...prev, id]
    )
  }

  const form = useForm<MenuValues>({
    resolver: zodResolver(menuSchema),
    defaultValues: {
      name: item?.name ?? '',
      category_id: item?.category_id ?? undefined,
      price: item ? String(item.price) : '',
      description: item?.description ?? '',
      preparation_time: item?.preparation_time ? String(item.preparation_time) : '',
      is_available: item?.is_available ?? true,
      is_featured: item?.is_featured ?? false,
      allow_price_override: item?.allow_price_override ?? false,
      show_in_qr_menu: item?.show_in_qr_menu ?? true,
      tags: item?.tags?.join(', ') ?? '',
    },
  })

  async function onSubmit(values: MenuValues) {
    const price = parseFloat(values.price)
    if (isNaN(price) || price <= 0) {
      form.setError('price', { message: 'Harga harus angka positif' })
      return
    }

    const payload = {
      outlet_id: outletId,
      name: values.name,
      category_id: values.category_id ?? null,
      price,
      description: values.description || null,
      preparation_time: values.preparation_time ? parseInt(values.preparation_time) : null,
      is_available: values.is_available,
      is_featured: values.is_featured,
      allow_price_override: values.allow_price_override,
      show_in_qr_menu: values.show_in_qr_menu,
      is_active: true,
      tags: values.tags ? values.tags.split(',').map((t) => t.trim()).filter(Boolean) : null,
      sort_order: item?.sort_order ?? 0,
      variants: null,
      image_url: imageUrl,
    }

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const table = supabase.from('menu_items') as any

    const markImagePersisted = () => {
      if (imageUrl) pendingImageUrlsRef.current.delete(imageUrl)
      const previous = savedImageUrlRef.current
      savedImageUrlRef.current = imageUrl
      if (previous && previous !== imageUrl) {
        void removeImageAsset(previous).catch((error) => {
          console.warn('Gagal membersihkan gambar menu lama:', error)
        })
      }
    }

    try {
      if (item) {
        const { error } = await table.update(payload).eq('id', item.id)
        if (error) throw error
        markImagePersisted()
        await syncExtras.mutateAsync({ itemId: item.id, extraIds: selectedExtras })
        toast({ title: 'Menu berhasil diperbarui' })
      } else {
        const { data: newItem, error } = await table.insert(payload).select('id').single()
        if (error) throw error
        markImagePersisted()
        if (selectedExtras.length > 0) {
          await syncExtras.mutateAsync({ itemId: newItem.id, extraIds: selectedExtras })
        }
        toast({ title: 'Menu berhasil ditambahkan' })
      }
    } catch (error) {
      toast({
        title: item ? 'Gagal memperbarui menu' : 'Gagal menambah menu',
        description: humanizeError(error),
        variant: 'destructive',
      })
      return
    }

    qc.invalidateQueries({ queryKey: ['menu-items'] })
    onClose()
  }

  return (
    <Form {...form}>
      {/* Ref upload hanya dibaca ketika callback submit dijalankan, bukan saat render. */}
      {/* eslint-disable-next-line react-hooks/refs */}
      <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-6">

        {/* Image upload */}
        <div className="space-y-2">
          <label className="text-sm font-medium">Foto Menu</label>
          <input
            ref={fileInputRef}
            type="file"
            accept="image/jpeg,image/png,image/webp"
            className="hidden"
            onChange={handleImageUpload}
          />
          {imageUrl ? (
            <div className="relative w-full h-40 rounded-lg overflow-hidden border bg-muted">
              <img src={imageUrl} alt="preview" className="h-full w-full object-cover" />
              <Button
                type="button"
                variant="ghost"
                size="icon-sm"
                onClick={handleRemoveImage}
                disabled={removingImage}
                aria-label="Hapus gambar menu"
                className="absolute right-2 top-2 rounded-full bg-black/60 text-white hover:bg-black/80 hover:text-white"
              >
                <X className="h-4 w-4" />
              </Button>
            </div>
          ) : (
          <Button
            type="button"
            variant="outline"
            onClick={() => fileInputRef.current?.click()}
            disabled={uploading}
            className="h-32 w-full flex-col gap-2 whitespace-normal rounded-lg border-2 border-dashed border-muted-foreground/30 text-muted-foreground hover:border-primary/50 hover:bg-muted/50"
          >
              <Upload className="h-6 w-6" />
              <span className="text-sm">{uploading ? 'Mengupload...' : 'Klik untuk upload foto'}</span>
              <span className="text-xs">JPG, PNG, WebP · Maks 5 MB</span>
          </Button>
          )}
          {imageUrl && (
            <Button type="button" variant="outline" size="sm" onClick={() => fileInputRef.current?.click()} disabled={uploading}>
              <Upload className="h-3.5 w-3.5 mr-1" />
              {uploading ? 'Mengupload...' : 'Ganti Foto'}
            </Button>
          )}
        </div>

        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <FormField control={form.control} name="name" render={({ field }) => (
            <FormItem className="sm:col-span-2">
              <FormLabel>Nama Menu</FormLabel>
              <FormControl><Input placeholder="Contoh: Nasi Goreng Spesial" {...field} /></FormControl>
              <FormMessage />
            </FormItem>
          )} />

          <FormField control={form.control} name="category_id" render={({ field }) => (
            <FormItem>
              <FormLabel>Kategori</FormLabel>
              <Select onValueChange={field.onChange} defaultValue={field.value}>
                <FormControl><SelectTrigger><SelectValue placeholder="Pilih kategori" /></SelectTrigger></FormControl>
                <SelectContent>
                  {categories.map((c) => <SelectItem key={c.id} value={c.id}>{c.name}</SelectItem>)}
                </SelectContent>
              </Select>
              <FormMessage />
            </FormItem>
          )} />

          <FormField control={form.control} name="price" render={({ field }) => (
            <FormItem>
              <FormLabel>Harga (Rp)</FormLabel>
              <FormControl>
                <Input
                  inputMode="numeric"
                  placeholder="15.000"
                  value={field.value ? Number(field.value.replace(/\./g, '')).toLocaleString('id-ID') : ''}
                  onChange={(e) => {
                    const raw = e.target.value.replace(/\./g, '').replace(/\D/g, '')
                    field.onChange(raw)
                  }}
                />
              </FormControl>
              <FormMessage />
            </FormItem>
          )} />

          <FormField control={form.control} name="allow_price_override" render={({ field }) => (
            <FormItem className="flex items-center justify-between gap-4 rounded-lg border p-4 sm:col-span-2">
              <div className="space-y-0.5">
                <FormLabel className="text-sm">Ubah Harga Jual</FormLabel>
                <p className="text-xs text-muted-foreground">
                  Izinkan kasir mengubah harga jual produk ini saat transaksi.
                </p>
              </div>
              <FormControl>
                <Switch
                  checked={field.value}
                  onCheckedChange={field.onChange}
                  aria-label="Izinkan kasir mengubah harga jual"
                />
              </FormControl>
            </FormItem>
          )} />

          <FormField control={form.control} name="show_in_qr_menu" render={({ field }) => (
            <FormItem className="flex items-center justify-between gap-4 rounded-lg border p-4 sm:col-span-2">
              <div className="space-y-0.5">
                <FormLabel className="text-sm">Menu QR</FormLabel>
                <p className="text-xs text-muted-foreground">
                  Tampilkan produk ini di Menu QR untuk pemesanan pelanggan.
                </p>
              </div>
              <FormControl>
                <Switch
                  checked={field.value}
                  onCheckedChange={field.onChange}
                  aria-label="Tampilkan produk di Menu QR"
                />
              </FormControl>
            </FormItem>
          )} />

          <FormField control={form.control} name="description" render={({ field }) => (
            <FormItem className="sm:col-span-2">
              <FormLabel>Deskripsi</FormLabel>
              <FormControl><Textarea placeholder="Deskripsi menu..." rows={2} maxLength={500} {...field} /></FormControl>
              <FormMessage />
            </FormItem>
          )} />

          <FormField control={form.control} name="preparation_time" render={({ field }) => (
            <FormItem>
              <FormLabel>Waktu Masak (menit)</FormLabel>
              <FormControl><Input type="number" min={1} placeholder="15" {...field} /></FormControl>
              <FormMessage />
            </FormItem>
          )} />

          <FormField control={form.control} name="tags" render={({ field }) => (
            <FormItem>
              <FormLabel>Tags (pisah koma)</FormLabel>
              <FormControl><Input placeholder="pedas, populer, baru" {...field} /></FormControl>
              <FormMessage />
            </FormItem>
          )} />
        </div>

        <div className="flex gap-6">
          <FormField control={form.control} name="is_available" render={({ field }) => (
            <FormItem className="flex items-center gap-2 space-y-0">
              <FormControl><Checkbox checked={field.value} onCheckedChange={field.onChange} /></FormControl>
              <FormLabel className="font-normal">Tersedia</FormLabel>
            </FormItem>
          )} />
          <FormField control={form.control} name="is_featured" render={({ field }) => (
            <FormItem className="flex items-center gap-2 space-y-0">
              <FormControl><Checkbox checked={field.value} onCheckedChange={field.onChange} /></FormControl>
              <FormLabel className="font-normal">Unggulan</FormLabel>
            </FormItem>
          )} />
        </div>

        {/* Extras section */}
        {extras.length > 0 && (
          <>
            <Separator />
            <div className="space-y-2">
              <p className="text-sm font-medium">Ekstra yang Tersedia</p>
              <p className="text-xs text-muted-foreground">Pilih item tambahan yang dapat dipesan bersama menu ini</p>
              <div className="grid max-h-56 grid-cols-1 gap-2 overflow-y-auto sm:grid-cols-2">
                {extras.filter((e) => e.is_active).map((ex) => (
                  <label
                    key={ex.id}
                    className="flex items-center gap-2 rounded-lg border px-3 py-2 cursor-pointer hover:bg-muted/50 transition-colors"
                  >
                    <Checkbox
                      checked={selectedExtras.includes(ex.id)}
                      onCheckedChange={() => toggleExtra(ex.id)}
                    />
                    <div className="min-w-0">
                      <p className="text-sm truncate">{ex.name}</p>
                      <p className="text-xs text-muted-foreground">
                        {ex.menu_extra_options?.length
                          ? `${ex.menu_extra_options.length} opsi`
                          : 'Belum ada opsi'}
                      </p>
                    </div>
                  </label>
                ))}
              </div>
              {selectedExtras.length > 0 && (
                <p className="text-xs text-primary">{selectedExtras.length} ekstra dipilih</p>
              )}
            </div>
          </>
        )}

        {/* Recipe section — only shown when editing an existing menu item */}
        {item && (
          <>
            <Separator />
            <RecipeSection menuItemId={item.id} outletId={outletId} />
          </>
        )}

        <div className="flex justify-end gap-2 pt-2">
          <Button type="button" variant="outline" onClick={onClose}>Batal</Button>
          <Button type="submit" disabled={form.formState.isSubmitting}>
            {form.formState.isSubmitting ? 'Menyimpan...' : item ? 'Perbarui' : 'Tambah'}
          </Button>
        </div>
      </form>
    </Form>
  )
}

// ─── Recipe Section ───────────────────────────────────────────────────────────

function RecipeSection({ menuItemId, outletId }: { menuItemId: string; outletId: string }) {
  const { toast } = useToast()
  const { data: recipes = [], isLoading } = useMenuRecipes(menuItemId)
  const { data: ingredients = [] } = useIngredients(outletId)
  const upsert = useUpsertRecipe()
  const deleteRecipe = useDeleteRecipe()

  const [selectedIngredient, setSelectedIngredient] = useState('')
  const [qty, setQty] = useState('')

  const usedIngredientIds = new Set(recipes.map((r) => r.ingredient_id))
  const availableIngredients = ingredients.filter((i) => !usedIngredientIds.has(i.id))

  async function handleAdd() {
    if (!selectedIngredient || !qty || parseFloat(qty) <= 0) {
      toast({ title: 'Pilih bahan dan masukkan qty', variant: 'destructive' })
      return
    }
    try {
      await upsert.mutateAsync({
        menu_item_id: menuItemId,
        ingredient_id: selectedIngredient,
        qty_per_portion: parseFloat(qty),
      })
      setSelectedIngredient('')
      setQty('')
      toast({ title: 'Bahan ditambahkan ke resep' })
    } catch (error) {
      toast({ title: 'Gagal menambahkan bahan', description: humanizeError(error), variant: 'destructive' })
    }
  }

  async function handleDelete(id: string) {
    try {
      await deleteRecipe.mutateAsync({ id, menu_item_id: menuItemId })
      toast({ title: 'Bahan dihapus dari resep' })
    } catch (error) {
      toast({ title: 'Gagal menghapus bahan', description: humanizeError(error), variant: 'destructive' })
    }
  }

  return (
    <div className="space-y-3">
      <div className="flex items-center gap-2">
        <FlaskConical className="h-4 w-4 text-muted-foreground" />
        <p className="text-sm font-medium">Resep Bahan Baku</p>
        <span className="text-xs text-muted-foreground">(untuk pengurangan stok otomatis)</span>
      </div>

      {/* Current recipe list */}
      {isLoading ? (
        <div className="h-8 bg-muted rounded animate-pulse" />
      ) : recipes.length === 0 ? (
        <p className="text-xs text-muted-foreground italic">
          Belum ada resep — stok tidak akan berkurang otomatis.
        </p>
      ) : (
        <div className="space-y-1.5">
          {recipes.map((r) => (
            <div
              key={r.id}
              className="flex items-center justify-between rounded-lg border bg-muted/30 px-3 py-2"
            >
              <div className="flex items-center gap-2">
                <span className="text-sm font-medium">{r.ingredients?.name ?? '—'}</span>
                <span className="text-xs text-muted-foreground">
                  {r.qty_per_portion} {r.ingredients?.unit ?? ''}
                </span>
              </div>
              <Button
                type="button"
                variant="ghost"
                size="icon-xs"
                onClick={() => handleDelete(r.id)}
                aria-label={`Hapus bahan ${r.ingredients?.name ?? ''}`}
                disabled={deleteRecipe.isPending}
                className="text-muted-foreground hover:text-destructive"
              >
                <X className="h-4 w-4" />
              </Button>
            </div>
          ))}
        </div>
      )}

      {/* Add ingredient row */}
      {availableIngredients.length > 0 && (
        <div className="flex gap-2">
          <Select value={selectedIngredient} onValueChange={setSelectedIngredient}>
            <SelectTrigger className="flex-1 h-8 text-xs">
              <SelectValue placeholder="Pilih bahan..." />
            </SelectTrigger>
            <SelectContent>
              {availableIngredients.map((i) => (
                <SelectItem key={i.id} value={i.id} className="text-xs">
                  {i.name} ({i.unit})
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
          <Input
            type="number"
            min={0}
            step="0.01"
            placeholder="Qty"
            value={qty}
            onChange={(e) => setQty(e.target.value)}
            onKeyDown={(e) => e.key === '-' && e.preventDefault()}
            className="w-20 h-8 text-xs"
          />
          <Button
            type="button"
            size="sm"
            className="h-8"
            disabled={upsert.isPending}
            onClick={handleAdd}
            aria-label="Tambah bahan ke resep"
          >
            <Plus className="h-3.5 w-3.5" />
          </Button>
        </div>
      )}

      {availableIngredients.length === 0 && recipes.length > 0 && (
        <p className="text-xs text-muted-foreground">Semua bahan sudah ditambahkan.</p>
      )}

      {ingredients.length === 0 && (
        <p className="text-xs text-amber-600">
          Belum ada bahan baku — tambahkan dulu di menu Stok.
        </p>
      )}
    </div>
  )
}

export default function MenuManager() {
  const { activeOutletId } = useOutlet()
  const navigate = useNavigate()
  const [selectedCategory, setSelectedCategory] = useState<string | undefined>()
  const [search, setSearch] = useState('')
  const { data: categories = [] } = useMenuCategories(activeOutletId ?? '')
  const { data: items = [], isLoading } = useMenuItems(activeOutletId ?? '', selectedCategory)
  const deleteMenu = useDeleteMenuItem()
  const { toast } = useToast()

  const filtered = items.filter((i) => i.name.toLowerCase().includes(search.toLowerCase()))

  if (!activeOutletId) {
    return <NoOutlet />
  }

  return (
    <div className="space-y-4">
      <PageHeader title="Kelola Menu">
        <Button onClick={() => navigate('/admin/menu/new')}>
          <Plus className="mr-2 h-4 w-4" /> Tambah Menu
        </Button>
      </PageHeader>

      <div className="flex gap-2 flex-wrap">
        <Button variant={!selectedCategory ? 'default' : 'outline'} size="sm" onClick={() => setSelectedCategory(undefined)}>Semua</Button>
        {categories.map((c) => (
          <Button key={c.id} variant={selectedCategory === c.id ? 'default' : 'outline'} size="sm" onClick={() => setSelectedCategory(c.id)}>
            {c.icon && <span className="mr-1">{c.icon}</span>}
            {c.name}
          </Button>
        ))}
      </div>

      <div className="relative max-w-xs">
        <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground" />
        <Input placeholder="Cari menu..." className="pl-9" value={search} onChange={(e) => setSearch(e.target.value)} />
      </div>

      {isLoading ? (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {Array.from({ length: 6 }).map((_, i) => (
            <Card key={i}><CardContent className="p-4"><div className="h-32 bg-muted rounded animate-pulse" /></CardContent></Card>
          ))}
        </div>
      ) : (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {filtered.map((item) => (
            <Card key={item.id} className="overflow-hidden">
              <div className="h-32 bg-muted flex items-center justify-center">
                {item.image_url ? (
                  <img src={item.image_url} alt={item.name} className="h-full w-full object-cover" />
                ) : (
                  <ImageOff className="h-8 w-8 text-muted-foreground/40" />
                )}
              </div>
              <CardContent className="p-3">
                <div className="flex items-start justify-between gap-2">
                  <div className="min-w-0">
                    <p className="font-medium truncate">{item.name}</p>
                    <p className="text-sm text-muted-foreground">{item.menu_categories?.name ?? '—'}</p>
                    <p className="text-sm font-semibold mt-1"><CurrencyDisplay value={item.price} /></p>
                  </div>
                  <div className="flex flex-col items-end gap-1 shrink-0">
                    <Badge variant={item.is_available ? 'default' : 'secondary'} className="text-xs">
                      {item.is_available ? 'Tersedia' : 'Habis'}
                    </Badge>
                    {item.is_featured && <Badge variant="outline" className="text-xs">Unggulan</Badge>}
                    {item.allow_price_override && <Badge variant="outline" className="text-xs">Harga fleksibel</Badge>}
                    {!item.show_in_qr_menu && <Badge variant="secondary" className="text-xs">Tidak tampil di QR</Badge>}
                  </div>
                </div>
                <div className="flex gap-1 mt-3">
                  <Button variant="outline" size="sm" className="flex-1" onClick={() => navigate(`/admin/menu/${item.id}/edit`)}>
                    <Pencil className="h-3.5 w-3.5 mr-1" /> Edit
                  </Button>
                  <ConfirmDialog
                    title={`Hapus "${item.name}"?`}
                    description="Menu akan dihapus permanen kalau belum pernah dipesan, atau di-arsipkan kalau ada history transaksi."
                    confirmLabel="Hapus"
                    destructive
                    onConfirm={() => deleteMenu.mutateAsync(item.id, {
                      onSuccess: async (res) => {
                        // Bersihkan file gambar dari storage saat delete sukses (permanen maupun arsip).
                        if ((res.status === 'deleted' || res.status === 'archived') && item.image_url) {
                          try {
                            await removeImageAsset(item.image_url)
                          } catch (rmErr) {
                            console.warn('Gagal hapus gambar dari storage:', rmErr)
                            toast({
                              title: 'Menu dihapus, tapi gambar gagal dibersihkan',
                              description: humanizeError(rmErr),
                              variant: 'destructive',
                            })
                          }
                        }
                        toast({
                          title: res.status === 'archived' ? 'Menu di-arsipkan' : 'Menu dihapus permanen',
                          description: res.reason,
                        })
                      },
                      onError: (e) => toast({ title: 'Gagal hapus', description: humanizeError(e), variant: 'destructive' }),
                    })}
                    trigger={
                      <Button variant="outline" size="sm" className="text-destructive hover:text-destructive" aria-label={`Hapus menu ${item.name}`}>
                        <Trash2 className="h-3.5 w-3.5" />
                      </Button>
                    }
                  />
                </div>
              </CardContent>
            </Card>
          ))}
          {filtered.length === 0 && (
            <div className="col-span-full py-16 text-center text-muted-foreground">Tidak ada menu ditemukan.</div>
          )}
        </div>
      )}

    </div>
  )
}
