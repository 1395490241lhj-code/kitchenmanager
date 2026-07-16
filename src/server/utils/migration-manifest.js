// Phase 2C-3: a pure, dependency-free check that the migration filename
// manifest itself is well-formed — stable ordering, no duplicate version
// prefixes, no malformed filenames. This never touches a database (local or
// remote); it only reads directory entries. Real schema/RLS parity is a
// separate, read-only check against the linked project (see
// docs/DATABASE_MIGRATION_PARITY.md) — this module exists so a manifest
// mistake (two migrations timestamped identically, a typo breaking sort
// order) is caught by a fast, deterministic unit test instead of only ever
// being discovered by `supabase migration list` against a real project.
const fs = require('fs');
const path = require('path');

const MIGRATION_FILENAME_PATTERN = /^(\d{14})_([a-z0-9_]+)\.sql$/;

function parseMigrationManifest(filenames) {
  const entries = [];
  const errors = [];
  const seenVersions = new Set();

  for (const filename of filenames) {
    const match = MIGRATION_FILENAME_PATTERN.exec(filename);
    if (!match) {
      errors.push(`malformed migration filename: ${filename}`);
      continue;
    }
    const [, version, slug] = match;
    if (seenVersions.has(version)) {
      errors.push(`duplicate migration version: ${version}`);
      continue;
    }
    seenVersions.add(version);
    entries.push({ filename, version, slug });
  }

  const sortedByVersion = [...entries].sort((a, b) => (a.version < b.version ? -1 : a.version > b.version ? 1 : 0));
  const isStableOrder = entries.every((entry, index) => entry.version === sortedByVersion[index]?.version);
  if (!isStableOrder) {
    errors.push('migration filenames are not already in ascending version order on disk');
  }

  return {
    valid: errors.length === 0,
    errors,
    entries: sortedByVersion
  };
}

function loadMigrationManifest(migrationsDir) {
  let filenames;
  try {
    filenames = fs.readdirSync(migrationsDir).filter((name) => name.endsWith('.sql'));
  } catch (error) {
    return { valid: false, errors: [`cannot read migrations directory: ${error.message}`], entries: [] };
  }
  return parseMigrationManifest(filenames);
}

module.exports = {
  MIGRATION_FILENAME_PATTERN,
  parseMigrationManifest,
  loadMigrationManifest,
  DEFAULT_MIGRATIONS_DIR: path.join(__dirname, '..', '..', '..', 'supabase', 'migrations')
};
