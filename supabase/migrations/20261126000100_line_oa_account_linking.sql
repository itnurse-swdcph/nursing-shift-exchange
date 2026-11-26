create table if not exists public.line_user_links (
  user_id uuid primary key references auth.users(id) on delete cascade,
  line_user_id text not null unique,
  is_active boolean not null default true,
  linked_at timestamptz not null default now(),
  friend_verified_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.line_link_codes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  code_hash text not null unique,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists line_link_codes_user_created_idx on public.line_link_codes(user_id, created_at desc);
create index if not exists line_link_codes_expiry_idx on public.line_link_codes(expires_at) where consumed_at is null;
alter table public.line_user_links enable row level security;
alter table public.line_link_codes enable row level security;
revoke all on public.line_user_links from anon, authenticated;
revoke all on public.line_link_codes from anon, authenticated;
grant all on public.line_user_links to service_role;
grant all on public.line_link_codes to service_role;