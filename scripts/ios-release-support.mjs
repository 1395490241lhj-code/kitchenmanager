// Phase 2D-1: shared, dependency-free, network-free helpers for iOS release
// version/build-number validation and bumping. Both scripts/validate-ios-
// release.mjs and scripts/bump-ios-build.mjs import from here.
import fs from 'node:fs';
import path from 'node:path';

const SEMVER_PATTERN = /^\d+\.\d+(?:\.\d+)?$/;
const BUILD_NUMBER_PATTERN = /^[1-9]\d*$/;

function parseMarketingVersion(raw) {
  if (typeof raw !== 'string') return null;
  const trimmed = raw.trim();
  if (!SEMVER_PATTERN.test(trimmed)) return null;
  return trimmed;
}

// Strict on purpose: no leading zeros ("007"), no leading '+'/'-', no
// decimals, no whitespace — CURRENT_PROJECT_VERSION must be a plain positive
// integer for both Xcode and App Store Connect to accept it as a build
// number, and a leading zero would risk being misread as octal-shaped by
// some tooling.
function parseBuildNumber(raw) {
  if (typeof raw !== 'string') return null;
  const trimmed = raw.trim();
  if (!BUILD_NUMBER_PATTERN.test(trimmed)) return null;
  const value = Number(trimmed);
  if (!Number.isSafeInteger(value)) return null;
  return value;
}

function readPbxprojText(pbxprojPath) {
  return fs.readFileSync(pbxprojPath, 'utf8');
}

// Reads every `MARKETING_VERSION = ...;` / `CURRENT_PROJECT_VERSION = ...;`
// occurrence across every target/configuration in the project file, and
// reports whether they're all identical — a real release must never ship
// with, say, the test targets on a different version than the app itself.
function readPbxprojVersions(pbxprojPath) {
  const text = readPbxprojText(pbxprojPath);
  const marketingVersions = [...text.matchAll(/MARKETING_VERSION = ([^;]+);/g)].map((m) => m[1].trim());
  const buildNumbers = [...text.matchAll(/CURRENT_PROJECT_VERSION = ([^;]+);/g)].map((m) => m[1].trim());

  const uniqueMarketing = [...new Set(marketingVersions)];
  const uniqueBuild = [...new Set(buildNumbers)];

  return {
    marketingVersionRaw: uniqueMarketing.length === 1 ? uniqueMarketing[0] : null,
    marketingVersionOccurrences: marketingVersions.length,
    marketingVersionsConsistent: uniqueMarketing.length <= 1,
    allMarketingVersions: uniqueMarketing,
    buildNumberRaw: uniqueBuild.length === 1 ? uniqueBuild[0] : null,
    buildNumberOccurrences: buildNumbers.length,
    buildNumbersConsistent: uniqueBuild.length <= 1,
    allBuildNumbers: uniqueBuild
  };
}

function defaultLedgerPath(repoRoot) {
  return path.join(repoRoot, 'ios-native', 'Kitchen Manager', 'Config', 'release-build-ledger.json');
}

function readBuildLedger(ledgerPath) {
  try {
    const raw = fs.readFileSync(ledgerPath, 'utf8');
    const parsed = JSON.parse(raw);
    const lastBuildNumber = Number(parsed.lastBuildNumber);
    if (!Number.isSafeInteger(lastBuildNumber) || lastBuildNumber < 0) {
      return { lastBuildNumber: 0 };
    }
    return { lastBuildNumber };
  } catch {
    return { lastBuildNumber: 0 };
  }
}

function writeBuildLedger(ledgerPath, { lastBuildNumber }) {
  const payload = `${JSON.stringify({ lastBuildNumber }, null, 2)}\n`;
  fs.writeFileSync(ledgerPath, payload, 'utf8');
}

// Replaces every `CURRENT_PROJECT_VERSION = <old>;` occurrence with the new
// value — every target/configuration is kept in lockstep. Returns the
// number of occurrences replaced (0 means nothing matched, a caller error).
function bumpBuildNumberInPbxproj(pbxprojPath, newBuildNumber, { dryRun = false } = {}) {
  const text = readPbxprojText(pbxprojPath);
  const pattern = /CURRENT_PROJECT_VERSION = [^;]+;/g;
  const matches = text.match(pattern) || [];
  if (matches.length === 0) return { replacedCount: 0, wrote: false };
  const updated = text.replace(pattern, `CURRENT_PROJECT_VERSION = ${newBuildNumber};`);
  if (!dryRun) {
    fs.writeFileSync(pbxprojPath, updated, 'utf8');
  }
  return { replacedCount: matches.length, wrote: !dryRun };
}

export {
  SEMVER_PATTERN,
  BUILD_NUMBER_PATTERN,
  parseMarketingVersion,
  parseBuildNumber,
  readPbxprojVersions,
  defaultLedgerPath,
  readBuildLedger,
  writeBuildLedger,
  bumpBuildNumberInPbxproj
};
