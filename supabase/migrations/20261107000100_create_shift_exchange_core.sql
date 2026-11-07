-- Nursing Shift Exchange: isolated schema objects.
-- This migration intentionally does not alter existing P4P tables, policies, functions, or Auth users.

create table if not exists public.shift_change_documents (
  id uuid primary key default gen_random_uuid(),
  document_number text not null unique
    check (document_number ~ '^[0-9]+/[0-9]{4}$'),
  document_date date not null,
  created_by uuid not null references auth.users(id) on delete restrict default auth.uid(),
  created_at timestamptz not null default now()
);

create table if not exists public.shift_change_requests (
  id uuid primary key default gen_random_uuid(),
  requester_user_id uuid not null references auth.users(id) on delete restrict default auth.uid(),
  requester_staff_directory_id integer not null references public.staff_directory(source_row) on delete restrict,
  requester_name text not null,
  requester_unit_name text not null,
  request_type text not null check (request_type in ('unit', 'refer', 'supervision')),
  shift_date date not null,
  shift_period text not null check (shift_period in ('morning', 'afternoon', 'night')),
  document_id uuid references public.shift_change_documents(id) on delete set null,
  recipient_user_id uuid references auth.users(id) on delete set null,
  recipient_staff_directory_id integer not null references public.staff_directory(source_row) on delete restrict,
  recipient_name text not null,
  replacement_required boolean not null default false,
  replacement_date date,
  replacement_period text check (replacement_period in ('morning', 'afternoon', 'night')),
  requester_note text,
  status text not null default 'waiting_recipient'
    check (status in (
      'waiting_recipient',
      'waiting_unit_head',
      'waiting_nursing_head',
      'approved',
      'rejected',
      'cancelled'
    )),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint shift_change_replacement_fields_check check (
    (replacement_required = false and replacement_date is null and replacement_period is null)
    or
    (replacement_required = true and replacement_date is not null and replacement_period is not null)
  ),
  constraint shift_change_not_same_person check (
    requester_staff_directory_id <> recipient_staff_directory_id
  )
);

create table if not exists public.shift_change_approvals (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.shift_change_requests(id) on delete cascade,
  step_code text not null check (step_code in ('unit_head', 'nursing_head')),
  approver_staff_directory_id integer not null references public.staff_directory(source_row) on delete restrict,
  approver_user_id uuid references auth.users(id) on delete set null,
  approver_name text not null,
  decision text not null default 'pending'
    check (decision in ('pending', 'approved', 'rejected', 'skipped')),
  acted_by uuid references auth.users(id) on delete set null,
  comment text,
  acted_at timestamptz,
  created_at timestamptz not null default now(),
  unique (request_id, step_code)
);

create index if not exists idx_shift_change_requests_requester_created
  on public.shift_change_requests (requester_user_id, created_at desc);
create index if not exists idx_shift_change_requests_recipient_status
  on public.shift_change_requests (recipient_user_id, status, created_at desc);
create index if not exists idx_shift_change_requests_status_created
  on public.shift_change_requests (status, created_at desc);
create index if not exists idx_shift_change_approvals_approver_decision
  on public.shift_change_approvals (approver_user_id, decision, created_at desc);
create index if not exists idx_shift_change_approvals_staff_decision
  on public.shift_change_approvals (approver_staff_directory_id, decision);
create index if not exists idx_shift_change_approvals_request
  on public.shift_change_approvals (request_id);

alter table public.shift_change_documents enable row level security;
alter table public.shift_change_requests enable row level security;
alter table public.shift_change_approvals enable row level security;

-- Only signed-in staff can read document references. Writes will be exposed through
-- validated workflow RPCs in a later migration.
grant select on public.shift_change_documents to authenticated;
grant select, insert, select on public.shift_change_requests to authenticated;
grant select on public.shift_change_approvals to authenticated;

create policy "shift_change_documents_read_authenticated"
  on public.shift_change_documents for select to authenticated
  using ((select auth.uid()) is not null);

create policy "shift_change_requests_read_participants_or_approvers"
  on public.shift_change_requests for select to authenticated
  using (
    (select auth.uid()) = requester_user_id
    or (select auth.uid()) = recipient_user_id
    or exists (
      select 1
      from public.shift_change_approvals a
      join public.profiles p on p.staff_directory_id = a.approver_staff_directory_id
      where a.request_id = shift_change_requests.id
        and p.user_id = (select auth.uid())
    )
  );

create policy "shift_change_requests_insert_as_self"
  on public.shift_change_requests for insert to authenticated
  with check (
    (select auth.uid()) = requester_user_id
    and exists (
      select 1
      from public.profiles p
      where p.user_id = (select auth.uid())
        and p.staff_directory_id = requester_staff_directory_id
    )
  );

create policy "shift_change_approvals_read_participants"
  on public.shift_change_approvals for select to authenticated
  using (
    exists (
      select 1
      from public.profiles p
      where p.user_id = (select auth.uid())
        and p.staff_directory_id = shift_change_approvals.approver_staff_directory_id
    )
    or exists (
      select 1
      from public.shift_change_requests r
      where r.id = shift_change_approvals.request_id
        and (
          r.requester_user_id = (select auth.uid())
          or r.recipient_user_id = (select auth.uid())
        )
    )
  );

-- No direct UPDATE/DELETE grants or policies are created for workflow records.
-- Subsequent migrations will add narrow RPCs for accept/reject/approve/cancel.
