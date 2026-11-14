-- Personal calendar shows the resulting shift after exchange, not the shift transferred away.
CREATE OR REPLACE FUNCTION shift_exchange_private.get_my_shift_calendar(p_month date)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'shift_exchange_private'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_staff_id integer;
  v_rows jsonb;
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
  with calendar_rows as (
    select e.id::text id, e.staff_directory_id, e.shift_date, e.shift_period, e.shift_type, e.note, e.source, e.exchange_request_id,
      case when e.exchange_request_id is not null then r.status else null end exchange_status
    from public.shift_schedule_entries e
    left join public.shift_change_requests r on r.id=e.exchange_request_id
    where e.staff_directory_id=v_staff_id and e.shift_date>=p_month and e.shift_date<(p_month+interval '1 month')::date
    union all
    select 'pending-'||r.id::text||'-replacement-requester',r.requester_staff_directory_id,r.replacement_date,r.replacement_period,r.request_type,
      'รอรับเวรทดแทนจาก '||r.recipient_name,'exchange'::text,r.id,r.status
    from public.shift_change_requests r
    where r.requester_staff_directory_id=v_staff_id and r.replacement_required
      and r.status in ('waiting_recipient','waiting_unit_head','waiting_group_head','waiting_nursing_head')
      and r.replacement_date>=p_month and r.replacement_date<(p_month+interval '1 month')::date
      and not exists(select 1 from public.shift_schedule_entries e where e.exchange_request_id=r.id and e.staff_directory_id=v_staff_id and e.shift_date=r.replacement_date and e.shift_period=r.replacement_period)
    union all
    select 'pending-'||r.id::text||'-recipient',r.recipient_staff_directory_id,r.shift_date,r.shift_period,r.request_type,
      'รอรับเวรจาก '||r.requester_name,'exchange'::text,r.id,r.status
    from public.shift_change_requests r
    where r.recipient_staff_directory_id=v_staff_id and r.status in ('waiting_recipient','waiting_unit_head','waiting_group_head','waiting_nursing_head')
      and r.shift_date>=p_month and r.shift_date<(p_month+interval '1 month')::date
      and not exists(select 1 from public.shift_schedule_entries e where e.exchange_request_id=r.id and e.staff_directory_id=v_staff_id and e.shift_date=r.shift_date and e.shift_period=r.shift_period)
  )
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'staff_directory_id',staff_directory_id,'shift_date',shift_date,
    'shift_period',shift_period,'shift_type',shift_type,'note',note,'source',source,'exchange_request_id',exchange_request_id,'exchange_status',exchange_status)
    order by shift_date,shift_period),'[]'::jsonb) into v_rows from calendar_rows;
  return v_rows;
end;
$function$;
