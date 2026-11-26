
create or replace function shift_exchange_private.cancel_shift_change_request(p_request_id uuid)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, auth, shift_exchange_private
as $$
declare v_uid uuid:=auth.uid(); v_request public.shift_change_requests%rowtype;
begin
  if v_uid is null then raise exception 'กรุณาเข้าสู่ระบบก่อนดำเนินการ'; end if;
  select r.* into v_request from public.shift_change_requests r where r.id=p_request_id for update;
  if not found or v_request.requester_user_id<>v_uid then raise exception 'คุณไม่มีสิทธิ์ยกเลิกคำขอนี้'; end if;
  if v_request.status not in ('waiting_recipient','waiting_unit_head','waiting_group_head','waiting_refer_head','waiting_nursing_head') then
    raise exception 'ไม่สามารถยกเลิกคำขอในสถานะปัจจุบันได้';
  end if;
  update public.shift_change_approvals set decision='skipped',acted_by=v_uid,
    comment='ยกเลิกคำขอโดยผู้ขอ',acted_at=now()
  where request_id=p_request_id and decision='pending';
  update public.shift_change_requests set status='cancelled',updated_at=now() where id=p_request_id;
  return jsonb_build_object('request_id',p_request_id,'status','cancelled');
end;
$$;
