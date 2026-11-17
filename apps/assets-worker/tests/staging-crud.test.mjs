import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import vm from 'node:vm'
import { webcrypto } from 'node:crypto'
import test from 'node:test'
import ts from 'typescript'

const source = readFileSync(new URL('../src/index.ts', import.meta.url), 'utf8')
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
}).outputText

const ownerId = 'owner-1'
const outletA = '849aada5-8e64-4e1e-b5f4-5d626b44739e'
const outletB = '19c1ef33-ccea-4aa7-b6a6-12ce0e134ed8'
const staging = {
  ENVIRONMENT: 'staging',
  R2_BUCKET_NAME: 'time420s-assets-staging',
  PUBLIC_ASSET_BASE_URL: 'https://time420s-r2-staging.official-b0d.workers.dev',
  SUPABASE_URL: 'https://supabase.example',
  SUPABASE_ANON_KEY: 'anon-key',
}
const production = {
  ENVIRONMENT: 'production',
  R2_BUCKET_NAME: 'time420s-assets',
  PUBLIC_ASSET_BASE_URL: 'https://assets.time420s.my.id',
  SUPABASE_URL: 'https://supabase.example',
  SUPABASE_ANON_KEY: 'anon-key',
}

function loadWorker({ role = 'owner', profileOutletId = null } = {}) {
  const module = { exports: {} }
  const fetch = async (input, init = {}) => {
    const url = String(input)
    const authorization = new Headers(init.headers).get('Authorization')
    if (authorization !== 'Bearer valid-token') return new Response(null, { status: 401 })
    if (url.includes('/auth/v1/user')) return Response.json({ id: ownerId })
    if (url.includes('/rest/v1/profiles')) {
      return Response.json([{ id: ownerId, role, outlet_id: profileOutletId, is_active: true }])
    }
    throw new Error(`Unexpected fetch: ${url}`)
  }
  vm.runInNewContext(compiled, {
    module, exports: module.exports, URL, Request, Response, Headers, fetch,
    crypto: webcrypto,
    caches: { default: { delete: async () => true, match: async () => undefined, put: async () => undefined } },
  })
  return module.exports.default
}

function memoryBucket(initial = new Map()) {
  const objects = new Map(initial)
  return {
    objects,
    put: async (key, value, options) => objects.set(key, { bytes: Buffer.from(value), ...options }),
    head: async (key) => {
      const item = objects.get(key)
      return item ? { key, customMetadata: item.customMetadata ?? {} } : null
    },
    delete: async (value) => {
      for (const key of Array.isArray(value) ? value : [value]) objects.delete(key)
    },
    list: async ({ prefix, cursor }) => {
      const keys = [...objects.keys()].filter((key) => key.startsWith(prefix)).sort()
      const eligible = cursor ? keys.filter((key) => key > cursor) : keys
      const page = eligible.slice(0, 2)
      return { objects: page.map((key) => ({ key })), truncated: eligible.length > page.length, cursor: eligible.length > page.length ? page.at(-1) : undefined }
    },
  }
}

const context = { waitUntil() {} }
const auth = { Authorization: 'Bearer valid-token' }

test('upload requires authentication and emits staging namespace/public URL', async () => {
  const worker = loadWorker()
  const bucket = memoryBucket()
  const base = { ...staging, IMAGES: bucket }
  const unauthenticated = await worker.fetch(new Request('https://worker.test/v1/images', {
    method: 'POST', headers: { 'Content-Type': 'image/webp', 'X-Outlet-Id': outletA }, body: new Uint8Array([1, 2, 3]),
  }), base, context)
  assert.equal(unauthenticated.status, 401)
  assert.equal(bucket.objects.size, 0)

  const response = await worker.fetch(new Request('https://worker.test/v1/images', {
    method: 'POST', headers: { ...auth, 'Content-Type': 'image/webp', 'X-Outlet-Id': outletA, 'X-Asset-Scope': 'menu' }, body: new Uint8Array([1, 2, 3]),
  }), base, context)
  assert.equal(response.status, 201)
  const body = await response.json()
  assert.match(body.key, new RegExp(`^menu-images/${outletA}/menu/[0-9a-f-]{36}\\.webp$`, 'i'))
  assert.equal(body.url, `${staging.PUBLIC_ASSET_BASE_URL}/assets/${body.key}`)
  assert.deepEqual([...bucket.objects.get(body.key).bytes], [1, 2, 3])
})

