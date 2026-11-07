-- Secure workflow RPCs for Nursing Shift Exchange.
-- This migration only touches shift_change_* objects and a private helper schema.
-- It does not modify P4P tables, policies, functions, or Auth users.

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

alter table public.shift_change_requests
  add column if not exists recipient_decision text
    check (recipient_decision in ('accepted', 'rejected')),
  add column if not exists recipient_comment text,
  add column if not exists recipient_acted_by uuid references auth.users(id) on delete set null,
  add column if not exists recipient_acted_at timestamptz;

alter table public.shift_change_approvals
  add column if not exists approver_org_role text;

create index if not exists idx_shift_change_approvals_step_decision
  on public.shift_change_approvals (step_code, decision, request_id);

-- Resolve and create the request from the authenticated user's own staff mapping.
create or replace function private.create_shift_change_request(
  p_recipient_staff_directory_id integer,
  p_request_type text,
  p_shift_date date,
  p_shift_period text,
  p_document_number text default null,
  p_document_date date default null,
  p_replacement_required boolean default false,
  p_replacement_date date default null,
  p_replacement_period text default null,
  p_requester_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, auth, private
as $$
declare
  v_uid uuid := auth.uid();
  v_requester public.staff_directory%rowtype;
  v_recipient public.staff_directory%rowtype;
  v_first public.staff_directory%rowtype;
  v_final public.staff_directory%rowtype;
  v_first_count integer;
  v_final_count integer;
  v_use_group boolean := false;
  v_first_skipped boolean := false;
  v_doc_id uuid;
  v_request_id uuid;
  v_recipient_user_id uuid;
  v_first_name text;
  v_final_name text;
begin
  if v_uid is null then
    raise exception 'กรุณาเข้าสู่ระบบก่อนส่งคำขอ';
  end if;

  select sd.* into v_requester
  from public.profiles p
  join public.staff_directory sd on sd.source_row = p.staff_directory_id
  where p.user_id = v_uid and sd.active is true;

  if not found then
    raise exception 'บัญชีนี้ยังไม่เชื่อมโยงกับทะเบียนบุคลากรที่ปฏิบัติงาน';
  end if;

  if p_recipient_staff_directory_id is null
     or p_recipient_staff_directory_id = v_requester.source_row then
    raise exception 'กรุณาเลือกผู้รับเปลี่ยนเวรที่เป็นบุคคลอื่น';
  end if;

  select sd.* into v_recipient
  from public.staff_directory sd
  where sd.source_row = p_recipient_staff_directory_id
    and sd.active is true;

  if not found then
    raise exception 'ไม่พบผู้รับเปลี่ยนเวรในทะเบียนบุคลากรที่ยังปฏิบัติงาน';
  end if;

  if p_request_type is null or p_request_type not in ('unit', 'refer', 'supervision') then
    raise exception 'ประเภทเวรไม่ถูกต้อง';
  end if;
  if p_shift_date is null or p_shift_period is null or p_shift_period not in ('morning', 'afternoon', 'night') then
    raise exception 'กรุณาระบุวันที่และช่วงเวรให้ถูกต้อง';
  end if;
  if p_replacement_required is null then
    raise exception 'กรุณาระบุเงื่อนไขการทดแทนเวร';
  end if;
  if p_replacement_required and
     (p_replacement_date is null or p_replacement_period not in ('morning', 'afternoon', 'night')) then
    raise exception 'กรุณาระบุวันที่และช่วงเวรที่ต้องทดแทน';
  end if;
  if not p_replacement_required and
     (p_replacement_date is not null or p_replacement_period is not null) then
    raise exception 'ไม่ต้องระบุวันทดแทนเมื่อเลือกไม่ทดแทน';
  end if;

  if nullif(trim(coalesce(p_document_number, '')), '') is not null then
    if p_document_number !~ '^[0-9]+/[0-9]{4}$' or p_document_date is null then
      raise exception 'เลขที่หนังสือ/คำสั่งต้องอยู่ในรูปแบบ 123/2569 และต้องระบุวันที่เอกสาร';
    end if;
    select d.id into v_doc_id
    from public.shift_change_documents d
    where d.document_number = trim(p_document_number);

    if v_doc_id is not null then
      if not exists (
        select 1 from public.shift_change_documents d
        where d.id = v_doc_id and d.document_date = p_document_date
      ) then
        raise exception 'เลขที่หนังสือนี้เคยบันทึกไว้ด้วยวันที่เอกสารอื่น';
      end if;
    else
      insert into public.shift_change_documents(document_number, document_date, created_by)
      values (trim(p_document_number), p_document_date, v_uid)
      returning id into v_doc_id;
    end if;
  elsif p_document_date is not null then
    raise exception 'หากระบุวันที่เอกสาร ต้องระบุเลขที่หนังสือ/คำสั่งด้วย';
  end if;

  -- Resolve the final approver first so self-approval can be handled safely.
  -- The nursing group head is the active final approver mapping for this hospital.
  select count(*) into v_final_count
  from public.staff_directory h
  where h.active is true
    and h.org_role = 'หัวหน้ากลุ่มงาน'
    and h.unit_name = 'กลุ่มการพยาบาล'
    and h.nursing_group = 'กลุ่มการพยาบาล';

  if v_final_count <> 1 then
    raise exception 'ไม่พบผู้อนุมัติขั้นสุดท้ายที่ระบุได้เพียง 1 คนจากทะเบียนกลุ่มการพยาบาล (พบ % รายการ)', v_final_count;
  end if;

  select h.* into v_final
  from public.staff_directory h
  where h.active is true
    and h.org_role = 'หัวหน้ากลุ่มงาน'
    and h.unit_name = 'กลุ่มการพยาบาล'
    and h.nursing_group = 'กลุ่มการพยาบาล';

  -- First approver: unit head for the requester's primary unit, excluding the requester.
  select count(*) into v_first_count
  from public.staff_directory h
  where h.active is true
    and h.org_role = 'หัวหน้างาน'
    and h.source_row <> v_requester.source_row
    and v_requester.unit_name is not null
    and (
      h.unit_name = v_requester.unit_name
      or v_requester.unit_name = any(string_to_array(coalesce(h.extra_unit_names, ''), '|'))
    );

  if v_first_count > 1 then
    raise exception 'พบหัวหน้างานผู้รับอนุมัติมากกว่า 1 คนสำหรับหน่วยงานผู้ขอ';
  end if;

  if v_first_count = 0 then
    -- If the unit has no other unit head, the nursing group head substitutes at this same step.
    v_use_group := true;
    select count(*) into v_first_count
    from public.staff_directory h
    where h.active is true
      and h.org_role = 'หัวหน้ากลุ่มงาน'
      and h.source_row <> v_requester.source_row
      and v_requester.nursing_group is not null
      and (
        h.nursing_group = v_requester.nursing_group
        or v_requester.nursing_group = any(string_to_array(coalesce(h.extra_nursing_group_names, ''), '|'))
      );

    if v_first_count > 1 then
      raise exception 'พบหัวหน้ากลุ่มงานผู้รับอนุมัติมากกว่า 1 คนสำหรับกลุ่มงานของผู้ขอ';
    end if;
  end if;

  if v_first_count = 0 then
    -- If no other unit/group head exists, the final approver performs the single approval.
    -- If the requester is that same final approver, skip step one and retain the final self-approval.
    v_first := v_final;
    v_first_skipped := (v_requester.source_row = v_final.source_row);
  elsif v_use_group then
    select h.* into v_first
    from public.staff_directory h
    where h.active is true
      and h.org_role = 'หัวหน้ากลุ่มงาน'
      and h.source_row <> v_requester.source_row
      and v_requester.nursing_group is not null
      and (
        h.nursing_group = v_requester.nursing_group
        or v_requester.nursing_group = any(string_to_array(coalesce(h.extra_nursing_group_names, ''), '|'))
      );
  else
    select h.* into v_first
    from public.staff_directory h
    where h.active is true
      and h.org_role = 'หัวหน้างาน'
      and h.source_row <> v_requester.source_row
      and v_requester.unit_name is not null
      and (
        h.unit_name = v_requester.unit_name
        or v_requester.unit_name = any(string_to_array(coalesce(h.extra_unit_names, ''), '|'))
      );
  end if;

  v_first_name := concat_ws(' ', v_first.prefix, v_first.first_name, v_first.last_name);
  v_final_name := concat_ws(' ', v_final.prefix, v_final.first_name, v_final.last_name);

  select p.user_id into v_recipient_user_id
  from public.profiles p
  where p.staff_directory_id = v_recipient.source_row
  limit 1;

  insert into public.shift_change_requests (
    requester_user_id, requester_staff_directory_id, requester_name, requester_unit_name,
    request_type, shift_date, shift_period, document_id,
    recipient_user_id, recipient_staff_directory_id, recipient_name,
    replacement_required, replacement_date, replacement_period, requester_note, status
  )
  values (
    v_uid, v_requester.source_row,
    concat_ws(' ', v_requester.prefix, v_requester.first_name, v_requester.last_name),
    coalesce(v_requester.unit_name, ''),
    p_request_type, p_shift_date, p_shift_period, v_doc_id,
    v_recipient_user_id, v_recipient.source_row,
    concat_ws(' ', v_recipient.prefix, v_recipient.first_name, v_recipient.last_name),
    p_replacement_required,
    case when p_replacement_required then p_replacement_date else null end,
    case when p_replacement_required then p_replacement_period else null end,
    nullif(trim(coalesce(p_requester_note, '')), ''),
    'waiting_recipient'
  )
  returning id into v_request_id;

  insert into public.shift_change_approvals (
    request_id, step_code, approver_staff_directory_id, approver_user_id,
    approver_name, approver_org_role, decision
  )
  values (
    v_request_id, 'unit_head', v_first.source_row,
    (select p.user_id from public.profiles p where p.staff_directory_id = v_first.source_row limit 1),
    v_first_name, v_first.org_role,
    case when v_first_skipped then 'skipped' else 'pending' end,
    case when v_first_skipped then 'ผู้ขอเป็นผู้อนุมัติขั้นสุดท้าย จึงข้ามขั้นแรกเพื่อไม่ให้อนุมัติตนเองซ้ำ' else null end,
    case when v_first_skipped then now() else null end
  );

  insert into public.shift_change_approvals (
    request_id, step_code, approver_staff_directory_id, approver_user_id,
    approver_name, approver_org_role, decision, comment, acted_at
  )
  values (
    v_request_id, 'nursing_head', v_final.source_row,
    (select p.user_id from public.profiles p where p.staff_directory_id = v_final.source_row limit 1),
    v_final_name, v_final.org_role,
    case when v_first.source_row = v_final.source_row then 'skipped' else 'pending' end,
    case when v_first.source_row = v_final.source_row then 'ผู้อนุมัติเป็นบุคคลเดียวกับขั้นก่อนหน้า จึงข้ามการอนุมัติซ้ำ' else null end,
    case when v_first.source_row = v_final.source_row then now() else null end
  );

  return v_request_id;
end;
$$;

create or replace function private.respond_to_shift_change_request(
  p_request_id uuid,
  p_decision text,
  p_comment text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth, private
as $$
declare
  v_uid uuid := auth.uid();
  v_request public.shift_change_requests%rowtype;
  v_staff_id integer;
begin
  if v_uid is null then raise exception 'กรุณาเข้าสู่ระบบก่อนดำเนินการ'; end if;
  if p_decision not in ('accepted', 'rejected') then raise exception 'การตอบรับคำขอไม่ถูกต้อง'; end if;

  select p.staff_directory_id into v_staff_id
  from public.profiles p where p.user_id = v_uid;

  select r.* into v_request
  from public.shift_change_requests r
  where r.id = p_request_id
  for update;

  if not found or v_request.recipient_staff_directory_id is distinct from v_staff_id then
    raise exception 'คุณไม่มีสิทธิ์ดำเนินการกับคำขอนี้';
  end if;
  if v_request.status <> 'waiting_recipient' then
    raise exception 'คำขอนี้ไม่ได้อยู่ในสถานะรอรับงานแล้ว';
  end if;

  update public.shift_change_requests
  set recipient_user_id = v_uid,
      recipient_decision = p_decision,
      recipient_comment = nullif(trim(coalesce(p_comment, '')), ''),
      recipient_acted_by = v_uid,
      recipient_acted_at = now(),
      status = case
        when p_decision = 'rejected' then 'rejected'
        when exists (
          select 1 from public.shift_change_approvals a
          where a.request_id = p_request_id and a.step_code = 'unit_head' and a.decision = 'skipped'
        ) then 'waiting_nursing_head'
        else 'waiting_unit_head'
      end,
      updated_at = now()
  where id = p_request_id;

  return jsonb_build_object('request_id', p_request_id, 'status',
    case when p_decision = 'accepted' then 'waiting_unit_head' else 'rejected' end);
end;
$$;

create or replace function private.decide_shift_change_approval(
  p_request_id uuid,
  p_decision text,
  p_comment text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth, private
as $$
declare
  v_uid uuid := auth.uid();
  v_staff_id integer;
  v_request public.shift_change_requests%rowtype;
  v_step text;
  v_approval_id uuid;
  v_next_status text;
begin
  if v_uid is null then raise exception 'กรุณาเข้าสู่ระบบก่อนดำเนินการ'; end if;
  if p_decision not in ('approved', 'rejected') then raise exception 'ผลการอนุมัติไม่ถูกต้อง'; end if;

  select p.staff_directory_id into v_staff_id
  from public.profiles p where p.user_id = v_uid;

  select r.* into v_request
  from public.shift_change_requests r
  where r.id = p_request_id
  for update;

  if not found then raise exception 'ไม่พบคำขอเปลี่ยนเวร'; end if;

  v_step := case
    when v_request.status = 'waiting_unit_head' then 'unit_head'
    when v_request.status = 'waiting_nursing_head' then 'nursing_head'
    else null
  end;

  if v_step is null then raise exception 'คำขอนี้ไม่ได้อยู่ในสถานะรออนุมัติ'; end if;

  select a.id into v_approval_id
  from public.shift_change_approvals a
  where a.request_id = p_request_id
    and a.step_code = v_step
    and a.decision = 'pending'
    and a.approver_staff_directory_id = v_staff_id
  for update;

  if v_approval_id is null then
    raise exception 'บัญชีนี้ไม่ใช่ผู้อนุมัติที่ได้รับมอบหมายในขั้นตอนนี้';
  end if;

  update public.shift_change_approvals
  set decision = p_decision,
      acted_by = v_uid,
      comment = nullif(trim(coalesce(p_comment, '')), ''),
      acted_at = now()
  where id = v_approval_id;

  if p_decision = 'rejected' then
    v_next_status := 'rejected';
  elsif v_step = 'unit_head' then
    if exists (
      select 1 from public.shift_change_approvals a
      where a.request_id = p_request_id and a.step_code = 'nursing_head' and a.decision = 'skipped'
    ) then
      v_next_status := 'approved';
    else
      v_next_status := 'waiting_nursing_head';
    end if;
  else
    v_next_status := 'approved';
  end if;

  update public.shift_change_requests
  set status = v_next_status, updated_at = now()
  where id = p_request_id;

  return jsonb_build_object('request_id', p_request_id, 'status', v_next_status, 'step', v_step);
end;
$$;

create or replace function private.cancel_shift_change_request(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth, private
as $$
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
  if v_request.status not in ('waiting_recipient', 'waiting_unit_head', 'waiting_nursing_head') then
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
$$;

create or replace function private.get_shift_exchange_staff()
returns jsonb
language sql
security definer
set search_path = pg_catalog, public, auth, private
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'staff_directory_id', sd.source_row,
    'full_name', concat_ws(' ', sd.prefix, sd.first_name, sd.last_name),
    'position', sd.position,
    'unit_name', sd.unit_name,
    'nursing_group', sd.nursing_group,
    'org_role', sd.org_role,
    'has_account', exists (
      select 1 from public.profiles p where p.staff_directory_id = sd.source_row
    )
  ) order by sd.first_name, sd.last_name), '[]'::jsonb)
  from public.staff_directory sd
  where sd.active is true;
$$;

create or replace function private.get_shift_exchange_my_requests()
returns jsonb
language sql
security definer
set search_path = pg_catalog, public, auth, private
as $$
  select coalesce(jsonb_agg(to_jsonb(r) || jsonb_build_object(
    'approvals', (
      select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at), '[]'::jsonb)
      from public.shift_change_approvals a where a.request_id = r.id
    ),
    'document', (
      select to_jsonb(d) from public.shift_change_documents d where d.id = r.document_id
    )
  ) order by r.created_at desc), '[]'::jsonb)
  from public.shift_change_requests r
  where r.requester_user_id = auth.uid();
