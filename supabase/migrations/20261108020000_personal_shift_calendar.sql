-- Personal monthly shift calendar and approved exchange synchronization.
create table if not exists public.shift_schedule_entries (
  id uuid primary key default gen_random_uuid(),
  staff_directory_id integer not null references public.staff_directory(source_row),
  shift_date date not null,
  shift_period text not null check (shift_period in ('morning','afternoon','night')),
  shift_type text not null check (shift_type in ('unit','refer','supervision')),
  note text,
  source text not null default 'manual' check (source in ('manual','exchange')),
  exchange_request_id uuid references public.shift_change_requests(id),
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint shift_schedule_entries_staff_day_period_key unique (staff_directory_id, shift_date, shift_period)
);
create index if not exists shift_schedule_entries_staff_date_idx on public.shift_schedule_entries (staff_directory_id, shift_date);
create index if not exists shift_schedule_entries_date_idx on public.shift_schedule_entries (shift_date, shift_period);
alter table public.shift_schedule_entries enable row level security;
create policy shift_schedule_entries_no_direct_access on public.shift_schedule_entries for all to authenticated using (false) with check (false);
revoke all on public.shift_schedule_entries from anon, authenticated;

create table if not exists public.shift_schedule_exchange_log (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null unique references public.shift_change_requests(id),
  requester_staff_directory_id integer not null references public.staff_directory(source_row),
  recipient_staff_directory_id integer not null references public.staff_directory(source_row),
  shift_date date not null,
  shift_period text not null,
  shift_type text not null,
  replacement_required boolean not null,
  replacement_date date,
  replacement_period text,
  applied_at timestamptz not null default now()
);
alter table public.shift_schedule_exchange_log enable row level security;
create policy shift_schedule_exchange_log_no_direct_access on public.shift_schedule_exchange_log for all to authenticated using (false) with check (false);
revoke all on public.shift_schedule_exchange_log from anon, authenticated;

create or replace function shift_exchange_private.apply_approved_shift_exchange()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, auth, shift_exchange_private
as $function$
declare
  v_requester_entry public.shift_schedule_entries%rowtype;
  v_recipient_entry public.shift_schedule_entries%rowtype;
  v_shift_type text := new.request_type;
begin
  if new.status <> 'approved' or old.status = 'approved' then return new; end if;

  select * into v_requester_entry
  from public.shift_schedule_entries
  where staff_directory_id = new.requester_staff_directory_id
    and shift_date = new.shift_date and shift_period = new.shift_period
  for update;

  if found then
    v_shift_type := v_requester_entry.shift_type;
    update public.shift_schedule_entries
      set staff_directory_id = new.recipient_staff_directory_id, source = 'exchange',
          exchange_request_id = new.id, updated_by = null, updated_at = now()
    where id = v_requester_entry.id;
  else
    insert into public.shift_schedule_entries(
      staff_directory_id, shift_date, shift_period, shift_type, source,
      exchange_request_id, created_by, updated_by
    ) values (
      new.recipient_staff_directory_id, new.shift_date, new.shift_period, v_shift_type,
      'exchange', new.id, new.requester_user_id, null
    );
  end if;

  if new.replacement_required then
    select * into v_recipient_entry
    from public.shift_schedule_entries
    where staff_directory_id = new.recipient_staff_directory_id
      and shift_date = new.replacement_date and shift_period = new.replacement_period
    for update;

    if found then
      update public.shift_schedule_entries
        set staff_directory_id = new.requester_staff_directory_id, source = 'exchange',
            exchange_request_id = new.id, updated_by = null, updated_at = now()
      where id = v_recipient_entry.id;
    else
      insert into public.shift_schedule_entries(
        staff_directory_id, shift_date, shift_period, shift_type, source,
        exchange_request_id, created_by, updated_by
      ) values (
        new.requester_staff_directory_id, new.replacement_date, new.replacement_period,
        v_shift_type, 'exchange', new.id, new.requester_user_id, null
      );
    end if;
  end if;

  insert into public.shift_schedule_exchange_log(
    request_id, requester_staff_directory_id, recipient_staff_directory_id,
    shift_date, shift_period, shift_type, replacement_required, replacement_date, replacement_period
  ) values (
    new.id, new.requester_staff_directory_id, new.recipient_staff_directory_id,
    new.shift_date, new.shift_period, v_shift_type, new.replacement_required,
    new.replacement_date, new.replacement_period
  );
  return new;
end;
$function$;

drop trigger if exists shift_change_requests_apply_schedule on public.shift_change_requests;
create trigger shift_change_requests_apply_schedule
after update of status on public.shift_change_requests
for each row when (new.status = 'approved' and old.status is distinct from new.status)
execute function shift_exchange_private.apply_approved_shift_exchange();

