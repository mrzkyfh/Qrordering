import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

type Candidate = {
  outlet_id: string
  business_date: string
  order_count: number
}

const MAX_BODY_BYTES = 2 * 1024
const MAX_ARCHIVE_JSON_BYTES = 100 * 1024 * 1024
const MAX_ARCHIVE_GZIP_BYTES = 25 * 1024 * 1024

class RequestTooLargeError extends Error {}
class ArchiveTooLargeError extends Error {}
class InvalidRequestError extends Error {}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      'Content-Type': 'application/json',
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
    },
  })

async function readJsonBody(req: Request): Promise<Record<string, unknown>> {
  const declaredLength = Number(req.headers.get('content-length') ?? 0)
  if (declaredLength > MAX_BODY_BYTES) throw new RequestTooLargeError()

  const raw = await req.text()
  if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) {
    throw new RequestTooLargeError()
  }
  if (!raw.trim()) return {}

  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    throw new InvalidRequestError()
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new InvalidRequestError()
  }
  return parsed as Record<string, unknown>
}

async function secretsEqual(expected: string, supplied: string): Promise<boolean> {
  const encoder = new TextEncoder()
  const [expectedHash, suppliedHash] = await Promise.all([
    crypto.subtle.digest('SHA-256', encoder.encode(expected)),
    crypto.subtle.digest('SHA-256', encoder.encode(supplied)),
  ])
  const left = new Uint8Array(expectedHash)
  const right = new Uint8Array(suppliedHash)
  let difference = 0
  for (let index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index]
  }
  return difference === 0
}

async function gzip(text: string): Promise<Uint8Array> {
  const stream = new Blob([text], { type: 'application/json' })
    .stream()
    .pipeThrough(new CompressionStream('gzip'))
  return new Uint8Array(await new Response(stream).arrayBuffer())
}

async function gunzip(bytes: ArrayBuffer): Promise<string> {
  const reader = new Blob([bytes])
    .stream()
    .pipeThrough(new DecompressionStream('gzip'))
    .getReader()
  const decoder = new TextDecoder()
  let totalBytes = 0
  let text = ''

  while (true) {
    const { done, value } = await reader.read()
    if (done) break
    totalBytes += value.byteLength
    if (totalBytes > MAX_ARCHIVE_JSON_BYTES) {
      await reader.cancel()
      throw new ArchiveTooLargeError()
    }
    text += decoder.decode(value, { stream: true })
  }
  return text + decoder.decode()
}

async function sha256(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', bytes)
  return [...new Uint8Array(digest)]
    .map((value) => value.toString(16).padStart(2, '0'))
    .join('')
}

