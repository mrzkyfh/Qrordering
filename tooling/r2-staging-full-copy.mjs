import { createHash, createHmac } from 'node:crypto'
import { readFile, stat, writeFile } from 'node:fs/promises'
import path from 'node:path'

const EXPECTED_BUCKET = 'time420s-assets-staging'
const FORBIDDEN_BUCKET = 'time420s-assets'
const EXPECTED_COUNT = 127
const EXPECTED_BYTES = 5195078

function loadEnv(text) {
  return Object.fromEntries(
    text.split(/\r?\n/).map((line) => line.trim())
      .filter((line) => line && !line.startsWith('#') && line.includes('='))
      .map((line) => {
        const normalized = line.startsWith('export ') ? line.slice(7).trim() : line
        const at = normalized.indexOf('=')
        return [normalized.slice(0, at).trim(), normalized.slice(at + 1).trim().replace(/^(['"])(.*)\1$/, '$2')]
      }),
  )
}

const sha256 = (value) => createHash('sha256').update(value).digest('hex')
const hmac = (key, value) => createHmac('sha256', key).update(value).digest()
const encodedPath = (key) => key.split('/').map(encodeURIComponent).join('/')

function signer(env) {
  const endpoint = new URL(env.R2_ENDPOINT)
  if (endpoint.protocol !== 'https:') throw new Error('R2_ENDPOINT must use HTTPS')
  if (!/^[a-f0-9]+\.r2\.cloudflarestorage\.com$/i.test(endpoint.hostname)) {
    throw new Error('R2_ENDPOINT is not a Cloudflare R2 endpoint')
  }
  return async function signedFetch(method, key = '', body = null, extraHeaders = {}, query = {}) {
    const now = new Date()
    const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, '')
    const date = amzDate.slice(0, 8)
    const payload = body ?? Buffer.alloc(0)
    const payloadHash = sha256(payload)
    const pathname = key
      ? `/${encodeURIComponent(env.R2_BUCKET)}/${encodedPath(key)}`
      : `/${encodeURIComponent(env.R2_BUCKET)}`
    const canonicalQuery = Object.entries(query).sort(([a], [b]) => a.localeCompare(b))
      .map(([name, value]) => `${encodeURIComponent(name)}=${encodeURIComponent(value)}`).join('&')
    const headers = { host: endpoint.host, 'x-amz-content-sha256': payloadHash, 'x-amz-date': amzDate, ...extraHeaders }
    const names = Object.keys(headers).map((name) => name.toLowerCase()).sort()
    const canonicalHeaders = names.map((name) => `${name}:${String(headers[name]).trim()}\n`).join('')
    const canonicalRequest = [method, pathname, canonicalQuery, canonicalHeaders, names.join(';'), payloadHash].join('\n')
    const scope = `${date}/auto/s3/aws4_request`
    const stringToSign = ['AWS4-HMAC-SHA256', amzDate, scope, sha256(canonicalRequest)].join('\n')
    const dateKey = hmac(`AWS4${env.R2_SECRET_ACCESS_KEY}`, date)
    const regionKey = hmac(dateKey, 'auto')
    const serviceKey = hmac(regionKey, 's3')
    const signingKey = hmac(serviceKey, 'aws4_request')
    const signature = createHmac('sha256', signingKey).update(stringToSign).digest('hex')
    const authorization = `AWS4-HMAC-SHA256 Credential=${env.R2_ACCESS_KEY_ID}/${scope}, SignedHeaders=${names.join(';')}, Signature=${signature}`
    const target = new URL(pathname, endpoint)
    for (const [name, value] of Object.entries(query)) target.searchParams.set(name, value)
    return fetch(target, { method, headers: { ...headers, Authorization: authorization }, body: method === 'PUT' ? payload : undefined })
  }
}

function xmlDecode(value) {
  return value.replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&apos;', "'").replaceAll('&amp;', '&')
}

async function listAll(request) {
  const objects = []
  let token
  do {
    const query = { 'list-type': '2' }
    if (token) query['continuation-token'] = token
    const response = await request('GET', '', null, {}, query)
    if (!response.ok) throw new Error(`Bucket listing failed: HTTP ${response.status}`)
    const xml = await response.text()
    for (const match of xml.matchAll(/<Contents>([\s\S]*?)<\/Contents>/g)) {
      const key = match[1].match(/<Key>([\s\S]*?)<\/Key>/)?.[1]
      const size = match[1].match(/<Size>(\d+)<\/Size>/)?.[1]
      if (key != null && size != null) objects.push({ key: xmlDecode(key), size: Number(size) })
    }
    token = xml.match(/<NextContinuationToken>([\s\S]*?)<\/NextContinuationToken>/)?.[1]
    if (token) token = xmlDecode(token)
  } while (token)
  return objects.sort((a, b) => a.key.localeCompare(b.key))
}

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

const envFile = process.argv[2] ?? '.env.r2-staging'
const backupRoot = process.argv[3] ?? 'backups/r2-pre-migration-20261008-231330'
const env = loadEnv(await readFile(envFile, 'utf8'))
const required = ['R2_ACCESS_KEY_ID', 'R2_SECRET_ACCESS_KEY', 'R2_ENDPOINT', 'R2_BUCKET']
const missingEnv = required.filter((name) => !env[name])
if (missingEnv.length) throw new Error(`Missing required variables: ${missingEnv.join(', ')}`)
if (env.R2_BUCKET !== EXPECTED_BUCKET || env.R2_BUCKET === FORBIDDEN_BUCKET) {
  throw new Error(`Bucket guard rejected target; expected exactly ${EXPECTED_BUCKET}`)
}

const manifestPath = path.join(backupRoot, 'manifest.json')
const reportPath = path.join(backupRoot, 'r2-staging-copy-report.json')
const manifest = JSON.parse(await readFile(manifestPath, 'utf8'))
const seenKeys = new Set()
let sourceBytes = 0
const prepared = []
for (const entry of manifest) {
  const key = `${entry.bucket}/${entry.objectPath}`
  if (seenKeys.has(key)) throw new Error(`Duplicate deterministic key: ${key}`)
  seenKeys.add(key)
  const localPath = path.join(backupRoot, entry.localPath)
  const info = await stat(localPath)
  const bytes = await readFile(localPath)
  const digest = sha256(bytes)
  if (info.size !== entry.size || info.size !== entry.remoteSize) throw new Error(`Source size mismatch: ${entry.localPath}`)
  if (digest !== entry.sha256) throw new Error(`Source SHA-256 mismatch: ${entry.localPath}`)
  sourceBytes += info.size
  prepared.push({ entry, key, localPath, bytes, digest })
}
if (manifest.length !== EXPECTED_COUNT || sourceBytes !== EXPECTED_BYTES) {
  throw new Error(`Source guard rejected: count=${manifest.length}, bytes=${sourceBytes}`)
}

const request = signer(env)
const baseline = await listAll(request)
if (baseline.length !== 0) {
  throw new Error(`Staging bucket is not clean; found ${baseline.length} unexpected object(s): ${baseline.map((x) => x.key).join(', ')}`)
}

console.log(`target bucket guard=PASS (${EXPECTED_BUCKET})`)
console.log(`source validation=PASS (${manifest.length} objects, ${sourceBytes} bytes)`)
console.log('staging baseline=PASS (0 objects)')

const startedAt = new Date().toISOString()
const uploadRecords = await mapLimit(prepared, 6, async (item) => {
  const response = await request('PUT', item.key, item.bytes, { 'content-type': item.entry.contentType || 'application/octet-stream' })
  if (!response.ok) throw new Error(`Upload failed: ${item.key}, HTTP ${response.status}`)
  return {
    sourcePath: item.entry.localPath,
    r2Key: item.key,
    byteSize: item.bytes.length,
    localSha256: item.digest,
    uploadStatus: 'PASS',
  }
})
console.log(`uploads=PASS (${uploadRecords.length}/${EXPECTED_COUNT})`)

const remote = await listAll(request)
const expectedByKey = new Map(prepared.map((item) => [item.key, item]))
const remoteByKey = new Map(remote.map((item) => [item.key, item]))
const missingR2 = prepared.filter((item) => !remoteByKey.has(item.key)).map((item) => item.key)
const unexpectedR2 = remote.filter((item) => !expectedByKey.has(item.key)).map((item) => item.key)
const sizeMismatches = prepared.filter((item) => remoteByKey.has(item.key) && remoteByKey.get(item.key).size !== item.bytes.length)
  .map((item) => ({ key: item.key, expected: item.bytes.length, actual: remoteByKey.get(item.key).size }))
const remoteBytes = remote.reduce((sum, item) => sum + item.size, 0)

if (remote.length !== EXPECTED_COUNT || remoteBytes !== EXPECTED_BYTES || missingR2.length || unexpectedR2.length || sizeMismatches.length) {
  throw new Error(`Post-upload inventory mismatch: count=${remote.length}, bytes=${remoteBytes}, missing=${missingR2.length}, unexpected=${unexpectedR2.length}, sizeMismatch=${sizeMismatches.length}`)
}
console.log(`inventory=PASS (${remote.length} objects, ${remoteBytes} bytes)`)

const verificationRecords = await mapLimit(prepared, 6, async (item) => {
  const response = await request('GET', item.key)
  if (!response.ok) throw new Error(`Verification GET failed: ${item.key}, HTTP ${response.status}`)
  const bytes = Buffer.from(await response.arrayBuffer())
  const digest = sha256(bytes)
  if (bytes.length !== item.bytes.length) throw new Error(`Verification size mismatch: ${item.key}`)
  if (digest !== item.digest) throw new Error(`Verification SHA-256 mismatch: ${item.key}`)
  return { r2Key: item.key, sizeVerification: 'PASS', sha256Verification: 'PASS' }
})
console.log(`full GET SHA-256 verification=PASS (${verificationRecords.length}/${EXPECTED_COUNT})`)

const logoPath = 'menu-images/d81e6a71-bb92-45b0-be88-cca026ed783e/logos/2928c880-a0a2-4f57-98d6-a1654e1266f3.webp'
const menuSamples = prepared.filter((item) => item.key.includes('/menu/'))
const sampleKeys = [menuSamples[0]?.key, logoPath, menuSamples.at(-1)?.key].filter(Boolean)
let publicRead = { enabled: false, status: 'NOT_CONFIGURED', samples: [] }
if (env.R2_PUBLIC_BASE_URL) {
  const base = new URL(env.R2_PUBLIC_BASE_URL.endsWith('/') ? env.R2_PUBLIC_BASE_URL : `${env.R2_PUBLIC_BASE_URL}/`)
  const samples = []
  for (const key of sampleKeys) {
    const expected = expectedByKey.get(key)
    const url = new URL(encodedPath(key), base)
    const response = await fetch(url)
    const bytes = Buffer.from(await response.arrayBuffer())
    const digest = sha256(bytes)
    const passed = response.ok && bytes.length > 0 && bytes.length === expected.bytes.length && digest === expected.digest
    samples.push({ key, httpStatus: response.status, bytes: bytes.length, sha256Matches: digest === expected.digest, status: passed ? 'PASS' : 'FAIL' })
  }
  publicRead = { enabled: true, status: samples.every((x) => x.status === 'PASS') ? 'PASS' : 'FAIL', samples }
}

const report = {
  startedAt,
  completedAt: new Date().toISOString(),
  sourceManifest: manifestPath,
  targetBucket: EXPECTED_BUCKET,
  baselineObjectCount: baseline.length,
  source: { count: manifest.length, bytes: sourceBytes },
  target: { count: remote.length, bytes: remoteBytes },
  reconciliation: {
    missingR2Objects: missingR2,
    unexpectedR2Objects: unexpectedR2,
    sizeMismatches,
    sha256Mismatches: 0,
  },
  publicRead,
  objects: uploadRecords.map((upload, index) => ({ ...upload, ...verificationRecords[index] })),
  copyStatus: publicRead.status === 'PASS' ? 'R2 STAGING COPY VERIFIED' : 'R2 STAGING COPY CORE VERIFIED; PUBLIC READ NOT VERIFIED',
}
await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 })
console.log(`public read=${publicRead.status}`)
console.log(`report=${reportPath}`)
if (publicRead.status !== 'PASS') {
  throw new Error('Public-read verification did not pass; set R2_PUBLIC_BASE_URL to the enabled staging public origin and rerun verification')
}
console.log('R2 STAGING COPY VERIFIED')
