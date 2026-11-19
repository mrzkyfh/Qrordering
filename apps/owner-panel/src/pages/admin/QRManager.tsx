import { useState } from 'react'
import { Link } from 'react-router'
import QRCode from 'qrcode'
import { AlertCircle, QrCode, RefreshCw, Download } from 'lucide-react'
import { useOutlet } from '@/hooks/useOutlet'
import { useTables } from '@/hooks/queries/useOutlets'
import { useRealtimeTables } from '@/hooks/useRealtimeOrders'
import { supabase } from '@/lib/supabase'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from '@/components/ui/alert-dialog'
import { useToast } from '@/hooks/use-toast'
import { useQueryClient } from '@tanstack/react-query'
import { humanizeError } from '@/lib/errorMessage'
import { cn } from '@/lib/utils'
import type { RestaurantTable } from '@/types/database'
import logo from '@/assets/mejaku-icon.svg'

function resolveMenuBaseUrl(): string {
  const configured = (import.meta.env.VITE_MENU_BASE_URL as string | undefined)?.trim()
  if (configured) return configured

  // Workers dalam akun yang sama memakai suffix workers.dev yang sama. Dengan
  // ini QR tidak memerlukan custom domain atau hardcode subdomain akun.
  const hostname = window.location.hostname
  if (hostname.startsWith('qrordering.') && hostname.endsWith('.workers.dev')) {
    return `${window.location.protocol}//qrordering-menu.${hostname.slice('qrordering.'.length)}`
  }

  throw new Error('Alamat menu pelanggan belum dikonfigurasi.')
}

// Escape nilai dinamis agar tidak jadi DOM XSS saat ditulis ke window cetak.
function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!))
}

interface QRBranding {
  businessName: string
  outletName: string
  address: string
  phone: string
  logoUrl: string
}

function tableLabel(tableNumber: string): string {
  const value = tableNumber.trim()
  if (!value) return 'Meja tanpa nomor'
  return /^meja\b/i.test(value) ? value : `Meja ${value}`
}

function buildMenuUrl(token: string): string {
  const url = new URL(resolveMenuBaseUrl())
  const isLocal = url.hostname === 'localhost' || url.hostname === '127.0.0.1'
  if (!['http:', 'https:'].includes(url.protocol) || (import.meta.env.PROD && !isLocal && url.protocol !== 'https:')) {
    throw new Error('Alamat customer menu harus menggunakan HTTPS.')
  }
  url.searchParams.set('token', token)
  return url.toString()
}

function safeImageUrl(url: string): string {
  return /^(https?:\/\/|data:image\/|\/)/i.test(url) ? escapeHtml(url) : ''
}

function isQrPngDataUrl(value: string): boolean {
  return /^data:image\/png;base64,[a-z0-9+/=\s]+$/i.test(value)
}

function hasUsableQR(table: RestaurantTable): boolean {
  return Boolean(table.qr_token?.trim() && table.qr_code_url && isQrPngDataUrl(table.qr_code_url))
}

function hasAnyQRData(table: RestaurantTable): boolean {
  return Boolean(table.qr_token?.trim() || table.qr_code_url?.trim())
}

function formatGeneratedAt(value: string | null): string {
  if (!value) return '—'
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? 'Data tanggal tidak valid' : date.toLocaleDateString('id-ID')
}

function loadImage(src: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const image = new Image()
    if (/^https?:\/\//i.test(src)) image.crossOrigin = 'anonymous'
    image.onload = () => resolve(image)
    image.onerror = () => reject(new Error('Gambar tidak dapat dimuat'))
    image.src = src
  })
}

