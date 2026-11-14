-- Normalize legacy approval rows for general staff and expose pending requests in personal calendars.
begin;

update public.shift_change_approvals a
set decision = 'skipped',
    comment = coalesce(a.comment, 'ข้ามขั้นตอนหัวหน้ากลุ่มงานตาม workflow เจ้าหน้าที่ทั่วไป'),
    acted_at = coalesce(a.acted_at, now())
from public.shift_change_requests r
join public.staff_directory d on d.source_row = r.requester_staff_directory_id
where a.request_id = r.id
  and a.step_code = 'group_head'
  and a.decision = 'pending'
  and coalesce(replace(trim(d.org_role), ' ', ''), '') not in ('หัวหน้างาน', 'หัวหน้ากลุ่มงาน');

update public.shift_change_requests r
set status = case
  when r.status = 'waiting_group_head'
       and exists (select 1 from public.shift_change_approvals u
                   where u.request_id = r.id and u.step_code = 'unit_head'
                     and u.decision in ('approved','skipped'))
    then 'waiting_nursing_head'
  when r.status = 'waiting_group_head' then 'waiting_unit_head'
  else r.status
end,
updated_at = now()
where r.status = 'waiting_group_head'
  and exists (select 1 from public.shift_change_approvals g
              where g.request_id = r.id and g.step_code = 'group_head'
                and g.decision = 'skipped');

create or replace function shift_exchange_private.get_my_shift_calendar(p_month date)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'auth', 'shift_exchange_private'
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

  with calendar_rows as (
    select
      e.id::text as id, e.staff_directory_id, e.shift_date, e.shift_period,
      e.shift_type, e.note, e.source, e.exchange_request_id,
      case when e.exchange_request_id is not null then r.status else null end as exchange_status
    from public.shift_schedule_entries e
    left join public.shift_change_requests r on r.id = e.exchange_request_id
    where e.staff_directory_id = v_staff_id
      and e.shift_date >= p_month
      and e.shift_date < (p_month + interval '1 month')::date

    union all

    -- Virtual pending items: visible in the calendar without creating a fabricated schedule row.
    select
      ('pending-' || r.id::text || '-requester') as id,
      r.requester_staff_directory_id as staff_directory_id,
      r.shift_date, r.shift_period, r.request_type as shift_type,
      coalesce(r.requester_note, 'รายการแลกเวรรอดำเนินการ') as note,
      'exchange'::text as source, r.id as exchange_request_id, r.status as exchange_status
    from public.shift_change_requests r
    where r.requester_staff_directory_id = v_staff_id
      and r.status in ('waiting_recipient','waiting_unit_head','waiting_group_head','waiting_nursing_head')
      and r.shift_date >= p_month
      and r.shift_date < (p_month + interval '1 month')::date
      and not exists (
        select 1 from public.shift_schedule_entries e
        where e.exchange_request_id = r.id
          and e.staff_directory_id = v_staff_id
          and e.shift_date = r.shift_date
          and e.shift_period = r.shift_period
      )

    union all

    select
      ('pending-' || r.id::text || '-replacement') as id,
      r.recipient_staff_directory_id as staff_directory_id,
      r.replacement_date as shift_date, r.replacement_period as shift_period,
      r.request_type as shift_type,
      coalesce(r.requester_note, 'รายการรับเวรทดแทนรอดำเนินการ') as note,
      'exchange'::text as source, r.id as exchange_request_id, r.status as exchange_status
    from public.shift_change_requests r
    where r.recipient_staff_directory_id = v_staff_id
      and r.replacement_required
      and r.status in ('waiting_recipient','waiting_unit_head','waiting_group_head','waiting_nursing_head')
      and r.replacement_date >= p_month
      and r.replacement_date < (p_month + interval '1 month')::date
      and not exists (
        select 1 from public.shift_schedule_entries e
        where e.exchange_request_id = r.id
          and e.staff_directory_id = v_staff_id
          and e.shift_date = r.replacement_date
          and e.shift_period = r.replacement_period
      )
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id,
    'staff_directory_id', staff_directory_id,
    'shift_date', shift_date,
    'shift_period', shift_period,
    'shift_type', shift_type,
    'note', note,
    'source', source,
    'exchange_request_id', exchange_request_id,
    'exchange_status', exchange_status
  ) order by shift_date, shift_period), '[]'::jsonb)
  into v_rows
  from calendar_rows;

  return v_rows;
end;
$function$;

create or replace function public.get_my_shift_calendar(p_month date)
returns jsonb
language sql
set search_path to 'pg_catalog', 'public', 'auth', 'shift_exchange_private'
as $function$
  select shift_exchange_private.get_my_shift_calendar(p_month);
$function$;

commit;
