# Stem Examspace

Stem Examspace is a web app for a tutoring centre that runs school-subject classes and university-entrance preparation (TMUA, FSAT, UCAT). Students, parents, teachers, tutors, correctors, admins and the owner each sign in to a role-specific area. Staff use the web app in a browser; there is no desktop app. Accounts, approvals and audit logging run on Supabase (Postgres, Auth, Edge Functions).

## Layout

| Path | Contents |
| --- | --- |
| `apps/web` | Next.js 16 web app (Playwright end-to-end tests in `apps/web/e2e`) |
| `packages/shared` | Shared TypeScript code, tested with Vitest |
| `supabase` | Migrations, pgTAP database tests, Edge Functions and their Deno tests |
| `scripts` | Database test runner and owner setup script |

## Run locally

1. `npm ci`
2. Create `.env.dev.local` at the repo root with `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` and `TEST_INBOX_DOMAIN`. This file is git-ignored and used by scripts and Edge Function tests only.
3. Copy `apps/web/.env.local.example` to `apps/web/.env.local` and fill in the public URL and anon key. Never put the service-role key there.
4. `npm run dev -w @stem/web` serves the app at http://localhost:3005.

## Tests

- Unit: `npm test -w @stem/shared`
- Types and lint: `npx tsc --noEmit -p packages/shared`, `npx tsc --noEmit -p apps/web`, `npm run lint -w @stem/web`
- Database (pgTAP, needs a linked Supabase project and CLI login): `npm run db:test`
- Edge Functions (needs `.env.dev.local`): `deno test --config supabase/functions/deno.json --allow-net --allow-env --allow-read --env-file=.env.dev.local <file>`. Run one file at a time; the hosted Auth sign-in rate limit makes parallel runs fail.
- End to end: `npx playwright test` from `apps/web` (starts its own server on port 3005, runs serially).

## CI

`.github/workflows/ci.yml` has two jobs.

- **checks** runs on every push to `main` and every pull request. It needs no secrets: install, lint, type checks, shared unit tests and a production build with dummy public env values.
- **integration** runs only when started by hand (Actions tab, "CI", "Run workflow"). It runs the pgTAP tests, each Edge Function test file in turn (with a two-minute pause between files), and the Playwright suite against the hosted Supabase project. Runs queue; two never overlap.

The repository owner must add these repository secrets (Settings, Secrets and variables, Actions). The job fails immediately with a message if one is missing.

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`
- `SUPABASE_ACCESS_TOKEN`
- `SUPABASE_PROJECT_REF`
- `TEST_INBOX_DOMAIN`

**Warning:** the integration tests currently run against the Supabase project that will become the live one. Before launch, create a separate test project and point these secrets at it, so tests never touch real data.
