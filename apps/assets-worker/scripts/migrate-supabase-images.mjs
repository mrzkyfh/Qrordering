import { createHash } from 'node:crypto'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { extname, join } from 'node:path'
import { spawnSync } from 'node:child_process'

const supabaseUrl = process.env.SUPABASE_URL?.replace(/\/$/, '')
const anonKey = process.env.SUPABASE_ANON_KEY
const workerUrl = (process.env.ASSET_WORKER_URL ||
  'https://time420s-assets.timess402coffee.workers.dev').replace(/\/$/, '')
const bucket = process.env.R2_BUCKET || 'time420s-images'

if (!supabaseUrl || !anonKey) {
  throw new Error('SUPABASE_URL dan SUPABASE_ANON_KEY wajib tersedia')
}

const headers = { apikey: anonKey }
const response = await fetch(
  `${supabaseUrl}/rest/v1/menu_items?select=id,outlet_id,name,image_url` +
    '&image_url=not.is.null&order=outlet_id.asc,name.asc',
  { headers },
)
if (!response.ok) throw new Error(`Inventaris Supabase gagal: HTTP ${response.status}`)

const rows = await response.json()
const byUrl = new Map()
for (const row of rows) {
  if (typeof row.image_url !== 'string' || !row.image_url) continue
  const marker = '/menu-images/'
  const markerIndex = row.image_url.indexOf(marker)
  if (markerIndex < 0) continue
  const oldPath = decodeURIComponent(row.image_url.slice(markerIndex + marker.length).split('?')[0])
  if (!oldPath || oldPath.includes('..') || oldPath.startsWith('/')) continue
  byUrl.set(row.image_url, { ...row, oldPath, key: `menu/${oldPath}` })
}

const temp = await mkdtemp(join(tmpdir(), 'time420s-r2-migration-'))
const manifest = []
try {
  let index = 0
  for (const item of byUrl.values()) {
    index += 1
    const source = await fetch(item.image_url)
    if (!source.ok) throw new Error(`${item.name}: unduh gagal HTTP ${source.status}`)
    const contentType = source.headers.get('content-type')?.split(';')[0] || 'application/octet-stream'
    if (!contentType.startsWith('image/')) throw new Error(`${item.name}: sumber bukan gambar`)
    const bytes = Buffer.from(await source.arrayBuffer())
    const extension = extname(item.oldPath) || '.img'
    const filePath = join(temp, `${String(index).padStart(3, '0')}${extension}`)
    await writeFile(filePath, bytes)

    const upload = spawnSync(
      'npx',
      ['wrangler', 'r2', 'object', 'put', `${bucket}/${item.key}`, '--file', filePath,
        '--content-type', contentType, '--remote'],
      { cwd: new URL('..', import.meta.url), encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] },
    )
    if (upload.status !== 0) {
      throw new Error(`${item.name}: upload R2 gagal\n${upload.stderr || upload.stdout}`)
    }

    const targetUrl = `${workerUrl}/assets/${item.key}`
    const target = await fetch(targetUrl, { cache: 'no-store' })
    if (!target.ok) throw new Error(`${item.name}: verifikasi R2 gagal HTTP ${target.status}`)
    const copied = Buffer.from(await target.arrayBuffer())
    const sourceHash = createHash('sha256').update(bytes).digest('hex')
    const targetHash = createHash('sha256').update(copied).digest('hex')
    if (sourceHash !== targetHash) throw new Error(`${item.name}: checksum berbeda`)

    manifest.push({
      id: item.id,
      outlet_id: item.outlet_id,
      name: item.name,
      source_url: item.image_url,
      target_url: targetUrl,
      key: item.key,
      bytes: bytes.length,
      sha256: sourceHash,
    })
    process.stdout.write(`[${index}/${byUrl.size}] ${item.name} OK\n`)
  }
  await writeFile(
    new URL('../migration-manifest.json', import.meta.url),
    `${JSON.stringify(manifest, null, 2)}\n`,
  )
  const totalBytes = manifest.reduce((sum, item) => sum + item.bytes, 0)
  process.stdout.write(`Selesai: ${manifest.length} gambar, ${totalBytes} byte\n`)
} finally {
  await rm(temp, { recursive: true, force: true })
}
