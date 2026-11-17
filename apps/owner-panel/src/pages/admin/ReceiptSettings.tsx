import { useState, useEffect, useRef } from 'react'
import { removeImageAsset, uploadImageAsset } from '@/lib/imageStorage'
import { humanizeError } from '@/lib/errorMessage'
import { useOutlet } from '@/hooks/useOutlet'
import { useUpdateOutlet } from '@/hooks/queries/useOutlets'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Switch } from '@/components/ui/switch'
import { Textarea } from '@/components/ui/textarea'
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/tabs'
import { AlignLeft, AlignCenter, AlignRight, X, Plus, Store, GripVertical } from 'lucide-react'
import { cn } from '@/lib/utils'
import { useToast } from '@/hooks/use-toast'

// ─── Types ────────────────────────────────────────────────────────────────────

type CustomField = { id: string; label: string; value: string; visible: boolean }

type RS = {
  showLogo: boolean
  logoStyle: 'normal' | 'full'
  logoUrl: string
  showBusinessName: boolean
  showOutletName: boolean
  showAddress: boolean
  showPhone: boolean
  showCity: boolean
  showProvince: boolean
  showCountry: boolean
  customHeaderFields: CustomField[]
  limitPrint: boolean
  customHeader: boolean
  customHeaderText: string
  customHeaderAlign: 'left' | 'center' | 'right'
  showOrderNumber: boolean
  showOrderTime: boolean
  showCashierOrder: boolean
  showCashierPay: boolean
  showCustomer: boolean
  showWaiter: boolean
  showOrderType: boolean
  showOrderName: boolean
  showTable: boolean
  customBodyFields: CustomField[]
  footer: string
}

const DEFAULTS: RS = {
  showLogo: true,
  logoStyle: 'normal',
  logoUrl: '',
  showBusinessName: false,
  showOutletName: true,
  showAddress: true,
  showPhone: false,
  showCity: false,
  showProvince: false,
  showCountry: false,
  customHeaderFields: [],
  limitPrint: false,
  customHeader: false,
  customHeaderText: '',
  customHeaderAlign: 'center',
  showOrderNumber: true,
  showOrderTime: true,
  showCashierOrder: true,
  showCashierPay: true,
  showCustomer: true,
  showWaiter: true,
  showOrderType: true,
  showOrderName: true,
  showTable: true,
  customBodyFields: [],
  footer: '',
}

function newField(): CustomField {
  return { id: Math.random().toString(36).slice(2), label: '', value: '', visible: true }
}

// ─── Custom field list ────────────────────────────────────────────────────────

function CustomFieldList({
  fields,
  onChange,
  placeholder,
}: {
  fields: CustomField[]
  onChange: (fields: CustomField[]) => void
  placeholder?: string
}) {
  function update(id: string, patch: Partial<CustomField>) {
    onChange(fields.map((f) => (f.id === id ? { ...f, ...patch } : f)))
  }
  function remove(id: string) {
    onChange(fields.filter((f) => f.id !== id))
  }
  function add() {
    onChange([...fields, newField()])
  }

  return (
    <div className="space-y-1">
      {fields.length > 0 && (
        <div className="hidden sm:grid grid-cols-[16px_1fr_1fr_36px_32px] gap-2 px-1 mb-1">
          <span />
          <span className="text-xs text-muted-foreground">Label</span>
          <span className="text-xs text-muted-foreground">Nilai</span>
          <span className="text-xs text-muted-foreground text-center">Tampil</span>
          <span />
        </div>
      )}

      {fields.map((f) => (
        <div key={f.id} className="grid grid-cols-[16px_1fr_36px_32px] gap-2 items-center sm:grid-cols-[16px_1fr_1fr_36px_32px]">
          <GripVertical className="h-4 w-4 text-muted-foreground/40 row-start-1" />
          <Input
            className="col-start-2 row-start-1 sm:col-start-auto sm:row-start-auto"
            placeholder={placeholder ?? 'Label'}
            value={f.label}
            onChange={(e) => update(f.id, { label: e.target.value })}
          />
          <Input
            className="col-start-2 col-span-3 row-start-2 sm:col-start-auto sm:col-span-1 sm:row-start-auto"
            placeholder="Nilai"
            value={f.value}
            onChange={(e) => update(f.id, { value: e.target.value })}
          />
          <div className="col-start-3 row-start-1 flex justify-center sm:col-start-auto sm:row-start-auto">
            <Switch
              aria-label={`${f.visible ? 'Sembunyikan' : 'Tampilkan'} field ${f.label || 'tanpa nama'}`}
              checked={f.visible}
              onCheckedChange={(v) => update(f.id, { visible: v })}
            />
          </div>
          <Button
            type="button"
            variant="ghost"
            size="icon-sm"
            className="text-muted-foreground hover:text-destructive col-start-4 row-start-1 sm:col-start-auto sm:row-start-auto"
            onClick={() => remove(f.id)}
            aria-label={`Hapus field ${f.label || 'tanpa nama'}`}
          >
            <X className="h-3.5 w-3.5" />
          </Button>
        </div>
      ))}

      <Button
        type="button"
        variant="outline"
        size="sm"
        className="w-full mt-2"
        onClick={add}
      >
        <Plus className="h-3.5 w-3.5 mr-1.5" /> Tambah Field
      </Button>
    </div>
  )
}