create or replace function public.get_my_shift_calendar(p_month date)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, auth, shift_exchange_private
as $function$
declare v_uid uuid := auth.uid(); v_staff_id integer; v_rows jsonb;
begin
  if v_uid is null then raise exception 'กรุณาเข้าสู่ระบบ'; end if;
  if p_month is null or extract(day from p_month) <> 1 then raise exception 'กรุณาระบุวันแรกของเดือนที่ต้องการดู'; end if;
  if shift_exchange_private.is_central_admin(v_uid) then
    select target_staff_directory_id into v_staff_id from shift_exchange_private.impersonation_sessions where admin_user_id = v_uid;
    if v_staff_id is null then raise exception 'กรุณาเลือกบุคลากรเพื่อดูตารางเวรแทนก่อน'; end if;
  else
    select staff_directory_id into v_staff_id from public.profiles where user_id = v_uid;
  end if;
  if v_staff_id is null then raise exception 'บัญชีนี้ยังไม่เชื่อมโยงกับทะเบียนบุคลากร'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id, 'staff_directory_id', e.staff_directory_id, 'shift_date', e.shift_date,
    'shift_period', e.shift_period, 'shift_type', e.shift_type, 'note', e.note,
    'source', e.source, 'exchange_request_id', e.exchange_request_id
  ) order by e.shift_date, e.shift_period), '[]'::jsonb)
  into v_rows from public.shift_schedule_entries e
  where e.staff_directory_id = v_staff_id and e.shift_date >= p_month
    and e.shift_date < (p_month + interval '1 month')::date;
  return v_rows;
end;
$function$;

create or replace function public.save_my_shift_entry(
  p_id uuid, p_shift_date date, p_shift_period text, p_shift_type text, p_note text default null
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, auth, shift_exchange_private
as $function$
declare v_uid uuid := auth.uid(); v_staff_id integer; v_row public.shift_schedule_entries%rowtype;
begin
  if v_uid is null then raise exception 'กรุณาเข้าสู่ระบบ'; end if;
  if p_shift_date is null or p_shift_period not in ('morning','afternoon','night')
     or p_shift_type not in ('unit','refer','supervision') then raise exception 'ข้อมูลวันที่หรือประเภทเวรไม่ถูกต้อง'; end if;
  if shift_exchange_private.is_central_admin(v_uid) then
    select target_staff_directory_id into v_staff_id from shift_exchange_private.impersonation_sessions where admin_user_id = v_uid;
    if v_staff_id is null then raise exception 'กรุณาเลือกบุคลากรเพื่อแก้ไขตารางเวรแทนก่อน'; end if;
  else
    select staff_directory_id into v_staff_id from public.profiles where user_id = v_uid;
  end if;
  if v_staff_id is null then raise exception 'บัญชีนี้ยังไม่เชื่อมโยงกับทะเบียนบุคลากร'; end if;
  if p_id is null then
    insert into public.shift_schedule_entries(
      staff_directory_id, shift_date, shift_period, shift_type, note, source, created_by, updated_by
    ) values (v_staff_id, p_shift_date, p_shift_period, p_shift_type,
      nullif(trim(coalesce(p_note,'')),''), 'manual', v_uid, v_uid) returning * into v_row;
  else
    update public.shift_schedule_entries set shift_date = p_shift_date, shift_period = p_shift_period,
      shift_type = p_shift_type, note = nullif(trim(coalesce(p_note,'')),''),
      updated_by = v_uid, updated_at = now()
    where id = p_id and staff_directory_id = v_staff_id returning * into v_row;
    if not found then raise exception 'ไม่พบเวรนี้ในตารางของคุณ หรือไม่มีสิทธิ์แก้ไข'; end if;
  end if;
  return jsonb_build_object('id',v_row.id,'shift_date',v_row.shift_date,'shift_period',v_row.shift_period,
    'shift_type',v_row.shift_type,'note',v_row.note,'source',v_row.source,'exchange_request_id',v_row.exchange_request_id);
end;
$function$;

create or replace function public.delete_my_shift_entry(p_id uuid)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, auth, shift_exchange_private
as $function$
declare v_uid uuid := auth.uid(); v_staff_id integer; v_deleted integer;
begin
  if v_uid is null then raise exception 'กรุณาเข้าสู่ระบบ'; end if;
  if shift_exchange_private.is_central_admin(v_uid) then
    select target_staff_directory_id into v_staff_id from shift_exchange_private.impersonation_sessions where admin_user_id = v_uid;
    if v_staff_id is null then raise exception 'กรุณาเลือกบุคลากรเพื่อแก้ไขตารางเวรแทนก่อน'; end if;
  else
    select staff_directory_id into v_staff_id from public.profiles where user_id = v_uid;
  end if;
  if v_staff_id is null then raise exception 'บัญชีนี้ยังไม่เชื่อมโยงกับทะเบียนบุคลากร'; end if;
  delete from public.shift_schedule_entries where id = p_id and staff_directory_id = v_staff_id;
  get diagnostics v_deleted = row_count;
  if v_deleted = 0 then raise exception 'ไม่พบเวรนี้ในตารางของคุณ หรือไม่มีสิทธิ์ลบ'; end if;
  return jsonb_build_object('deleted',true,'id',p_id);
end;
$function$;

revoke all on function public.get_my_shift_calendar(date) from public, anon;
revoke all on function public.save_my_shift_entry(uuid,date,text,text,text) from public, anon;
revoke all on function public.delete_my_shift_entry(uuid) from public, anon;
grant execute on function public.get_my_shift_calendar(date) to authenticated;
grant execute on function public.save_my_shift_entry(uuid,date,text,text,text) to authenticated;
grant execute on function public.delete_my_shift_entry(uuid) to authenticated;
revoke all on function shift_exchange_private.apply_approved_shift_exchange() from public, anon, authenticated;


-- Keep public RPC endpoints SECURITY INVOKER. Privileged implementation stays in
-- the non-exposed shift_exchange_private schema and validates auth.uid().
create or replace function shift_exchange_private.get_my_shift_calendar(p_month date)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, auth, shift_exchange_private
as $function$
declare v_uid uuid := auth.uid(); v_staff_id integer; v_rows jsonb;
begin
  if v_uid is null then raise exception 'กรุณาเข้าสู่ระบบ'; end if;
  if p_month is null or extract(day from p_month) <> 1 then raise exception 'กรุณาระบุวันแรกของเดือนที่ต้องการดู'; end if;
  if shift_exchange_private.is_central_admin(v_uid) then
    select target_staff_directory_id into v_staff_id from shift_exchange_private.impersonation_sessions where admin_user_id=v_uid;
    if v_staff_id is null then raise exception 'กรุณาเลือกบุคลากรเพื่อดูตารางเวรแทนก่อน'; end if;
  else
    select staff_directory_id into v_staff_id from public.profiles where user_id=v_uid;
  end if;
  if v_staff_id is null then raise exception 'บัญชีนี้ยังไม่เชื่อมโยงกับทะเบียนบุคลากร'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',e.id,'staff_directory_id',e.staff_directory_id,'shift_date',e.shift_date,
    'shift_period',e.shift_period,'shift_type',e.shift_type,'note',e.note,
    'source',e.source,'exchange_request_id',e.exchange_request_id
  ) order by e.shift_date,e.shift_period),'[]'::jsonb)
  into v_rows from public.shift_schedule_entries e
  where e.staff_directory_id=v_staff_id and e.shift_date>=p_month
    and e.shift_date<(p_month+interval '1 month')::date;
  return v_rows;
