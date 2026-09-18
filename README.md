# سكن | Sakan

Flutter Arabic RTL customer app, Flutter Web administration, and Supabase/PostgreSQL booking backend.

## Source

The full source tree is packaged in `sakan-source.tar.gz` (124 files). Extract it before development:

```sh
tar -xzf sakan-source.tar.gz
```

The extracted README contains local setup, testing and mobile build instructions. `docs/implementation-status.md` records what is implemented and what remains. The archive contains no production credentials.

## Deployment

Vercel extracts the source and builds both web applications in **live** mode:

- `/customer/` — customer application
- `/admin/` — administration (authentication and roles required)

Set `SUPABASE_URL` and the public `SUPABASE_ANON_KEY` in Vercel environment settings. Never use a service-role or secret key in Flutter. No demo listings are inserted in the production database.

## Database

`sakan-database.sql` bootstraps an empty Supabase database with 34 tables, RLS policies, booking holds, payments records, operations and audit controls. It is not an idempotent migration: do not rerun it on an initialized database. Subsequent changes should use the individual migrations in the extracted source.

## Production readiness

This is an MVP. SMS OTP requires an SMS provider; actual payments and refunds require a configured and verified payment provider adapter. Push delivery, store signing, actual property data and administrator onboarding remain separate activation steps. Uploading source and deploying the web interface does not enable these services automatically.
