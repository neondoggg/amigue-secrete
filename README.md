# Amigue Secrete — Ugly T-shit night

Static site + Vercel serverless API + Supabase Postgres. The original HTML is kept at `amiguis-grid.html`; the public page at `public/index.html` preserves its embedded cartoon stickers and current copy.

## Connect Supabase

1. Create a Supabase project and open **SQL Editor**.
2. Run [`supabase/schema.sql`](supabase/schema.sql) once.
3. In Vercel project settings, add `SUPABASE_URL` and `SUPABASE_SECRET_KEY` as server environment variables for Production, Preview, and Development. Find the URL in the Supabase Connect dialog and the secret key under Settings → API Keys. Keep the secret key private; it must never be added to the HTML or a `NEXT_PUBLIC_` variable. The API also accepts the legacy `SUPABASE_SERVICE_ROLE_KEY` variable if you already configured it.

## Deploy on Vercel

Import this repository into Vercel. The project uses `public/` for the static page and `api/action.js` for serverless requests. No build command is needed. Install dependencies with `npm install`, then deploy. The public URL is the shared link; 8-character group codes are entered on the home page.

For local development, install dependencies and run `vercel dev` after configuring the two environment variables in a local `.env.local` file. Do not commit that file.

## Privacy model

The browser never reads the participant table directly. Vercel keeps the Supabase secret key on the server. Each participant receives a random 256-bit token; the browser stores it locally and the API stores only its SHA-256 hash. The draw is created atomically inside Postgres, checks that every person gets a different person, and the assignment endpoint returns only the authenticated participant's recipient. The public group view contains names and event details, never assignments.

The draw is one-time and closes the room to new participants. Anyone in the room can trigger it once at least two participants have joined. Participants should keep their browser storage to retain access to their own result.
