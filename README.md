# Target Update — ODR

Separate ODR sales-performance application. It is **not** the existing Target Update dashboard for another department.

## Features

- TABS ID + admin-issued password sign-in via Supabase Auth (TABS IDs are mapped to internal synthetic emails; no dependency on Zain TABS authentication).
- Admin sees all agents; agents only see their own targets and sales. Database row-level security enforces the rule.
- Admin-only monthly Excel target import from the `Agent View` worksheet.
- Admin-only monthly CSV sales snapshot import from `MTD_ODR_SALES_REPORT.csv`.
- Separate Postpaid (`Cons Postpaid`, `HAC`), MBB (`HBB`) and Broadband (`HBB-5G`, `Fiber - FTTH`) counts.
- Projected month-end = actual / day of last completed transaction × number of days in the month. Run rate = projected / target.
- Pace bands: Excellent ≥90%, Good ≥85%, Decent ≥75%, Below pace <75%.
- Department → Team Leader → Agent reporting and daily points charts; team-leader summary rows are excluded from rollups.
- INFO_CHANNEL breakdown for department reporting; subscriber numbers are retained with agent-level RLS.
- Campaign mapping is package-code based. Admin can edit rules and override an individual subscriber's points without losing that override on a monthly report reupload.

## Setup

1. Create a **new dedicated Supabase project** after choosing the organization. Do not run the schema on an existing unrelated project.
2. Apply `supabase/schema.sql` in the SQL editor. Review the policies in the Supabase dashboard.
3. In Auth settings, disable public signup. Create the admin account with Auth Admin API using the email `<ADMIN_TABS>@tabs.target-update.invalid`, a secure temporary password, and **app_metadata** `{ "role": "admin", "tabs": "<ADMIN_TABS>" }`. The synthetic domain is intentionally not deliverable; password recovery must be admin-managed.
4. Create Vercel environment variables from `.env.example` (publishable key only; do not expose secret keys to the browser).
5. `npm install && npm run build`; deploy to a **separate Vercel project** connected to a new private GitHub repository.
6. Admin logs in and uploads the monthly targets before the CSV. In this first prototype, individual agent accounts must be provisioned by a trusted admin script or Auth Admin API, with each user's `app_metadata.tabs` set to their TABS username. Never allow an agent to select their own TABS mapping.

### ODR dashboard enhancement

Before deploying the new dashboard, run `supabase/odr-enhancements.sql` **once** in the dedicated ODR project's SQL Editor. It adds transaction-level sales, point rules, preserved overrides, and reporting snapshots. It leaves the prior tables and accounts intact. Test the policies with separate agent credentials before general rollout.

## Cautions before production

- Upload replaces the month’s sales snapshot. Current browser implementation deletes then inserts; an interrupted upload can leave incomplete records. Move to a transactional backend import before accepting production data.
- The source report includes customer phone numbers and other personal information. The app deliberately keeps **only per-agent segment counts**, not identifiable sales rows.
- Unknown agent IDs cause an import error. This prevents silent omission but requires that the target file includes all relevant agents.
- Initial passwords, account resets, audit monitoring, large imports and managed backups need an admin provisioning workflow before rollout.
- Confirm that shared broadband (`HBB-Shared`, `Shared-Fiber`) and prepaid rows should remain excluded; they are not included by the original `Agent View` SUMIFS logic.
