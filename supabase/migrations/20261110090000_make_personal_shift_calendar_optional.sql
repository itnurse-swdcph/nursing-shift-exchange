-- Keep personal shift calendars optional.
-- Approved exchanges update existing personal schedule rows only.
-- Do not create synthetic calendar entries for users who have not maintained a schedule.

create or replace function shift_exchange_private.apply_approved_shift_exchange()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, auth, shift_exchange_private
as $function$
declare
  v_requester_entry public.shift_schedule_entries%rowtype;
  v_recipient_entry public.shift_schedule_entries%rowtype;
  v_shift_type text := new.request_type;
begin
  if new.status <> 'approved' or old.status = 'approved' then
    return new;
  end if;

  -- Protect against re-applying the same approved exchange.
  if exists (
    select 1
    from public.shift_schedule_exchange_log
    where request_id = new.id
  ) then
    return new;
  end if;

  -- Move the requester's existing shift to the recipient, if it exists.
  -- If the requester does not maintain a personal calendar, leave it untouched.
  select *
    into v_requester_entry
  from public.shift_schedule_entries
  where staff_directory_id = new.requester_staff_directory_id
    and shift_date = new.shift_date
    and shift_period = new.shift_period
  for update;

  if found then
    v_shift_type := v_requester_entry.shift_type;

    update public.shift_schedule_entries
    set staff_directory_id = new.recipient_staff_directory_id,
        source = 'exchange',
        exchange_request_id = new.id,
        updated_by = null,
        updated_at = now()
    where id = v_requester_entry.id;
  end if;

  -- For a reciprocal replacement, move the recipient's existing shift back
  -- to the requester only when that calendar row exists.
  if new.replacement_required then
    select *
      into v_recipient_entry
    from public.shift_schedule_entries
    where staff_directory_id = new.recipient_staff_directory_id
      and shift_date = new.replacement_date
      and shift_period = new.replacement_period
    for update;

    if found then
      update public.shift_schedule_entries
      set staff_directory_id = new.requester_staff_directory_id,
          source = 'exchange',
          exchange_request_id = new.id,
          updated_by = null,
          updated_at = now()
      where id = v_recipient_entry.id;
    end if;
  end if;

  -- Always record the approved exchange for audit/history, even when neither
  -- person has entered a personal schedule.
  insert into public.shift_schedule_exchange_log(
    request_id,
    requester_staff_directory_id,
    recipient_staff_directory_id,
    shift_date,
    shift_period,
    shift_type,
    replacement_required,
    replacement_date,
    replacement_period
  )
  values (
    new.id,
    new.requester_staff_directory_id,
    new.recipient_staff_directory_id,
    new.shift_date,
    new.shift_period,
    v_shift_type,
    new.replacement_required,
    new.replacement_date,
    new.replacement_period
  )
  on conflict (request_id) do nothing;

  return new;
end;
$function$;
