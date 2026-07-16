// Phase 2D-1: pre-archive release-version sanity check. Pure file reads —
// no network access, no Xcode invocation. Run via `npm run ios:release:check`
// before any real archive/TestFlight upload.
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import {
  parseMarketingVersion,
  parseBuildNumber,
  readPbxprojVersions,
  defaultLedgerPath,
  readBuildLedger
} from './ios-release-support.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const DEFAULT_PBXPROJ = path.join(
  ROOT, 'ios-native', 'Kitchen Manager', 'Kitchen Manager.xcodeproj', 'project.pbxproj'
);

function validateIOSRelease({ pbxprojPath = DEFAULT_PBXPROJ, ledgerPath = defaultLedgerPath(ROOT) } = {}) {
  const errors = [];
  const versions = readPbxprojVersions(pbxprojPath);

  if (!versions.marketingVersionsConsistent) {
    errors.push(`MARKETING_VERSION is inconsistent across targets/configurations: ${versions.allMarketingVersions.join(', ')}`);
  }
  const marketingVersion = versions.marketingVersionRaw ? parseMarketingVersion(versions.marketingVersionRaw) : null;
  if (versions.marketingVersionRaw && !marketingVersion) {
    errors.push(`MARKETING_VERSION is malformed: "${versions.marketingVersionRaw}" (expected e.g. "1.2.0")`);
  }
  if (!versions.marketingVersionRaw) {
    errors.push('MARKETING_VERSION could not be read from the project file');
  }

  if (!versions.buildNumbersConsistent) {
    errors.push(`CURRENT_PROJECT_VERSION is inconsistent across targets/configurations: ${versions.allBuildNumbers.join(', ')}`);
  }
  const buildNumber = versions.buildNumberRaw ? parseBuildNumber(versions.buildNumberRaw) : null;
  if (versions.buildNumberRaw && buildNumber === null) {
    errors.push(`CURRENT_PROJECT_VERSION is malformed: "${versions.buildNumberRaw}" (expected a positive integer, no leading zero)`);
  }
  if (!versions.buildNumberRaw) {
    errors.push('CURRENT_PROJECT_VERSION could not be read from the project file');
  }

  const ledger = readBuildLedger(ledgerPath);
  if (buildNumber !== null && buildNumber < ledger.lastBuildNumber) {
    errors.push(`CURRENT_PROJECT_VERSION (${buildNumber}) is lower than the last recorded build number (${ledger.lastBuildNumber}) — build numbers must never regress or be reused`);
  }

  return {
    valid: errors.length === 0,
    errors,
    marketingVersion,
    buildNumber,
    lastRecordedBuildNumber: ledger.lastBuildNumber
  };
}

function main() {
  const result = validateIOSRelease();
  if (result.valid) {
    console.log(`[ios-release] OK — MARKETING_VERSION=${result.marketingVersion} CURRENT_PROJECT_VERSION=${result.buildNumber} (last recorded: ${result.lastRecordedBuildNumber})`);
    return;
  }
  console.error('[ios-release] validation failed:');
  for (const error of result.errors) {
    console.error(`  - ${error}`);
  }
  process.exitCode = 1;
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  main();
}

export { validateIOSRelease, DEFAULT_PBXPROJ };
