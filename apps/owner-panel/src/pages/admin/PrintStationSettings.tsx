import { useState, useEffect } from 'react'
import { useOutlet } from '@/hooks/useOutlet'
import { useUpdateOutlet } from '@/hooks/queries/useOutlets'
import { useMenuCategories } from '@/hooks/queries/useMenuItems'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Select, SelectTrigger, SelectValue, SelectContent, SelectItem,
} from '@/components/ui/select'
import { X, Plus, Printer, Info, AlertTriangle } from 'lucide-react'
import { useToast } from '@/hooks/use-toast'
import { humanizeError } from '@/lib/errorMessage'

type Station = { id: string; name: string }
type Category = { id: string; name: string }

const UNASSIGNED = '__unassigned__'
const EXCLUDED = '__excluded__'

// ── Preview tiket dapur/bar — mirror persis format cetak asli
// (lib/shared/services/kitchen_ticket_builder.dart: KitchenTicketBuilder.build)
// agar owner tahu PERSIS apa yang akan tercetak, bukan tebakan.
function KitchenTicketPreview({
  station,
  categories,
}: {
  station: Station | undefined
  categories: Category[]
}) {
  const now = new Date()
  const timeStr = now.toLocaleDateString('id-ID', {
    day: '2-digit', month: '2-digit',
  }) + ' ' + now.toLocaleTimeString('id-ID', { hour: '2-digit', minute: '2-digit' })

  return (
    <div className="font-mono text-[9px] bg-white border-2 border-dashed border-muted rounded-lg p-3 w-full shadow-sm select-none leading-relaxed">
      {!station ? (
        <p className="text-center text-muted-foreground py-6">
          Belum ada stasiun untuk dipreview.
        </p>
      ) : (
        <>
          <p className="text-center font-bold text-[12px] uppercase">{station.name}</p>
          <div className="border-t border-dashed my-1.5" />

          <div className="space-y-0.5 mb-1.5">
            <div className="flex justify-between">
              <span className="text-muted-foreground">No</span>
              <span className="font-bold">TEST-001</span>
            </div>
            <div className="flex justify-between">
              <span className="text-muted-foreground">Waktu</span>
              <span>{timeStr}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-muted-foreground">Jenis</span>
              <span>Dine-In</span>
            </div>
            <div className="flex justify-between">
              <span className="text-muted-foreground">Meja</span>
              <span className="font-bold">5</span>
            </div>
          </div>
          <div className="border-t border-dashed my-1.5" />

          {categories.length === 0 ? (
            <p className="text-center text-muted-foreground py-3">
              Belum ada kategori dipetakan ke stasiun ini — tiket akan kosong.
            </p>
          ) : (
            <div className="space-y-1">
              {categories.map((c) => (
                <p key={c.id} className="font-bold text-[12px] uppercase">
                  1x {c.name}
                </p>
              ))}
            </div>
          )}
        </>
      )}
    </div>
  )
}

