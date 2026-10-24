# JayVC (single-service package)

This compact deployment package serves the JayVC website and API from one Node.js process.

## Structure

- `public/index.html` — the built website entry document.
- `public/assets/` — the compiled interactive frontend JavaScript and styles.
- `index.js` — root backend entry point.
- `server/` — bundled Express API server and its worker modules.
- `package.json` — start/build scripts for local use and Render.

The readable frontend and backend source files are not included in this compact production package; the frontend and API are prebuilt bundles. Keep the original source ZIP/repository for making code changes and regenerating these assets.

## Run locally

Use Node.js 20 or later. Set `PORT` to the port you want to use and configure the environment variables below, then run:

```bash
npm start
```

## Render Web Service

- Root Directory: repository root
- Build Command: `npm run build`
- Start Command: `npm start`

Render supplies `PORT` automatically.

## Environment variables

Configure in the hosting service dashboard. Do not put secret values in browser code or commit them:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`
- `DAILY_API_KEY`
- `TURNSTILE_SITE_KEY`
- `TURNSTILE_SECRET_KEY`

If the Supabase project/schema, Daily API key, or Turnstile configuration is missing, the UI reports demo/unavailable mode.
