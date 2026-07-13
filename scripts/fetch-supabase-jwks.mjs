// scripts/fetch-supabase-jwks.mjs
//
// Fetches the current Supabase JWKS (public verification keys only — this is
// not a secret, it's the same document any client can fetch anonymously) and
// prints it as a single-line JSON string, ready to paste into Render's
// SUPABASE_JWKS_JSON environment variable. This is the manual "snapshot" used
// as a fallback for when Render's own DNS resolution of the Supabase JWKS
// hostname breaks (see src/server/auth/jwt.js's local-fallback verifier).
//
// This script never reads or prints a password, an access/refresh token, or
// any key that isn't already public (anon/publishable key is only used here
// as the identifying `apikey` header Supabase's JWKS endpoint expects).
//
// Usage:
//   SUPABASE_JWKS_URL=https://YOUR_PROJECT_REF.supabase.co/auth/v1/.well-known/jwks.json \
//   SUPABASE_ANON_KEY=YOUR_ANON_OR_PUBLISHABLE_KEY \
//   node scripts/fetch-supabase-jwks.mjs
//
// Or simply source .env.development.local first (it already has both):
//   set -a && source .env.development.local && set +a
//   node scripts/fetch-supabase-jwks.mjs
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { validateJwksJsonValue } = require('../src/server/config.js');

function fail(message) {
  console.error(`[fetch-supabase-jwks] ${message}`);
  process.exitCode = 1;
}

async function main() {
  const jwksUrl = String(process.env.SUPABASE_JWKS_URL || '').trim();
  const anonKey = String(process.env.SUPABASE_ANON_KEY || '').trim();
  if (!jwksUrl) {
    return fail('Missing SUPABASE_JWKS_URL. Set it (or source .env.development.local) before running this script.');
  }
  if (!anonKey) {
    return fail('Missing SUPABASE_ANON_KEY. Set it (or source .env.development.local) before running this script.');
  }

  let response;
  try {
    response = await fetch(jwksUrl, { headers: { apikey: anonKey, Accept: 'application/json' } });
  } catch (error) {
    return fail(`Request to the JWKS endpoint failed (${error?.code || error?.name || 'unknown error'}).`);
  }
  if (!response.ok) {
    return fail(`JWKS endpoint returned HTTP ${response.status}.`);
  }

  let body;
  try {
    body = await response.json();
  } catch {
    return fail('JWKS endpoint did not return valid JSON.');
  }

  // Re-run the exact same validation Render's own startup check runs, so a
  // bad snapshot is caught here instead of silently breaking the fallback
  // later. This never prints the JSON itself, only the sanitized reason.
  const { jwks, keyCount, error } = validateJwksJsonValue(JSON.stringify(body));
  if (error) {
    return fail(`Fetched JWKS failed validation: ${error}`);
  }

  const singleLine = JSON.stringify(jwks);
  console.log(singleLine);
  console.error(`[fetch-supabase-jwks] OK — ${keyCount} public key(s). This is safe to paste into Render's SUPABASE_JWKS_JSON environment variable.`);
  console.error('[fetch-supabase-jwks] This script does NOT write to any repo file — copy the line above manually into the Render dashboard.');
  console.error('[fetch-supabase-jwks] Re-run this after Supabase rotates its signing keys, since a stale snapshot only helps until the next rotation.');
}

await main();
