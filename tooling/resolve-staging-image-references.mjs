import { createHash } from 'node:crypto'
import { execFile, spawn } from 'node:child_process'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)
const root = process.cwd()
const accountId = '4e5b204f44bdff9f75eda4c3e99ee098'
const bucket = 'qrordering-assets'
const productionBase = 'https://assets.qrordering.my.id'
const stagingHost = 'pub-03e9996cd3b549a4b55663ff7ec18251.r2.dev'
const runId = new Date().toISOString().replaceAll(':', '').replaceAll('-', '').replace(/\.\d{3}Z$/, 'Z')
const outputDir = path.join(root, 'backups', `resolve-staging-images-${runId}`)

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

function runWrangler(args, env) {
  return new Promise((resolve, reject) => {
    const child = spawn('npx', ['wrangler', ...args], {
      cwd: path.join(root, 'apps/assets-worker'), env, stdio: ['ignore', 'ignore', 'pipe'],
    })
    let stderr = ''
    child.stderr.on('data', (value) => { stderr += value })
    child.on('close', (code) => code === 0 ? resolve() : reject(new Error(stderr.slice(-500))))
  })
}

const owner = parseEnv(await readFile(path.join(root, 'apps/owner-panel/.env'), 'utf8'))
const cloudflare = parseEnv(await readFile(path.join(root, '.env.cloudflare-production'), 'utf8'))
if (!owner.VITE_SUPABASE_URL || !owner.VITE_SUPABASE_ANON_KEY || !cloudflare.CLOUDFLARE_API_TOKEN) {
  throw new Error('Required local configuration is missing')
}
const headers = { apikey: owner.VITE_SUPABASE_ANON_KEY, Authorization: `Bearer ${owner.VITE_SUPABASE_ANON_KEY}` }
const cfEnv = { ...process.env, CLOUDFLARE_API_TOKEN: cloudflare.CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID: accountId }
await mkdir(outputDir, { recursive: true })

const columns = 'id,name,outlet_id,image_url,updated_at'
const query = `${owner.VITE_SUPABASE_URL}/rest/v1/menu_items?select=${columns}&image_url=not.is.null&order=id.asc`
const dbResponse = await fetch(query, { headers })
if (!dbResponse.ok) throw new Error(`Database audit failed: HTTP ${dbResponse.status}`)
const allRows = await dbResponse.json()
const rows = allRows.filter((row) => {
  try { return new URL(row.image_url).hostname === stagingHost } catch { return false }
})
if (rows.length !== 2) throw new Error(`Guard failed: expected exactly 2 staging rows, found ${rows.length}`)

const results = []
for (const [index, row] of rows.entries()) {
  const stagingUrl = new URL(row.image_url)
  const key = decodeURIComponent(stagingUrl.pathname.replace(/^\//, ''))
  if (!key.startsWith('menu-images/')) throw new Error(`Unsafe object key for row ${row.id}`)
  const sourceResponse = await fetch(stagingUrl, { redirect: 'manual' })
  if (sourceResponse.status !== 200) throw new Error(`Staging read failed for row ${row.id}: HTTP ${sourceResponse.status}`)
  const sourceBytes = Buffer.from(await sourceResponse.arrayBuffer())
  const sourceHash = sha256(sourceBytes)
  const sourcePath = path.join(outputDir, `source-${index}`)
  const productionPath = path.join(outputDir, `production-${index}`)
  await writeFile(sourcePath, sourceBytes, { mode: 0o600 })

  let productionExists = true
  let productionBytes
  try {
    await runWrangler(['r2', 'object', 'get', `${bucket}/${key}`, '--file', productionPath, '--remote'], cfEnv)
    productionBytes = await readFile(productionPath)
  } catch {
    productionExists = false
  }
  if (productionExists && sha256(productionBytes) !== sourceHash) {
    throw new Error(`COLLISION for ${key}: staging=${sourceHash}, production=${sha256(productionBytes)}`)
  }
  let promoted = false
  if (!productionExists) {
    const contentType = sourceResponse.headers.get('content-type')?.split(';')[0] || 'application/octet-stream'
    await runWrangler(['r2', 'object', 'put', `${bucket}/${key}`, '--file', sourcePath,
      '--content-type', contentType, '--cache-control', 'public, max-age=31536000, immutable', '--remote'], cfEnv)
    promoted = true
  }
  await runWrangler(['r2', 'object', 'get', `${bucket}/${key}`, '--file', productionPath, '--remote'], cfEnv)
  productionBytes = await readFile(productionPath)
  const productionUrl = `${productionBase}/${key.split('/').map(encodeURIComponent).join('/')}`
  const publicResponse = await fetch(productionUrl, { redirect: 'manual' })
  const publicBytes = Buffer.from(await publicResponse.arrayBuffer())
  results.push({
    row, key, staging: { status: sourceResponse.status, size: sourceBytes.length,
      contentType: sourceResponse.headers.get('content-type')?.split(';')[0], sha256: sourceHash },
    productionBefore: productionExists ? 'identical' : 'missing', promoted,
    production: { url: productionUrl, status: publicResponse.status,
      contentType: publicResponse.headers.get('content-type')?.split(';')[0], size: productionBytes.length,
      sha256: sha256(productionBytes), authenticatedMatch: sha256(productionBytes) === sourceHash,
      publicSize: publicBytes.length, publicSha256: sha256(publicBytes), publicMatch: sha256(publicBytes) === sourceHash },
  })
}

const { stdout: infoOut } = await execFileAsync('npx', ['wrangler', 'r2', 'bucket', 'info', bucket, '--json'], {
  cwd: path.join(root, 'apps/assets-worker'), env: cfEnv, maxBuffer: 1024 * 1024,
})
const bucketInfo = JSON.parse(infoOut.slice(infoOut.indexOf('{')))
const report = { generatedAt: new Date().toISOString(), rows: results, productionBucket: {
  objectCount: Number(bucketInfo.object_count), totalBytes: Number(bucketInfo.total_size),
}, databaseUpdated: false }
const reportPath = path.join(outputDir, 'promotion-report.json')
await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 })
console.log(JSON.stringify({ reportPath, rows: results, productionBucket: report.productionBucket }, null, 2))
