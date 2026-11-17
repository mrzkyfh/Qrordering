// Protect versioned assets from HTML fallback and cached missing responses.
async function fetch(request, env) {
  const response = await env.ASSETS.fetch(request)
  const contentType = (response.headers.get('content-type') || '').toLowerCase()

  if (contentType.includes('text/html')) {
    return new Response('Asset not found', {
      status: 404,
      headers: {
        'Cache-Control': 'no-store, max-age=0',
        'Content-Type': 'text/plain; charset=UTF-8',
        'X-Content-Type-Options': 'nosniff',
      },
    })
  }

  if (response.status === 404) {
    const headers = new Headers(response.headers)
    headers.set('Cache-Control', 'no-store, max-age=0')
    return new Response(response.body, {
      status: 404,
      statusText: response.statusText,
      headers,
    })
  }

  return response
}

export default { fetch }
