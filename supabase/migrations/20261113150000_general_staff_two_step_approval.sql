do $migration$
declare
  v_def text;
begin
  v_def := pg_get_functiondef('shift_exchange_private.create_shift_change_request(integer,text,date,text,text,date,boolean,date,text,text)'::regprocedure);
  v_def := replace(
    v_def,
    '  -- If requester is the final approver, retain final self-approval while skipping earlier self-approval.
  if v_requester.source_row=v_final_id then',
    '  -- General staff use only two approval stages: unit head and nursing head.
  -- Keep the group_head record skipped for legacy workflow compatibility.
  if replace(trim(coalesce(v_requester.org_role,'''')),'' '','''') not in (''หัวหน้างาน'',''หัวหน้ากลุ่มงาน'')
     and v_requester.source_row<>v_final_id then
    v_group_id:=v_final_id;
    v_group_skipped:=true;
    v_final_skipped:=false;
    if v_unit_id is null or v_unit_id=v_final_id then
      v_unit_skipped:=true;
    end if;
  end if;

  -- If requester is the final approver, retain final self-approval while skipping earlier self-approval.
  if v_requester.source_row=v_final_id then'
  );
  if v_def = pg_get_functiondef('shift_exchange_private.create_shift_change_request(integer,text,date,text,text,date,boolean,date,text,text)'::regprocedure) then
    raise exception 'Could not locate approval routing insertion point; no changes applied';
  end if;
  execute v_def;
end
$migration$;