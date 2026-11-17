import test from 'node:test'
import assert from 'node:assert/strict'
import worker from '../../worker/index.js'
const onRequest = ({ next }) => worker.fetch(new Request('https://panel.example/assets/test.js'), { ASSETS: { fetch: next } })

test('asset yang ada diteruskan tanpa mengubah cache header', async () => {
  const original = new Response('console.log("ok")', {
    status: 200,
    headers: {
      'Content-Type': 'application/javascript',
      'Cache-Control': 'public, max-age=31536000, immutable',
    },
  })

  const result = await onRequest({ next: async () => original })

  assert.equal(result, original)
  assert.equal(result.status, 200)
  assert.match(result.headers.get('cache-control'), /immutable/)
})

test('HTML fallback untuk asset hilang menjadi 404 dan tidak boleh dicache', async () => {
  const result = await onRequest({
    next: async () => new Response('<!doctype html><div id="root"></div>', {
      status: 200,
      headers: {
        'Content-Type': 'text/html; charset=UTF-8',
        'Cache-Control': 'public, max-age=31536000, immutable',
      },
    }),
  })

  assert.equal(result.status, 404)
  assert.equal(result.headers.get('content-type'), 'text/plain; charset=UTF-8')
  assert.match(result.headers.get('cache-control'), /no-store/)
  assert.equal(result.headers.get('x-content-type-options'), 'nosniff')
})

test('404 dari asset server tetap 404 dan dipaksa no-store', async () => {
  const result = await onRequest({
    next: async () => new Response('missing', {
      status: 404,
      headers: { 'Cache-Control': 'public, max-age=31536000, immutable' },
    }),
  })

  assert.equal(result.status, 404)
  assert.match(result.headers.get('cache-control'), /no-store/)
})