end;
$function$;

create or replace function shift_exchange_private.save_my_shift_entry(
  p_id uuid,p_shift_date date,p_shift_period text,p_shift_type text,p_note text default null
)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, auth, shift_exchange_private
as $function$
declare v_uid uuid:=auth.uid(); v_staff_id integer; v_row public.shift_schedule_entries%rowtype;
begin
  if v_uid is null then raise exception 'กรุณาเข้าสู่ระบบ'; end if;
  if p_shift_date is null or p_shift_period not in ('morning','afternoon','night')
     or p_shift_type not in ('unit','refer','supervision') then raise exception 'ข้อมูลวันที่หรือประเภทเวรไม่ถูกต้อง'; end if;
  if shift_exchange_private.is_central_admin(v_uid) then
    select target_staff_directory_id into v_staff_id from shift_exchange_private.impersonation_sessions where admin_user_id=v_uid;
    if v_staff_id is null then raise exception 'กรุณาเลือกบุคลากรเพื่อแก้ไขตารางเวรแทนก่อน'; end if;
  else
    select staff_directory_id into v_staff_id from public.profiles where user_id=v_uid;
  end if;
  if v_staff_id is null then raise exception 'บัญชีนี้ยังไม่เชื่อมโยงกับทะเบียนบุคลากร'; end if;
  if p_id is null then
    insert into public.shift_schedule_entries(staff_directory_id,shift_date,shift_period,shift_type,note,source,created_by,updated_by)
    values(v_staff_id,p_shift_date,p_shift_period,p_shift_type,nullif(trim(coalesce(p_note,'')),''),'manual',v_uid,v_uid)
    returning * into v_row;
  else
    update public.shift_schedule_entries set shift_date=p_shift_date,shift_period=p_shift_period,
      shift_type=p_shift_type,note=nullif(trim(coalesce(p_note,'')),''),updated_by=v_uid,updated_at=now()
    where id=p_id and staff_directory_id=v_staff_id returning * into v_row;
    if not found then raise exception 'ไม่พบเวรนี้ในตารางของคุณ หรือไม่มีสิทธิ์แก้ไข'; end if;
  end if;
  return jsonb_build_object('id',v_row.id,'shift_date',v_row.shift_date,'shift_period',v_row.shift_period,
    'shift_type',v_row.shift_type,'note',v_row.note,'source',v_row.source,'exchange_request_id',v_row.exchange_request_id);
