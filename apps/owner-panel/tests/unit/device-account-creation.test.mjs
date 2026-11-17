import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'

const root = new URL('../../../', import.meta.url)
const [createStaff, boundaryMigration, bootstrapMigration] = await Promise.all([
  readFile(new URL('supabase/functions/create-staff/index.ts', root), 'utf8'),
  readFile(new URL('supabase/migrations/217_device_auth_boundary_hardening.sql', root), 'utf8'),
  readFile(new URL('supabase/migrations/219_fix_device_bootstrap_service_role_detection.sql', root), 'utf8'),
])

test('akun perangkat meminta role pelanggan dan memverifikasi hasil penyimpanan', () => {
  assert.match(
    createStaff,
    /user_metadata:\s*\{\s*full_name:\s*effectiveName,\s*role:\s*effectiveRole\s*\}/,
  )

  const completionUpdate = createStaff.match(
    /\.from\('profiles'\)\s*\.update\(\{([\s\S]*?)\}\)\s*\.eq\('id', newId\)/,
  )?.[1]
  assert.ok(completionUpdate, 'blok UPDATE pelengkap profil harus ditemukan')
  assert.match(completionUpdate, /\brole:\s*effectiveRole/)
  assert.match(createStaff, /\.select\('role, outlet_id'\)\s*\.single\(\)/)
  assert.match(createStaff, /savedProfile\?\.role !== effectiveRole/)
})

test('trigger boundary tetap menolak perubahan antara staf dan perangkat', () => {
  assert.match(
    boundaryMigration,
    /\(OLD\.role = 'pelanggan'\) IS DISTINCT FROM \(NEW\.role = 'pelanggan'\)/,
  )
})

test('bootstrap perangkat hanya dibuka untuk service-role dan akun Auth baru', () => {
  assert.match(bootstrapMigration, /auth\.role\(\)/)
  assert.match(bootstrapMigration, /= 'service_role'/)
  assert.match(bootstrapMigration, /OLD\.role = 'kasir'/)
  assert.match(bootstrapMigration, /NEW\.role = 'pelanggan'/)
  assert.match(bootstrapMigration, /raw_user_meta_data->>'role' = 'pelanggan'/)
  assert.match(bootstrapMigration, /interval '5 minutes'/)
  assert.match(bootstrapMigration, /RAISE EXCEPTION[\s\S]*Role akun perangkat tidak dapat diubah/)
})
