import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const {
  parseMigrationManifest,
  loadMigrationManifest,
  MIGRATION_FILENAME_PATTERN,
  DEFAULT_MIGRATIONS_DIR
} = require('../src/server/utils/migration-manifest');

// ── 1-2. Manifest ordering / duplicate detection ────────────────────────

test('migration manifest: stable ascending order is accepted', () => {
  const result = parseMigrationManifest([
    '20260713000100_auth_household_foundation.sql',
    '20260713000200_sync_business_foundation.sql'
  ]);
  assert.equal(result.valid, true);
  assert.deepEqual(result.errors, []);
  assert.equal(result.entries.length, 2);
  assert.equal(result.entries[0].version, '20260713000100');
  assert.equal(result.entries[1].version, '20260713000200');
});

test('migration manifest: a duplicate version prefix is rejected', () => {
  const result = parseMigrationManifest([
    '20260713000100_auth_household_foundation.sql',
    '20260713000100_a_second_migration_with_the_same_timestamp.sql'
  ]);
  assert.equal(result.valid, false);
  assert.ok(result.errors.some((message) => message.includes('duplicate migration version')));
});

test('migration manifest: an out-of-order-on-disk listing is flagged even though sorting would fix it', () => {
  // parseMigrationManifest always returns entries sorted by version (so a
  // caller can rely on ascending order), but still reports an error when
  // the *input* filename list wasn't already in that order — this exists to
  // catch a filesystem/tool that silently reordered files, not just to
  // re-sort them and move on.
  const result = parseMigrationManifest([
    '20260713000200_sync_business_foundation.sql',
    '20260713000100_auth_household_foundation.sql'
  ]);
  assert.equal(result.valid, false);
  assert.ok(result.errors.some((message) => message.includes('ascending version order')));
  assert.equal(result.entries[0].version, '20260713000100', 'entries are still returned sorted, regardless of the error');
});

test('migration manifest: a malformed filename is rejected with a stable error, not a crash', () => {
  const result = parseMigrationManifest(['not-a-valid-migration-name.sql']);
  assert.equal(result.valid, false);
  assert.ok(result.errors.some((message) => message.includes('malformed migration filename')));
});

test('migration manifest: filename pattern requires a 14-digit timestamp and a snake_case slug', () => {
  assert.ok(MIGRATION_FILENAME_PATTERN.test('20260713000100_auth_household_foundation.sql'));
  assert.ok(!MIGRATION_FILENAME_PATTERN.test('2026-07-13_foundation.sql'));
  assert.ok(!MIGRATION_FILENAME_PATTERN.test('20260713000100_Has-Capitals-And-Dashes.sql'));
});

// ── 3. Real repository manifest is currently valid ──────────────────────

test('migration manifest: the real repository migrations directory is currently well-formed', () => {
  const result = loadMigrationManifest(path.join(ROOT, 'supabase', 'migrations'));
  assert.equal(result.valid, true, JSON.stringify(result.errors));
  assert.equal(result.entries.length, 3);
});

test('migration manifest: DEFAULT_MIGRATIONS_DIR resolves to the real repository migrations directory', () => {
  assert.ok(fs.existsSync(DEFAULT_MIGRATIONS_DIR));
  assert.ok(fs.statSync(DEFAULT_MIGRATIONS_DIR).isDirectory());
});

test('migration manifest: an unreadable directory fails closed with a descriptive error, not a thrown exception', () => {
  const result = loadMigrationManifest(path.join(ROOT, 'supabase', 'migrations-that-do-not-exist'));
  assert.equal(result.valid, false);
  assert.ok(result.errors[0].includes('cannot read migrations directory'));
});

// ── 4. loadMigrationManifest must not depend on filesystem enumeration order ──

test('migration manifest: loadMigrationManifest is valid regardless of the order files were written to disk', () => {
  // fs.readdirSync's enumeration order is filesystem/OS-dependent and not
  // guaranteed to match creation or lexicographic order. Writing the newer
  // migration first (so a naive implementation trusting raw readdirSync
  // order would see it "out of order") must still validate cleanly, since
  // loadMigrationManifest sorts before checking.
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'km-migration-manifest-test-'));
  try {
    fs.writeFileSync(path.join(tempDir, '20260713000200_sync_business_foundation.sql'), '-- second\n');
    fs.writeFileSync(path.join(tempDir, '20260713000100_auth_household_foundation.sql'), '-- first\n');
    const result = loadMigrationManifest(tempDir);
    assert.equal(result.valid, true, JSON.stringify(result.errors));
    assert.equal(result.entries[0].version, '20260713000100');
    assert.equal(result.entries[1].version, '20260713000200');
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});
