-- Apply calendar ownership as soon as an exchange request is created.
-- Pending exchanges are visible on the new owner's calendar with their live workflow status.
-- Rejecting/cancelling restores any existing calendar rows; absent rows are never fabricated.

create or replace function shift_exchange_private.sync_shift_calendar_with_request()
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
  if tg_op = 'INSERT' then
    select * into v_requester_entry
    from public.shift_schedule_entries
    where staff_directory_id = new.requester_staff_directory_id
      and shift_date = new.shift_date
      and shift_period = new.shift_period
    for update;

    if found then
      v_shift_type := v_requester_entry.shift_type;
      update public.shift_schedule_entries
      set staff_directory_id = new.recipient_staff_directory_id,
          source = 'exchange',
          exchange_request_id = new.id,
          updated_by = null,
          updated_at = now()
      where id = v_requester_entry.id;
    end if;

    if new.replacement_required then
      select * into v_recipient_entry
      from public.shift_schedule_entries
      where staff_directory_id = new.recipient_staff_directory_id
        and shift_date = new.replacement_date
        and shift_period = new.replacement_period
      for update;

      if found then
        update public.shift_schedule_entries
        set staff_directory_id = new.requester_staff_directory_id,
            source = 'exchange',
            exchange_request_id = new.id,
            updated_by = null,
            updated_at = now()
        where id = v_recipient_entry.id;
      end if;
    end if;

    return new;
  end if;

  if new.status in ('rejected', 'cancelled')
     and old.status not in ('rejected', 'cancelled', 'approved') then
    -- Return the originally requested shift to the requester.
    update public.shift_schedule_entries
    set staff_directory_id = new.requester_staff_directory_id,
        source = 'manual',
        exchange_request_id = null,
        updated_by = null,
        updated_at = now()
    where exchange_request_id = new.id
      and shift_date = new.shift_date
      and shift_period = new.shift_period
      and staff_directory_id = new.recipient_staff_directory_id;

    -- Return the replacement shift to the recipient, if one existed.
    if new.replacement_required then
      update public.shift_schedule_entries
      set staff_directory_id = new.recipient_staff_directory_id,
          source = 'manual',
          exchange_request_id = null,
          updated_by = null,
          updated_at = now()
      where exchange_request_id = new.id
        and shift_date = new.replacement_date
        and shift_period = new.replacement_period
        and staff_directory_id = new.requester_staff_directory_id;
    end if;

    return new;
  end if;

  if new.status = 'approved' and old.status is distinct from 'approved' then
    insert into public.shift_schedule_exchange_log(
      request_id, requester_staff_directory_id, recipient_staff_directory_id,
      shift_date, shift_period, shift_type, replacement_required,
      replacement_date, replacement_period
    )
    select new.id, new.requester_staff_directory_id, new.recipient_staff_directory_id,
      new.shift_date, new.shift_period,
      coalesce((
        select e.shift_type from public.shift_schedule_entries e
        where e.exchange_request_id = new.id
          and e.shift_date = new.shift_date
          and e.shift_period = new.shift_period
        limit 1
      ), v_shift_type),
      new.replacement_required, new.replacement_date, new.replacement_period
    on conflict (request_id) do nothing;
  end if;

  return new;
end;
$function$;

drop trigger if exists shift_change_requests_apply_schedule on public.shift_change_requests;
drop trigger if exists shift_change_requests_sync_schedule on public.shift_change_requests;
create trigger shift_change_requests_sync_schedule
after insert or update of status on public.shift_change_requests
for each row
execute function shift_exchange_private.sync_shift_calendar_with_request();

-- Return the request status with each exchanged shift so the calendar can label it.
create or replace function shift_exchange_private.get_my_shift_calendar(p_month date)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, auth, shift_exchange_private
as $function$
declare
  v_uid uuid := auth.uid();
  v_staff_id integer;
  v_rows jsonb;
begin
  if v_uid is null then raise exception 'กรุณาเข้าสู่ระบบ'; end if;
  if p_month is null or extract(day from p_month) <> 1 then
    raise exception 'กรุณาระบุวันแรกของเดือนที่ต้องการดู';
  end if;

  if shift_exchange_private.is_central_admin(v_uid) then
    select target_staff_directory_id into v_staff_id
    from shift_exchange_private.impersonation_sessions
    where admin_user_id = v_uid;
    if v_staff_id is null then
      raise exception 'กรุณาเลือกบุคลากรเพื่อดูตารางเวรแทนก่อน';
    end if;
  else
    select staff_directory_id into v_staff_id
    from public.profiles where user_id = v_uid;
  end if;

  if v_staff_id is null then
    raise exception 'บัญชีนี้ยังไม่เชื่อมโยงกับทะเบียนบุคลากร';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id,
    'staff_directory_id', e.staff_directory_id,
    'shift_date', e.shift_date,
    'shift_period', e.shift_period,
    'shift_type', e.shift_type,
    'note', e.note,
    'source', e.source,
    'exchange_request_id', e.exchange_request_id,
    'exchange_status', case when e.exchange_request_id is not null then r.status else null end
  ) order by e.shift_date, e.shift_period), '[]'::jsonb)
  into v_rows
  from public.shift_schedule_entries e
  left join public.shift_change_requests r on r.id = e.exchange_request_id
  where e.staff_directory_id = v_staff_id
    and e.shift_date >= p_month
    and e.shift_date < (p_month + interval '1 month')::date;

  return v_rows;
end;
$function$;

create or replace function public.get_my_shift_calendar(p_month date)
returns jsonb language sql security invoker
set search_path = pg_catalog, public, auth, shift_exchange_private
as $function$
  select shift_exchange_private.get_my_shift_calendar(p_month);
$function$;

grant execute on function shift_exchange_private.get_my_shift_calendar(date) to authenticated;
grant execute on function public.get_my_shift_calendar(date) to authenticated;
revoke all on function shift_exchange_private.get_my_shift_calendar(date) from public, anon;
revoke all on function public.get_my_shift_calendar(date) from public, anon;