async function downloadQRPoster(dataUrl: string, table: RestaurantTable, branding: QRBranding) {
  if (!isQrPngDataUrl(dataUrl)) throw new Error('Data QR tidak valid. Buat ulang QR Code meja ini.')
  const canvas = document.createElement('canvas')
  // A5 portrait pada 300 DPI agar mudah dipasang tegak di meja/dinding.
  canvas.width = 1748
  canvas.height = 2480
  const ctx = canvas.getContext('2d')
  if (!ctx) throw new Error('Canvas tidak tersedia')

  const ink = '#20242a'
  const muted = '#667085'
  const primary = '#0f766e'
  ctx.fillStyle = '#ffffff'
  ctx.fillRect(0, 0, canvas.width, canvas.height)
  ctx.fillStyle = primary
  ctx.fillRect(0, 0, canvas.width, 405)

  const logoImage = await loadImage(branding.logoUrl).catch(() => loadImage(logo))
  ctx.fillStyle = '#ffffff'
  ctx.beginPath()
  ctx.arc(420, 205, 108, 0, Math.PI * 2)
  ctx.fill()
  ctx.save()
  ctx.beginPath()
  ctx.arc(420, 205, 92, 0, Math.PI * 2)
  ctx.clip()
  ctx.drawImage(logoImage, 328, 113, 184, 184)
  ctx.restore()
  ctx.textAlign = 'left'
  ctx.fillStyle = '#ffffff'
  ctx.font = '800 82px Arial, sans-serif'
  ctx.fillText(branding.businessName, 570, 205, 1020)
  ctx.font = '700 38px Arial, sans-serif'
  ctx.fillText('Pesan langsung dari meja Anda', 570, 280, 1000)

  ctx.textAlign = 'center'
  ctx.fillStyle = ink
  ctx.font = '800 98px Arial, sans-serif'
  ctx.fillText('Scan untuk memesan', 874, 610, 1500)
  ctx.fillStyle = muted
  ctx.font = '400 43px Arial, sans-serif'
  ctx.fillText('Arahkan kamera ponsel ke kode di bawah', 874, 700, 1400)

  const qrImage = await loadImage(dataUrl)
  const shellX = 454, shellY = 780, shellSize = 840
  ctx.fillStyle = '#ffffff'
  ctx.beginPath()
  ctx.roundRect(shellX, shellY, shellSize, shellSize, 80)
  ctx.fill()
  ctx.strokeStyle = primary
  ctx.lineWidth = 14
  ctx.stroke()
  ctx.strokeStyle = '#d1d5db'
  ctx.lineWidth = 6
  ctx.setLineDash([18, 14])
  ctx.beginPath()
  ctx.roundRect(shellX + 48, shellY + 48, shellSize - 96, shellSize - 96, 48)
  ctx.stroke()
  ctx.setLineDash([])
  ctx.drawImage(qrImage, shellX + 92, shellY + 92, shellSize - 184, shellSize - 184)

  ctx.fillStyle = ink
  ctx.beginPath()
  ctx.roundRect(624, 1698, 500, 176, 88)
  ctx.fill()
  const tableNumber = table.table_number.replace(/^meja\s*/i, '').trim()
  ctx.fillStyle = '#ffffff'
  ctx.font = '800 42px Arial, sans-serif'
  ctx.fillText('MEJA', 758, 1807)
  ctx.font = '800 104px Arial, sans-serif'
  ctx.fillText(tableNumber || '-', 976, 1837)

  const steps = [
    ['1', 'Scan kode QR'],
    ['2', 'Pilih menu dan pesan'],
    ['3', 'Bayar QRIS atau ke kasir'],
  ] as const
  steps.forEach(([number, label], index) => {
    const x = 350 + index * 524
    ctx.fillStyle = primary
    ctx.beginPath()
    ctx.arc(x, 2110, 58, 0, Math.PI * 2)
    ctx.fill()
    ctx.fillStyle = '#ffffff'
    ctx.font = '800 40px Arial, sans-serif'
    ctx.fillText(number, x, 2125)
    ctx.fillStyle = '#344054'
    ctx.font = '700 35px Arial, sans-serif'
    if (index === 2) {
      ctx.fillText('Bayar QRIS atau ke', x, 2240, 440)
      ctx.fillText('kasir', x, 2285, 440)
    } else ctx.fillText(label, x, 2240, 440)
  })
  ctx.fillStyle = muted
  ctx.font = '400 31px Arial, sans-serif'
  ctx.fillText('Tanpa unduh aplikasi. Pesanan langsung diteruskan ke dapur setelah pembayaran', 874, 2392, 1550)
  ctx.fillText('dikonfirmasi.', 874, 2434, 1500)

  const a = document.createElement('a')
  a.href = canvas.toDataURL('image/png', 1)
  a.download = `qr-${tableLabel(table.table_number).toLowerCase().replace(/\s+/g, '-')}.png`
  a.click()
}

