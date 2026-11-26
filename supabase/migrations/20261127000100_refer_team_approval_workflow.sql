
-- Dedicated first approval for Refer shift exchanges.
alter table public.shift_change_requests drop constraint if exists shift_change_requests_status_check;
alter table public.shift_change_requests add constraint shift_change_requests_status_check
  check (status in ('waiting_recipient','waiting_unit_head','waiting_group_head','waiting_refer_head','waiting_nursing_head','approved','rejected','cancelled'));

alter table public.shift_change_approvals drop constraint if exists shift_change_approvals_step_code_check;
alter table public.shift_change_approvals add constraint shift_change_approvals_step_code_check
  check (step_code in ('unit_head','group_head','refer_head','nursing_head'));

create or replace function shift_exchange_private.route_refer_approval_insert()
returns trigger language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare v_type text;
begin
  select request_type into v_type from public.shift_change_requests where id = new.request_id;
  if v_type = 'refer' then
    if new.step_code = 'unit_head' then
      new.step_code := 'refer_head';
      new.approver_staff_directory_id := 378;
      select user_id into new.approver_user_id from public.profiles where staff_directory_id = 378 limit 1;
      select concat_ws(' ',prefix,first_name,last_name), 'หัวหน้าทีมการพยาบาลส่งต่อ'
        into new.approver_name,new.approver_org_role
      from public.staff_directory where source_row = 378;
      new.decision := 'pending'; new.comment := null; new.acted_by := null; new.acted_at := null;
    elsif new.step_code = 'group_head' then
      new.decision := 'skipped';
      new.comment := 'เวร Refer ใช้หัวหน้าทีมการพยาบาลส่งต่อเป็นผู้อนุมัติขั้นต้น';
      new.acted_at := now();
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_route_refer_approval_insert on public.shift_change_approvals;
create trigger trg_route_refer_approval_insert before insert on public.shift_change_approvals
for each row execute function shift_exchange_private.route_refer_approval_insert();

create or replace function shift_exchange_private.respond_to_shift_change_request(
  p_request_id uuid, p_decision text, p_comment text default null
) returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, auth, shift_exchange_private
as $$
declare v_uid uuid:=auth.uid(); v_request public.shift_change_requests%rowtype;
  v_staff_id integer; v_next_step text; v_next_status text;
begin
  if v_uid is null then raise exception 'กรุณาเข้าสู่ระบบก่อนดำเนินการ'; end if;
  if p_decision not in ('accepted','rejected') then raise exception 'การตอบรับคำขอไม่ถูกต้อง'; end if;
  select staff_directory_id into v_staff_id from public.profiles where user_id=v_uid;
  select * into v_request from public.shift_change_requests where id=p_request_id for update;
  if not found or v_request.recipient_staff_directory_id is distinct from v_staff_id then raise exception 'คุณไม่มีสิทธิ์ดำเนินการกับคำขอนี้'; end if;
  if v_request.status<>'waiting_recipient' then raise exception 'คำขอนี้ไม่ได้อยู่ในสถานะรอรับงานแล้ว'; end if;
  if p_decision='rejected' then
    update public.shift_change_approvals set decision='skipped',acted_by=v_uid,comment='ผู้รับปฏิเสธการรับเปลี่ยนเวร',acted_at=now()
    where request_id=p_request_id and decision='pending';
    v_next_status:='rejected';
  else
    select step_code into v_next_step from public.shift_change_approvals where request_id=p_request_id and decision='pending'
    order by case step_code when 'unit_head' then 1 when 'group_head' then 2 when 'refer_head' then 3 else 4 end limit 1;
    v_next_status:=case v_next_step when 'unit_head' then 'waiting_unit_head' when 'group_head' then 'waiting_group_head'
      when 'refer_head' then 'waiting_refer_head' when 'nursing_head' then 'waiting_nursing_head' else 'approved' end;
  end if;
  update public.shift_change_requests set recipient_user_id=v_uid,recipient_decision=p_decision,
    recipient_comment=nullif(trim(coalesce(p_comment,'')),''),recipient_acted_by=v_uid,recipient_acted_at=now(),
    status=v_next_status,updated_at=now() where id=p_request_id;
  return jsonb_build_object('request_id',p_request_id,'status',v_next_status);
end;
$$;

create or replace function shift_exchange_private.decide_shift_change_approval(
  p_request_id uuid, p_decision text, p_comment text default null
) returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, auth, shift_exchange_private
as $$
declare v_uid uuid:=auth.uid(); v_staff_id integer; v_request public.shift_change_requests%rowtype;
  v_step text; v_approval_id uuid; v_next_step text; v_next_status text; v_name text;
