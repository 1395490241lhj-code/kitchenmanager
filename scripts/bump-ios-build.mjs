// Phase 2D-1: bump CURRENT_PROJECT_VERSION (the iOS build number) across
// every target/configuration in the Xcode project, and record the new value
// in a small tracked ledger file so a later `validate-ios-release.mjs` run
// (possibly from a different machine/branch) can detect a regression or a
// reused build number. Pure file read/write — no network access, no Xcode
// invocation, no git commit (never runs `git commit` itself; a caller
// decides whether/when to commit the result).
//
// Usage: node scripts/bump-ios-build.mjs [--dry-run]
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import {
  readPbxprojVersions,
  defaultLedgerPath,
  readBuildLedger,
  writeBuildLedger,
  bumpBuildNumberInPbxproj
} from './ios-release-support.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const DEFAULT_PBXPROJ = path.join(
  ROOT, 'ios-native', 'Kitchen Manager', 'Kitchen Manager.xcodeproj', 'project.pbxproj'
);

function bumpIOSBuild({ pbxprojPath = DEFAULT_PBXPROJ, ledgerPath = defaultLedgerPath(ROOT), dryRun = false } = {}) {
  const versions = readPbxprojVersions(pbxprojPath);
  if (!versions.buildNumbersConsistent) {
    throw new Error(`refusing to bump: CURRENT_PROJECT_VERSION is already inconsistent across targets (${versions.allBuildNumbers.join(', ')}) — fix that by hand first`);
  }
  const currentBuildNumber = versions.buildNumberRaw ? Number(versions.buildNumberRaw) : NaN;
  if (!Number.isSafeInteger(currentBuildNumber)) {
    throw new Error(`refusing to bump: could not read a valid current CURRENT_PROJECT_VERSION ("${versions.buildNumberRaw}")`);
  }

  const ledger = readBuildLedger(ledgerPath);
  // The new value is always strictly greater than both the value currently
  // in the project file and whatever was last recorded — this is what makes
  // reuse/regression structurally impossible even if the two ever drift
  // (e.g. someone hand-edited the pbxproj back down).
  const newBuildNumber = Math.max(currentBuildNumber, ledger.lastBuildNumber) + 1;

  const { replacedCount, wrote } = bumpBuildNumberInPbxproj(pbxprojPath, newBuildNumber, { dryRun });
  if (replacedCount === 0) {
    throw new Error('refusing to bump: no CURRENT_PROJECT_VERSION occurrences found in the project file');
  }
  if (!dryRun) {
    writeBuildLedger(ledgerPath, { lastBuildNumber: newBuildNumber });
  }

  return { previousBuildNumber: currentBuildNumber, newBuildNumber, replacedCount, wrote };
}

function main() {
  const dryRun = process.argv.includes('--dry-run');
  try {
    const result = bumpIOSBuild({ dryRun });
    const verb = dryRun ? 'would bump' : 'bumped';
    console.log(`[bump-ios-build] ${verb} CURRENT_PROJECT_VERSION ${result.previousBuildNumber} -> ${result.newBuildNumber} (${result.replacedCount} occurrence(s) in the project file)`);
    if (dryRun) {
      console.log('[bump-ios-build] dry run — no file was written');
    }
  } catch (error) {
    console.error(`[bump-ios-build] failed: ${error.message}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  main();
}

export { bumpIOSBuild, DEFAULT_PBXPROJ };
