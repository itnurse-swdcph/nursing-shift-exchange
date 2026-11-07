-- Audited impersonation for central admin account 11450 in Nursing Shift Exchange only.
-- The public RPC wrappers temporarily evaluate existing workflow functions as the selected target user.
-- The actual authenticated admin and selected target are recorded separately in a private audit table.
-- Creating/submitting new requests is explicitly denied to the central admin account.

create table if not exists shift_exchange_private.impersonation_sessions (
  admin_user_id uuid primary key references auth.users(id) on delete cascade,
  target_user_id uuid not null references auth.users(id) on delete cascade,
  target_staff_directory_id integer not null,
  started_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists shift_exchange_private.impersonation_audit (
  id bigint generated always as identity primary key,
  admin_user_id uuid not null references auth.users(id) on delete restrict,
  target_user_id uuid not null references auth.users(id) on delete restrict,
  target_staff_directory_id integer not null,
  action text not null,
  request_id uuid,
  decision text,
  details jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now()
);
alter table shift_exchange_private.impersonation_sessions enable row level security;
alter table shift_exchange_private.impersonation_audit enable row level security;
revoke all on shift_exchange_private.impersonation_sessions, shift_exchange_private.impersonation_audit from public, anon, authenticated;
grant select,insert,update,delete on shift_exchange_private.impersonation_sessions to postgres;
grant select,insert on shift_exchange_private.impersonation_audit to postgres;
grant usage,select on sequence shift_exchange_private.impersonation_audit_id_seq to postgres;

create or replace function shift_exchange_private.is_central_admin(p_uid uuid default auth.uid())
returns boolean language sql stable security definer
set search_path=pg_catalog,auth,public
as $$
 select exists (select 1 from auth.users u where u.id=p_uid and lower(split_part(coalesce(u.email,''),'@',1))='11450');
$$;

create or replace function public.get_shift_exchange_impersonation()
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,auth,shift_exchange_private
as $$
declare v_uid uuid:=auth.uid(); v_target uuid; v_staff integer; v_name text;
begin
 if not shift_exchange_private.is_central_admin(v_uid) then raise exception 'ไม่มีสิทธิ์ใช้โหมดทดสอบแทนบุคลากร'; end if;
 select s.target_user_id,s.target_staff_directory_id into v_target,v_staff from shift_exchange_private.impersonation_sessions s where s.admin_user_id=v_uid;
 if v_target is null then return jsonb_build_object('active',false); end if;
 select coalesce(p.full_name,concat_ws(' ',sd.prefix,sd.first_name,sd.last_name)) into v_name
 from public.profiles p left join public.staff_directory sd on sd.source_row=p.staff_directory_id where p.user_id=v_target;
 return jsonb_build_object('active',true,'target_user_id',v_target,'target_staff_directory_id',v_staff,'target_name',v_name);
end;
$$;

create or replace function public.start_shift_exchange_impersonation(p_target_staff_directory_id integer)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,auth,shift_exchange_private
as $$
declare v_uid uuid:=auth.uid(); v_target uuid; v_name text;
begin
 if not shift_exchange_private.is_central_admin(v_uid) then raise exception 'ไม่มีสิทธิ์ใช้โหมดทดสอบแทนบุคลากร'; end if;
 select p.user_id,coalesce(p.full_name,concat_ws(' ',sd.prefix,sd.first_name,sd.last_name)) into v_target,v_name
 from public.profiles p join public.staff_directory sd on sd.source_row=p.staff_directory_id
 where p.staff_directory_id=p_target_staff_directory_id and sd.active is true limit 1;
 if v_target is null then raise exception 'บุคลากรนี้ยังไม่มีบัญชีผู้ใช้หรือไม่อยู่ในสถานะปฏิบัติงาน'; end if;
 insert into shift_exchange_private.impersonation_sessions(admin_user_id,target_user_id,target_staff_directory_id)
 values(v_uid,v_target,p_target_staff_directory_id)
 on conflict(admin_user_id) do update set target_user_id=excluded.target_user_id,target_staff_directory_id=excluded.target_staff_directory_id,started_at=now(),updated_at=now();
 insert into shift_exchange_private.impersonation_audit(admin_user_id,target_user_id,target_staff_directory_id,action,details)
 values(v_uid,v_target,p_target_staff_directory_id,'start_session',jsonb_build_object('target_name',v_name));
 return jsonb_build_object('active',true,'target_user_id',v_target,'target_staff_directory_id',p_target_staff_directory_id,'target_name',v_name);
end;
$$;

create or replace function public.stop_shift_exchange_impersonation()
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,auth,shift_exchange_private
as $$
declare v_uid uuid:=auth.uid(); v_target uuid; v_staff integer;
begin
 if not shift_exchange_private.is_central_admin(v_uid) then raise exception 'ไม่มีสิทธิ์ใช้โหมดทดสอบแทนบุคลากร'; end if;
 select target_user_id,target_staff_directory_id into v_target,v_staff from shift_exchange_private.impersonation_sessions where admin_user_id=v_uid;
 if v_target is not null then
  insert into shift_exchange_private.impersonation_audit(admin_user_id,target_user_id,target_staff_directory_id,action) values(v_uid,v_target,v_staff,'stop_session');
  delete from shift_exchange_private.impersonation_sessions where admin_user_id=v_uid;
 end if;
 return jsonb_build_object('active',false);
end;
$$;

create or replace function public.create_shift_change_request(
 p_recipient_staff_directory_id integer,p_request_type text,p_shift_date date,p_shift_period text,
 p_document_number text default null,p_document_date date default null,p_replacement_required boolean default false,
 p_replacement_date date default null,p_replacement_period text default null,p_requester_note text default null
) returns uuid language plpgsql security definer
set search_path=pg_catalog,public,auth,shift_exchange_private
as $$
begin
 if shift_exchange_private.is_central_admin(auth.uid()) then raise exception 'บัญชีแอดมินกลางไม่สามารถสร้างคำขอใหม่ได้ รวมถึงขณะทดสอบแทนบุคลากร'; end if;
 return shift_exchange_private.create_shift_change_request(p_recipient_staff_directory_id,p_request_type,p_shift_date,p_shift_period,p_document_number,p_document_date,p_replacement_required,p_replacement_date,p_replacement_period,p_requester_note);
end;
$$;

create or replace function public.get_shift_exchange_staff()
returns jsonb language sql security definer set search_path=pg_catalog,public,auth,shift_exchange_private
as $$ select shift_exchange_private.get_shift_exchange_staff(); $$;

create or replace function public.get_shift_exchange_my_requests()
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth,shift_exchange_private
as $$
declare v_uid uuid:=auth.uid(); v_target uuid; v_result jsonb;
begin
 if shift_exchange_private.is_central_admin(v_uid) then select target_user_id into v_target from shift_exchange_private.impersonation_sessions where admin_user_id=v_uid; if v_target is not null then perform set_config('request.jwt.claim.sub',v_target::text,true); end if; end if;
 v_result:=shift_exchange_private.get_shift_exchange_my_requests();
 perform set_config('request.jwt.claim.sub',coalesce(v_uid::text,''),true);
 return v_result;
end;
$$;

create or replace function public.get_shift_exchange_received_requests()
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth,shift_exchange_private
as $$
declare v_uid uuid:=auth.uid(); v_target uuid; v_result jsonb;
begin
 if shift_exchange_private.is_central_admin(v_uid) then select target_user_id into v_target from shift_exchange_private.impersonation_sessions where admin_user_id=v_uid; if v_target is not null then perform set_config('request.jwt.claim.sub',v_target::text,true); end if; end if;
 v_result:=shift_exchange_private.get_shift_exchange_received_requests();
 perform set_config('request.jwt.claim.sub',coalesce(v_uid::text,''),true);
 return v_result;
end;
$$;

create or replace function public.get_shift_exchange_pending_approvals()
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth,shift_exchange_private
as $$
declare v_uid uuid:=auth.uid(); v_target uuid; v_result jsonb;
begin
 if shift_exchange_private.is_central_admin(v_uid) then select target_user_id into v_target from shift_exchange_private.impersonation_sessions where admin_user_id=v_uid; if v_target is not null then perform set_config('request.jwt.claim.sub',v_target::text,true); end if; end if;
 v_result:=shift_exchange_private.get_shift_exchange_pending_approvals();
 perform set_config('request.jwt.claim.sub',coalesce(v_uid::text,''),true);
 return v_result;
end;
$$;

create or replace function public.respond_to_shift_change_request(p_request_id uuid,p_decision text,p_comment text default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth,shift_exchange_private
as $$
declare v_uid uuid:=auth.uid(); v_target uuid; v_staff integer; v_result jsonb;
begin
 select target_user_id,target_staff_directory_id into v_target,v_staff from shift_exchange_private.impersonation_sessions where admin_user_id=v_uid;
 if shift_exchange_private.is_central_admin(v_uid) then if v_target is null then raise exception 'กรุณาเลือกบุคลากรที่ต้องการทดสอบแทนก่อน'; end if; perform set_config('request.jwt.claim.sub',v_target::text,true); end if;
 v_result:=shift_exchange_private.respond_to_shift_change_request(p_request_id,p_decision,p_comment);
 perform set_config('request.jwt.claim.sub',coalesce(v_uid::text,''),true);
 if shift_exchange_private.is_central_admin(v_uid) then insert into shift_exchange_private.impersonation_audit(admin_user_id,target_user_id,target_staff_directory_id,action,request_id,decision,details) values(v_uid,v_target,v_staff,'respond_to_request',p_request_id,p_decision,jsonb_build_object('comment',p_comment)); end if;
 return v_result;
end;
$$;

create or replace function public.decide_shift_change_approval(p_request_id uuid,p_decision text,p_comment text default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth,shift_exchange_private
as $$
declare v_uid uuid:=auth.uid(); v_target uuid; v_staff integer; v_result jsonb;
begin
 select target_user_id,target_staff_directory_id into v_target,v_staff from shift_exchange_private.impersonation_sessions where admin_user_id=v_uid;
 if shift_exchange_private.is_central_admin(v_uid) then if v_target is null then raise exception 'กรุณาเลือกบุคลากรที่ต้องการทดสอบแทนก่อน'; end if; perform set_config('request.jwt.claim.sub',v_target::text,true); end if;
 v_result:=shift_exchange_private.decide_shift_change_approval(p_request_id,p_decision,p_comment);
 perform set_config('request.jwt.claim.sub',coalesce(v_uid::text,''),true);
 if shift_exchange_private.is_central_admin(v_uid) then insert into shift_exchange_private.impersonation_audit(admin_user_id,target_user_id,target_staff_directory_id,action,request_id,decision,details) values(v_uid,v_target,v_staff,'decide_approval',p_request_id,p_decision,jsonb_build_object('comment',p_comment)); end if;
 return v_result;
end;
$$;

create or replace function public.cancel_shift_change_request(p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth,shift_exchange_private
as $$
declare v_uid uuid:=auth.uid(); v_target uuid; v_staff integer; v_result jsonb;
begin
 select target_user_id,target_staff_directory_id into v_target,v_staff from shift_exchange_private.impersonation_sessions where admin_user_id=v_uid;
 if shift_exchange_private.is_central_admin(v_uid) then if v_target is null then raise exception 'กรุณาเลือกบุคลากรที่ต้องการทดสอบแทนก่อน'; end if; perform set_config('request.jwt.claim.sub',v_target::text,true); end if;
 v_result:=shift_exchange_private.cancel_shift_change_request(p_request_id);
 perform set_config('request.jwt.claim.sub',coalesce(v_uid::text,''),true);
 if shift_exchange_private.is_central_admin(v_uid) then insert into shift_exchange_private.impersonation_audit(admin_user_id,target_user_id,target_staff_directory_id,action,request_id,decision) values(v_uid,v_target,v_staff,'cancel_request',p_request_id,'cancelled'); end if;
 return v_result;
end;
$$;

revoke all on function public.get_shift_exchange_impersonation() from public,anon;
revoke all on function public.start_shift_exchange_impersonation(integer) from public,anon;
revoke all on function public.stop_shift_exchange_impersonation() from public,anon;
grant execute on function public.get_shift_exchange_impersonation() to authenticated;
grant execute on function public.start_shift_exchange_impersonation(integer) to authenticated;
grant execute on function public.stop_shift_exchange_impersonation() to authenticated;