serve(async (req) => {
  if (req.method !== 'POST') {
    const response = json({ error: 'Method not allowed' }, 405)
    response.headers.set('Allow', 'POST')
    return response
  }

  const expectedSecret = Deno.env.get('ARCHIVE_JOB_SECRET')
  const suppliedSecret = req.headers.get('x-archive-secret')
  if (
    !expectedSecret ||
    !suppliedSecret ||
    !(await secretsEqual(expectedSecret, suppliedSecret))
  ) {
    return json({ error: 'Unauthorized' }, 401)
  }

  let runId: string | null = null
  let client: ReturnType<typeof createClient> | null = null
  try {
    const body = await readJsonBody(req)
    const keepDays = Math.max(90, Math.min(Number(body.keep_days) || 90, 3650))
    const limitDays = Math.max(1, Math.min(Number(body.limit_days) || 5, 10))
    const invokedBy = ['manual', 'test'].includes(String(body.invoked_by))
      ? String(body.invoked_by)
      : 'cron'
    client = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      { auth: { persistSession: false, autoRefreshToken: false } },
    )

    const { data: run, error: runError } = await client
      .from('transaction_archive_runs')
      .insert({
        keep_days: keepDays,
        candidate_limit: limitDays,
        invoked_by: invokedBy,
      })
      .select('id')
      .single()
    if (runError) throw runError
    runId = run.id

    const { data: candidates, error: candidateError } = await client.rpc(
      'transaction_archive_candidates',
      { p_keep_days: keepDays, p_limit: limitDays },
    )
    if (candidateError) throw candidateError

    const results: Array<Record<string, unknown>> = []
    const failures: Array<Record<string, unknown>> = []
    for (const candidate of (candidates ?? []) as Candidate[]) {
      try {
        const { data: payload, error: payloadError } = await client.rpc(
          'build_transaction_archive_payload',
          {
            p_outlet_id: candidate.outlet_id,
            p_business_date: candidate.business_date,
          },
        )
        if (payloadError) throw payloadError

        const orders = Array.isArray(payload?.orders) ? payload.orders : []
        if (
          orders.length === 0 ||
          orders.length !== Number(candidate.order_count)
        ) {
          throw new Error(
            `Jumlah order berubah untuk ${candidate.outlet_id}/${candidate.business_date}`,
          )
        }

        const totalAmount = orders.reduce(
          (sum: number, order: Record<string, unknown>) =>
            sum + Number(order.total_amount ?? 0),
          0,
        )
        const serialized = JSON.stringify(payload)
        if (new TextEncoder().encode(serialized).byteLength > MAX_ARCHIVE_JSON_BYTES) {
          throw new ArchiveTooLargeError()
        }
        const encoded = await gzip(serialized)
        if (encoded.byteLength > MAX_ARCHIVE_GZIP_BYTES) {
          throw new ArchiveTooLargeError()
        }
        const checksum = await sha256(encoded)
        const [year, month] = candidate.business_date.split('-')
        const storagePath =
          `${candidate.outlet_id}/${year}/${month}/${candidate.business_date}.json.gz`

        const { error: uploadError } = await client.storage
          .from('transaction-archives')
          .upload(storagePath, encoded, {
            contentType: 'application/gzip',
            upsert: true,
            cacheControl: '31536000',
          })
        if (uploadError) throw uploadError

        // Jangan percaya hanya notifikasi upload. Baca ulang object privat,
        // cocokkan checksum, buka gzip, lalu periksa identitas dan jumlah order.
        const { data: downloaded, error: downloadError } = await client.storage
          .from('transaction-archives')
          .download(storagePath)
        if (downloadError || !downloaded) {
          throw downloadError ?? new Error('Arsip tidak dapat dibaca ulang')
        }

        const downloadedBytes = await downloaded.arrayBuffer()
        const downloadedChecksum = await sha256(
          new Uint8Array(downloadedBytes),
        )
        if (downloadedChecksum !== checksum) {
          throw new Error('Checksum arsip tidak cocok')
        }

        const verified = JSON.parse(await gunzip(downloadedBytes))
        if (
          verified.outlet_id !== candidate.outlet_id ||
          verified.business_date !== candidate.business_date ||
          !Array.isArray(verified.orders) ||
          verified.orders.length !== orders.length
        ) {
          throw new Error('Isi arsip tidak lolos verifikasi')
        }

        const { data: finalized, error: finalizeError } = await client.rpc(
          'finalize_transaction_archive',
          {
            p_outlet_id: candidate.outlet_id,
            p_business_date: candidate.business_date,
            p_storage_path: storagePath,
            p_checksum_sha256: checksum,
            p_order_count: orders.length,
            p_total_amount: totalAmount,
            p_compressed_bytes: encoded.byteLength,
          },
        )
        if (finalizeError) throw finalizeError

        results.push({
          outlet_id: candidate.outlet_id,
          business_date: candidate.business_date,
          order_count: finalized,
          compressed_bytes: encoded.byteLength,
        })
      } catch (error) {
        const message =
          error instanceof Error ? error.message : 'Kesalahan arsip tidak dikenal'
        console.error(
          `archive-orders candidate failed ${candidate.outlet_id}/${candidate.business_date}`,
          error,
        )
        failures.push({
          outlet_id: candidate.outlet_id,
          business_date: candidate.business_date,
          error: message,
        })
      }
    }

    const archivedOrderCount = results.reduce(
      (sum, result) => sum + Number(result.order_count ?? 0),
      0,
    )
    const status =
      failures.length === 0
        ? 'completed'
        : results.length === 0
          ? 'failed'
          : 'partial'

    const { error: finishError } = await client
      .from('transaction_archive_runs')
      .update({
        finished_at: new Date().toISOString(),
        status,
        candidate_count: (candidates ?? []).length,
        archived_count: results.length,
        archived_order_count: archivedOrderCount,
        failed_count: failures.length,
        failures,
      })
      .eq('id', runId)
    if (finishError) throw finishError

    return json(
      {
        success: failures.length === 0,
        run_id: runId,
        archived: results,
        failures: failures.map((failure) => ({
          outlet_id: failure.outlet_id,
          business_date: failure.business_date,
          error: 'Arsip gagal diproses',
        })),
      },
      status === 'failed' ? 500 : status === 'partial' ? 207 : 200,
    )
  } catch (error) {
    console.error('archive-orders failed', error)
    if (client && runId) {
      await client
        .from('transaction_archive_runs')
        .update({
          finished_at: new Date().toISOString(),
          status: 'failed',
          failed_count: 1,
          failures: [
            {
              error:
                error instanceof Error
                  ? error.message
                  : 'Kesalahan arsip tidak dikenal',
            },
          ],
        })
        .eq('id', runId)
    }
    if (error instanceof RequestTooLargeError) {
      return json({ error: 'Body request terlalu besar', run_id: runId }, 413)
    }
    if (error instanceof InvalidRequestError) {
      return json({ error: 'Body request tidak valid', run_id: runId }, 400)
    }
    if (error instanceof ArchiveTooLargeError) {
      return json({ error: 'Arsip terlalu besar untuk diproses', run_id: runId }, 422)
    }
    return json({ error: 'Gagal membuat arsip', run_id: runId }, 500)
  }
})
