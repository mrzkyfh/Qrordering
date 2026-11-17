import { createHash } from 'node:crypto'
import { execFile, spawn } from 'node:child_process'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)
const ROOT = process.cwd()
const PROJECT_REF = 'yjmrabgpxjbunwtsiavs'
const ACCOUNT_ID = '4e5b204f44bdff9f75eda4c3e99ee098'
const TARGET_BUCKET = 'qrordering-assets'
const PUBLIC_BASE = 'https://assets.qrordering.my.id'
const CACHE_CONTROL = 'public, max-age=31536000, immutable'
const BASELINE_PATH = path.join(ROOT, 'backups/r2-production-copy-20261010T172104Z/production-r2-copy-manifest.json')
const runId = new Date().toISOString().replaceAll(':', '').replaceAll('-', '').replace(/\.\d{3}Z$/, 'Z')
const outputDir = path.join(ROOT, 'backups', `r2-production-delta-${runId}`)
const sourceDir = path.join(outputDir, 'source')
const readbackDir = path.join(outputDir, 'readback')

function parseEnv(text) {
  return Object.fromEntries(text.split(/\r?\n/).map((line) => line.trim())
    .filter((line) => line && !line.startsWith('#') && line.includes('='))
    .map((line) => {
      const normalized = line.startsWith('export ') ? line.slice(7).trim() : line
      const at = normalized.indexOf('=')
      return [normalized.slice(0, at).trim(), normalized.slice(at + 1).trim().replace(/^(['"])(.*)\1$/, '$2')]
    }))
}

const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex')
const encoded = (value) => value.split('/').map(encodeURIComponent).join('/')

async function mapLimit(items, limit, fn) {
  const results = new Array(items.length)
  let cursor = 0
  async function worker() {
    while (cursor < items.length) {
      const index = cursor++
      results[index] = await fn(items[index], index)
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker))
  return results
}

async function retry(label, fn) {
  let last
  for (let attempt = 1; attempt <= 3; attempt++) {
    try { return await fn(attempt) } catch (error) {
      last = error
      if (attempt < 3) await new Promise((resolve) => setTimeout(resolve, attempt * 500))
    }
  }
  throw new Error(`${label}: ${last?.message ?? last}`)
}

async function storagePaths(bucket) {
  const { stdout } = await execFileAsync('supabase', [
    'storage', 'ls', `ss:///${bucket}`, '--recursive', '--project-ref', PROJECT_REF,
    '--experimental', '--output-format', 'json',
  ], { cwd: ROOT, maxBuffer: 8 * 1024 * 1024 })
  const line = stdout.split(/\r?\n/).find((value) => value.trim().startsWith('{"paths"'))
  if (!line) throw new Error(`Storage inventory unavailable for ${bucket}`)
  return JSON.parse(line).paths
    .map((value) => value.replace(new RegExp(`^/${bucket}/`), ''))
    .filter((value) => value && value !== `${bucket}/`)
    .sort()
}

function runWrangler(args, env) {
  return new Promise((resolve, reject) => {
    const child = spawn('npx', ['wrangler', ...args], {
      cwd: path.join(ROOT, 'apps/assets-worker'), env, stdio: ['ignore', 'ignore', 'pipe'],
    })
    let stderr = ''
    child.stderr.on('data', (value) => { stderr += value })
    child.on('close', (code) => code === 0 ? resolve() : reject(new Error(`exit ${code}: ${stderr.slice(-500)}`)))
  })
}

const production = parseEnv(await readFile(path.join(ROOT, '.env.cloudflare-production'), 'utf8'))
const owner = parseEnv(await readFile(path.join(ROOT, 'apps/owner-panel/.env'), 'utf8'))
if (!production.CLOUDFLARE_API_TOKEN || !owner.VITE_SUPABASE_URL || !owner.VITE_SUPABASE_ANON_KEY) {
  throw new Error('Required local production configuration is missing')
}
const childEnv = { ...process.env, CLOUDFLARE_API_TOKEN: production.CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID: ACCOUNT_ID }
const supabaseHeaders = { apikey: owner.VITE_SUPABASE_ANON_KEY, Authorization: `Bearer ${owner.VITE_SUPABASE_ANON_KEY}` }
await mkdir(sourceDir, { recursive: true })
await mkdir(readbackDir, { recursive: true })

const [menuPaths, qrPaths] = await Promise.all([storagePaths('menu-images'), storagePaths('qr-codes')])
let sourceDone = 0
const sourceObjects = await mapLimit(menuPaths, 8, async (objectPath) => retry(`source ${objectPath}`, async () => {
  const url = `${owner.VITE_SUPABASE_URL}/storage/v1/object/public/menu-images/${encoded(objectPath)}`
  const response = await fetch(url)
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  const bytes = Buffer.from(await response.arrayBuffer())
  const localPath = path.join(sourceDir, objectPath)
  await mkdir(path.dirname(localPath), { recursive: true })
  await writeFile(localPath, bytes, { mode: 0o600 })
  sourceDone++
  if (sourceDone % 20 === 0 || sourceDone === menuPaths.length) console.log(`source ${sourceDone}/${menuPaths.length}`)
  return {
    sourceBucket: 'menu-images', sourcePath: objectPath, destinationKey: `menu-images/${objectPath}`,
    size: bytes.length, sha256: sha256(bytes), contentType: response.headers.get('content-type')?.split(';')[0] ?? 'application/octet-stream',
  }
}))

const baseline = JSON.parse(await readFile(BASELINE_PATH, 'utf8')).objects
const baselineByKey = new Map(baseline.map((item) => [item.destinationKey, item]))
const sourceByKey = new Map(sourceObjects.map((item) => [item.destinationKey, item]))
const newSinceBaseline = sourceObjects.filter((item) => !baselineByKey.has(item.destinationKey)).map((item) => item.destinationKey)
const changedSinceBaseline = sourceObjects.filter((item) => baselineByKey.has(item.destinationKey) && baselineByKey.get(item.destinationKey).sha256 !== item.sha256).map((item) => item.destinationKey)
const missingSource = baseline.filter((item) => !sourceByKey.has(item.destinationKey)).map((item) => item.destinationKey)

let dbRows = [], offset = 0
while (true) {
  const response = await fetch(`${owner.VITE_SUPABASE_URL}/rest/v1/menu_items?select=id,image_url&order=id.asc&offset=${offset}&limit=1000`, { headers: supabaseHeaders })
  if (!response.ok) throw new Error(`menu_items audit HTTP ${response.status}`)
  const page = await response.json()
  dbRows.push(...page)
  if (page.length < 1000) break
  offset += page.length
}
const distribution = { total: dbRows.length, nonNull: 0, supabase: 0, productionR2: 0, stagingR2: 0, other: 0 }
const referencedBuckets = new Set()
for (const row of dbRows) {
  if (!row.image_url) continue
  distribution.nonNull++
  const value = String(row.image_url)
  if (value.includes('.supabase.co/storage/v1/')) {
    distribution.supabase++
    const match = value.match(/\/storage\/v1\/(?:object|render\/image)\/public\/([^/]+)/)
    if (match) referencedBuckets.add(decodeURIComponent(match[1]))
  } else if (value.startsWith(`${PUBLIC_BASE}/`)) distribution.productionR2++
  else if (value.includes('.r2.dev/') || value.includes('qrordering-r2-staging')) distribution.stagingR2++
  else distribution.other++
}

let readDone = 0
const initialR2 = await mapLimit(sourceObjects, 6, async (item, index) => {
  const outPath = path.join(readbackDir, `initial-${index}.bin`)
  try {
    await runWrangler(['r2', 'object', 'get', `${TARGET_BUCKET}/${item.destinationKey}`, '--file', outPath, '--remote'], childEnv)
    const bytes = await readFile(outPath)
    readDone++
    if (readDone % 20 === 0 || readDone === sourceObjects.length) console.log(`r2 audit ${readDone}/${sourceObjects.length}`)
    return { key: item.destinationKey, exists: true, size: bytes.length, sha256: sha256(bytes), matches: bytes.length === item.size && sha256(bytes) === item.sha256 }
  } catch (error) {
    readDone++
    return { key: item.destinationKey, exists: false, matches: false, error: error.message }
  }
})
const missingInR2 = initialR2.filter((item) => !item.exists).map((item) => item.key)
const differentInR2 = initialR2.filter((item) => item.exists && !item.matches).map((item) => item.key)
const syncKeys = new Set([...missingInR2, ...differentInR2])

const syncFailures = []
let synced = 0
await mapLimit(sourceObjects.filter((item) => syncKeys.has(item.destinationKey)), 4, async (item) => {
  try {
    await retry(`upload ${item.destinationKey}`, () => runWrangler([
      'r2', 'object', 'put', `${TARGET_BUCKET}/${item.destinationKey}`, '--file', path.join(sourceDir, item.sourcePath),
      '--content-type', item.contentType, '--cache-control', CACHE_CONTROL, '--remote',
    ], childEnv))
    synced++
    console.log(`delta uploaded ${synced}/${syncKeys.size}`)
  } catch (error) { syncFailures.push({ key: item.destinationKey, error: error.message }) }
})

let finalDone = 0
const finalR2 = await mapLimit(sourceObjects, 6, async (item, index) => {
  const outPath = path.join(readbackDir, `final-${index}.bin`)
  try {
    await runWrangler(['r2', 'object', 'get', `${TARGET_BUCKET}/${item.destinationKey}`, '--file', outPath, '--remote'], childEnv)
    const bytes = await readFile(outPath)
    finalDone++
    if (finalDone % 20 === 0 || finalDone === sourceObjects.length) console.log(`final verify ${finalDone}/${sourceObjects.length}`)
    return { key: item.destinationKey, exists: true, size: bytes.length, sha256: sha256(bytes), matches: bytes.length === item.size && sha256(bytes) === item.sha256 }
  } catch (error) {
    finalDone++
    return { key: item.destinationKey, exists: false, matches: false, error: error.message }
  }
})

const sourceBytes = sourceObjects.reduce((sum, item) => sum + item.size, 0)
const missingAfter = finalR2.filter((item) => !item.exists).map((item) => item.key)
const mismatchAfter = finalR2.filter((item) => item.exists && !item.matches).map((item) => item.key)
const { stdout: infoOut } = await execFileAsync('npx', ['wrangler', 'r2', 'bucket', 'info', TARGET_BUCKET, '--json'], { cwd: path.join(ROOT, 'apps/assets-worker'), env: childEnv, maxBuffer: 1024 * 1024 })
const bucketInfo = JSON.parse(infoOut.slice(infoOut.indexOf('{')))
const r2Count = Number(bucketInfo.object_count)
const extraCount = Number.isFinite(r2Count) ? Math.max(0, r2Count - sourceObjects.length) : null

const samples = [sourceObjects[0], sourceObjects[Math.floor(sourceObjects.length / 2)], sourceObjects.at(-1)].filter(Boolean)
const publicSamples = []
for (const item of samples) {
  const response = await fetch(`${PUBLIC_BASE}/${encoded(item.destinationKey)}`, { redirect: 'manual' })
  const bytes = Buffer.from(await response.arrayBuffer())
  publicSamples.push({ key: item.destinationKey, status: response.status, redirect: response.headers.get('location'), contentType: response.headers.get('content-type')?.split(';')[0], sizeMatch: bytes.length === item.size, hashMatch: sha256(bytes) === item.sha256 })
}

const report = {
  generatedAt: new Date().toISOString(),
  supabase: { totalCount: sourceObjects.length + qrPaths.length, totalBytes: sourceBytes, menuImages: { count: sourceObjects.length, bytes: sourceBytes }, qrCodes: { count: qrPaths.length, paths: qrPaths }, referencedBuckets: [...referencedBuckets] },
  baselineDelta: { newObjects: newSinceBaseline, changedObjects: changedSinceBaseline, missingSourceObjects: missingSource },
  databaseImageUrlDistribution: distribution,
  beforeSync: { missingInR2, differentInR2 },
  sync: { missingCopied: missingInR2.filter((key) => !syncFailures.some((failure) => failure.key === key)).length, changedResynced: differentInR2.filter((key) => !syncFailures.some((failure) => failure.key === key)).length, failures: syncFailures },
  productionR2: { objectCount: r2Count, totalBytes: sourceObjects.reduce((sum, item) => sum + (finalR2.find((row) => row.key === item.destinationKey)?.matches ? item.size : 0), 0), extraCount },
  afterSync: { missing: missingAfter, checksumMismatches: mismatchAfter },
  publicSamples,
  safety: { supabaseDeleted: 0, databaseModified: false, transactionsModified: false, qrModified: false, stagingModified: false, deploymentPerformed: false, buildPerformed: false },
  objects: sourceObjects.map((item) => ({ ...item, initialR2: initialR2.find((row) => row.key === item.destinationKey), finalR2: finalR2.find((row) => row.key === item.destinationKey) })),
}
const reportPath = path.join(outputDir, 'delta-sync-report.json')
await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 })
console.log(JSON.stringify({ reportPath, supabase: report.supabase, baselineDelta: { new: newSinceBaseline.length, changed: changedSinceBaseline.length, missingSource: missingSource.length }, database: distribution, beforeSync: { missing: missingInR2.length, different: differentInR2.length }, sync: report.sync, productionR2: report.productionR2, afterSync: { missing: missingAfter.length, checksumMismatch: mismatchAfter.length }, publicPass: publicSamples.every((x) => x.status === 200 && !x.redirect && x.sizeMatch && x.hashMatch) }, null, 2))
if (syncFailures.length || missingAfter.length || mismatchAfter.length || publicSamples.some((x) => x.status !== 200 || x.redirect || !x.sizeMatch || !x.hashMatch)) process.exitCode = 1
