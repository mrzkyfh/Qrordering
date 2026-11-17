import { createHash } from 'node:crypto'
import { readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'

const EXPECTED_BASE = 'https://pub-03e9996cd3b549a4b55663ff7ec18251.r2.dev/'
const EXPECTED_COUNT = 127
const EXPECTED_BYTES = 5195078
const REFERENCED_LOGO = 'menu-images/d81e6a71-bb92-45b0-be88-cca026ed783e/logos/2928c880-a0a2-4f57-98d6-a1654e1266f3.webp'
const NEGATIVE_KEY = '__verification__/this-object-does-not-exist.webp'

const sha256 = (value) => createHash('sha256').update(value).digest('hex')
const encodedPath = (key) => key.split('/').map(encodeURIComponent).join('/')

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

async function fetchWithRetry(url, attempts = 3) {
  let lastError
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      return await fetch(url, { method: 'GET', redirect: 'error' })
    } catch (error) {
      lastError = error
      if (attempt < attempts) await new Promise((resolve) => setTimeout(resolve, 150 * attempt))
    }
  }
  throw lastError
}

const backupRoot = process.argv[2] ?? 'backups/r2-pre-migration-20261008-231330'
const publicBase = new URL(process.argv[3] ?? EXPECTED_BASE)
if (publicBase.href !== EXPECTED_BASE) throw new Error(`Public endpoint guard rejected: expected exactly ${EXPECTED_BASE}`)

const reportPath = path.join(backupRoot, 'r2-staging-copy-report.json')
const report = JSON.parse(await readFile(reportPath, 'utf8'))
if (report.targetBucket !== 'qrordering-assets-staging') throw new Error('Report target bucket guard rejected')
if (report.objects.length !== EXPECTED_COUNT || report.target.count !== EXPECTED_COUNT || report.target.bytes !== EXPECTED_BYTES) {
  throw new Error('Existing authenticated-copy reconciliation is not the expected 127 objects / 5,195,078 bytes')
}
if (report.objects.some((item) => item.uploadStatus !== 'PASS' || item.sizeVerification !== 'PASS' || item.sha256Verification !== 'PASS')) {
  throw new Error('Existing authenticated verification record contains a failure')
}

const menuObjects = report.objects.filter((item) => item.r2Key.includes('/menu/'))
const representativeKeys = [menuObjects[0]?.r2Key, REFERENCED_LOGO, menuObjects.at(-1)?.r2Key].filter(Boolean)
if (!report.objects.some((item) => item.r2Key === REFERENCED_LOGO)) throw new Error('Referenced receipt logo is absent from copy report')

console.log(`public endpoint guard=PASS (${publicBase.origin})`)
console.log(`authenticated record=PASS (${report.objects.length}/${EXPECTED_COUNT})`)
console.log('public requests use no Authorization header or signed query parameters')

const startedAt = new Date().toISOString()
// Keep verification deliberately sequential. The r2.dev development endpoint
// can intermittently reset bursts of parallel requests, producing false
// negatives even though a sequential checksum retry succeeds.
const results = await mapLimit(report.objects, 1, async (item) => {
  const localBytes = await readFile(path.join(backupRoot, item.sourcePath))
  const localHash = sha256(localBytes)
  if (localBytes.length !== item.byteSize || localHash !== item.localSha256) {
    throw new Error(`Local source validation failed before public GET: ${item.r2Key}`)
  }
  const url = new URL(encodedPath(item.r2Key), publicBase)
  try {
    const response = await fetchWithRetry(url)
    const bytes = Buffer.from(await response.arrayBuffer())
    const remoteHash = sha256(bytes)
    const contentType = response.headers.get('content-type')
    const statusPass = response.status === 200
    const nonEmptyPass = bytes.length > 0
    const sizePass = bytes.length === localBytes.length
    const sha256Pass = remoteHash === localHash
    const contentTypePass = contentType?.split(';')[0].trim().toLowerCase() === 'image/webp'
    return {
      key: item.r2Key,
      httpStatus: response.status,
      responseBytes: bytes.length,
      expectedBytes: localBytes.length,
      contentType,
      statusPass,
      nonEmptyPass,
      sizePass,
      sha256Pass,
      contentTypePass,
      status: statusPass && nonEmptyPass && sizePass && sha256Pass && contentTypePass ? 'PASS' : 'FAIL',
    }
  } catch (error) {
    return { key: item.r2Key, status: 'FAIL', error: error instanceof Error ? error.message : String(error) }
  }
})

const negativeUrl = new URL(encodedPath(NEGATIVE_KEY), publicBase)
let negativeTest
try {
  const response = await fetchWithRetry(negativeUrl)
  const bytes = Buffer.from(await response.arrayBuffer())
  negativeTest = {
    key: NEGATIVE_KEY,
    httpStatus: response.status,
    responseBytes: bytes.length,
    status: response.status === 404 ? 'PASS' : 'FAIL',
  }
} catch (error) {
  negativeTest = { key: NEGATIVE_KEY, status: 'FAIL', error: error instanceof Error ? error.message : String(error) }
}

const httpFailures = results.filter((item) => !item.statusPass).map((item) => ({ key: item.key, httpStatus: item.httpStatus ?? null, error: item.error ?? null }))
const sizeMismatches = results.filter((item) => item.sizePass === false).map((item) => ({ key: item.key, expected: item.expectedBytes, actual: item.responseBytes }))
const sha256Mismatches = results.filter((item) => item.sha256Pass === false).map((item) => item.key)
const contentTypeMismatches = results.filter((item) => item.contentTypePass === false).map((item) => ({ key: item.key, contentType: item.contentType }))
const passed = results.filter((item) => item.status === 'PASS').length
const representative = representativeKeys.map((key) => results.find((item) => item.key === key))
const publicPass = passed === EXPECTED_COUNT && negativeTest.status === 'PASS'

report.publicRead = {
  enabled: true,
  baseUrl: publicBase.href.replace(/\/$/, ''),
  authenticationSent: false,
  startedAt,
  completedAt: new Date().toISOString(),
  testedObjects: results.length,
  passedObjects: passed,
  httpFailures,
  sizeMismatches,
  sha256Mismatches,
  contentTypeMismatches,
  representativeKeys,
  representative,
  negativeTest,
  status: publicPass ? 'PASS' : 'FAIL',
  objects: results,
}
report.copyStatus = publicPass ? 'R2 STAGING COPY VERIFIED' : 'R2 STAGING PUBLIC READ BLOCKED'
await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 })

console.log(`public objects=${passed}/${results.length} PASS`)
console.log(`http failures=${httpFailures.length}`)
console.log(`size mismatches=${sizeMismatches.length}`)
console.log(`SHA-256 mismatches=${sha256Mismatches.length}`)
console.log(`content-type mismatches=${contentTypeMismatches.length}`)
console.log(`negative nonexistent-object test=${negativeTest.status} (HTTP ${negativeTest.httpStatus ?? 'request error'})`)
console.log(report.copyStatus)
if (!publicPass) process.exitCode = 1