begin
  if v_uid is null then raise exception 'กรุณาเข้าสู่ระบบก่อนดำเนินการ'; end if;
  if p_decision not in ('approved','rejected') then raise exception 'ผลการอนุมัติไม่ถูกต้อง'; end if;
  select staff_directory_id into v_staff_id from public.profiles where user_id=v_uid;
  select * into v_request from public.shift_change_requests where id=p_request_id for update;
  if not found then raise exception 'ไม่พบคำขอเปลี่ยนเวร'; end if;
  v_step:=case v_request.status when 'waiting_unit_head' then 'unit_head' when 'waiting_group_head' then 'group_head'
    when 'waiting_refer_head' then 'refer_head' when 'waiting_nursing_head' then 'nursing_head' else null end;
  if v_step is null then raise exception 'คำขอนี้ไม่ได้อยู่ในสถานะรออนุมัติ'; end if;
  if v_step='refer_head' and (v_request.request_type<>'refer' or v_staff_id not in (378,411)
    or v_staff_id=v_request.requester_staff_directory_id) then
    raise exception 'เฉพาะหัวหน้าทีมการพยาบาลส่งต่อที่ได้รับมอบหมายเท่านั้นจึงอนุมัติขั้นตอนนี้ได้';
  end if;
  select id into v_approval_id from public.shift_change_approvals
  where request_id=p_request_id and step_code=v_step and decision='pending'
    and ((v_step='refer_head' and v_request.request_type='refer' and v_staff_id in (378,411)) or approver_staff_directory_id=v_staff_id)
  for update;
  if v_approval_id is null then raise exception 'บัญชีนี้ไม่ใช่ผู้อนุมัติที่ได้รับมอบหมายในขั้นตอนนี้'; end if;
  if v_step='refer_head' then
    select concat_ws(' ',prefix,first_name,last_name) into v_name from public.staff_directory where source_row=v_staff_id;
    update public.shift_change_approvals set approver_staff_directory_id=v_staff_id,approver_user_id=v_uid,
      approver_name=v_name,approver_org_role='หัวหน้าทีมการพยาบาลส่งต่อ' where id=v_approval_id;
  end if;
  update public.shift_change_approvals set decision=p_decision,acted_by=v_uid,
    comment=nullif(trim(coalesce(p_comment,'')),''),acted_at=now() where id=v_approval_id;
  if p_decision='rejected' then
    update public.shift_change_approvals set decision='skipped',acted_by=v_uid,
      comment='คำขอไม่ผ่านการอนุมัติในขั้นก่อนหน้า',acted_at=now() where request_id=p_request_id and decision='pending';
    v_next_status:='rejected';
  else
    select step_code into v_next_step from public.shift_change_approvals where request_id=p_request_id and decision='pending'
    order by case step_code when 'unit_head' then 1 when 'group_head' then 2 when 'refer_head' then 3 else 4 end limit 1;
    v_next_status:=case v_next_step when 'unit_head' then 'waiting_unit_head' when 'group_head' then 'waiting_group_head'
      when 'refer_head' then 'waiting_refer_head' when 'nursing_head' then 'waiting_nursing_head' else 'approved' end;
  end if;
  update public.shift_change_requests set status=v_next_status,updated_at=now() where id=p_request_id;
  return jsonb_build_object('request_id',p_request_id,'status',v_next_status,'step',v_step);
end;
$$;

create or replace function shift_exchange_private.get_shift_exchange_pending_approvals()
returns jsonb language sql security definer
set search_path = pg_catalog, public, auth, shift_exchange_private
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',r.id,'requester_name',r.requester_name,'requester_unit_name',r.requester_unit_name,
    'requester_staff_directory_id',r.requester_staff_directory_id,'recipient_name',r.recipient_name,
    'request_type',r.request_type,'shift_date',r.shift_date,'shift_period',r.shift_period,
    'status',r.status,'requester_note',r.requester_note,'replacement_required',r.replacement_required,
    'replacement_date',r.replacement_date,'replacement_period',r.replacement_period,'created_at',r.created_at,
    'document',(select jsonb_build_object('document_number',d.document_number,'document_date',d.document_date)
      from public.shift_change_documents d where d.id=r.document_id),
    'approval',jsonb_build_object('step_code',a.step_code,'approver_name',a.approver_name,
      'approver_org_role',a.approver_org_role,'decision',a.decision,'comment',a.comment)
  ) order by r.created_at),'[]'::jsonb)
  from public.shift_change_approvals a join public.shift_change_requests r on r.id=a.request_id
  join public.profiles p on p.user_id=auth.uid()
  where a.decision='pending' and (
    (a.approver_staff_directory_id=p.staff_directory_id and (
      (a.step_code='unit_head' and r.status='waiting_unit_head')
      or (a.step_code='group_head' and r.status='waiting_group_head')
      or (a.step_code='nursing_head' and r.status='waiting_nursing_head')
    ))
    or (a.step_code='refer_head' and r.request_type='refer' and r.status='waiting_refer_head'
      and p.staff_directory_id in (378,411) and r.requester_staff_directory_id<>p.staff_directory_id)
  );