function printQR(dataUrl: string, table: RestaurantTable, branding: QRBranding): boolean {
  if (!isQrPngDataUrl(dataUrl)) throw new Error('Data QR tidak valid. Buat ulang QR Code meja ini.')
  const win = window.open('', '_blank')
  if (!win) return false
  win.opener = null
  // dataUrl sudah dibatasi ke PNG base64; seluruh data outlet di-escape.
  const safeQr = escapeHtml(dataUrl)
  const safeTable = escapeHtml(tableLabel(table.table_number))
  const safeBusiness = escapeHtml(branding.businessName)
  const safeLogo = safeImageUrl(branding.logoUrl)
  const safeTableNumber = escapeHtml(table.table_number.replace(/^meja\s*/i, '').trim() || '-')
  win.document.write(`
    <!doctype html>
    <html lang="id">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width,initial-scale=1" />
        <title>QR Code ${safeTable}</title>
        <style>
          @page { size: A5 portrait; margin: 0; }
          * { box-sizing: border-box; }
          html, body { margin: 0; min-height: 100%; }
          body {
            display: grid;
            place-items: center;
            background: #d9d9d9; color: #20242a;
            font-family: Arial, Helvetica, sans-serif;
            -webkit-print-color-adjust: exact;
            print-color-adjust: exact;
          }
          .poster {
            position: relative;
            width: 148mm;
            height: 210mm;
            overflow: hidden;
            background: #fff;
          }
          .top { height: 38mm; display:flex; align-items:center; justify-content:center; background:#0f766e; color:#fff; }
          .brand { display: flex; align-items: center; gap: 4mm; }
          .brand-logo {
            width: 18mm; height: 18mm; padding:1.5mm; border-radius: 50%; object-fit: cover; background:#fff;
          }
          .brand-copy { text-align: left; }
          .business { margin: 0; font-size: 7mm; line-height: 1; font-weight: 800; }
          .outlet { margin-top: 1.4mm; font-size: 3.5mm; font-weight: 700; }
          .scan-heading { margin-top: 11mm; text-align: center; font-size: 10mm; line-height: 1; font-weight: 800; }
          .scan-subtitle { margin-top:3mm; text-align:center; color:#667085; font-size:4mm; }
          .main { display: flex; flex-direction: column; align-items: center; gap: 5mm; margin-top: 6mm; }
          .qr-shell {
            width: 72mm; height: 72mm; margin: auto; padding: 6mm; background: #fff;
            border: 1.1mm solid #0f766e; border-radius:7mm; outline: .5mm dashed #d1d5db; outline-offset: -5mm;
          }
          .qr { display: block; width: 60mm; height: 60mm; margin: auto; }
          .table-panel { display:flex; align-items:center; justify-content:center; gap:3mm; min-width:43mm; height:16mm; padding:0 7mm; border-radius:9mm; color:#fff; background:#20242a; }
          .table-word { font-size:3.7mm; font-weight:800; letter-spacing:.55mm; }
          .table-number { margin:0; font-size:9mm; line-height:1; font-weight:800; }
          .steps { display:grid; grid-template-columns:repeat(3,1fr); gap:3mm; width:100%; padding:0 8mm; margin-top:3mm; text-align:center; }
          .step-no { display:grid; place-items:center; width:10mm; height:10mm; margin:auto; border-radius:50%; color:#fff; background:#0f766e; font-size:4mm; font-weight:800; }
          .step-label { margin-top:3mm; color:#344054; font-size:3.2mm; line-height:1.25; font-weight:700; }
          .footer { margin:5mm 7mm 0; text-align:center; color:#667085; font-size:3mm; line-height:1.35; }
          @media print {
            body { background: #fff; }
            .poster { width: 148mm; height: 210mm; }
          }
        </style>
      </head>
      <body>
        <main class="poster">
          <header class="top">
            <div class="brand">
              ${safeLogo ? `<img class="brand-logo" src="${safeLogo}" alt="Logo ${safeBusiness}" />` : ''}
              <div class="brand-copy">
                <h1 class="business">${safeBusiness}</h1>
                <div class="outlet">Pesan langsung dari meja Anda</div>
              </div>
            </div>
          </header>
          <div class="scan-heading">Scan untuk memesan</div>
          <div class="scan-subtitle">Arahkan kamera ponsel ke kode di bawah</div>
          <section class="main">
            <div class="qr-shell"><img class="qr" src="${safeQr}" alt="QR ${safeTable}" /></div>
            <div class="table-panel">
              <span class="table-word">MEJA</span><h2 class="table-number">${safeTableNumber}</h2>
            </div>
          </section>
          <section class="steps">
            <div><span class="step-no">1</span><div class="step-label">Scan kode QR</div></div>
            <div><span class="step-no">2</span><div class="step-label">Pilih menu dan pesan</div></div>
            <div><span class="step-no">3</span><div class="step-label">Bayar QRIS atau ke kasir</div></div>
          </section>
          <footer class="footer">Tanpa unduh aplikasi. Pesanan langsung diteruskan ke dapur setelah pembayaran dikonfirmasi.</footer>
        </main>
        <script>
          window.addEventListener('load', function () {
            setTimeout(function () { window.print() }, 150)
          })
          window.addEventListener('afterprint', function () { window.close() })
        </script>
      </body>
    </html>
  `)
  win.document.close()
  return true
}

