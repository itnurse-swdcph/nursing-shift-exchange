# Nursing Shift Exchange

ระบบแลกเปลี่ยนเวร กลุ่มการพยาบาล โรงพยาบาลสมเด็จพระยุพราชสว่างแดนดิน

## Technology
- React + TypeScript + Vite
- Supabase Auth / PostgreSQL (ใช้บัญชีเดิมของโรงพยาบาล)
- Thai-first responsive UI

## Development
1. Copy `.env.example` to `.env.local`.
2. Set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY`.
3. Run `npm install` and `npm run dev`.

## Database
Migrations are stored in `supabase/migrations`. The first migration creates isolated `shift_change_*` tables and policies only. It does not modify P4P tables or authentication records.

**Do not apply migrations to the shared production project until the SQL and access rules have been reviewed.**

## Workflow baseline
1. Requester submits a request → รอรับงาน.
2. Recipient accepts → routed to the requester's unit head; if none exists, the nursing group head acts in that approval step.
3. Nursing director / acting nursing director gives final approval.
4. Final status → อนุมัติแล้ว.

Approver mapping is derived from `staff_directory` and `profiles.staff_directory_id`, not from the P4P display role alone.
