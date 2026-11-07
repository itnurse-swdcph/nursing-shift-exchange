# Nursing Shift Exchange

ระบบแลกเปลี่ยนเวร กลุ่มการพยาบาล โรงพยาบาลสมเด็จพระยุพราชสว่างแดนดิน

## Technology
- React + TypeScript + Vite
- Supabase Auth / PostgreSQL (ใช้บัญชีเดิมของโรงพยาบาล)
- Thai-first responsive UI
- Noto Sans Thai; official minimal white / navy / soft teal theme

## Development
1. Copy `.env.example` to `.env.local`.
2. Set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY`.
3. Run `npm install`.
4. Run `npm run dev`.
5. Run `npm run build` to type-check and build.

## GitHub Pages
The repository site uses the Vite base path `/nursing-shift-exchange/`. The `Deploy to GitHub Pages` workflow builds `dist` and publishes it on every push to `main`. In repository **Settings → Pages → Build and deployment**, set **Source** to **GitHub Actions**. The browser client uses the Supabase publishable key (safe for public clients); database access remains protected by authenticated RPC checks and RLS.

## Database
Migrations are stored in `supabase/migrations`.

- `20261107000100_create_shift_exchange_core.sql`: creates isolated `shift_change_*` tables and participant read policies.
- `20261107000200_add_shift_exchange_workflow_rpcs.sql`: adds validated workflow RPCs, private SECURITY DEFINER implementation functions, and authenticated-only public RPC wrappers.

**The migrations have not been applied to the shared production Supabase project.** Review and test them before applying. They must not modify P4P tables, policies, functions, or Auth users.

New tables and RPC functions have explicit grants because Supabase's Data API no longer exposes newly created public-schema objects by default.

## Workflow
1. Requester submits a request → `รอรับงาน`.
2. The recipient accepts or rejects the request.
3. The first approval is the requester unit's `หัวหน้างาน`. If no other active unit head is assigned, the matching `หัวหน้ากลุ่มงาน` substitutes in this same step.
4. The active Nursing Group head is the final approval mapping.
5. If the same person is assigned to both approval levels, the duplicate step is skipped. The requester cannot approve their own first-level step; the final approver may self-approve as agreed.
6. Rejection closes remaining pending approval steps. The requester can cancel while the request is awaiting acceptance or approval.

Approver mapping is derived from `staff_directory` and `profiles.staff_directory_id`, not from `profiles.role`. The workflow checks the primary unit and nursing group, including extra unit/group assignments, and fails safely if it finds ambiguous approver mappings.

The recipient must have an active linked account so they can accept or reject the request. Approver records are still created from `staff_directory` even if an approver account is not yet linked; that person can act once their account is linked.

## Current implementation
- Existing-account login
- Shift request form with unit / Refer / supervision, date, shift period, optional document reference, recipient search, replacement details, and note
- My requests, received requests, and pending approval queues
- Accept / reject, approve / reject, and cancel actions
- Responsive request cards and Thai date display
- Monthly report screen is still a placeholder; print templates and report rules will be added after the workflow is verified.

A GitHub Actions build workflow runs `npm install` and `npm run build` on pushes and pull requests to `main`.