$$;

create or replace function private.get_shift_exchange_received_requests()
returns jsonb
language sql
security definer
set search_path = pg_catalog, public, auth, private
as $$
  select coalesce(jsonb_agg(to_jsonb(r) || jsonb_build_object(
    'approvals', (
      select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at), '[]'::jsonb)
      from public.shift_change_approvals a where a.request_id = r.id
    ),
    'document', (
      select to_jsonb(d) from public.shift_change_documents d where d.id = r.document_id
    )
  ) order by r.created_at desc), '[]'::jsonb)
  from public.shift_change_requests r
  where r.recipient_staff_directory_id = (
    select p.staff_directory_id from public.profiles p where p.user_id = auth.uid()
  );
$$;

create or replace function private.get_shift_exchange_pending_approvals()
returns jsonb
language sql
security definer
set search_path = pg_catalog, public, auth, private
as $$
  select coalesce(jsonb_agg(to_jsonb(r) || jsonb_build_object(
    'approval', to_jsonb(a),
    'document', (
      select to_jsonb(d) from public.shift_change_documents d where d.id = r.document_id
    )
  ) order by r.created_at), '[]'::jsonb)
  from public.shift_change_approvals a
  join public.shift_change_requests r on r.id = a.request_id
  join public.profiles p on p.user_id = auth.uid()
  where a.approver_staff_directory_id = p.staff_directory_id
    and a.decision = 'pending'
    and (
      (a.step_code = 'unit_head' and r.status = 'waiting_unit_head')
      or (a.step_code = 'nursing_head' and r.status = 'waiting_nursing_head')
    );
