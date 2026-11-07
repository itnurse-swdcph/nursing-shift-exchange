-- Enable request creation while central admin 11450 is impersonating a selected staff account.
-- The request is created using the selected staff identity by the existing validated workflow.
-- A private audit record preserves the real admin actor separately from the simulated requester.

create or replace function public.create_shift_change_request(
 p_recipient_staff_directory_id integer,p_request_type text,p_shift_date date,p_shift_period text,
 p_document_number text default null,p_document_date date default null,p_replacement_required boolean default false,
 p_replacement_date date default null,p_replacement_period text default null,p_requester_note text default null
) returns uuid
language plpgsql security definer
set search_path=pg_catalog,public,auth,shift_exchange_private
as $$
declare
 v_admin uuid:=auth.uid();
 v_target uuid;
 v_staff integer;
 v_request_id uuid;
begin
 if shift_exchange_private.is_central_admin(v_admin) then
   select target_user_id,target_staff_directory_id into v_target,v_staff
   from shift_exchange_private.impersonation_sessions
   where admin_user_id=v_admin;
   if v_target is null then
     raise exception 'กรุณาเลือกบุคลากรที่ต้องการทดสอบแทนก่อนส่งคำขอ';
   end if;
   perform set_config('request.jwt.claim.sub',v_target::text,true);
   v_request_id:=shift_exchange_private.create_shift_change_request(
     p_recipient_staff_directory_id,p_request_type,p_shift_date,p_shift_period,
     p_document_number,p_document_date,p_replacement_required,
     p_replacement_date,p_replacement_period,p_requester_note
   );
   perform set_config('request.jwt.claim.sub',v_admin::text,true);
   insert into shift_exchange_private.impersonation_audit(
     admin_user_id,target_user_id,target_staff_directory_id,action,request_id,decision,details
   ) values (
     v_admin,v_target,v_staff,'create_request',v_request_id,'created',
     jsonb_build_object(
       'recipient_staff_directory_id',p_recipient_staff_directory_id,
       'request_type',p_request_type,
       'shift_date',p_shift_date,
       'shift_period',p_shift_period
     )
   );
   return v_request_id;
 end if;
 return shift_exchange_private.create_shift_change_request(
   p_recipient_staff_directory_id,p_request_type,p_shift_date,p_shift_period,
   p_document_number,p_document_date,p_replacement_required,
   p_replacement_date,p_replacement_period,p_requester_note
 );
end;
$$;
