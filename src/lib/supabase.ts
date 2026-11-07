import { createClient } from '@supabase/supabase-js'

// Publishable key is designed for browser use; database access remains protected by RLS and RPC checks.
const supabaseUrl = import.meta.env.VITE_SUPABASE_URL || 'https://foypareeazfzidwygolc.supabase.co'
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY || 'sb_publishable_8qxOgD-AHGnv9RWWAZTUQQ_I0MPIMv3'

export const isSupabaseConfigured = Boolean(supabaseUrl && supabaseAnonKey)

export const supabase = isSupabaseConfigured
  ? createClient(supabaseUrl, supabaseAnonKey, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true,
      },
    })
  : null