$$;

-- Internal functions are not exposed through the Data API schema.
revoke all on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated;

-- Public RPC entry points are invoker wrappers. Only authenticated users may execute them.
create or replace function public.create_shift_change_request(
  p_recipient_staff_directory_id integer,
  p_request_type text,
  p_shift_date date,
  p_shift_period text,
  p_document_number text default null,
  p_document_date date default null,
  p_replacement_required boolean default false,
  p_replacement_date date default null,
  p_replacement_period text default null,
  p_requester_note text default null
) returns uuid language sql security invoker
set search_path = pg_catalog, public, private
as $$ select private.create_shift_change_request(
  p_recipient_staff_directory_id, p_request_type, p_shift_date, p_shift_period,
  p_document_number, p_document_date, p_replacement_required, p_replacement_date,
  p_replacement_period, p_requester_note
); $$;

create or replace function public.respond_to_shift_change_request(
  p_request_id uuid, p_decision text, p_comment text default null
) returns jsonb language sql security invoker
set search_path = pg_catalog, public, private
as $$ select private.respond_to_shift_change_request(p_request_id, p_decision, p_comment); $$;

create or replace function public.decide_shift_change_approval(
  p_request_id uuid, p_decision text, p_comment text default null
) returns jsonb language sql security invoker
set search_path = pg_catalog, public, private
as $$ select private.decide_shift_change_approval(p_request_id, p_decision, p_comment); $$;