// ─── Sub-components ───────────────────────────────────────────────────────────

function SectionHeader({ title, desc }: { title: string; desc?: string }) {
  return (
    <div className="mb-3">
      <p className="font-semibold text-sm">{title}</p>
      {desc && <p className="text-xs text-muted-foreground mt-0.5">{desc}</p>}
    </div>
  )
}

function ToggleRow({
  label,
  checked,
  onChange,
}: {
  label: string
  checked: boolean
  onChange: (v: boolean) => void
}) {
  return (
    <div className="flex items-center justify-between py-2.5 border-b last:border-0">
      <p className="text-sm">{label}</p>
      <Switch aria-label={`${checked ? 'Nonaktifkan' : 'Aktifkan'} ${label}`} checked={checked} onCheckedChange={onChange} />
    </div>
  )
}

// ─── Receipt preview ──────────────────────────────────────────────────────────

const MOCK_SUBTOTAL = 35000

function fmt(n: number) {
  return n.toLocaleString('id-ID')
}

function ReceiptPreview({
  outletName,
  address,
  phone,
  rs,
  taxActive,
  taxName,
  taxPercent,
  taxInclusive,
  serviceChargePct,
}: {
  outletName: string
  address: string | null
  phone: string | null
  rs: RS
  taxActive: boolean
  taxName: string
  taxPercent: number
  taxInclusive: boolean
  serviceChargePct: number
}) {
  const alignClass =
    rs.customHeaderAlign === 'left'
      ? 'text-left'
      : rs.customHeaderAlign === 'right'
      ? 'text-right'
      : 'text-center'

  const visibleHeaderFields = rs.customHeaderFields.filter((f) => f.visible && f.label)
  const visibleBodyFields = rs.customBodyFields.filter((f) => f.visible && f.label)

  const serviceCharge = Math.round(MOCK_SUBTOTAL * serviceChargePct / 100)
  const taxBase = MOCK_SUBTOTAL + serviceCharge
  const taxAmount = taxActive && taxPercent > 0
    ? taxInclusive
      ? Math.round(taxBase - taxBase / (1 + taxPercent / 100))
      : Math.round(taxBase * taxPercent / 100)
    : 0
  const total = taxInclusive
    ? taxBase
    : taxBase + taxAmount

  return (
    <div className="font-mono text-[9px] bg-white border-2 border-dashed border-muted rounded-lg p-3 w-full shadow-sm select-none leading-relaxed max-h-[80vh] overflow-y-auto">
      {rs.showLogo && (
        <div className="flex justify-center mb-1.5">
          <div
            className={cn(
              'bg-muted flex items-center justify-center rounded',
              rs.logoStyle === 'full' ? 'w-full h-8' : 'h-8 w-8 rounded-full'
            )}
          >
            <Store className="h-4 w-4 text-muted-foreground" />
          </div>
        </div>
      )}

      <div className="text-center space-y-0.5 mb-1">
        {rs.showBusinessName && <p className="font-bold text-[10px]">{outletName}</p>}
        {rs.showOutletName && (
          <p className={cn('font-bold text-[10px]', rs.showBusinessName && 'font-normal text-muted-foreground')}>
            {outletName}
          </p>
        )}
        {rs.showAddress && address && <p className="text-muted-foreground">{address}</p>}
        {rs.showPhone && phone && <p className="text-muted-foreground">{phone}</p>}
        {rs.showCity && <p className="text-muted-foreground">Jakarta</p>}
        {rs.showProvince && <p className="text-muted-foreground">DKI Jakarta</p>}
        {rs.showCountry && <p className="text-muted-foreground">Indonesia</p>}
        {visibleHeaderFields.map((f) => (
          <p key={f.id} className="text-muted-foreground">
            {f.label}{f.value ? ` : ${f.value}` : ''}
          </p>
        ))}
      </div>

      {rs.customHeader && rs.customHeaderText && (
        <p className={cn('text-muted-foreground mb-1', alignClass)}>{rs.customHeaderText}</p>
      )}

      <div className="border-t border-dashed my-1.5" />

      <div className="space-y-0.5 mb-1">
        {rs.showOrderNumber && (
          <div className="flex gap-1">
            <span className="w-[72px] shrink-0 text-muted-foreground">No Nota</span>
            <span>: CS/221187/9999</span>
          </div>
        )}
        {rs.showOrderTime && (
          <div className="flex gap-1">
            <span className="w-[72px] shrink-0 text-muted-foreground">Waktu</span>
            <span>: 23/05/26 10:00</span>
          </div>
        )}
        {rs.showCashierOrder && (
          <div className="flex gap-1">
            <span className="w-[72px] shrink-0 text-muted-foreground">Kasir Order</span>
            <span>: Budi</span>
          </div>
        )}
        {rs.showCashierPay && (
          <div className="flex gap-1">
            <span className="w-[72px] shrink-0 text-muted-foreground">Kasir Bayar</span>
            <span>: Budi</span>
          </div>
        )}
        {rs.showCustomer && (
          <div className="flex gap-1">
            <span className="w-[72px] shrink-0 text-muted-foreground">Customer</span>
            <span>: Ahmad</span>
          </div>
        )}
        {rs.showWaiter && (
          <div className="flex gap-1">
            <span className="w-[72px] shrink-0 text-muted-foreground">Dilayani</span>
            <span>: Staff</span>
          </div>
        )}
        {rs.showOrderType && (
          <div className="flex gap-1">
            <span className="w-[72px] shrink-0 text-muted-foreground">Jenis Order</span>
            <span>: Dine-In</span>
          </div>
        )}
        {rs.showOrderName && (
          <div className="flex gap-1">
            <span className="w-[72px] shrink-0 text-muted-foreground">Nama Order</span>
            <span>: Meja VIP</span>
          </div>
        )}
        {rs.showTable && (
          <div className="flex gap-1">
            <span className="w-[72px] shrink-0 text-muted-foreground">Nomor Meja</span>
            <span>: 005</span>
          </div>
        )}
        {visibleBodyFields.map((f) => (
          <div key={f.id} className="flex gap-1">
            <span className="w-[72px] shrink-0 text-muted-foreground truncate">{f.label}</span>
            <span>: {f.value}</span>
          </div>
        ))}
      </div>

      <div className="border-t border-dashed my-1.5" />

      <div className="space-y-0.5 mb-1">
        <div className="flex justify-between">
          <span>Nasi Goreng Special</span>
          <span>25.000</span>
        </div>
        {/* Extra/topping — sinkron dengan cetakan asli (order_item_options),
            agar owner tahu baris ini ikut tercetak di struk (dgn harga) &
            tiket dapur (tanpa harga). */}
        <p className="text-muted-foreground pl-2">+ Extra Telur (+3.000)</p>
        <div className="flex justify-between">
          <span>Es Teh Manis x2</span>
          <span>10.000</span>
        </div>
      </div>

      <div className="border-t border-dashed my-1.5" />

      <div className="space-y-0.5 mb-1">
        <div className="flex justify-between">
          <span>Subtotal 2 Produk</span>
          <span>{fmt(MOCK_SUBTOTAL)}</span>
        </div>
        {serviceChargePct > 0 && (
          <div className="flex justify-between">
            <span>Service Charge {serviceChargePct}%</span>
            <span>{fmt(serviceCharge)}</span>
          </div>
        )}
        {taxActive && taxPercent > 0 && !taxInclusive && (
          <div className="flex justify-between">
            <span>{taxName || 'Pajak'} {taxPercent}%</span>
            <span>{fmt(taxAmount)}</span>
          </div>
        )}
        <div className="flex justify-between font-bold border-t border-dashed pt-1 mt-1">
          <span>Total Tagihan</span>
          <span>{fmt(total)}</span>
        </div>
        <div className="flex justify-between text-muted-foreground">
          <span>Tunai</span>
          <span>{fmt(total + 15000)}</span>
        </div>
        <div className="flex justify-between text-muted-foreground">
          <span>Kembali</span>
          <span>15.000</span>
        </div>
      </div>

      {taxActive && taxPercent > 0 && taxInclusive && (
        <div className="text-center text-muted-foreground mt-1 mb-1 space-y-0.5">
          <div className="border-t border-dashed" />
          <p>Harga Sudah Termasuk {taxName || 'Pajak'}</p>
          <p>Senilai Rp {fmt(taxAmount)}</p>
        </div>
      )}

      {rs.footer && (
        <>
          <div className="border-t border-dashed my-1.5" />
          <p className="text-center text-muted-foreground whitespace-pre-line">{rs.footer}</p>
        </>
      )}

    </div>
  )
}

