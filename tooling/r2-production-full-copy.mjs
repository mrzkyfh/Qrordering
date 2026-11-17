import { createHash } from 'node:crypto'
import { execFile } from 'node:child_process'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)
const PROJECT_REF = 'yjmrabgpxjbunwtsiavs'
const SOURCE_BUCKET = 'menu-images'
const TARGET_BUCKET = 'time420s-assets'
const ACCOUNT_ID = '4e5b204f44bdff9f75eda4c3e99ee098'
const PUBLIC_BASE = 'https://assets.time420s.my.id'
const CANARY_KEY = 'menu-images/d81e6a71-bb92-45b0-be88-cca026ed783e/menu/49ad52e7-4546-48eb-92fb-5213d6000691.webp'
const CACHE_CONTROL = 'public, max-age=31536000, immutable'
const ROOT = process.cwd()
const RUN_ID = new Date().toISOString().replaceAll(':', '').replaceAll('-', '').replace(/\.\d{3}Z$/, 'Z')
const OUTPUT = path.join(ROOT, 'backups', `r2-production-copy-${RUN_ID}`)
const DOWNLOADS = path.join(OUTPUT, 'storage')
const READBACKS = path.join(OUTPUT, 'readback')

function loadEnv(text) {
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
  const out = new Array(items.length)
  let cursor = 0
  async function worker() {
    while (cursor < items.length) {
      const index = cursor++
      out[index] = await fn(items[index], index)
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker))
  return out
}

async function retry(label, fn) {
  let last
  for (let attempt = 1; attempt <= 3; attempt++) {
    try { return await fn(attempt) } catch (error) {
      last = error
      if (attempt < 3) await new Promise((resolve) => setTimeout(resolve, 500 * attempt))
    }
  }
  throw new Error(`${label}: ${last?.message ?? last}`)
}

const production = loadEnv(await readFile(path.join(ROOT, '.env.cloudflare-production'), 'utf8'))
const owner = loadEnv(await readFile(path.join(ROOT, 'apps/owner-panel/.env'), 'utf8'))
if (!production.CLOUDFLARE_API_TOKEN) throw new Error('Production Cloudflare token is missing')
if (!owner.VITE_SUPABASE_URL || !owner.VITE_SUPABASE_ANON_KEY) throw new Error('Supabase local config is missing')

const childEnv = { ...process.env, CLOUDFLARE_API_TOKEN: production.CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID: ACCOUNT_ID }
const supabaseHeaders = { apikey: owner.VITE_SUPABASE_ANON_KEY, Authorization: `Bearer ${owner.VITE_SUPABASE_ANON_KEY}` }

await mkdir(DOWNLOADS, { recursive: true })
await mkdir(READBACKS, { recursive: true })

