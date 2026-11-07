-- Supporting indexes for foreign keys in the isolated shift-exchange tables.
-- This migration does not touch P4P objects.
create index if not exists idx_shift_change_documents_created_by
  on public.shift_change_documents (created_by);

create index if not exists idx_shift_change_requests_requester_staff
  on public.shift_change_requests (requester_staff_directory_id);

create index if not exists idx_shift_change_requests_recipient_staff
  on public.shift_change_requests (recipient_staff_directory_id);

create index if not exists idx_shift_change_requests_document
  on public.shift_change_requests (document_id);

create index if not exists idx_shift_change_requests_recipient_acted_by
  on public.shift_change_requests (recipient_acted_by);

create index if not exists idx_shift_change_approvals_acted_by
  on public.shift_change_approvals (acted_by);
