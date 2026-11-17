import { createHash } from 'node:crypto'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { extname, join } from 'node:path'
import { spawnSync } from 'node:child_process'

const supabaseUrl = process.env.SUPABASE_URL?.replace(/\/$/, '')
const anonKey = process.env.SUPABASE_ANON_KEY
const sourceOrigin = (process.env.SOURCE_ASSET_ORIGIN || 'https://assets.qrordering.my.id').replace(/\/$/, '')
const targetOrigin = (process.env.TARGET_ASSET_ORIGIN || 'https://qrordering-r2-staging.official-b0d.workers.dev').replace(/\/$/, '')
const bucket = process.env.R2_BUCKET || 'qrordering-assets-staging'
const apply = process.env.APPLY === '1'
const partTotal = Math.max(1, Number.parseInt(process.env.PART_TOTAL || '1', 10))
const partIndex = Math.max(0, Number.parseInt(process.env.PART_INDEX || '0', 10))

if (!supabaseUrl || !anonKey) {
  throw new Error('SUPABASE_URL dan SUPABASE_ANON_KEY wajib tersedia')
}

const headers = { apikey: anonKey, authorization: `Bearer ${anonKey}` }
const endpoints = [
  ['menu_items', 'id,name,image_url', 'image_url'],
  ['outlets', 'id,name,logo_url', 'logo_url'],
]
const assets = new Map()

for (const [table, select, column] of endpoints) {
  const url = `${supabaseUrl}/rest/v1/${table}?select=${select}&${column}=not.is.null`
  const response = await fetch(url, { headers })
  if (!response.ok) throw new Error(`${table}: inventaris gagal HTTP ${response.status}`)
  for (const row of await response.json()) {
    const sourceUrl = row[column]
    if (typeof sourceUrl !== 'string' || !sourceUrl.startsWith(`${sourceOrigin}/`)) continue
    const key = decodeURIComponent(new URL(sourceUrl).pathname.replace(/^\/+/, ''))
    if (!key || key.includes('..') || key.includes('\\')) continue
    assets.set(sourceUrl, { table, id: row.id, name: row.name, sourceUrl, key })
  }
}

if (partIndex >= partTotal) throw new Error('PART_INDEX harus lebih kecil dari PART_TOTAL')
const selectedAssets = [...assets.values()].filter((_, index) => index % partTotal === partIndex)
process.stdout.write(
  `Inventaris: ${assets.size} object; part ${partIndex + 1}/${partTotal}: ${selectedAssets.length} object\n`,
)
if (!apply) {
  process.stdout.write('Dry-run selesai. Jalankan dengan APPLY=1 untuk menyalin.\n')
  process.exit(0)
}

const temp = await mkdtemp(join(tmpdir(), 'qrordering-production-r2-copy-'))
const manifest = []
try {
  let index = 0
  for (const asset of selectedAssets) {
    index += 1
    const canonicalTarget = `${targetOrigin}/assets/${asset.key}`
    const existing = await fetch(canonicalTarget, { method: 'HEAD', cache: 'no-store' })
    if (existing.ok) {
      process.stdout.write(`[part ${partIndex + 1} ${index}/${selectedAssets.length}] ${asset.name}: sudah ada\n`)
      manifest.push({ ...asset, targetUrl: canonicalTarget, status: 'existing' })
      continue
    }

    const source = await fetch(asset.sourceUrl, { cache: 'no-store' })
    if (!source.ok) throw new Error(`${asset.name}: sumber HTTP ${source.status}`)
    const contentType = source.headers.get('content-type')?.split(';')[0] || 'application/octet-stream'
    if (!contentType.startsWith('image/')) throw new Error(`${asset.name}: sumber bukan gambar`)
    const bytes = Buffer.from(await source.arrayBuffer())
    const filePath = join(temp, `${String(index).padStart(4, '0')}${extname(asset.key) || '.img'}`)
    await writeFile(filePath, bytes)

    const childEnv = { ...process.env }
    delete childEnv.CLOUDFLARE_API_TOKEN
    const upload = spawnSync(
      'npx',
      ['wrangler', 'r2', 'object', 'put', `${bucket}/${asset.key}`, '--file', filePath,
        '--content-type', contentType, '--remote'],
      { cwd: new URL('..', import.meta.url), env: childEnv, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] },
    )
    if (upload.status !== 0) {
      throw new Error(`${asset.name}: upload gagal\n${upload.stderr || upload.stdout}`)
    }

    const target = await fetch(canonicalTarget, { cache: 'no-store' })
    if (!target.ok) throw new Error(`${asset.name}: target HTTP ${target.status}`)
    const copied = Buffer.from(await target.arrayBuffer())
    const sourceHash = createHash('sha256').update(bytes).digest('hex')
    const targetHash = createHash('sha256').update(copied).digest('hex')
    if (sourceHash !== targetHash) throw new Error(`${asset.name}: checksum berbeda`)
    manifest.push({ ...asset, targetUrl: canonicalTarget, status: 'copied', bytes: bytes.length, sha256: sourceHash })
    process.stdout.write(`[part ${partIndex + 1} ${index}/${selectedAssets.length}] ${asset.name}: copied + verified\n`)
  }
  const manifestPath = process.env.MANIFEST_PATH || join(temp, 'manifest.json')
  await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`)
  process.stdout.write(`Selesai: ${manifest.length} object diverifikasi. Manifest: ${manifestPath}\n`)
} finally {
  if (!process.env.MANIFEST_PATH) await rm(temp, { recursive: true, force: true })
}
