import { createHash, createHmac, randomUUID } from 'node:crypto'
import { readFile } from 'node:fs/promises'

const EXPECTED_BUCKET = 'qrordering-assets-staging'

function loadEnv(text) {
  return Object.fromEntries(
    text
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line && !line.startsWith('#') && line.includes('='))
      .map((line) => {
        const normalized = line.startsWith('export ') ? line.slice(7).trim() : line
        const at = normalized.indexOf('=')
        const key = normalized.slice(0, at).trim()
        const value = normalized
          .slice(at + 1)
          .trim()
          .replace(/^(['"])(.*)\1$/, '$2')
        return [key, value]
      }),
  )
}

const sha256 = (value) => createHash('sha256').update(value).digest('hex')
const hmac = (key, value) => createHmac('sha256', key).update(value).digest()

function encodedPath(key) {
  return key.split('/').map(encodeURIComponent).join('/')
}

function signer(env) {
  const endpoint = new URL(env.R2_ENDPOINT)
  if (endpoint.protocol !== 'https:') throw new Error('R2_ENDPOINT must use HTTPS')
  const accountMatch = endpoint.hostname.match(/^([a-f0-9]+)\.r2\.cloudflarestorage\.com$/i)
  if (!accountMatch) throw new Error('R2_ENDPOINT is not a Cloudflare R2 endpoint')

  return async function signedFetch(method, key, body = null, extraHeaders = {}, query = {}) {
    const now = new Date()
    const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, '')
    const date = amzDate.slice(0, 8)
    const payload = body ?? Buffer.alloc(0)
    const payloadHash = sha256(payload)
    const pathname = key
      ? `/${encodeURIComponent(env.R2_BUCKET)}/${encodedPath(key)}`
      : `/${encodeURIComponent(env.R2_BUCKET)}`
    const canonicalQuery = Object.entries(query)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([name, value]) => `${encodeURIComponent(name)}=${encodeURIComponent(value)}`)
      .join('&')
    const headers = {
      host: endpoint.host,
      'x-amz-content-sha256': payloadHash,
      'x-amz-date': amzDate,
      ...extraHeaders,
    }
    const signedHeaderNames = Object.keys(headers).map((name) => name.toLowerCase()).sort()
    const canonicalHeaders = signedHeaderNames.map((name) => `${name}:${String(headers[name]).trim()}\n`).join('')
    const canonicalRequest = [
      method,
      pathname,
      canonicalQuery,
      canonicalHeaders,
      signedHeaderNames.join(';'),
      payloadHash,
    ].join('\n')
    const scope = `${date}/auto/s3/aws4_request`
    const stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      scope,
      sha256(canonicalRequest),
    ].join('\n')
    const dateKey = hmac(`AWS4${env.R2_SECRET_ACCESS_KEY}`, date)
    const regionKey = hmac(dateKey, 'auto')
    const serviceKey = hmac(regionKey, 's3')
    const signingKey = hmac(serviceKey, 'aws4_request')
    const signature = createHmac('sha256', signingKey).update(stringToSign).digest('hex')
    const authorization =
      `AWS4-HMAC-SHA256 Credential=${env.R2_ACCESS_KEY_ID}/${scope}, ` +
      `SignedHeaders=${signedHeaderNames.join(';')}, Signature=${signature}`
    const target = new URL(pathname, endpoint)
    for (const [name, value] of Object.entries(query)) target.searchParams.set(name, value)
    return fetch(target, {
      method,
      headers: { ...headers, Authorization: authorization },
      body: method === 'PUT' ? payload : undefined,
    })
  }
}

const envFile = process.argv[2] ?? '.env.r2-staging'
const env = loadEnv(await readFile(envFile, 'utf8'))
const required = ['R2_ACCESS_KEY_ID', 'R2_SECRET_ACCESS_KEY', 'R2_ENDPOINT', 'R2_BUCKET']
const missing = required.filter((name) => !env[name])

console.log(`R2_BUCKET=${env.R2_BUCKET || 'NOT SET'}`)
console.log(`R2_ENDPOINT=${env.R2_ENDPOINT || 'NOT SET'}`)
console.log(`credential status=${missing.length === 0 ? 'SET' : 'NOT SET'}`)
if (missing.length) throw new Error(`Missing required variables: ${missing.join(', ')}`)
if (env.R2_BUCKET !== EXPECTED_BUCKET) {
  throw new Error(`Bucket guard rejected: expected ${EXPECTED_BUCKET}`)
}

const request = signer(env)
const key = `_preflight/${randomUUID()}.txt`
const payload = Buffer.from('QRORDERING R2 STAGING PREFLIGHT v1\n', 'utf8')
const expectedHash = sha256(payload)
let uploaded = false

try {
  const initialList = await request('GET', '', null, {}, { 'list-type': '2' })
  if (!initialList.ok) throw new Error(`Initial bucket listing failed: HTTP ${initialList.status}`)
  const initialState = Buffer.from(await initialList.arrayBuffer())

  const put = await request('PUT', key, payload, { 'content-type': 'text/plain; charset=utf-8' })
  if (!put.ok) throw new Error(`PUT failed: HTTP ${put.status}`)
  uploaded = true

  const head = await request('HEAD', key)
  if (!head.ok) throw new Error(`HEAD failed: HTTP ${head.status}`)
  const remoteLength = Number(head.headers.get('content-length'))
  if (remoteLength !== payload.length) {
    throw new Error(`HEAD size mismatch: expected ${payload.length}, got ${remoteLength}`)
  }

  const get = await request('GET', key)
  if (!get.ok) throw new Error(`GET failed: HTTP ${get.status}`)
  const downloaded = Buffer.from(await get.arrayBuffer())
  if (!downloaded.equals(payload)) throw new Error('Downloaded bytes differ')
  if (sha256(downloaded) !== expectedHash) throw new Error('Downloaded SHA-256 differs')

  const deleted = await request('DELETE', key)
  if (!deleted.ok && deleted.status !== 204) {
    throw new Error(`DELETE failed: HTTP ${deleted.status}`)
  }
  uploaded = false

  const missingObject = await request('HEAD', key)
  if (missingObject.status !== 404) {
    throw new Error(`Delete verification failed: expected HTTP 404, got ${missingObject.status}`)
  }

  const finalList = await request('GET', '', null, {}, { 'list-type': '2' })
  if (!finalList.ok) throw new Error(`Final bucket listing failed: HTTP ${finalList.status}`)
  const finalState = Buffer.from(await finalList.arrayBuffer())
  if (!finalState.equals(initialState)) {
    throw new Error('Bucket listing differs from its preflight baseline')
  }

  console.log('upload=PASS')
  console.log('head=PASS')
  console.log('read-bytes=PASS')
  console.log('sha256=PASS')
  console.log('delete=PASS')
  console.log('post-delete-head=404 PASS')
  console.log('bucket-baseline-restored=PASS')
} finally {
  if (uploaded) {
    const cleanup = await request('DELETE', key)
    console.log(`emergency-cleanup=${cleanup.ok || cleanup.status === 204 ? 'PASS' : 'FAILED'}`)
  }
}
