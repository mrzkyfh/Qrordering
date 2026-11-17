import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import vm from 'node:vm'
import { webcrypto } from 'node:crypto'
import test from 'node:test'
import ts from 'typescript'

const source = readFileSync(new URL('../src/index.ts', import.meta.url), 'utf8')
const compiled = ts.transpileModule(source, {
  compilerOptions: {
    module: ts.ModuleKind.CommonJS,
    target: ts.ScriptTarget.ES2022,
  },
}).outputText

function loadWorker({ cacheDelete }) {
  const module = { exports: {} }
  const fetch = async (input) => {
    const url = String(input)
    if (url.includes('/auth/v1/user')) {
      return Response.json({ id: 'owner-1' })
    }
    if (url.includes('/rest/v1/profiles')) {
      return Response.json([
        {
          id: 'owner-1',
          role: 'owner',
          outlet_id: null,
          is_active: true,
        },
      ])
    }
    throw new Error(`Unexpected fetch: ${url}`)
  }
  vm.runInNewContext(compiled, {
    module,
    exports: module.exports,
    URL,
    Request,
    Response,
    Headers,
    fetch,
    crypto: webcrypto,
    caches: {
      default: {
        delete: cacheDelete,
        match: async () => undefined,
        put: async () => undefined,
      },
    },
  })
  return module.exports.default
}

const outletId = '849aada5-8e64-4e1e-b5f4-5d626b44739e'
const key = `menu-images/${outletId}/menu/29ae5ef5-a833-4f97-a57a-00e547f57a35.png`
const stagingEnv = {
  ENVIRONMENT: 'staging',
  R2_BUCKET_NAME: 'qrordering-assets-staging',
  PUBLIC_ASSET_BASE_URL: 'https://qrordering-r2-staging.official-b0d.workers.dev',
}

test('DELETE removes the R2 object and its canonical public cache entry', async () => {
  const deletedR2 = []
  const deletedCache = []
  const worker = loadWorker({
    cacheDelete: async (request) => {
      deletedCache.push(request.url)
      return true
    },
  })
  const response = await worker.fetch(
    new Request(
      `https://assets.example/v1/images?key=${encodeURIComponent(key)}`,
      { method: 'DELETE', headers: { Authorization: 'Bearer token' } },
    ),
    {
      IMAGES: {
        head: async () => ({ customMetadata: { outletId } }),
        delete: async (value) => deletedR2.push(value),
      },
      SUPABASE_URL: 'https://supabase.example',
      SUPABASE_ANON_KEY: 'anon-key',
      ...stagingEnv,
    },
    { waitUntil() {} },
  )

  assert.equal(response.status, 200)
  assert.deepEqual(deletedR2, [key])
  assert.deepEqual(deletedCache, [`https://assets.example/assets/${key}`])
})

test('retry still clears cache when the R2 object is already absent', async () => {
  const deletedCache = []
  const worker = loadWorker({
    cacheDelete: async (request) => {
      deletedCache.push(request.url)
      return true
    },
  })
  const response = await worker.fetch(
    new Request(
      `https://assets.example/v1/images?key=${encodeURIComponent(key)}`,
      { method: 'DELETE', headers: { Authorization: 'Bearer token' } },
    ),
    {
      IMAGES: {
        head: async () => null,
        delete: async () => assert.fail('R2 delete must not run'),
      },
      SUPABASE_URL: 'https://supabase.example',
      SUPABASE_ANON_KEY: 'anon-key',
      ...stagingEnv,
    },
    { waitUntil() {} },
  )

  assert.equal(response.status, 200)
  assert.deepEqual(deletedCache, [`https://assets.example/assets/${key}`])
})

test('missing public asset returns a non-cacheable cross-origin 404', async () => {
  const worker = loadWorker({ cacheDelete: async () => false })
  const response = await worker.fetch(
    new Request(`https://assets.example/assets/${key}`),
    {
      IMAGES: {
        get: async () => null,
      },
    },
    { waitUntil() {} },
  )

  assert.equal(response.status, 404)
  assert.equal(response.headers.get('cache-control'), 'no-store')
  assert.equal(response.headers.get('access-control-allow-origin'), '*')
  assert.equal(response.headers.get('x-content-type-options'), 'nosniff')
})

test('invalid public asset key uses the same non-cacheable 404 response', async () => {
  const worker = loadWorker({ cacheDelete: async () => false })
  const response = await worker.fetch(
    new Request('https://assets.example/assets/%2E%2E%2Finvalid.png'),
    { IMAGES: {} },
    { waitUntil() {} },
  )

  assert.equal(response.status, 404)
  assert.equal(response.headers.get('cache-control'), 'no-store')
  assert.equal(response.headers.get('access-control-allow-origin'), '*')
})
