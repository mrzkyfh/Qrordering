import { useEffect, useState } from 'react'
import type { ReactNode } from 'react'
import { Building2, PackageOpen, Percent, Printer } from 'lucide-react'
import { useOutlet } from '@/hooks/useOutlet'
import { useUpdateOutlet } from '@/hooks/queries/useOutlets'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import { Switch } from '@/components/ui/switch'
import { useToast } from '@/hooks/use-toast'
import { humanizeError } from '@/lib/errorMessage'

type FormState = {
  name: string; address: string; timezone: string; currency: string
  tax: number; service: number; taxActive: boolean; serviceActive: boolean; rounding: number
  paper: '58mm' | '80mm'; autoPrint: boolean; footer: string
  session: number; lowStock: number; autoClose: boolean
}
const initial: FormState = { name: '', address: '', timezone: 'Asia/Jakarta', currency: 'IDR', tax: 0, service: 0, taxActive: true, serviceActive: true, rounding: 0, paper: '80mm', autoPrint: false, footer: '', session: 120, lowStock: 5, autoClose: true }

export default function Settings() {
  const { activeOutlet, activeOutletId } = useOutlet()
  const update = useUpdateOutlet()
  const { toast } = useToast()
  const [form, setForm] = useState<FormState>(initial)
  const set = <K extends keyof FormState>(key: K, value: FormState[K]) => setForm((old) => ({ ...old, [key]: value }))

  useEffect(() => {
    if (!activeOutlet) return
    const s = activeOutlet.settings
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setForm({ name: activeOutlet.name, address: activeOutlet.address ?? '', timezone: s.timezone ?? 'Asia/Jakarta', currency: s.currency ?? 'IDR', tax: s.tax_percent ?? 0, service: s.service_charge_percent ?? 0, taxActive: s.tax_active ?? true, serviceActive: (s.service_charge_percent ?? 0) > 0, rounding: s.rounding ?? 0, paper: s.paper_size ?? '80mm', autoPrint: s.auto_print_receipt ?? false, footer: s.receipt_footer ?? '', session: s.table_session_minutes ?? 120, lowStock: s.default_low_stock_threshold ?? 5, autoClose: s.auto_close_out_of_stock ?? true })
  }, [activeOutlet])

  async function save() {
    if (!activeOutlet || !activeOutletId || form.name.trim().length < 2) return
    try {
      await update.mutateAsync({ id: activeOutletId, updates: { name: form.name.trim(), address: form.address.trim() || null, settings: { ...activeOutlet.settings, timezone: form.timezone, currency: form.currency, tax_percent: form.taxActive ? form.tax : 0, service_charge_percent: form.serviceActive ? form.service : 0, tax_active: form.taxActive, rounding: form.rounding, paper_size: form.paper, auto_print_receipt: form.autoPrint, receipt_footer: form.footer, table_session_minutes: form.session, default_low_stock_threshold: form.lowStock, auto_close_out_of_stock: form.autoClose } } })
      toast({ title: 'Pengaturan outlet disimpan' })
    } catch (error) { toast({ title: 'Gagal menyimpan', description: humanizeError(error), variant: 'destructive' }) }
  }

  if (!activeOutletId) return <NoOutlet />
  const cards = [
    { title: 'Profil outlet', icon: Building2, body: <div className="grid gap-4 sm:grid-cols-2"><Field label="Nama outlet"><Input value={form.name} onChange={(e) => set('name', e.target.value)} /></Field><Field label="Mata uang"><Input value={form.currency} readOnly /></Field><Field label="Alamat" wide><Textarea value={form.address} onChange={(e) => set('address', e.target.value)} /></Field><Field label="Zona waktu"><select className="w-full rounded-xl border bg-white px-3" value={form.timezone} onChange={(e) => set('timezone', e.target.value)}><option value="Asia/Jakarta">Asia/Jakarta (WIB)</option><option value="Asia/Makassar">Asia/Makassar (WITA)</option><option value="Asia/Jayapura">Asia/Jayapura (WIT)</option></select></Field></div> },
    { title: 'Pajak dan biaya layanan', icon: Percent, body: <div className="space-y-4"><Toggle label="Aktifkan pajak" checked={form.taxActive} onChange={(v) => set('taxActive', v)}><Input type="number" min={0} max={100} value={form.tax} onChange={(e) => set('tax', Number(e.target.value))} aria-label="Persentase pajak" /></Toggle><Toggle label="Aktifkan biaya layanan" checked={form.serviceActive} onChange={(v) => set('serviceActive', v)}><Input type="number" min={0} max={100} value={form.service} onChange={(e) => set('service', Number(e.target.value))} aria-label="Persentase biaya layanan" /></Toggle><Field label="Pembulatan nominal"><Input type="number" min={0} step={100} value={form.rounding} onChange={(e) => set('rounding', Number(e.target.value))} /></Field></div> },
    { title: 'Cetak struk', icon: Printer, body: <div className="space-y-4"><Field label="Ukuran kertas"><select className="w-full rounded-xl border bg-white px-3" value={form.paper} onChange={(e) => set('paper', e.target.value as FormState['paper'])}><option value="58mm">58 mm</option><option value="80mm">80 mm</option></select></Field><Toggle label="Cetak otomatis setelah pembayaran" checked={form.autoPrint} onChange={(v) => set('autoPrint', v)} /><Field label="Teks bawah struk"><Textarea value={form.footer} onChange={(e) => set('footer', e.target.value)} placeholder="Terima kasih telah berkunjung" /></Field></div> },
    { title: 'Sesi meja dan stok', icon: PackageOpen, body: <div className="space-y-4"><Field label="Masa berlaku sesi meja (menit)"><Input type="number" min={15} value={form.session} onChange={(e) => set('session', Number(e.target.value))} /></Field><Field label="Batas stok rendah bawaan"><Input type="number" min={0} value={form.lowStock} onChange={(e) => set('lowStock', Number(e.target.value))} /></Field><Toggle label="Tutup produk otomatis saat stok 0" checked={form.autoClose} onChange={(v) => set('autoClose', v)} /></div> },
  ]
  return <div className="space-y-6"><PageHeader title="Pengaturan" subtitle="Kelola profil outlet, pajak, struk, sesi meja, dan kebijakan stok."><Button onClick={save} disabled={update.isPending}>{update.isPending ? 'Menyimpan...' : 'Simpan perubahan'}</Button></PageHeader><div className="grid gap-5 xl:grid-cols-2">{cards.map(({ title, icon: Icon, body }) => <section key={title} className="admin-card p-6"><div className="mb-5 flex items-center gap-3"><span className="rounded-xl bg-[#FDECEC] p-2.5"><Icon className="h-5 w-5 text-[#C62828]" /></span><h2 className="font-semibold">{title}</h2></div>{body}</section>)}</div></div>
}

function Field({ label, children, wide = false }: { label: string; children: ReactNode; wide?: boolean }) { return <label className={wide ? 'block sm:col-span-2' : 'block'}><span className="mb-1.5 block text-sm font-medium">{label}</span>{children}</label> }
function Toggle({ label, checked, onChange, children }: { label: string; checked: boolean; onChange: (value: boolean) => void; children?: ReactNode }) { return <div className="flex min-h-16 items-center justify-between gap-4 rounded-xl border p-4"><div className="flex-1"><p className="text-sm font-medium">{label}</p>{children && <div className="mt-2 max-w-36">{children}</div>}</div><Switch checked={checked} onCheckedChange={onChange} aria-label={label} /></div> }