create or replace function public.cancel_shift_change_request(p_request_id uuid)
returns jsonb language sql security invoker
set search_path = pg_catalog, public, private
as $$ select private.cancel_shift_change_request(p_request_id); $$;

create or replace function public.get_shift_exchange_staff()
returns jsonb language sql security invoker
set search_path = pg_catalog, public, private
as $$ select private.get_shift_exchange_staff(); $$;

create or replace function public.get_shift_exchange_my_requests()
returns jsonb language sql security invoker
set search_path = pg_catalog, public, private
as $$ select private.get_shift_exchange_my_requests(); $$;

create or replace function public.get_shift_exchange_received_requests()
returns jsonb language sql security invoker
set search_path = pg_catalog, public, private
as $$ select private.get_shift_exchange_received_requests(); $$;

create or replace function public.get_shift_exchange_pending_approvals()
returns jsonb language sql security invoker
set search_path = pg_catalog, public, private
as $$ select private.get_shift_exchange_pending_approvals(); $$;

revoke all on function public.create_shift_change_request(integer,text,date,text,text,date,boolean,date,text,text) from public, anon;
revoke all on function public.respond_to_shift_change_request(uuid,text,text) from public, anon;
revoke all on function public.decide_shift_change_approval(uuid,text,text) from public, anon;
revoke all on function public.cancel_shift_change_request(uuid) from public, anon;
revoke all on function public.get_shift_exchange_staff() from public, anon;
revoke all on function public.get_shift_exchange_my_requests() from public, anon;
revoke all on function public.get_shift_exchange_received_requests() from public, anon;
revoke all on function public.get_shift_exchange_pending_approvals() from public, anon;

grant execute on function public.create_shift_change_request(integer,text,date,text,text,date,boolean,date,text,text) to authenticated;
grant execute on function public.respond_to_shift_change_request(uuid,text,text) to authenticated;
grant execute on function public.decide_shift_change_approval(uuid,text,text) to authenticated;
grant execute on function public.cancel_shift_change_request(uuid) to authenticated;
grant execute on function public.get_shift_exchange_staff() to authenticated;
grant execute on function public.get_shift_exchange_my_requests() to authenticated;
grant execute on function public.get_shift_exchange_received_requests() to authenticated;
grant execute on function public.get_shift_exchange_pending_approvals() to authenticated;