const { stdout: listStdout } = await execFileAsync('supabase', [
  'storage', 'ls', `ss:///${SOURCE_BUCKET}`, '--recursive', '--project-ref', PROJECT_REF,
  '--experimental', '--output-format', 'json',
], { cwd: ROOT, maxBuffer: 4 * 1024 * 1024 })
const listLine = listStdout.split(/\r?\n/).find((line) => line.trim().startsWith('{"paths"'))
if (!listLine) throw new Error('Supabase inventory did not return paths')
const sourcePaths = JSON.parse(listLine).paths.map((item) => item.replace(/^\/menu-images\//, '')).sort()
if (new Set(sourcePaths).size !== sourcePaths.length) throw new Error('Duplicate Supabase source path')

let downloaded = 0
const manifest = await mapLimit(sourcePaths, 6, async (objectPath) => retry(`source ${objectPath}`, async () => {
  const sourceUrl = `${owner.VITE_SUPABASE_URL}/storage/v1/object/public/${SOURCE_BUCKET}/${encoded(objectPath)}`
  const response = await fetch(sourceUrl)
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  const bytes = Buffer.from(await response.arrayBuffer())
  const contentType = response.headers.get('content-type')?.split(';')[0] ?? 'application/octet-stream'
  const localPath = path.join(DOWNLOADS, SOURCE_BUCKET, objectPath)
  await mkdir(path.dirname(localPath), { recursive: true })
  await writeFile(localPath, bytes, { mode: 0o600 })
  downloaded++
  if (downloaded % 20 === 0 || downloaded === sourcePaths.length) console.log(`source ${downloaded}/${sourcePaths.length}`)
  return { sourceBucket: SOURCE_BUCKET, sourcePath: objectPath, destinationKey: `${SOURCE_BUCKET}/${objectPath}`, size: bytes.length, contentType, sha256: sha256(bytes), status: 'SOURCE_VERIFIED' }
}))

const sourceBytes = manifest.reduce((sum, item) => sum + item.size, 0)
const canary = manifest.find((item) => item.destinationKey === CANARY_KEY)
if (!canary) throw new Error('Verified canary is absent from current Supabase source')
const canaryResponse = await fetch(`${PUBLIC_BASE}/${encoded(CANARY_KEY)}`, { redirect: 'manual' })
const canaryBytes = Buffer.from(await canaryResponse.arrayBuffer())
if (canaryResponse.status !== 200 || canaryBytes.length !== canary.size || sha256(canaryBytes) !== canary.sha256) {
  throw new Error('Existing production canary does not match current Supabase source')
}
canary.status = 'VERIFIED_ALREADY_COPIED'
console.log(`inventory ${manifest.length} objects / ${sourceBytes} bytes; canary verified`)

let copied = 0
const uploadFailures = []
await mapLimit(manifest.filter((item) => item.destinationKey !== CANARY_KEY), 4, async (item) => {
  const localPath = path.join(DOWNLOADS, item.sourceBucket, item.sourcePath)
  try {
    await retry(`upload ${item.destinationKey}`, async () => {
      await execFileAsync('npx', ['wrangler', 'r2', 'object', 'put', `${TARGET_BUCKET}/${item.destinationKey}`,
        '--file', localPath, '--content-type', item.contentType, '--cache-control', CACHE_CONTROL, '--remote'],
      { cwd: ROOT, env: childEnv, maxBuffer: 1024 * 1024 })
    })
    item.status = 'UPLOADED'
    copied++
    if (copied % 10 === 0 || copied === manifest.length - 1) console.log(`uploaded ${copied}/${manifest.length - 1}`)
  } catch (error) {
    item.status = 'UPLOAD_FAILED'
    uploadFailures.push({ key: item.destinationKey, error: error.message })
  }
})

let verified = 0
const verificationFailures = []
await mapLimit(manifest.filter((item) => item.status !== 'UPLOAD_FAILED'), 4, async (item) => {
  const outPath = path.join(READBACKS, item.destinationKey)
  await mkdir(path.dirname(outPath), { recursive: true })
  try {
    await retry(`readback ${item.destinationKey}`, async () => {
      await execFileAsync('npx', ['wrangler', 'r2', 'object', 'get', `${TARGET_BUCKET}/${item.destinationKey}`, '--file', outPath, '--remote'],
        { cwd: ROOT, env: childEnv, maxBuffer: 1024 * 1024 })
    })
    const bytes = await readFile(outPath)
    item.r2Size = bytes.length
    item.r2Sha256 = sha256(bytes)
    item.sizeMatch = item.r2Size === item.size
    item.hashMatch = item.r2Sha256 === item.sha256
    if (!item.sizeMatch || !item.hashMatch) throw new Error('size/hash mismatch')
    item.status = item.destinationKey === CANARY_KEY ? 'VERIFIED_ALREADY_COPIED' : 'COPIED_AND_VERIFIED'
    verified++
    if (verified % 10 === 0 || verified === manifest.length) console.log(`readback ${verified}/${manifest.length}`)
  } catch (error) {
    item.status = 'READBACK_FAILED'
    verificationFailures.push({ key: item.destinationKey, error: error.message })
  }
})

const samples = [canary, [...manifest].sort((a, b) => a.size - b.size)[0], [...manifest].sort((a, b) => b.size - a.size)[0], manifest.find((x) => x.sourcePath.includes('/logos/')), manifest[Math.floor(manifest.length / 2)]]
  .filter((item, index, all) => item && all.findIndex((x) => x.destinationKey === item.destinationKey) === index)
const publicSamples = []
for (const item of samples) {
  const response = await fetch(`${PUBLIC_BASE}/${encoded(item.destinationKey)}`, { redirect: 'manual' })
  const bytes = Buffer.from(await response.arrayBuffer())
  publicSamples.push({ key: item.destinationKey, httpStatus: response.status, redirect: response.headers.get('location'), contentType: response.headers.get('content-type')?.split(';')[0] ?? null, cacheControl: response.headers.get('cache-control'), etag: response.headers.get('etag'), size: bytes.length, sizeMatch: bytes.length === item.size, hashMatch: sha256(bytes) === item.sha256, status: response.status === 200 && bytes.length === item.size && sha256(bytes) === item.sha256 ? 'PASS' : 'FAIL' })
}

let rollbackVerified = 0
const rollbackFailures = []
await mapLimit(manifest, 6, async (item) => {
  try {
    await retry(`rollback ${item.sourcePath}`, async () => {
      const response = await fetch(`${owner.VITE_SUPABASE_URL}/storage/v1/object/public/${SOURCE_BUCKET}/${encoded(item.sourcePath)}`)
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      const bytes = Buffer.from(await response.arrayBuffer())
      if (bytes.length !== item.size || sha256(bytes) !== item.sha256) throw new Error('size/hash mismatch')
    })
    rollbackVerified++
    if (rollbackVerified % 20 === 0 || rollbackVerified === manifest.length) console.log(`rollback ${rollbackVerified}/${manifest.length}`)
  } catch (error) { rollbackFailures.push({ path: item.sourcePath, error: error.message }) }
})

let bucketInfo = null
try {
  const { stdout } = await execFileAsync('npx', ['wrangler', 'r2', 'bucket', 'info', TARGET_BUCKET, '--json'], { cwd: ROOT, env: childEnv, maxBuffer: 1024 * 1024 })
  bucketInfo = JSON.parse(stdout.slice(stdout.indexOf('{')))
} catch { bucketInfo = { object_count: 'NOT_AVAILABLE', bucket_size: 'NOT_AVAILABLE' } }

const report = {
  generatedAt: new Date().toISOString(), source: { bucket: SOURCE_BUCKET, count: manifest.length, bytes: sourceBytes },
  destination: { accountId: ACCOUNT_ID, bucket: TARGET_BUCKET, publicBase: PUBLIC_BASE, reportedObjectCount: bucketInfo.object_count, reportedBucketSize: bucketInfo.bucket_size },
  cachePolicy: CACHE_CONTROL, immutableKeyBasis: 'UUID filename; normal replacement creates a new UUID key',
  alreadyVerifiedCanary: 1, newObjectsCopied: copied, successful: manifest.filter((x) => ['VERIFIED_ALREADY_COPIED', 'COPIED_AND_VERIFIED'].includes(x.status)).length,
  failed: uploadFailures.length + verificationFailures.length, uploadFailures, verificationFailures,
  publicSamples, rollback: { verified: rollbackVerified, failures: rollbackFailures },
  safety: { databaseModified: false, qrModified: false, stagingModified: false, deploymentPerformed: false, clientNetworkTest: 'NOT PERFORMED — ACCEPTED FOR TONIGHT\'S COPY' },
  objects: manifest,
}
await writeFile(path.join(OUTPUT, 'production-r2-copy-manifest.json'), `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 })
console.log(JSON.stringify({ output: OUTPUT, sourceCount: manifest.length, sourceBytes, canary: 1, copied, successful: report.successful, failed: report.failed, publicSamples: publicSamples.map((x) => x.status), rollbackVerified, rollbackFailed: rollbackFailures.length, bucketInfo }, null, 2))
if (report.failed || rollbackFailures.length || publicSamples.some((x) => x.status !== 'PASS')) process.exitCode = 1
