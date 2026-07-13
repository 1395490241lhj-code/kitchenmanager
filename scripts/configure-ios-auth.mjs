import { chmod, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const outputPath = join(root, 'ios-native', 'Kitchen Manager', 'Config', 'Local.xcconfig');
const rawURL = (process.env.SUPABASE_URL ?? '').trim();
const publishableKey = (
  process.env.SUPABASE_PUBLISHABLE_KEY
  ?? process.env.SUPABASE_ANON_KEY
  ?? ''
).trim();

function fail(message) {
  console.error(`Unable to configure iOS authentication: ${message}`);
  process.exit(1);
}

let parsedURL;
try {
  parsedURL = new URL(rawURL);
} catch {
  fail('SUPABASE_URL must be a valid HTTPS URL.');
}

if (parsedURL.protocol !== 'https:' || parsedURL.username || parsedURL.password) {
  fail('SUPABASE_URL must be HTTPS and must not contain credentials.');
}
if (!publishableKey || publishableKey.includes('YOUR_')) {
  fail('SUPABASE_PUBLISHABLE_KEY (or legacy SUPABASE_ANON_KEY) is missing.');
}
if (/service.?role/i.test(publishableKey)) {
  fail('a service-role key must never be embedded in the iOS app.');
}

const xcconfigURL = rawURL.replace('https://', 'https:/$()/');
const content = [
  '// Generated locally by npm run configure:ios-auth. Do not commit.',
  `SUPABASE_URL = ${xcconfigURL}`,
  `SUPABASE_PUBLISHABLE_KEY = ${publishableKey}`,
  '',
].join('\n');

await writeFile(outputPath, content, { encoding: 'utf8', mode: 0o600 });
await chmod(outputPath, 0o600);
console.log('Created the ignored iOS authentication configuration file.');
