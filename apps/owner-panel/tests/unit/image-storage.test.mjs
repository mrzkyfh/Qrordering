import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import vm from 'node:vm'
import ts from 'typescript'

const outlet = '11111111-1111-4111-8111-111111111111'
const productionApi = 'https://qrordering-r2-production.official-b0d.workers.dev'
const productionPublic = 'https://assets.qrordering.my.id'
const stagingApi = 'https://qrordering-r2-staging.official-b0d.workers.dev'

function storageModule({ backend = '', uploadError = null, fetchImpl, stagingApiUrl = '' } = {}) {
  const calls = []
  const storage = {
    upload: async (...args) => { calls.push(['upload', ...args]); return { error: uploadError } },
    remove: async (paths) => { calls.push(['remove', paths]); return { error: null } },
    getPublicUrl: (path) => ({ data: { publicUrl: `https://gateway.example/storage/v1/object/public/menu-images/${path}` } }),
  }
  const env = {
    VITE_SUPABASE_URL: 'https://project.supabase.co',
    VITE_IMAGE_STORAGE_BACKEND: backend,
    VITE_R2_STAGING_API_URL: stagingApiUrl,
    VITE_R2_API_URL: productionApi,
  }
  let source = readFileSync(new URL('../../src/lib/imageStorage.ts', import.meta.url), 'utf8')
  for (const [key, value] of Object.entries(env)) source = source.replaceAll(`import.meta.env.${key}`, JSON.stringify(value))
  const code = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText
  const exports = {}
  vm.runInNewContext(code, {
    exports, URL, crypto, File,
    fetch: fetchImpl ?? (async () => { throw new Error('Unexpected fetch') }),
    require: () => ({ supabase: {
      auth: { getSession: async () => ({ data: { session: { access_token: 'session-token' } }, error: null }) },
      storage: { from: (bucket) => { assert.equal(bucket, 'menu-images'); return storage } },
    } }),
  })
  return { ...exports, calls }
}

test('staging upload uses the isolated official-account Worker', async () => {
  let requestUrl
  const key = `menu-images/${outlet}/menu/22222222-2222-4222-8222-222222222222.webp`
  const api = storageModule({
    backend: 'r2-staging',
    stagingApiUrl: stagingApi,
    fetchImpl: async (url) => {
      requestUrl = url
      return Response.json({ key, url: `${stagingApi}/assets/${key}` }, { status: 201 })
    },
  })
  assert.equal(
    await api.uploadImageAsset(new File(['image'], 'menu.webp', { type: 'image/webp' }), outlet),
    `${stagingApi}/assets/${key}`,
  )
  assert.equal(requestUrl, `${stagingApi}/v1/images`)
})

test('legacy mode uploads to Supabase with immutable UUID key', async () => {
  const api = storageModule()
  const url = await api.uploadImageAsset(new File(['image'], 'logo.png', { type: 'image/png' }), outlet, 'logos')
  assert.match(api.calls[0][1], new RegExp(`^${outlet}/logos/[0-9a-f-]{36}\\.png$`, 'i'))
  assert.equal(url, `https://project.supabase.co/storage/v1/object/public/menu-images/${api.calls[0][1]}`)
  assert.equal(api.calls[0][3].upsert, false)
})

test('production upload uses authenticated Worker and validates production public URL', async () => {
  let request
  const api = storageModule({ backend: 'r2-production', fetchImpl: async (url, init) => {
    request = { url, init }
    const key = `menu-images/${outlet}/menu/22222222-2222-4222-8222-222222222222.webp`
    return Response.json({ key, url: `${productionPublic}/assets/${key}` }, { status: 201 })
  } })
  const result = await api.uploadImageAsset(new File(['image'], 'menu.webp', { type: 'image/webp' }), outlet)
  assert.equal(result, `${productionPublic}/assets/menu-images/${outlet}/menu/22222222-2222-4222-8222-222222222222.webp`)
  assert.equal(request.url, `${productionApi}/v1/images`)
  assert.equal(request.init.headers.Authorization, 'Bearer session-token')
  assert.equal(request.init.headers['X-Outlet-Id'], outlet)
})

test('production upload failure is propagated and returns no URL', async () => {
  const api = storageModule({ backend: 'r2-production', fetchImpl: async () => Response.json({ error: 'denied' }, { status: 403 }) })
  await assert.rejects(api.uploadImageAsset(new File(['image'], 'menu.webp', { type: 'image/webp' }), outlet), /denied/)
})

test('production delete accepts exact R2 key but never deletes legacy Supabase URL', async () => {
  const requests = []
  const api = storageModule({ backend: 'r2-production', fetchImpl: async (url, init) => {
    requests.push({ url, init }); return Response.json({ deleted: true })
  } })
  await api.removeImageAsset(`https://project.supabase.co/storage/v1/object/public/menu-images/${outlet}/menu/old.webp`)
  assert.equal(requests.length, 0)
  const r2 = `${productionPublic}/assets/menu-images/${outlet}/menu/22222222-2222-4222-8222-222222222222.webp`
  await api.removeImageAsset(r2)
  assert.equal(requests.length, 1)
  assert.match(requests[0].url, new RegExp(`^${productionApi}/v1/images\\?key=`))
  assert.equal(requests[0].init.method, 'DELETE')
})

test('R2 mode marks outlet cleanup handled without broad-prefix delete', async () => {
  let fetches = 0
  const api = storageModule({ backend: 'r2-production', fetchImpl: async () => { fetches++; return Response.json({}) } })
  assert.equal(await api.cleanupOutletImageAssets(outlet), true)
  assert.equal(fetches, 0)
})

test('legacy Supabase delete remains scoped to approved origin and bucket', async () => {
  const api = storageModule()
  await api.removeImageAsset('https://project.supabase.co/storage/v1/object/public/menu-images/outlet/menu/a.png?version=1')
  assert.equal(JSON.stringify(api.calls), JSON.stringify([['remove', ['outlet/menu/a.png']]]))
  await api.removeImageAsset('https://foreign.example/storage/v1/object/public/menu-images/outlet/menu/a.png')
  await api.removeImageAsset('https://project.supabase.co/storage/v1/object/public/other/outlet/a.png')
  assert.equal(api.calls.length, 1)
})