$$;

create or replace function public.get_shift_exchange_history_search(
  p_group_name text default null,p_unit_name text default null,p_staff_directory_id integer default null,
  p_date_from date default null,p_date_to date default null,p_status text default null,
  p_search text default null,p_limit integer default 5000
) returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, public, auth, shift_exchange_private
as $$
declare v_uid uuid:=auth.uid(); v_allowed boolean:=false; v_refer_only boolean:=false; v_rows jsonb;
begin
  if v_uid is null then raise exception 'กรุณาเข้าสู่ระบบ'; end if;
  select exists(select 1 from public.profiles p where p.user_id=v_uid and p.staff_directory_id in (378,411)) into v_refer_only;
  v_allowed:=shift_exchange_private.is_central_admin(v_uid) or v_refer_only or exists(
    select 1 from public.profiles p left join public.staff_directory sd on sd.source_row=p.staff_directory_id
    where p.user_id=v_uid and (p.role in ('head','group_head')
      or coalesce(nullif(trim(p.org_role),''),sd.org_role) in ('หัวหน้างาน','หัวหน้ากลุ่มงาน','หัวหน้าพยาบาล','รักษาการหัวหน้าพยาบาล'))
  );
  if not v_allowed then raise exception 'ไม่มีสิทธิ์สืบค้นประวัติการแลกเปลี่ยนเวร'; end if;
  select coalesce(jsonb_agg(result_row.payload order by result_row.shift_date desc,result_row.created_at desc),'[]'::jsonb) into v_rows
  from (
    select r.shift_date,r.created_at,jsonb_build_object(
      'id',r.id,'requester_name',r.requester_name,'requester_staff_directory_id',r.requester_staff_directory_id,
      'requester_unit_name',r.requester_unit_name,'group_name',coalesce(nullif(trim(u.parent_group),''),requester_staff.nursing_group),
      'recipient_name',r.recipient_name,'recipient_staff_directory_id',r.recipient_staff_directory_id,
      'recipient_decision',r.recipient_decision,'recipient_comment',r.recipient_comment,'recipient_acted_at',r.recipient_acted_at,
      'request_type',r.request_type,'shift_date',r.shift_date,'shift_period',r.shift_period,'status',r.status,
      'requester_note',r.requester_note,'replacement_required',r.replacement_required,'replacement_date',r.replacement_date,
      'replacement_period',r.replacement_period,'created_at',r.created_at,'updated_at',r.updated_at,
      'document',(select jsonb_build_object('document_number',d.document_number,'document_date',d.document_date)
        from public.shift_change_documents d where d.id=r.document_id),
      'approvals',(select coalesce(jsonb_agg(jsonb_build_object('step_code',a.step_code,'approver_name',a.approver_name,
        'approver_staff_directory_id',a.approver_staff_directory_id,'approver_org_role',a.approver_org_role,
        'decision',a.decision,'comment',a.comment,'acted_at',a.acted_at) order by a.created_at),'[]'::jsonb)
        from public.shift_change_approvals a where a.request_id=r.id)
    ) as payload
    from public.shift_change_requests r
    left join public.units u on trim(u.name)=trim(r.requester_unit_name)
    left join public.staff_directory requester_staff on requester_staff.source_row=r.requester_staff_directory_id
    where (not v_refer_only or r.request_type='refer')
      and (nullif(trim(p_group_name),'') is null or coalesce(nullif(trim(u.parent_group),''),requester_staff.nursing_group)=trim(p_group_name))
      and (nullif(trim(p_unit_name),'') is null or r.requester_unit_name=trim(p_unit_name))
      and (p_staff_directory_id is null or r.requester_staff_directory_id=p_staff_directory_id)
      and (p_date_from is null or r.shift_date>=p_date_from) and (p_date_to is null or r.shift_date<=p_date_to)
      and (nullif(trim(p_status),'') is null or r.status=trim(p_status))
      and (nullif(trim(p_search),'') is null
        or concat_ws(' ',r.requester_name,r.recipient_name,r.requester_unit_name,r.requester_note,r.recipient_comment,
          (select d.document_number from public.shift_change_documents d where d.id=r.document_id)) ilike '%'||trim(p_search)||'%'
        or exists(select 1 from public.shift_change_approvals a where a.request_id=r.id
          and concat_ws(' ',a.approver_name,a.approver_org_role,a.comment) ilike '%'||trim(p_search)||'%'))
    order by r.shift_date desc,r.created_at desc limit greatest(1,least(coalesce(p_limit,5000),5000))
  ) result_row;
  return v_rows;
end;
$$;
revoke all on function public.get_shift_exchange_history_search(text,text,integer,date,date,text,text,integer) from public,anon;
grant execute on function public.get_shift_exchange_history_search(text,text,integer,date,date,text,text,integer) to authenticated;
