create table if not exists public.shift_exchange_monthly_memos (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  owner_staff_directory_id integer,
  report_month date not null check (extract(day from report_month) = 1),
  document_number text not null check (length(btrim(document_number)) > 0),
  document_date date not null,
  snapshot jsonb not null,
  created_at timestamptz not null default now()
);

create index if not exists shift_exchange_monthly_memos_owner_month_created_idx
  on public.shift_exchange_monthly_memos (owner_user_id, report_month, created_at desc);

alter table public.shift_exchange_monthly_memos enable row level security;

revoke all on public.shift_exchange_monthly_memos from anon, public;
grant select, insert on public.shift_exchange_monthly_memos to authenticated;

drop policy if exists shift_exchange_monthly_memos_read_own on public.shift_exchange_monthly_memos;
create policy shift_exchange_monthly_memos_read_own
  on public.shift_exchange_monthly_memos
  for select to authenticated
  using ((select auth.uid()) = owner_user_id);

drop policy if exists shift_exchange_monthly_memos_insert_own on public.shift_exchange_monthly_memos;
create policy shift_exchange_monthly_memos_insert_own
  on public.shift_exchange_monthly_memos
  for insert to authenticated
  with check ((select auth.uid()) = owner_user_id);