test('wrong bucket/config guard fails closed before authentication or write', async () => {
  const worker = loadWorker()
  const bucket = memoryBucket()
  const response = await worker.fetch(new Request('https://worker.test/v1/images', {
    method: 'POST', headers: { ...auth, 'Content-Type': 'image/webp', 'X-Outlet-Id': outletA }, body: new Uint8Array([1]),
  }), { ...staging, R2_BUCKET_NAME: 'time420s-assets', IMAGES: bucket }, context)
  assert.equal(response.status, 503)
  assert.equal(bucket.objects.size, 0)
})

test('production guard emits assets.time420s.my.id URL and rejects staging bucket', async () => {
  const worker = loadWorker()
  const bucket = memoryBucket()
  const request = () => new Request('https://worker.test/v1/images', {
    method: 'POST', headers: { ...auth, 'Content-Type': 'image/webp', 'X-Outlet-Id': outletA }, body: new Uint8Array([1]),
  })
  const response = await worker.fetch(request(), { ...production, IMAGES: bucket }, context)
  assert.equal(response.status, 201)
  assert.match((await response.json()).url, /^https:\/\/assets\.time420s\.my\.id\/assets\/menu-images\//)

  const rejected = await worker.fetch(request(), { ...production, R2_BUCKET_NAME: 'time420s-assets-staging', IMAGES: bucket }, context)
  assert.equal(rejected.status, 503)
})

test('public Worker route never exposes transaction archive keys', async () => {
  const worker = loadWorker()
  let reads = 0
  const response = await worker.fetch(
    new Request('https://worker.test/assets/transaction-archives/outlet/archive.json'),
    { ...staging, IMAGES: { get: async () => { reads++; return null } } },
    context,
  )
  assert.equal(response.status, 404)
  assert.equal(reads, 0)
})

test('legacy root image URL remains readable after the public /assets cutover', async () => {
  const worker = loadWorker()
  const key = `menu-images/${outletA}/menu/22222222-2222-4222-8222-222222222222.webp`
  let requestedKey
  const response = await worker.fetch(
    new Request(`https://worker.test/${key}`),
    { ...staging, IMAGES: { get: async (value) => {
      requestedKey = value
      return {
        body: new Uint8Array([1, 2, 3]),
        httpEtag: '"etag"',
        writeHttpMetadata(headers) { headers.set('Content-Type', 'image/webp') },
      }
    } } },
    context,
  )
  assert.equal(response.status, 200)
  assert.equal(requestedKey, key)
  assert.equal(response.headers.get('Content-Type'), 'image/webp')
})

test('delete rejects unauthenticated, traversal, malformed, and cross-outlet keys', async () => {
  const worker = loadWorker({ role: 'manajer', profileOutletId: outletA })
  const validB = `menu-images/${outletB}/menu/29ae5ef5-a833-4f97-a57a-00e547f57a35.webp`
  const bucket = memoryBucket(new Map([[validB, { bytes: Buffer.from([1]) }]]))
  const env = { ...staging, IMAGES: bucket }
  const unauth = await worker.fetch(new Request(`https://worker.test/v1/images?key=${encodeURIComponent(validB)}`, { method: 'DELETE' }), env, context)
  assert.equal(unauth.status, 401)
  const traversal = await worker.fetch(new Request('https://worker.test/v1/images?key=menu-images%2F..%2Fsecret.webp', { method: 'DELETE', headers: auth }), env, context)
  assert.equal(traversal.status, 400)
  const malformed = await worker.fetch(new Request(`https://worker.test/v1/images?key=${encodeURIComponent(`menu-images/${outletB}/other/file.webp`)}`, { method: 'DELETE', headers: auth }), env, context)
  assert.equal(malformed.status, 400)
  const crossOutlet = await worker.fetch(new Request(`https://worker.test/v1/images?key=${encodeURIComponent(validB)}`, { method: 'DELETE', headers: auth }), env, context)
  assert.equal(crossOutlet.status, 403)
  assert.equal(bucket.objects.has(validB), true)
})

test('delete is idempotent for a valid authorized key', async () => {
  const worker = loadWorker({ role: 'manajer', profileOutletId: outletA })
  const key = `menu-images/${outletA}/logos/29ae5ef5-a833-4f97-a57a-00e547f57a35.webp`
  const bucket = memoryBucket(new Map([[key, { bytes: Buffer.from([1]) }]]))
  const env = { ...staging, IMAGES: bucket }
  for (let attempt = 0; attempt < 2; attempt++) {
    const response = await worker.fetch(new Request(`https://worker.test/v1/images?key=${encodeURIComponent(key)}`, { method: 'DELETE', headers: auth }), env, context)
    assert.equal(response.status, 200)
  }
  assert.equal(bucket.objects.size, 0)
})

test('immutable replacement uploads a new UUID key before deleting the old key', async () => {
  const worker = loadWorker()
  const oldKey = `menu-images/${outletA}/menu/11111111-1111-4111-8111-111111111111.webp`
  const bucket = memoryBucket(new Map([[oldKey, { bytes: Buffer.from([1]) }]]))
  const env = { ...staging, IMAGES: bucket }
  const upload = await worker.fetch(new Request('https://worker.test/v1/images', {
    method: 'POST', headers: { ...auth, 'Content-Type': 'image/webp', 'X-Outlet-Id': outletA, 'X-Asset-Scope': 'menu' }, body: new Uint8Array([9, 8, 7]),
  }), env, context)
  assert.equal(upload.status, 201)
  const replacement = await upload.json()
  assert.notEqual(replacement.key, oldKey)
  assert.equal(bucket.objects.has(oldKey), true)
  assert.equal(bucket.objects.has(replacement.key), true)
  const removeOld = await worker.fetch(new Request(`https://worker.test/v1/images?key=${encodeURIComponent(oldKey)}`, { method: 'DELETE', headers: auth }), env, context)
  assert.equal(removeOld.status, 200)
  assert.equal(bucket.objects.has(oldKey), false)
  assert.equal(bucket.objects.has(replacement.key), true)
})

test('receipt logo upload and delete use the isolated logos namespace', async () => {
  const worker = loadWorker()
  const bucket = memoryBucket()
  const env = { ...staging, IMAGES: bucket }
  const upload = await worker.fetch(new Request('https://worker.test/v1/images', {
    method: 'POST', headers: { ...auth, 'Content-Type': 'image/webp', 'X-Outlet-Id': outletA, 'X-Asset-Scope': 'logos' }, body: new Uint8Array([4, 2, 0]),
  }), env, context)
  assert.equal(upload.status, 201)
  const logo = await upload.json()
  assert.match(logo.key, new RegExp(`^menu-images/${outletA}/logos/`))
  const remove = await worker.fetch(new Request(`https://worker.test/v1/images?key=${encodeURIComponent(logo.key)}`, { method: 'DELETE', headers: auth }), env, context)
  assert.equal(remove.status, 200)
  assert.equal(bucket.objects.size, 0)
})

test('broad outlet-prefix cleanup route is not exposed', async () => {
  const worker = loadWorker()
  const key = `menu-images/${outletA}/menu/11111111-1111-4111-8111-111111111111.webp`
  const bucket = memoryBucket(new Map([[key, { bytes: Buffer.from([1]) }]]))
  const response = await worker.fetch(new Request(`https://worker.test/v1/outlets/${outletA}/assets`, { method: 'DELETE', headers: auth }), { ...production, IMAGES: bucket }, context)
  assert.equal(response.status, 404)
  assert.equal(bucket.objects.has(key), true)
})