end;
$function$;

create or replace function shift_exchange_private.delete_my_shift_entry(p_id uuid)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, auth, shift_exchange_private
as $function$
declare v_uid uuid:=auth.uid(); v_staff_id integer; v_deleted integer;
begin
  if v_uid is null then raise exception 'กรุณาเข้าสู่ระบบ'; end if;
  if shift_exchange_private.is_central_admin(v_uid) then
    select target_staff_directory_id into v_staff_id from shift_exchange_private.impersonation_sessions where admin_user_id=v_uid;
    if v_staff_id is null then raise exception 'กรุณาเลือกบุคลากรเพื่อแก้ไขตารางเวรแทนก่อน'; end if;
  else
    select staff_directory_id into v_staff_id from public.profiles where user_id=v_uid;
  end if;
  if v_staff_id is null then raise exception 'บัญชีนี้ยังไม่เชื่อมโยงกับทะเบียนบุคลากร'; end if;
  delete from public.shift_schedule_entries where id=p_id and staff_directory_id=v_staff_id;
  get diagnostics v_deleted=row_count;
  if v_deleted=0 then raise exception 'ไม่พบเวรนี้ในตารางของคุณ หรือไม่มีสิทธิ์ลบ'; end if;
  return jsonb_build_object('deleted',true,'id',p_id);
end;
$function$;

grant usage on schema shift_exchange_private to authenticated;
grant execute on function shift_exchange_private.get_my_shift_calendar(date) to authenticated;
grant execute on function shift_exchange_private.save_my_shift_entry(uuid,date,text,text,text) to authenticated;
grant execute on function shift_exchange_private.delete_my_shift_entry(uuid) to authenticated;
revoke all on function shift_exchange_private.get_my_shift_calendar(date) from public,anon;
revoke all on function shift_exchange_private.save_my_shift_entry(uuid,date,text,text,text) from public,anon;
revoke all on function shift_exchange_private.delete_my_shift_entry(uuid) from public,anon;

create or replace function public.get_my_shift_calendar(p_month date)
returns jsonb language sql stable security invoker
set search_path = pg_catalog, public, auth, shift_exchange_private
as $function$ select shift_exchange_private.get_my_shift_calendar(p_month); $function$;

create or replace function public.save_my_shift_entry(p_id uuid,p_shift_date date,p_shift_period text,p_shift_type text,p_note text default null)
returns jsonb language sql security invoker
set search_path = pg_catalog, public, auth, shift_exchange_private
as $function$ select shift_exchange_private.save_my_shift_entry(p_id,p_shift_date,p_shift_period,p_shift_type,p_note); $function$;

create or replace function public.delete_my_shift_entry(p_id uuid)
returns jsonb language sql security invoker
set search_path = pg_catalog, public, auth, shift_exchange_private
as $function$ select shift_exchange_private.delete_my_shift_entry(p_id); $function$;

grant usage on schema shift_exchange_private to authenticated;
grant execute on function shift_exchange_private.get_my_shift_calendar(date) to authenticated;
grant execute on function shift_exchange_private.save_my_shift_entry(uuid,date,text,text,text) to authenticated;
grant execute on function shift_exchange_private.delete_my_shift_entry(uuid) to authenticated;
revoke all on function shift_exchange_private.get_my_shift_calendar(date) from public,anon;
revoke all on function shift_exchange_private.save_my_shift_entry(uuid,date,text,text,text) from public,anon;
revoke all on function shift_exchange_private.delete_my_shift_entry(uuid) from public,anon;
revoke all on function public.get_my_shift_calendar(date) from public,anon;
revoke all on function public.save_my_shift_entry(uuid,date,text,text,text) from public,anon;
revoke all on function public.delete_my_shift_entry(uuid) from public,anon;
grant execute on function public.get_my_shift_calendar(date) to authenticated;
grant execute on function public.save_my_shift_entry(uuid,date,text,text,text) to authenticated;
grant execute on function public.delete_my_shift_entry(uuid) to authenticated;