export default function PrintStationSettings() {
  const { activeOutlet, activeOutletId } = useOutlet()
  const update = useUpdateOutlet()
  const { toast } = useToast()
  const { data: categories = [] } = useMenuCategories(activeOutletId ?? '')

  const [stations, setStations] = useState<Station[]>([])
  // peta category_id -> station_id
  const [catMap, setCatMap] = useState<Record<string, string>>({})
  const [excludedCategories, setExcludedCategories] = useState<Set<string>>(new Set())
  const [previewStationId, setPreviewStationId] = useState<string | null>(null)

  useEffect(() => {
    if (!activeOutlet) return
    const s = activeOutlet.settings
    // Sinkronkan form lokal ketika outlet aktif berubah.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setStations(Array.isArray(s?.print_stations) ? s!.print_stations : [])
    setCatMap(
      s?.print_category_station && typeof s.print_category_station === 'object'
        ? s.print_category_station
        : {},
    )
    setExcludedCategories(
      new Set(Array.isArray(s?.print_excluded_categories) ? s!.print_excluded_categories : []),
    )
  }, [activeOutlet])

  function addStation() {
    setStations((prev) => [...prev, { id: crypto.randomUUID(), name: '' }])
  }
  function renameStation(id: string, name: string) {
    setStations((prev) => prev.map((s) => (s.id === id ? { ...s, name } : s)))
  }
  function removeStation(id: string) {
    setStations((prev) => prev.filter((s) => s.id !== id))
    // bersihkan pemetaan kategori yang mengarah ke stasiun ini
    setCatMap((prev) => {
      const next = { ...prev }
      for (const k of Object.keys(next)) if (next[k] === id) delete next[k]
      return next
    })
  }
  function assignCategory(catId: string, stationId: string) {
    setCatMap((prev) => {
      const next = { ...prev }
      if (stationId === UNASSIGNED || stationId === EXCLUDED) delete next[catId]
      else next[catId] = stationId
      return next
    })
    setExcludedCategories((prev) => {
      const next = new Set(prev)
      if (stationId === EXCLUDED) next.add(catId)
      else next.delete(catId)
      return next
    })
  }

  async function handleSave() {
    if (!activeOutletId || !activeOutlet) return
    if (stations.some((s) => !s.name.trim())) {
      toast({ title: 'Nama stasiun wajib diisi', variant: 'destructive' })
      return
    }
    const clean = stations.map((s) => ({ ...s, name: s.name.trim() }))
    const normalizedNames = clean.map((s) => s.name.toLocaleLowerCase('id-ID'))
    if (new Set(normalizedNames).size !== normalizedNames.length) {
      toast({ title: 'Nama stasiun tidak boleh sama', variant: 'destructive' })
      return
    }
    const validIds = new Set(clean.map((s) => s.id))
    const cleanMap: Record<string, string> = {}
    for (const [cat, st] of Object.entries(catMap)) {
      if (validIds.has(st)) cleanMap[cat] = st
    }
    try {
      await update.mutateAsync({
        id: activeOutletId,
        updates: {
          settings: {
            ...activeOutlet.settings,
            print_stations: clean,
            print_category_station: cleanMap,
            print_excluded_categories: [...excludedCategories].filter((id) => !cleanMap[id]),
          },
        },
      })
      setStations(clean)
      toast({ title: 'Routing tiket dapur tersimpan' })
    } catch (error) {
      toast({
        title: 'Gagal menyimpan routing tiket',
        description: humanizeError(error),
        variant: 'destructive',
      })
    }
  }

  // Stasiun aktif untuk preview (nama terisi). Default: stasiun pertama,
  // otomatis pindah kalau stasiun yang lagi dipreview dihapus/dikosongkan.
  const namedStations = stations.filter((s) => s.name.trim().length > 0)
  const previewStation =
    namedStations.find((s) => s.id === previewStationId) ?? namedStations[0]

  const previewCategories: Category[] = previewStation
    ? categories.filter((c) => catMap[c.id] === previewStation.id)
    : []

  if (!activeOutletId) return <NoOutlet />

  return (
    <div className="grid md:grid-cols-[1fr_320px] gap-6 p-1 items-start">
      <div className="max-w-2xl space-y-6">
        <div>
          <h1 className="text-xl font-semibold flex items-center gap-2">
            <Printer className="h-5 w-5" /> Routing Tiket Dapur
          </h1>
          <p className="text-sm text-muted-foreground mt-1">
            Arahkan kategori menu ke bagian kerja seperti Dapur, Bar, atau Dessert.
          </p>
        </div>

        <section className="rounded-lg border border-blue-200 bg-blue-50 p-4 space-y-3 text-sm">
          <div className="flex gap-2">
            <Info className="h-4 w-4 text-blue-700 mt-0.5 shrink-0" />
            <div>
              <p className="font-medium text-blue-950">Stasiun bukan printer fisik</p>
              <p className="text-blue-900/80 mt-1">
                Stasiun adalah jalur pengelompokan tiket. Contoh: kategori Minuman
                diarahkan ke stasiun Bar, sedangkan Makanan ke stasiun Dapur.
              </p>
            </div>
          </div>
          <ol className="list-decimal pl-9 space-y-1 text-blue-900/80">
            <li>Buat nama stasiun dan petakan setiap kategori di halaman ini.</li>
            <li>Simpan perubahan.</li>
            <li>
              Di aplikasi POS buka Pengaturan Perangkat → Printer → pilih printer
              → tab Dapur, lalu pilih <strong>Stasiun Outlet</strong>.
            </li>
          </ol>
        </section>

        {namedStations.length > 0 && (
          <section className="flex gap-2 rounded-lg border border-amber-200 bg-amber-50 p-3 text-xs text-amber-900">
            <AlertTriangle className="h-4 w-4 mt-0.5 shrink-0" />
            <p>
              Routing baru mulai bekerja setelah printer fisik pada setiap perangkat
              POS diikat ke stasiunnya. Konfigurasi printer disimpan lokal di perangkat,
              sehingga status ikatannya tidak dapat dilihat dari web.
            </p>
          </section>
        )}

        {/* Daftar stasiun */}
        <section className="space-y-3">
          <h2 className="font-medium text-sm">Stasiun</h2>
          {stations.length === 0 && (
            <p className="text-sm text-muted-foreground">Belum ada stasiun.</p>
          )}
          {stations.map((s) => (
            <div key={s.id} className="flex items-center gap-2">
              <Input
                value={s.name}
                placeholder="Nama stasiun (mis. Dapur, Bar)"
                onChange={(e) => renameStation(s.id, e.target.value)}
              />
              <Button
                variant="ghost" size="icon-sm"
                onClick={() => removeStation(s.id)}
                aria-label={`Hapus stasiun ${s.name || 'tanpa nama'}`}
              >
                <X className="h-4 w-4" />
              </Button>
            </div>
          ))}
          <Button variant="outline" size="sm" onClick={addStation}>
            <Plus className="h-4 w-4 mr-1" /> Tambah Stasiun
          </Button>
        </section>

        {/* Pemetaan kategori → stasiun */}
        <section className="space-y-3">
          <h2 className="font-medium text-sm">Pemetaan Kategori</h2>
          {categories.length === 0 && (
            <p className="text-sm text-muted-foreground">Belum ada kategori menu.</p>
          )}
          {categories.map((c) => (
            <div key={c.id} className="flex items-center justify-between gap-2">
              <span className="text-sm">{c.name}</span>
              <Select
                value={catMap[c.id] ?? (excludedCategories.has(c.id) ? EXCLUDED : UNASSIGNED)}
                onValueChange={(v) => assignCategory(c.id, v)}
              >
                <SelectTrigger className="w-48">
                  <SelectValue placeholder="Belum dipetakan" />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value={UNASSIGNED}>Belum dipetakan (fallback dapur)</SelectItem>
                  <SelectItem value={EXCLUDED}>Sengaja tidak dicetak</SelectItem>
                  {namedStations.map((s) => (
                    <SelectItem key={s.id} value={s.id}>{s.name}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          ))}
        </section>

        <Button onClick={handleSave} disabled={update.isPending}>
          {update.isPending ? 'Menyimpan...' : 'Simpan Perubahan'}
        </Button>
      </div>

      {/* Preview tiket */}
      <div className="sticky top-4 space-y-2">
        <div className="flex items-center justify-between gap-2">
          <p className="text-xs text-muted-foreground font-medium">Preview Tiket</p>
          {namedStations.length > 1 && (
            <Select
              value={previewStation?.id ?? UNASSIGNED}
              onValueChange={(v) => setPreviewStationId(v)}
            >
              <SelectTrigger className="h-7 w-28 text-xs">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {namedStations.map((s) => (
                  <SelectItem key={s.id} value={s.id}>{s.name}</SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        </div>
        <KitchenTicketPreview station={previewStation} categories={previewCategories} />
      </div>
    </div>
  )
}
