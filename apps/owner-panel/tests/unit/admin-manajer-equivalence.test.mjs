import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'

const root = new URL('../../../', import.meta.url)
const [roleTypes, protectedRoute, sidebar, migration, retiredRoleMigration, createStaff, changeStaffPassword, assetWorker, printerSettings] =
  await Promise.all([
    readFile(new URL('owner-panel/src/types/database.ts', root), 'utf8'),
    readFile(new URL('owner-panel/src/router/ProtectedRoute.tsx', root), 'utf8'),
    readFile(new URL('owner-panel/src/components/layout/Sidebar.tsx', root), 'utf8'),
    readFile(new URL('supabase/migrations/199_admin_manajer_access_equivalence.sql', root), 'utf8'),
    readFile(new URL('supabase/migrations/200_retire_legacy_dapur_role.sql', root), 'utf8'),
    readFile(new URL('supabase/functions/create-staff/index.ts', root), 'utf8'),
    readFile(new URL('supabase/functions/change-staff-password/index.ts', root), 'utf8'),
    readFile(new URL('assets-worker/src/index.ts', root), 'utf8'),
    readFile(new URL('mobile/qrordering/lib/features/pos/presentation/pages/device_settings_page.dart', root), 'utf8'),
  ])

test('manajer dinormalisasi sebagai admin pada guard web dan database', () => {
  assert.match(roleTypes, /role === 'manajer' \? 'admin' : role/)
  assert.match(protectedRoute, /userRoleHasAccess\(profile\.role, allowedRoles\)/)
  assert.match(migration, /WHEN role = 'manajer' THEN 'admin'::public\.user_role/)
  assert.match(migration, /WHEN 'manajer' THEN 3/)
})

test('role akun dapur dipensiunkan tanpa menghapus fitur printer dapur', () => {
  assert.doesNotMatch(roleTypes, /['"]dapur['"]|\bdapur\s*:/i)
  assert.doesNotMatch(createStaff, /['"]dapur['"]/i)
  assert.doesNotMatch(changeStaffPassword, /\bdapur\s*:/i)
  assert.match(retiredRoleMigration, /UPDATE public\.profiles[\s\S]*SET role = 'kasir'/)
  assert.match(retiredRoleMigration, /RENAME VALUE 'dapur' TO '_removed_role'/)
  assert.match(retiredRoleMigration, /profiles_supported_role_check/)
  assert.match(printerSettings, /Printer Dapur/)
  assert.match(printerSettings, /dapurEnabled/)
})

test('permukaan admin non-RLS juga menerima manajer dengan batas rank setara', () => {
  assert.match(sidebar, /profile\?\.role === 'manajer'/)
  assert.match(createStaff, /const allowed = \['owner', 'admin', 'manajer'\]/)
  assert.match(createStaff, /admin:\s+\['kasir'\]/)
  assert.match(createStaff, /manajer:\s*\['kasir'\]/)
  assert.match(assetWorker, /profile\.role !== 'admin' && profile\.role !== 'manajer'/)
})
