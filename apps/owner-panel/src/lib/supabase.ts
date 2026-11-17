import { createClient } from '@supabase/supabase-js'

const primarySupabaseUrl = import.meta.env.VITE_SUPABASE_URL as string
const supabaseUrl =
  window.__QRORDERING_BACKEND_URL__?.trim() || primarySupabaseUrl
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string

if (!primarySupabaseUrl || !supabaseUrl || !supabaseAnonKey) {
  throw new Error('Missing Supabase environment variables')
}

const projectRef = new URL(primarySupabaseUrl).hostname.split('.')[0]

// Using untyped client — runtime types handled via our own type assertions per query
export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    storageKey: `sb-${projectRef}-auth-token`,
  },
  realtime: {
    params: { eventsPerSecond: 10 },
  },
})