// ─── Main page ────────────────────────────────────────────────────────────────

export default function ReceiptSettings() {
  const { activeOutlet, activeOutletId } = useOutlet()
  const update = useUpdateOutlet()
  const { toast } = useToast()
  const [rs, setRs] = useState<RS>(DEFAULTS)
  const [uploadingLogo, setUploadingLogo] = useState(false)
  const logoInputRef = useRef<HTMLInputElement>(null)
  const pendingLogoUrlsRef = useRef(new Set<string>())

  // Bersihkan unggahan sementara ketika pindah outlet atau meninggalkan halaman.
  // Logo yang sudah tersimpan tidak pernah masuk ke set ini.
  useEffect(() => {
    const pendingUrls = pendingLogoUrlsRef.current
    return () => {
      for (const url of Array.from(pendingUrls)) {
        pendingUrls.delete(url)
        void removeImageAsset(url).catch(() => undefined)
      }
    }
  }, [activeOutletId])

  // Sinkronisasi pengaturan outlet (context) → state form lokal yang editable
  useEffect(() => {
    if (!activeOutlet) return
    const s = activeOutlet.settings
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setRs({
      showLogo: s?.receipt_show_logo ?? true,
      logoStyle: s?.receipt_logo_style ?? 'normal',
      logoUrl: s?.receipt_logo_url ?? '',
      showBusinessName: s?.receipt_show_business_name ?? false,
      showOutletName: s?.receipt_show_outlet_name ?? true,
      showAddress: s?.receipt_show_address ?? true,
      showPhone: s?.receipt_show_phone ?? false,
      showCity: s?.receipt_show_city ?? false,
      showProvince: s?.receipt_show_province ?? false,
      showCountry: s?.receipt_show_country ?? false,
      customHeaderFields: s?.receipt_custom_header_fields ?? [],
      limitPrint: s?.receipt_limit_print ?? false,
      customHeader: s?.receipt_custom_header ?? false,
      customHeaderText: s?.receipt_custom_header_text ?? '',
      customHeaderAlign: s?.receipt_custom_header_align ?? 'center',
      showOrderNumber: s?.receipt_show_order_number ?? true,
      showOrderTime: s?.receipt_show_order_time ?? true,
      showCashierOrder: s?.receipt_show_cashier ?? true,
      showCashierPay: s?.receipt_show_cashier_pay ?? true,
      showCustomer: s?.receipt_show_customer ?? true,
      showWaiter: s?.receipt_show_waiter ?? true,
      showOrderType: s?.receipt_show_order_type ?? true,
      showOrderName: s?.receipt_show_order_name ?? true,
      showTable: s?.receipt_show_table ?? true,
      customBodyFields: s?.receipt_custom_body_fields ?? [],
      footer: s?.receipt_footer ?? '',
    })
  }, [activeOutlet])

  function set<K extends keyof RS>(key: K, value: RS[K]) {
    setRs((prev) => ({ ...prev, [key]: value }))
  }

  // Hapus file logo di Storage (best-effort — kegagalan tidak menghentikan alur).
  async function removeLogoFile(url: string | null | undefined) {
    try {
      await removeImageAsset(url)
    } catch {
      /* biarkan; file yatim tertangkap upload berikutnya */
    }
  }

  async function removePendingLogoFile(url: string | null | undefined) {
    if (!url || !pendingLogoUrlsRef.current.has(url)) return
    try {
      await removeImageAsset(url)
      pendingLogoUrlsRef.current.delete(url)
    } catch {
      // Tetap tandai sebagai pending agar cleanup halaman dapat mencoba lagi.
    }
  }

  // Unggah logo struk ke Cloudflare R2 melalui Worker terautentikasi.
  async function handleLogoUpload(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (!file || !activeOutletId) return
    if (!file.type.startsWith('image/')) {
      toast({ title: 'File harus gambar', variant: 'destructive' })
      return
    }
    if (file.size > 5 * 1024 * 1024) {
      toast({ title: 'Ukuran logo maksimal 5 MB', variant: 'destructive' })
      return
    }
    setUploadingLogo(true)
    try {
      const uploadedUrl = await uploadImageAsset(file, activeOutletId, 'logos')
      pendingLogoUrlsRef.current.add(uploadedUrl)
      // Setiap unggah memakai nama file baru (timestamp). Tanpa pembersihan,
      // file lama menumpuk selamanya → jatah Storage free plan (1GB) tergerus
      // pelan-pelan. Hapus unggahan sebelumnya yang BELUM tersimpan.
      if (rs.logoUrl) void removePendingLogoFile(rs.logoUrl)
      set('logoUrl', uploadedUrl)
      toast({ title: 'Logo diunggah', description: 'Klik Simpan untuk menerapkan.' })
    } catch (err) {
      toast({ title: 'Gagal unggah logo', description: humanizeError(err), variant: 'destructive' })
    } finally {
      setUploadingLogo(false)
      if (logoInputRef.current) logoInputRef.current.value = ''
    }
  }

  async function handleSave() {
    if (!activeOutletId || !activeOutlet) return
    // Logo tersimpan sebelumnya diganti/dihapus → bersihkan file lamanya
    // SETELAH settings baru sukses tersimpan.
    const prevLogoUrl = activeOutlet.settings?.receipt_logo_url ?? null
    try {
      await update.mutateAsync({
        id: activeOutletId,
        updates: {
          settings: {
            ...activeOutlet.settings,
            receipt_show_logo: rs.showLogo,
            receipt_logo_style: rs.logoStyle,
            receipt_logo_url: rs.logoUrl || null,
            receipt_show_business_name: rs.showBusinessName,
            receipt_show_outlet_name: rs.showOutletName,
            receipt_show_address: rs.showAddress,
            receipt_show_phone: rs.showPhone,
            receipt_show_city: rs.showCity,
            receipt_show_province: rs.showProvince,
            receipt_show_country: rs.showCountry,
            receipt_custom_header_fields: rs.customHeaderFields,
            receipt_limit_print: rs.limitPrint,
            receipt_custom_header: rs.customHeader,
            receipt_custom_header_text: rs.customHeaderText,
            receipt_custom_header_align: rs.customHeaderAlign,
            receipt_show_order_number: rs.showOrderNumber,
            receipt_show_order_time: rs.showOrderTime,
            receipt_show_cashier: rs.showCashierOrder,
            receipt_show_cashier_pay: rs.showCashierPay,
            receipt_show_customer: rs.showCustomer,
            receipt_show_waiter: rs.showWaiter,
            receipt_show_order_type: rs.showOrderType,
            receipt_show_order_name: rs.showOrderName,
            receipt_show_table: rs.showTable,
            receipt_custom_body_fields: rs.customBodyFields,
            receipt_footer: rs.footer,
          },
        },
      })
      // Mulai titik ini URL baru sudah direferensikan database dan tidak boleh
      // ikut cleanup sebagai unggahan sementara.
      if (rs.logoUrl) pendingLogoUrlsRef.current.delete(rs.logoUrl)
      if (prevLogoUrl && prevLogoUrl !== (rs.logoUrl || null)) {
        void removeLogoFile(prevLogoUrl)
      }
      toast({ title: 'Tersimpan', description: 'Pengaturan struk berhasil diperbarui.' })
    } catch (error) {
      toast({
        title: 'Gagal menyimpan pengaturan struk',
        description: humanizeError(error),
        variant: 'destructive',
      })
    }
  }

  function handleRemoveLogo() {
    if (rs.logoUrl) void removePendingLogoFile(rs.logoUrl)
    set('logoUrl', '')
  }

  if (!activeOutletId || !activeOutlet) return <NoOutlet />

  return (
    <div className="space-y-4">
      <h1 className="font-semibold text-lg">Pengaturan Struk</h1>

      <div className="rounded-lg border bg-muted/40 px-4 py-3 text-sm">
        Pengaturan struk untuk outlet <strong>{activeOutlet.name}</strong>.
        Ganti outlet melalui pemilih di bagian atas halaman.
      </div>

      {/* Batasan Cetak */}
      <div className="rounded-xl border bg-white shadow-sm p-5">
        <div className="flex items-center justify-between">
          <div>
            <p className="font-semibold text-sm">Batasan Jumlah Cetak Struk</p>
            <p className="text-xs text-muted-foreground mt-0.5">
              Batasi jumlah pemakaian cetakan struk yang akan digunakan di setiap transaksi
            </p>
          </div>
          <Switch aria-label="Batasi jumlah cetak struk" checked={rs.limitPrint} onCheckedChange={(v) => set('limitPrint', v)} />
        </div>
      </div>

      {/* Tabs + Preview */}
      <div className="grid grid-cols-1 lg:grid-cols-[1fr_300px] gap-4 items-start">
        <div className="rounded-xl border bg-white shadow-sm overflow-hidden">
          <div className="px-5 pt-5">
            <p className="font-semibold text-sm mb-4">Atur Tampilan Struk</p>
          </div>

          <Tabs defaultValue="header">
            <div className="px-5">
              <TabsList className="w-full justify-start rounded-none border-b bg-transparent p-0 h-auto gap-0">
                {(
                  [
                    { val: 'header', label: 'Header' },
                    { val: 'body', label: 'Body' },
                    { val: 'footer', label: 'Footer' },
                  ] as const
                ).map(({ val, label }) => (
                  <TabsTrigger
                    key={val}
                    value={val}
                    className="rounded-none border-b-2 border-transparent data-[state=active]:border-primary data-[state=active]:bg-transparent data-[state=active]:shadow-none px-5 py-2.5 text-sm"
                  >
                    {label}
                  </TabsTrigger>
                ))}
              </TabsList>
            </div>

            {/* ── HEADER TAB ── */}
            <TabsContent value="header" className="p-5 space-y-1 mt-0">
              <SectionHeader
                title="Informasi Outlet"
                desc="Atur informasi yang akan tampil pada bagian teratas struk"
              />

              {/* Logo */}
              <div className="border-b py-2.5">
                <div className="flex items-center justify-between">
                  <p className="text-sm">Logo</p>
                  <Switch aria-label="Tampilkan logo pada struk" checked={rs.showLogo} onCheckedChange={(v) => set('showLogo', v)} />
                </div>
                {rs.showLogo && (
                  <div className="mt-2 pl-1 space-y-3">
                    {/* Unggah gambar logo */}
                    <div className="flex items-center gap-3">
                      {rs.logoUrl ? (
                        <img
                          src={rs.logoUrl}
                          alt="Logo struk"
                          className="h-12 w-12 rounded border bg-white object-contain"
                        />
                      ) : (
                        <div className="flex h-12 w-12 items-center justify-center rounded border bg-muted text-muted-foreground">
                          <Store className="h-5 w-5" />
                        </div>
                      )}
                      <input
                        ref={logoInputRef}
                        type="file"
                        accept="image/*"
                        className="hidden"
                        onChange={handleLogoUpload}
                      />
                      <Button
                        type="button"
                        variant="outline"
                        size="sm"
                        disabled={uploadingLogo}
                        onClick={() => logoInputRef.current?.click()}
                      >
                        {uploadingLogo ? 'Mengunggah…' : rs.logoUrl ? 'Ganti Logo' : 'Unggah Logo'}
                      </Button>
                      {rs.logoUrl && (
                        <Button
                          type="button"
                          variant="ghost"
                          size="sm"
                          className="text-destructive"
                          onClick={handleRemoveLogo}
                        >
                          Hapus
                        </Button>
                      )}
                    </div>
                    <p className="text-[11px] text-muted-foreground">
                      Untuk cetak tajam, pakai logo hitam-putih / kontras tinggi. Klik Simpan setelah mengunggah.
                    </p>
                    {/* Ukuran logo pada struk */}
                    <div className="flex items-center gap-4">
                      <p className="text-xs text-muted-foreground shrink-0">Ukuran</p>
                      <div className="flex items-center gap-4">
                        {(['normal', 'full'] as const).map((style) => (
                          <button
                            type="button"
                            key={style}
                            aria-pressed={rs.logoStyle === style}
                            className="flex items-center gap-1.5 text-xs"
                            onClick={() => set('logoStyle', style)}
                          >
                            <span
                              className={cn(
                                'flex h-3.5 w-3.5 items-center justify-center rounded-full border-2',
                                rs.logoStyle === style ? 'border-primary' : 'border-muted-foreground/40'
                              )}
                            >
                              {rs.logoStyle === style && (
                                <span className="h-1.5 w-1.5 rounded-full bg-primary" />
                              )}
                            </span>
                            {style === 'normal' ? 'Normal' : 'Tampilan Penuh'}
                          </button>
                        ))}
                      </div>
                    </div>
                  </div>
                )}
              </div>

              <ToggleRow label="Nama Usaha" checked={rs.showBusinessName} onChange={(v) => set('showBusinessName', v)} />
              <ToggleRow label="Nama Outlet" checked={rs.showOutletName} onChange={(v) => set('showOutletName', v)} />
              <ToggleRow label="Alamat" checked={rs.showAddress} onChange={(v) => set('showAddress', v)} />
              <ToggleRow label="No Telepon" checked={rs.showPhone} onChange={(v) => set('showPhone', v)} />
              <ToggleRow label="Kota" checked={rs.showCity} onChange={(v) => set('showCity', v)} />
              <ToggleRow label="Provinsi" checked={rs.showProvince} onChange={(v) => set('showProvince', v)} />
              <ToggleRow label="Negara" checked={rs.showCountry} onChange={(v) => set('showCountry', v)} />

              {/* Custom header fields */}
              <div className="pt-4">
                <p className="text-sm font-medium mb-1">Field Kustom</p>
                <p className="text-xs text-muted-foreground mb-3">
                  Tambahkan informasi tambahan di bagian header struk
                </p>
                <CustomFieldList
                  fields={rs.customHeaderFields}
                  onChange={(f) => set('customHeaderFields', f)}
                  placeholder="Contoh: NPWPD"
                />
              </div>
            </TabsContent>

            {/* ── BODY TAB ── */}
            <TabsContent value="body" className="p-5 space-y-1 mt-0">
              {/* Custom header text */}
              <div className="border-b pb-4 mb-3">
                <div className="flex items-center justify-between mb-3">
                  <p className="text-sm font-medium">Teks Header Kustom</p>
                  <Switch aria-label="Aktifkan teks header khusus" checked={rs.customHeader} onCheckedChange={(v) => set('customHeader', v)} />
                </div>
                {rs.customHeader && (
                  <div className="space-y-2">
                    <div className="flex items-center justify-between">
                      <p className="text-xs text-muted-foreground">Perataan Teks</p>
                      <div className="flex gap-1">
                        {(
                          [
                            { val: 'left', Icon: AlignLeft },
                            { val: 'center', Icon: AlignCenter },
                            { val: 'right', Icon: AlignRight },
                          ] as const
                        ).map(({ val, Icon }) => (
                          <Button
                            key={val}
                            type="button"
                            variant={rs.customHeaderAlign === val ? 'default' : 'outline'}
                            size="icon-sm"
                            onClick={() => set('customHeaderAlign', val)}
                            aria-label={`Rata ${val === 'left' ? 'kiri' : val === 'center' ? 'tengah' : 'kanan'}`}
                            aria-pressed={rs.customHeaderAlign === val}
                          >
                            <Icon className="h-3.5 w-3.5" />
                          </Button>
                        ))}
                      </div>
                    </div>
                    <div className="relative">
                      <Textarea
                        value={rs.customHeaderText}
                        onChange={(e) => set('customHeaderText', e.target.value)}
                        placeholder="Contoh: NPWPD : 20000098192001202"
                        maxLength={500}
                        rows={3}
                        className={cn(
                          'resize-none pr-16',
                          rs.customHeaderAlign === 'center' && 'text-center',
                          rs.customHeaderAlign === 'right' && 'text-right'
                        )}
                      />
                      <span className="absolute bottom-2 right-2 text-[10px] text-muted-foreground pointer-events-none">
                        {rs.customHeaderText.length}/500
                      </span>
                    </div>
                  </div>
                )}
              </div>

              <SectionHeader title="Informasi Transaksi" />
              <ToggleRow label="Nomor Nota" checked={rs.showOrderNumber} onChange={(v) => set('showOrderNumber', v)} />
              <ToggleRow label="Waktu Transaksi" checked={rs.showOrderTime} onChange={(v) => set('showOrderTime', v)} />
              <ToggleRow label="Nama Kasir Order" checked={rs.showCashierOrder} onChange={(v) => set('showCashierOrder', v)} />
              <ToggleRow label="Nama Kasir Bayar" checked={rs.showCashierPay} onChange={(v) => set('showCashierPay', v)} />
              <ToggleRow label="Customer" checked={rs.showCustomer} onChange={(v) => set('showCustomer', v)} />
              <ToggleRow label="Dilayani oleh / Waiters" checked={rs.showWaiter} onChange={(v) => set('showWaiter', v)} />
              <ToggleRow label="Jenis Order" checked={rs.showOrderType} onChange={(v) => set('showOrderType', v)} />
              <ToggleRow label="Nama Order" checked={rs.showOrderName} onChange={(v) => set('showOrderName', v)} />
              <ToggleRow label="Nomor Meja" checked={rs.showTable} onChange={(v) => set('showTable', v)} />

              {/* Custom body fields */}
              <div className="pt-4">
                <p className="text-sm font-medium mb-1">Field Kustom</p>
                <p className="text-xs text-muted-foreground mb-3">
                  Tambahkan informasi tambahan di bagian body struk
                </p>
                <CustomFieldList
                  fields={rs.customBodyFields}
                  onChange={(f) => set('customBodyFields', f)}
                  placeholder="Contoh: No. Antrian"
                />
              </div>
            </TabsContent>

            {/* ── FOOTER TAB ── */}
            <TabsContent value="footer" className="p-5 mt-0">
              <SectionHeader title="Teks Footer" desc="Tampil di bagian bawah struk. Bisa multi-baris." />
              <Textarea
                value={rs.footer}
                onChange={(e) => set('footer', e.target.value)}
                placeholder="Contoh: Terima kasih telah berkunjung!"
                rows={4}
                className="resize-none"
              />
            </TabsContent>
          </Tabs>
        </div>

        {/* Receipt preview */}
        <div className="sticky top-4 space-y-2">
          <p className="text-xs text-muted-foreground font-medium">Preview Struk</p>
          <ReceiptPreview
            outletName={activeOutlet.name}
            address={activeOutlet.address}
            phone={activeOutlet.phone}
            rs={rs}
            taxActive={activeOutlet.settings?.tax_active ?? true}
            taxName={activeOutlet.settings?.tax_name ?? 'PPN'}
            taxPercent={activeOutlet.settings?.tax_percent ?? 0}
            taxInclusive={activeOutlet.settings?.tax_inclusive ?? false}
            serviceChargePct={activeOutlet.settings?.service_charge_percent ?? 0}
          />
        </div>
      </div>

      <div className="flex justify-end pb-4">
        <Button onClick={handleSave} disabled={update.isPending}>
          {update.isPending ? 'Menyimpan...' : 'Simpan Perubahan'}
        </Button>
      </div>
    </div>
  )
}
