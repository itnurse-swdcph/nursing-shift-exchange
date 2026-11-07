-- P4P-aligned multi-level approval routing and duplicate-approver suppression.
alter table public.shift_change_requests drop constraint if exists shift_change_requests_status_check;
alter table public.shift_change_requests add constraint shift_change_requests_status_check
 check (status in ('waiting_recipient','waiting_unit_head','waiting_group_head','waiting_nursing_head','approved','rejected','cancelled'));
alter table public.shift_change_approvals drop constraint if exists shift_change_approvals_step_code_check;
alter table public.shift_change_approvals add constraint shift_change_approvals_step_code_check
 check (step_code in ('unit_head','group_head','nursing_head'));

CREATE OR REPLACE FUNCTION shift_exchange_private.cancel_shift_change_request(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'shift_exchange_private'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_request public.shift_change_requests%rowtype;
begin
  if v_uid is null then raise exception 'กรุณาเข้าสู่ระบบก่อนดำเนินการ'; end if;

  select r.* into v_request
  from public.shift_change_requests r
  where r.id = p_request_id
  for update;

  if not found or v_request.requester_user_id <> v_uid then
    raise exception 'คุณไม่มีสิทธิ์ยกเลิกคำขอนี้';
  end if;
  if v_request.status not in ('waiting_recipient', 'waiting_unit_head', 'waiting_group_head', 'waiting_nursing_head') then
    raise exception 'ไม่สามารถยกเลิกคำขอในสถานะปัจจุบันได้';
  end if;

  update public.shift_change_approvals
  set decision = 'skipped',
      acted_by = v_uid,
      comment = 'ยกเลิกคำขอโดยผู้ขอ',
      acted_at = now()
  where request_id = p_request_id and decision = 'pending';

  update public.shift_change_requests
  set status = 'cancelled', updated_at = now()
  where id = p_request_id;

  return jsonb_build_object('request_id', p_request_id, 'status', 'cancelled');
end;
$function$


CREATE OR REPLACE FUNCTION shift_exchange_private.create_shift_change_request(p_recipient_staff_directory_id integer, p_request_type text, p_shift_date date, p_shift_period text, p_document_number text DEFAULT NULL::text, p_document_date date DEFAULT NULL::date, p_replacement_required boolean DEFAULT false, p_replacement_date date DEFAULT NULL::date, p_replacement_period text DEFAULT NULL::text, p_requester_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'shift_exchange_private'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_requester public.staff_directory%rowtype;
  v_recipient public.staff_directory%rowtype;
  v_unit public.staff_directory%rowtype;
  v_group public.staff_directory%rowtype;
  v_final public.staff_directory%rowtype;
  v_doc_id uuid;
  v_request_id uuid;
  v_recipient_user_id uuid;
  v_unit_id integer;
  v_group_id integer;
  v_final_id integer;
  v_unit_skipped boolean := false;
  v_group_skipped boolean := false;
  v_final_skipped boolean := false;
begin
  if v_uid is null then raise exception 'กรุณาเข้าสู่ระบบก่อนส่งคำขอ'; end if;
  select sd.* into v_requester from public.profiles p join public.staff_directory sd on sd.source_row=p.staff_directory_id
  where p.user_id=v_uid and sd.active is true;
  if not found then raise exception 'บัญชีนี้ยังไม่เชื่อมโยงกับทะเบียนบุคลากรที่ปฏิบัติงาน'; end if;
  if p_recipient_staff_directory_id is null or p_recipient_staff_directory_id=v_requester.source_row then
    raise exception 'กรุณาเลือกผู้รับเปลี่ยนเวรที่เป็นบุคคลอื่น';
  end if;
  select * into v_recipient from public.staff_directory where source_row=p_recipient_staff_directory_id and active is true;
  if not found then raise exception 'ไม่พบผู้รับเปลี่ยนเวรในทะเบียนบุคลากรที่ยังปฏิบัติงาน'; end if;
  if p_request_type is null or p_request_type not in ('unit','refer','supervision') then raise exception 'ประเภทเวรไม่ถูกต้อง'; end if;
  if p_shift_date is null or p_shift_period is null or p_shift_period not in ('morning','afternoon','night') then raise exception 'กรุณาระบุวันที่และช่วงเวรให้ถูกต้อง'; end if;
  if p_replacement_required is null then raise exception 'กรุณาระบุเงื่อนไขการทดแทนเวร'; end if;
  if p_replacement_required and (p_replacement_date is null or p_replacement_period is null or p_replacement_period not in ('morning','afternoon','night')) then raise exception 'กรุณาระบุวันที่และช่วงเวรที่ต้องทดแทน'; end if;
  if not p_replacement_required and (p_replacement_date is not null or p_replacement_period is not null) then raise exception 'ไม่ต้องระบุวันทดแทนเมื่อเลือกไม่ทดแทน'; end if;

  if nullif(trim(coalesce(p_document_number,'')),'') is not null then
    if p_document_number !~ '^[0-9]+/[0-9]{4}$' or p_document_date is null then raise exception 'เลขที่หนังสือ/คำสั่งต้องอยู่ในรูปแบบ 123/2569 และต้องระบุวันที่เอกสาร'; end if;
    select id into v_doc_id from public.shift_change_documents where document_number=trim(p_document_number);
    if v_doc_id is not null then
      if not exists(select 1 from public.shift_change_documents where id=v_doc_id and document_date=p_document_date) then raise exception 'เลขที่หนังสือนี้เคยบันทึกไว้ด้วยวันที่เอกสารอื่น'; end if;
    else
      insert into public.shift_change_documents(document_number,document_date,created_by) values(trim(p_document_number),p_document_date,v_uid) returning id into v_doc_id;
    end if;
  elsif p_document_date is not null then raise exception 'หากระบุวันที่เอกสาร ต้องระบุเลขที่หนังสือ/คำสั่งด้วย';
  end if;

  select * into v_final from public.staff_directory where active and source_row=2;
  if not found then raise exception 'ไม่พบหัวหน้าพยาบาล/รักษาการหัวหน้าพยาบาลในทะเบียนบุคลากร'; end if;
  v_final_id := v_final.source_row;

  -- Unit head: match primary and every additional unit (comma, semicolon or pipe separated).
  select h.* into v_unit
  from public.staff_directory h
  where h.active and h.source_row<>v_requester.source_row
    and (replace(trim(coalesce(h.org_role,'')),' ','')='หัวหน้างาน' or h.source_row in (2,6,21,148,165))
    and v_requester.unit_name is not null
    and exists(select 1 from regexp_split_to_table(concat_ws('|',nullif(h.unit_name,''),nullif(h.extra_unit_names,'')),'[,;|]') x(unit_name)
      where trim(x.unit_name)=trim(v_requester.unit_name))
  order by case when trim(coalesce(h.unit_name,''))=trim(v_requester.unit_name) then 0 else 1 end,
    case when replace(trim(coalesce(h.org_role,'')),' ','')='หัวหน้างาน' then 0 else 1 end,h.source_row
  limit 1;
  if found then v_unit_id:=v_unit.source_row; end if;

  -- Group head: match every group assigned to the requester and every group assigned to the approver.
  select h.* into v_group
  from public.staff_directory h
  where h.active and h.source_row<>v_requester.source_row
    and replace(trim(coalesce(h.org_role,'')),' ','')='หัวหน้ากลุ่มงาน'
    and exists(
      select 1
      from regexp_split_to_table(concat_ws('|',nullif(v_requester.nursing_group,''),nullif(v_requester.extra_nursing_group_names,'')),'[,;|]') rg(group_name)
      join regexp_split_to_table(concat_ws('|',nullif(h.nursing_group,''),nullif(h.extra_nursing_group_names,'')),'[,;|]') hg(group_name)
        on trim(rg.group_name)=trim(hg.group_name)
      where trim(rg.group_name)<>''
    )
  order by case when trim(coalesce(h.nursing_group,''))=trim(coalesce(v_requester.nursing_group,'')) then 0 else 1 end,h.source_row
  limit 1;
  if found then v_group_id:=v_group.source_row; end if;

  -- If a unit head exists but no group head is assigned, skip group approval and proceed to nursing head.
  if v_unit_id is not null and v_group_id is null then v_group_skipped:=true; end if;

  -- No assigned unit/group head: the final approver becomes the first available approval.
  if v_unit_id is null and v_group_id is null then v_group_id:=v_final_id; end if;

  -- Deduplicate the chain: the first completed occurrence of a person satisfies all later levels.
  if v_unit_id is not null and v_unit_id=v_group_id then v_group_skipped:=true; end if;
  if v_unit_id is not null and v_unit_id=v_final_id then v_group_skipped:=true; v_final_skipped:=true; end if;
  if v_unit_id is null and v_group_id=v_final_id then v_final_skipped:=true; end if;
  -- If the group-level approver is the final nursing head, the group approval is the final approval.
  if v_group_id is not null and v_group_id=v_final_id then v_final_skipped:=true; end if;
  -- If no unit head exists, group approval occupies the first actionable stage.
  if v_unit_id is null then v_unit_skipped:=true; end if;
  -- If requester is the final approver, retain final self-approval while skipping earlier self-approval.
  if v_requester.source_row=v_final_id then
    v_unit_skipped:=true;
    if v_group_id=v_final_id then v_group_skipped:=true; v_final_skipped:=false; end if;
  end if;

  select p.user_id into v_recipient_user_id from public.profiles p where p.staff_directory_id=v_recipient.source_row limit 1;
  if v_recipient_user_id is null then raise exception 'ผู้รับเปลี่ยนเวรยังไม่มีบัญชีผู้ใช้ในระบบ จึงยังไม่สามารถตอบรับคำขอได้'; end if;

  insert into public.shift_change_requests(
    requester_user_id,requester_staff_directory_id,requester_name,requester_unit_name,request_type,shift_date,shift_period,document_id,
    recipient_user_id,recipient_staff_directory_id,recipient_name,replacement_required,replacement_date,replacement_period,requester_note,status
  ) values(
    v_uid,v_requester.source_row,concat_ws(' ',v_requester.prefix,v_requester.first_name,v_requester.last_name),coalesce(v_requester.unit_name,''),
    p_request_type,p_shift_date,p_shift_period,v_doc_id,v_recipient_user_id,v_recipient.source_row,
    concat_ws(' ',v_recipient.prefix,v_recipient.first_name,v_recipient.last_name),p_replacement_required,
    case when p_replacement_required then p_replacement_date end,case when p_replacement_required then p_replacement_period end,
    nullif(trim(coalesce(p_requester_note,'')),''),'waiting_recipient'
  ) returning id into v_request_id;

  insert into public.shift_change_approvals(request_id,step_code,approver_staff_directory_id,approver_user_id,approver_name,approver_org_role,decision,comment,acted_at)
  values(v_request_id,'unit_head',coalesce(v_unit_id,v_group_id,v_final_id),
    (select user_id from public.profiles where staff_directory_id=coalesce(v_unit_id,v_group_id,v_final_id) limit 1),
    (select concat_ws(' ',prefix,first_name,last_name) from public.staff_directory where source_row=coalesce(v_unit_id,v_group_id,v_final_id)),
    (select org_role from public.staff_directory where source_row=coalesce(v_unit_id,v_group_id,v_final_id)),
    case when v_unit_skipped then 'skipped' else 'pending' end,
    case when v_unit_skipped then 'ไม่มีหัวหน้างานในหน่วยงานนี้ หรือข้ามขั้นเพื่อไม่ให้บุคคลเดียวกันอนุมัติซ้ำ' end,
    case when v_unit_skipped then now() end);

  insert into public.shift_change_approvals(request_id,step_code,approver_staff_directory_id,approver_user_id,approver_name,approver_org_role,decision,comment,acted_at)
  values(v_request_id,'group_head',coalesce(v_group_id,v_final_id),
    (select user_id from public.profiles where staff_directory_id=coalesce(v_group_id,v_final_id) limit 1),
    (select concat_ws(' ',prefix,first_name,last_name) from public.staff_directory where source_row=coalesce(v_group_id,v_final_id)),
    (select org_role from public.staff_directory where source_row=coalesce(v_group_id,v_final_id)),
    case when v_group_skipped then 'skipped' else 'pending' end,
    case when v_group_skipped then 'ไม่มีผู้อนุมัติกลุ่มงานแยกต่างหาก หรือบุคคลเดียวกับขั้นก่อนหน้า/ขั้นสุดท้าย' end,
    case when v_group_skipped then now() end);

  insert into public.shift_change_approvals(request_id,step_code,approver_staff_directory_id,approver_user_id,approver_name,approver_org_role,decision,comment,acted_at)
  values(v_request_id,'nursing_head',v_final_id,
    (select user_id from public.profiles where staff_directory_id=v_final_id limit 1),
    concat_ws(' ',v_final.prefix,v_final.first_name,v_final.last_name),v_final.org_role,
    case when v_final_skipped then 'skipped' else 'pending' end,
    case when v_final_skipped then 'ผู้อนุมัติคนเดียวกันได้อนุมัติในขั้นก่อนหน้าแล้ว จึงไม่ต้องอนุมัติซ้ำ' end,
    case when v_final_skipped then now() end);

  return v_request_id;
end;
$function$


CREATE OR REPLACE FUNCTION shift_exchange_private.decide_shift_change_approval(p_request_id uuid, p_decision text, p_comment text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'shift_exchange_private'
AS $function$
declare v_uid uuid:=auth.uid(); v_staff_id integer; v_request public.shift_change_requests%rowtype;
  v_step text; v_approval_id uuid; v_next_step text; v_next_status text;
begin
  if v_uid is null then raise exception 'กรุณาเข้าสู่ระบบก่อนดำเนินการ'; end if;
  if p_decision not in ('approved','rejected') then raise exception 'ผลการอนุมัติไม่ถูกต้อง'; end if;
  select staff_directory_id into v_staff_id from public.profiles where user_id=v_uid;
  select * into v_request from public.shift_change_requests where id=p_request_id for update;
  if not found then raise exception 'ไม่พบคำขอเปลี่ยนเวร'; end if;
  v_step:=case v_request.status when 'waiting_unit_head' then 'unit_head' when 'waiting_group_head' then 'group_head'
    when 'waiting_nursing_head' then 'nursing_head' else null end;
  if v_step is null then raise exception 'คำขอนี้ไม่ได้อยู่ในสถานะรออนุมัติ'; end if;
  select id into v_approval_id from public.shift_change_approvals where request_id=p_request_id and step_code=v_step
    and decision='pending' and approver_staff_directory_id=v_staff_id for update;
  if v_approval_id is null then raise exception 'บัญชีนี้ไม่ใช่ผู้อนุมัติที่ได้รับมอบหมายในขั้นตอนนี้'; end if;

  update public.shift_change_approvals set decision=p_decision,acted_by=v_uid,
    comment=nullif(trim(coalesce(p_comment,'')),''),acted_at=now() where id=v_approval_id;
  if p_decision='rejected' then
    update public.shift_change_approvals set decision='skipped',acted_by=v_uid,comment='คำขอไม่ผ่านการอนุมัติในขั้นก่อนหน้า',acted_at=now()
    where request_id=p_request_id and decision='pending';
    v_next_status:='rejected';
  else
    select step_code into v_next_step from public.shift_change_approvals where request_id=p_request_id and decision='pending'
    order by case step_code when 'unit_head' then 1 when 'group_head' then 2 else 3 end limit 1;
    v_next_status:=case v_next_step when 'unit_head' then 'waiting_unit_head' when 'group_head' then 'waiting_group_head'
      when 'nursing_head' then 'waiting_nursing_head' else 'approved' end;
  end if;
  update public.shift_change_requests set status=v_next_status,updated_at=now() where id=p_request_id;
  return jsonb_build_object('request_id',p_request_id,'status',v_next_status,'step',v_step);
end;
$function$


CREATE OR REPLACE FUNCTION shift_exchange_private.get_shift_exchange_pending_approvals()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'shift_exchange_private'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',r.id,'requester_name',r.requester_name,'requester_unit_name',r.requester_unit_name,
    'recipient_name',r.recipient_name,'request_type',r.request_type,'shift_date',r.shift_date,
    'shift_period',r.shift_period,'status',r.status,'requester_note',r.requester_note,
    'replacement_required',r.replacement_required,'replacement_date',r.replacement_date,
    'replacement_period',r.replacement_period,'created_at',r.created_at,
    'document',(select jsonb_build_object('document_number',d.document_number,'document_date',d.document_date)
      from public.shift_change_documents d where d.id=r.document_id),
    'approval',jsonb_build_object('step_code',a.step_code,'approver_name',a.approver_name,
      'approver_org_role',a.approver_org_role,'decision',a.decision,'comment',a.comment)
  ) order by r.created_at),'[]'::jsonb)
  from public.shift_change_approvals a join public.shift_change_requests r on r.id=a.request_id
  join public.profiles p on p.user_id=auth.uid()
  where a.approver_staff_directory_id=p.staff_directory_id and a.decision='pending'
    and ((a.step_code='unit_head' and r.status='waiting_unit_head')
      or (a.step_code='group_head' and r.status='waiting_group_head')
      or (a.step_code='nursing_head' and r.status='waiting_nursing_head'));
$function$


CREATE OR REPLACE FUNCTION shift_exchange_private.respond_to_shift_change_request(p_request_id uuid, p_decision text, p_comment text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'shift_exchange_private'
AS $function$
declare v_uid uuid:=auth.uid(); v_request public.shift_change_requests%rowtype; v_staff_id integer; v_next_step text; v_next_status text;
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
    select step_code into v_next_step from public.shift_change_approvals
    where request_id=p_request_id and decision='pending'
    order by case step_code when 'unit_head' then 1 when 'group_head' then 2 else 3 end limit 1;
    v_next_status:=case v_next_step when 'unit_head' then 'waiting_unit_head' when 'group_head' then 'waiting_group_head'
      when 'nursing_head' then 'waiting_nursing_head' else 'approved' end;
  end if;
  update public.shift_change_requests set recipient_user_id=v_uid,recipient_decision=p_decision,
    recipient_comment=nullif(trim(coalesce(p_comment,'')),''),recipient_acted_by=v_uid,recipient_acted_at=now(),
    status=v_next_status,updated_at=now() where id=p_request_id;
  return jsonb_build_object('request_id',p_request_id,'status',v_next_status);
end;
$function$

