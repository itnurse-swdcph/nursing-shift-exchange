create index if not exists shift_change_requests_history_date_idx
  on public.shift_change_requests (shift_date desc, requester_unit_name);

create index if not exists shift_change_requests_history_staff_idx
  on public.shift_change_requests (requester_staff_directory_id, shift_date desc);

create or replace function public.get_shift_exchange_history_search(
  p_group_name text default null,
  p_unit_name text default null,
  p_staff_directory_id integer default null,
  p_date_from date default null,
  p_date_to date default null,
  p_status text default null,
  p_search text default null,
  p_limit integer default 5000
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, auth, shift_exchange_private
as $function$
declare
  v_uid uuid := auth.uid();
  v_allowed boolean := false;
  v_rows jsonb;
begin
  if v_uid is null then
    raise exception 'กรุณาเข้าสู่ระบบ';
  end if;

  v_allowed := shift_exchange_private.is_central_admin(v_uid)
    or exists (
      select 1
      from public.profiles p
      left join public.staff_directory sd on sd.source_row = p.staff_directory_id
      where p.user_id = v_uid
        and (
          p.role in ('head', 'group_head')
          or coalesce(nullif(trim(p.org_role), ''), sd.org_role) in (
            'หัวหน้างาน', 'หัวหน้ากลุ่มงาน', 'หัวหน้าพยาบาล', 'รักษาการหัวหน้าพยาบาล'
          )
        )
    );

  if not v_allowed then
    raise exception 'ไม่มีสิทธิ์สืบค้นประวัติการแลกเปลี่ยนเวร';
  end if;

  select coalesce(jsonb_agg(result_row.payload order by result_row.shift_date desc, result_row.created_at desc), '[]'::jsonb)
    into v_rows
  from (
    select
      r.shift_date,
      r.created_at,
      jsonb_build_object(
        'id', r.id,
        'requester_name', r.requester_name,
        'requester_staff_directory_id', r.requester_staff_directory_id,
        'requester_unit_name', r.requester_unit_name,
        'group_name', coalesce(u.parent_group, requester_staff.nursing_group),
        'recipient_name', r.recipient_name,
        'recipient_staff_directory_id', r.recipient_staff_directory_id,
        'recipient_decision', r.recipient_decision,
        'recipient_comment', r.recipient_comment,
        'recipient_acted_at', r.recipient_acted_at,
        'request_type', r.request_type,
        'shift_date', r.shift_date,
        'shift_period', r.shift_period,
        'status', r.status,
        'requester_note', r.requester_note,
        'replacement_required', r.replacement_required,
        'replacement_date', r.replacement_date,
        'replacement_period', r.replacement_period,
        'created_at', r.created_at,
        'updated_at', r.updated_at,
        'document', (
          select jsonb_build_object('document_number', d.document_number, 'document_date', d.document_date)
          from public.shift_change_documents d where d.id = r.document_id
        ),
        'approvals', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'step_code', a.step_code,
            'approver_name', a.approver_name,
            'approver_staff_directory_id', a.approver_staff_directory_id,
            'approver_org_role', a.approver_org_role,
            'decision', a.decision,
            'comment', a.comment,
            'acted_at', a.acted_at
          ) order by a.created_at), '[]'::jsonb)
          from public.shift_change_approvals a where a.request_id = r.id
        )
      ) as payload
    from public.shift_change_requests r
    left join public.units u on trim(u.name) = trim(r.requester_unit_name)
    left join public.staff_directory requester_staff on requester_staff.source_row = r.requester_staff_directory_id
    where (nullif(trim(p_group_name), '') is null or coalesce(u.parent_group, requester_staff.nursing_group) = trim(p_group_name))
      and (nullif(trim(p_unit_name), '') is null or r.requester_unit_name = trim(p_unit_name))
      and (p_staff_directory_id is null or r.requester_staff_directory_id = p_staff_directory_id)
      and (p_date_from is null or r.shift_date >= p_date_from)
      and (p_date_to is null or r.shift_date <= p_date_to)
      and (nullif(trim(p_status), '') is null or r.status = trim(p_status))
      and (
        nullif(trim(p_search), '') is null
        or concat_ws(' ', r.requester_name, r.recipient_name, r.requester_unit_name, r.requester_note,
          (select d.document_number from public.shift_change_documents d where d.id = r.document_id)
        ) ilike '%' || trim(p_search) || '%'
      )
    order by r.shift_date desc, r.created_at desc
    limit greatest(1, least(coalesce(p_limit, 5000), 5000))
  ) result_row;

  return v_rows;
end;
$function$;

revoke all on function public.get_shift_exchange_history_search(text,text,integer,date,date,text,text,integer) from public, anon;
grant execute on function public.get_shift_exchange_history_search(text,text,integer,date,date,text,text,integer) to authenticated;