export default function QRManager() {
  const { activeOutletId, activeOutlet } = useOutlet()
  const {
    data: tables = [],
    isLoading,
    isError,
    error: tablesError,
    refetch: refetchTables,
  } = useTables(activeOutletId ?? '')
  const [preview, setPreview] = useState<{ table: RestaurantTable; url: string } | null>(null)
  const [generating, setGenerating] = useState<string | null>(null)
  const [pendingRegenerate, setPendingRegenerate] = useState<RestaurantTable | null>(null)
  const qc = useQueryClient()
  const { toast } = useToast()

  useRealtimeTables(activeOutletId)
  const branding: QRBranding = {
    businessName: 'mejaku',
    outletName: activeOutlet?.name?.trim() || 'mejaku',
    address: [activeOutlet?.address?.trim(), activeOutlet?.city?.trim()].filter(Boolean).join(', '),
    phone: activeOutlet?.phone?.trim() || '',
    logoUrl: logo,
  }

  async function generateQR(table: RestaurantTable) {
    if (!activeOutletId || table.outlet_id !== activeOutletId) {
      toast({ title: 'Meja tidak valid', description: 'Muat ulang halaman lalu pilih outlet kembali.', variant: 'destructive' })
      return
    }
    if (!table.is_active) {
      toast({ title: 'Meja tidak aktif', description: 'Aktifkan meja sebelum membuat QR Code.', variant: 'destructive' })
      return
    }

    setGenerating(table.id)
    try {
      // Setiap generate/regenerate merotasi token. QR lama langsung tidak valid.
      const token = crypto.randomUUID()
      const menuUrl = buildMenuUrl(token)

      // Generate QR sebagai data URL (PNG)
      const dataUrl = await QRCode.toDataURL(menuUrl, {
        width: 400,
        margin: 2,
        color: { dark: '#111827', light: '#ffffff' },
      })

      // Simpan token + URL secara atomik, lalu pastikan baris benar-benar berubah.
      const generatedAt = new Date().toISOString()
      const { data: savedTable, error } = await supabase
        .from('restaurant_tables')
        .update({
          qr_token: token,
          qr_code_url: dataUrl,
          qr_generated_at: generatedAt,
        })
        .eq('id', table.id)
        .eq('outlet_id', activeOutletId)
        .eq('is_active', true)
        .select('*')
        .single()

      if (error) throw error
      if (!savedTable?.id) throw new Error('Perubahan QR tidak tersimpan.')

      await qc.invalidateQueries({ queryKey: ['tables', activeOutletId] })
      setPreview({ table: savedTable as RestaurantTable, url: dataUrl })
      toast({
        title: table.qr_token ? 'QR Code baru berhasil dibuat' : 'QR Code berhasil dibuat',
        description: table.qr_token ? 'QR Code sebelumnya sudah tidak dapat digunakan.' : undefined,
      })
    } catch (e) {
      toast({ title: 'Gagal membuat QR', description: humanizeError(e), variant: 'destructive' })
    } finally {
      setGenerating(null)
    }
  }

  async function downloadQR(dataUrl: string, table: RestaurantTable) {
    try {
      await downloadQRPoster(dataUrl, table, branding)
    } catch (error) {
      toast({
        title: 'Gagal mengunduh desain QR',
        description: error instanceof Error ? error.message : 'Gambar tidak dapat dibuat.',
        variant: 'destructive',
      })
    }
  }

  async function activateTable(table: RestaurantTable) {
    if (!activeOutletId || table.outlet_id !== activeOutletId) return
    try {
      const { error } = await supabase.from('restaurant_tables').update({ is_active: true, status: 'available' }).eq('id', table.id).eq('outlet_id', activeOutletId)
      if (error) throw error
      await qc.invalidateQueries({ queryKey: ['tables', activeOutletId] })
      toast({ title: `${tableLabel(table.table_number)} diaktifkan` })
    } catch (error) { toast({ title: 'Gagal mengaktifkan meja', description: humanizeError(error), variant: 'destructive' }) }
  }

  if (!activeOutletId) return <NoOutlet />

  return (
    <div className="space-y-4">
      <PageHeader
        title="Meja dan QR"
        subtitle={`${tables.filter((table) => table.status === 'occupied').length} dari ${tables.length} meja sedang terisi. Setiap QR memakai token acak, bukan nomor meja.`}
      ><Button asChild><Link to="/admin/tables">Tambah meja</Link></Button></PageHeader>

      {isError ? (
        <div className="flex flex-col items-center justify-center gap-3 rounded-xl border border-red-200 bg-red-50 px-5 py-10 text-center">
          <AlertCircle className="h-7 w-7 text-red-600" />
          <div>
            <p className="font-semibold text-red-900">Daftar meja gagal dimuat</p>
            <p className="mt-1 text-sm text-red-700">
              {tablesError ? humanizeError(tablesError) : 'Periksa koneksi lalu coba muat ulang.'}
            </p>
          </div>
          <Button variant="outline" size="sm" onClick={() => void refetchTables()}>
            <RefreshCw className="mr-2 h-4 w-4" /> Muat Ulang
          </Button>
        </div>
      ) : (
        isLoading ? <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">{Array.from({ length: 4 }).map((_, i) => <div key={i} className="h-64 animate-pulse rounded-2xl border bg-white" />)}</div> : tables.length === 0 ? <div className="admin-card py-16 text-center text-sm text-muted-foreground">Belum ada meja. Tambahkan meja terlebih dahulu.</div> :
        <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          {tables.map((table) => {
            const status = !table.is_active ? 'Nonaktif' : table.status === 'occupied' ? 'Terisi' : 'Kosong'
            const statusClass = status === 'Kosong' ? 'bg-green-100 text-green-800' : status === 'Terisi' ? 'bg-blue-100 text-blue-900' : 'bg-gray-200 text-gray-700'
            return <article key={table.id} className="admin-card p-4">
              <div className="flex items-center justify-between gap-2"><h2 className="text-lg font-bold">{tableLabel(table.table_number)}</h2><span className={`rounded-full px-2.5 py-1 text-xs font-semibold ${statusClass}`}>{status}</span></div>
              <button type="button" onClick={() => hasUsableQR(table) && setPreview({ table, url: table.qr_code_url! })} className="mt-3 flex h-32 w-full items-center justify-center overflow-hidden rounded-xl border-2 border-dashed bg-[#F9FAFB]" aria-label={`Lihat QR ${tableLabel(table.table_number)}`}>
                {hasUsableQR(table) ? <img src={table.qr_code_url!} alt={`QR ${tableLabel(table.table_number)}`} className="h-24 w-24 object-contain" /> : <QrCode className="h-10 w-10 text-gray-400" />}
              </button>
              <p className="mt-2 text-center text-[11px] text-muted-foreground">Dibuat {formatGeneratedAt(table.qr_generated_at)}</p>
              <div className="mt-3 grid grid-cols-[1fr_44px] gap-2">
                <Button variant="outline" disabled={table.is_active && !hasUsableQR(table)} onClick={() => table.is_active ? (table.qr_code_url && void downloadQR(table.qr_code_url, table)) : void activateTable(table)}>{table.is_active ? <><Download className="mr-2 h-4 w-4" />Unduh QR</> : 'Aktifkan'}</Button>
                <Button variant="outline" size="icon" disabled={generating !== null || !table.is_active} onClick={() => hasAnyQRData(table) ? setPendingRegenerate(table) : void generateQR(table)} aria-label={`Ganti token ${tableLabel(table.table_number)}`}><RefreshCw className={cn('h-4 w-4', generating === table.id && 'animate-spin')} /></Button>
              </div>
            </article>
          })}
        </div>
      )}

      <Dialog open={!!preview} onOpenChange={(o) => !o && setPreview(null)}>
        <DialogContent className="max-h-[calc(100dvh-2rem)] max-w-lg overflow-y-auto p-0">
          <DialogHeader className="sr-only">
            <DialogTitle>QR Code — {preview ? tableLabel(preview.table.table_number) : ''}</DialogTitle>
          </DialogHeader>
          {preview && (
            <div>
              <div
                className="mx-auto my-3 flex aspect-[148/210] w-[calc(100%_-_1.5rem)] max-w-[26rem] flex-col overflow-hidden bg-white text-[#20242a] shadow-inner"
              >
                <div className="flex min-h-[20%] items-center justify-center gap-4 bg-[#0f766e] px-5 text-white">
                    <img
                      src={branding.logoUrl}
                      alt={`Logo ${branding.businessName}`}
                      className="h-14 w-14 shrink-0 rounded-full bg-white p-1 object-cover"
                      onError={(event) => { event.currentTarget.src = logo }}
                    />
                    <div className="text-left">
                      <p className="text-xl font-extrabold leading-none">{branding.businessName}</p>
                      <p className="mt-1 text-xs font-bold">Pesan langsung dari meja Anda</p>
                    </div>
                </div>
                <p className="mt-7 text-center text-3xl font-extrabold leading-none">Scan untuk memesan</p>
                <p className="mt-2 text-center text-sm text-[#667085]">Arahkan kamera ponsel ke kode di bawah</p>
                <div className="mt-4 flex flex-1 flex-col items-center gap-4">
                  <div className="mx-auto rounded-3xl border-[3px] border-[#0f766e] bg-white p-4 outline outline-2 -outline-offset-[12px] outline-dashed outline-[#d1d5db]">
                    <img
                      src={preview.url}
                      alt={`QR ${tableLabel(preview.table.table_number)}`}
                      className="h-44 w-44"
                    />
                  </div>
                  <div className="flex items-center gap-2.5 rounded-full bg-[#20242a] px-6 py-2 text-white">
                    <span className="text-xs font-extrabold tracking-widest">MEJA</span>
                    <span className="text-3xl font-extrabold leading-none">{preview.table.table_number.replace(/^meja\s*/i, '')}</span>
                  </div>
                </div>
                <div className="grid grid-cols-3 gap-2 px-5 text-center text-[10px] font-bold text-[#344054]">
                  {['Scan kode QR', 'Pilih menu dan pesan', 'Bayar QRIS atau ke kasir'].map((text, index) => (
                    <div key={text}><span className="mx-auto mb-2 grid h-7 w-7 place-items-center rounded-full bg-[#0f766e] text-xs text-white">{index + 1}</span>{text}</div>
                  ))}
                </div>
                <p className="px-5 pb-4 pt-4 text-center text-[10px] leading-snug text-[#667085]">Tanpa unduh aplikasi. Pesanan langsung diteruskan ke dapur setelah pembayaran dikonfirmasi.</p>
              </div>
              <div className="flex gap-2 justify-center border-t bg-white p-4">
                <Button size="sm" onClick={() => void downloadQR(preview.url, preview.table)}>
                  <Download className="h-4 w-4 mr-1" /> Unduh
                </Button>
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() => {
                    try {
                      if (!printQR(preview.url, preview.table, branding)) {
                        toast({
                          title: 'Jendela cetak diblokir',
                          description: 'Izinkan pop-up untuk situs ini lalu coba kembali.',
                          variant: 'destructive',
                        })
                      }
                    } catch (error) {
                      toast({
                        title: 'Gagal mencetak QR',
                        description: error instanceof Error ? error.message : 'Data QR tidak valid.',
                        variant: 'destructive',
                      })
                    }
                  }}
                >
                  Cetak
                </Button>
              </div>
            </div>
          )}
        </DialogContent>
      </Dialog>

      <AlertDialog open={!!pendingRegenerate} onOpenChange={(open) => !open && setPendingRegenerate(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Buat ulang QR {pendingRegenerate ? tableLabel(pendingRegenerate.table_number) : ''}?</AlertDialogTitle>
            <AlertDialogDescription>
              QR Code yang sudah dicetak sebelumnya akan langsung tidak berlaku. Cetak dan pasang QR Code yang baru setelah proses selesai.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Batal</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => {
                const table = pendingRegenerate
                setPendingRegenerate(null)
                if (table) void generateQR(table)
              }}
            >
              Ya, Buat Ulang
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  )
}
