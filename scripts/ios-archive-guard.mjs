// Phase 2D-1: pre-archive safety checks for the iOS app — pure file
// reads/greps, no network access, no Xcode invocation, never uploads
// anything. Run via `npm run ios:archive:guard` before any real
// Release/AppStore archive. This complements (does not replace)
// scripts/validate-ios-release.mjs (version/build number only).
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { execSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { readPbxprojVersions } from './ios-release-support.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const IOS_ROOT = path.join(ROOT, 'ios-native', 'Kitchen Manager');
const PBXPROJ = path.join(IOS_ROOT, 'Kitchen Manager.xcodeproj', 'project.pbxproj');
const SHARED_XCCONFIG = path.join(IOS_ROOT, 'Config', 'Shared.xcconfig');
const INFO_PLIST = path.join(IOS_ROOT, 'KitchenManager', 'Info.plist');

// Every flag that must read `NO` in the *committed* Shared.xcconfig for a
// safe archive — a Local.xcconfig override cannot un-safe these for a real
// archive, since Archive builds in this project never read a developer's
// personal Local.xcconfig in CI/clean-checkout contexts, and this check
// only ever reads the tracked file, never the gitignored one.
const REQUIRED_NO_FLAGS = [
  'SYNC_SMOKE_ENABLED',
  'GUEST_MERGE_SMOKE_ENABLED',
  'INVENTORY_SYNC_DOGFOOD_ENABLED',
  'INVENTORY_SYNC_DIAGNOSTICS_ENABLED'
];

function readFileIfExists(filePath) {
  try {
    return fs.readFileSync(filePath, 'utf8');
  } catch {
    return null;
  }
}

function checkWorkspaceClean() {
  try {
    const output = execSync('git status --short', { cwd: ROOT, encoding: 'utf8' });
    return { ok: output.trim() === '', detail: output.trim() === '' ? 'clean' : 'uncommitted changes present' };
  } catch (error) {
    return { ok: false, detail: `git status failed: ${error.message}` };
  }
}

// Matches only same-line whitespace (spaces/tabs) around `=`, deliberately
// never `\s` — `\s` also matches newlines, which would let an empty value
// ("KEY =" followed immediately by a newline) silently capture the *next*
// line's content as if it were this key's value. Found by testing, not
// assumed: an earlier version of this file had exactly this bug.
function readXcconfigValue(text, key) {
  const match = text.match(new RegExp(`^${key}[ \\t]*=[ \\t]*(.*)$`, 'm'));
  return match ? match[1].trim() : null;
}

function checkFlags() {
  const text = readFileIfExists(SHARED_XCCONFIG);
  if (text === null) return { ok: false, detail: 'Shared.xcconfig not found' };
  const failures = [];
  for (const flag of REQUIRED_NO_FLAGS) {
    const value = readXcconfigValue(text, flag);
    if ((value || '').toUpperCase() !== 'NO') failures.push(`${flag}=${value || 'MISSING'}`);
  }
  // CRASH_REPORTING_ENABLED must also be NO by default; a real DSN must
  // never be committed as a placeholder-looking-real value.
  const crashEnabled = readXcconfigValue(text, 'CRASH_REPORTING_ENABLED');
  if ((crashEnabled || '').toUpperCase() !== 'NO') failures.push('CRASH_REPORTING_ENABLED not NO');
  const dsnValue = readXcconfigValue(text, 'CRASH_REPORTING_DSN');
  if ((dsnValue || '') !== '') failures.push('CRASH_REPORTING_DSN is not empty in the committed config');

  return { ok: failures.length === 0, detail: failures.length === 0 ? 'all safe-default flags are NO' : failures.join(', ') };
}

function checkNoServiceRoleOrRealSecrets() {
  const text = readFileIfExists(SHARED_XCCONFIG) || '';
  const hasServiceRole = /SERVICE_ROLE/i.test(text);
  const supabaseUrlValue = readXcconfigValue(text, 'SUPABASE_URL') || '';
  const failures = [];
  if (hasServiceRole) failures.push('service-role reference found in Shared.xcconfig');
  if (supabaseUrlValue !== '') failures.push('SUPABASE_URL is not empty in the committed Shared.xcconfig (must stay blank; real value belongs only in gitignored Local.xcconfig)');
  return { ok: failures.length === 0, detail: failures.length === 0 ? 'no service-role/real URL in committed config' : failures.join(', ') };
}

function checkSchemeShared() {
  const schemesDir = path.join(IOS_ROOT, 'Kitchen Manager.xcodeproj', 'xcshareddata', 'xcschemes');
  const exists = fs.existsSync(schemesDir) && fs.readdirSync(schemesDir).some((name) => name.endsWith('.xcscheme'));
  return { ok: exists, detail: exists ? 'a shared .xcscheme exists' : 'no shared scheme found — CI/archive tooling on a fresh checkout cannot rely on an implicit scheme' };
}

function checkBundleIdentifier() {
  const text = readFileIfExists(PBXPROJ) || '';
  const ids = [...new Set([...text.matchAll(/PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);/g)].map((m) => m[1].trim()))];
  const appId = ids.find((id) => !id.endsWith('.Tests') && !id.endsWith('.UITests'));
  const ok = Boolean(appId) && appId !== 'com.example.YOUR_BUNDLE_ID' && !appId.includes('$(');
  return { ok, detail: ok ? `app bundle id resolved` : `could not resolve a concrete app bundle identifier (found: ${ids.join(', ') || 'none'})` };
}

function checkVersionAndBuild() {
  const versions = readPbxprojVersions(PBXPROJ);
  const ok = versions.marketingVersionsConsistent && versions.buildNumbersConsistent
    && Boolean(versions.marketingVersionRaw) && Boolean(versions.buildNumberRaw);
  return {
    ok,
    detail: ok
      ? `MARKETING_VERSION=${versions.marketingVersionRaw} CURRENT_PROJECT_VERSION=${versions.buildNumberRaw}`
      : 'version/build number missing or inconsistent across targets — run `npm run ios:release:check` for detail'
  };
}

// A minimum pixel size for at least one real icon image — rejects a
// trivial 1x1/16x16 placeholder or an accidentally-empty PNG without
// requiring full pixel-content analysis (whether an icon is a plain
// solid color is a design/App-Review judgment, not something this
// mechanical guard tries to detect).
const MIN_APP_ICON_DIMENSION = 512;
const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) {
      crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

// PNG dimensions are stored in the mandatory first IHDR chunk. Reading that
// fixed header keeps this guard identical on macOS and Linux instead of
// depending on the macOS-only `sips` executable. Chunk CRCs, compressed image
// data, and IEND are also checked so a header-only placeholder cannot pass.
function pngDimensions(filePath) {
  try {
    const png = fs.readFileSync(filePath);
    if (png.length < 33 || !png.subarray(0, PNG_SIGNATURE.length).equals(PNG_SIGNATURE)) {
      return { width: 0, height: 0 };
    }

    let offset = PNG_SIGNATURE.length;
    let width = 0;
    let height = 0;
    let sawIend = false;
    const idatChunks = [];

    while (offset + 12 <= png.length) {
      const length = png.readUInt32BE(offset);
      const typeStart = offset + 4;
      const dataStart = typeStart + 4;
      const dataEnd = dataStart + length;
      const chunkEnd = dataEnd + 4;
      if (chunkEnd > png.length) return { width: 0, height: 0 };

      const type = png.toString('ascii', typeStart, dataStart);
      const expectedCrc = png.readUInt32BE(dataEnd);
      const actualCrc = crc32(png.subarray(typeStart, dataEnd));
      if (expectedCrc !== actualCrc) return { width: 0, height: 0 };

      if (offset === PNG_SIGNATURE.length) {
        if (type !== 'IHDR' || length !== 13) return { width: 0, height: 0 };
        width = png.readUInt32BE(dataStart);
        height = png.readUInt32BE(dataStart + 4);
        if (width === 0 || height === 0) return { width: 0, height: 0 };
      } else if (type === 'IHDR') {
        return { width: 0, height: 0 };
      }

      if (type === 'IDAT') idatChunks.push(png.subarray(dataStart, dataEnd));
      if (type === 'IEND') {
        if (length !== 0) return { width: 0, height: 0 };
        sawIend = true;
        break;
      }
      offset = chunkEnd;
    }

    if (!sawIend || idatChunks.length === 0) return { width: 0, height: 0 };
    if (zlib.inflateSync(Buffer.concat(idatChunks)).length === 0) return { width: 0, height: 0 };
    return { width, height };
  } catch {
    return { width: 0, height: 0 };
  }
}

function checkAppIconPresence(assetsRoot = path.join(IOS_ROOT, 'KitchenManager')) {
  const appIconDirs = [];
  function walk(dir) {
    if (!fs.existsSync(dir)) return;
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        if (entry.name.endsWith('.appiconset')) appIconDirs.push(full);
        else walk(full);
      }
    }
  }
  walk(assetsRoot);

  if (appIconDirs.length === 0) {
    return { ok: false, detail: 'no AppIcon.appiconset found at all (no Assets.xcassets/asset catalog exists yet) — a real App Store archive requires a 1024x1024 app icon; this is a known, documented pending item (see docs/IOS_SIGNING_AND_ARCHIVE.md), not fixed by this script' };
  }

  const svgFiles = appIconDirs.flatMap((dir) => fs.readdirSync(dir).filter((name) => /\.svg$/i.test(name)).map((name) => path.join(dir, name)));
  const hasNonTrivialSvg = svgFiles.some((file) => fs.statSync(file).size > 256);

  const pngFiles = appIconDirs.flatMap((dir) => fs.readdirSync(dir).filter((name) => /\.png$/i.test(name)).map((name) => path.join(dir, name)));
  const hasRealSizedPng = pngFiles.some((file) => {
    const { width, height } = pngDimensions(file);
    return width >= MIN_APP_ICON_DIMENSION && height >= MIN_APP_ICON_DIMENSION;
  });

  const ok = hasRealSizedPng || hasNonTrivialSvg;
  return {
    ok,
    detail: ok
      ? 'an AppIcon asset with real, non-trivial image content exists'
      : `an AppIcon.appiconset exists but contains no image at least ${MIN_APP_ICON_DIMENSION}x${MIN_APP_ICON_DIMENSION}px (found ${pngFiles.length} PNG(s), ${svgFiles.length} SVG(s)) — a trivial/placeholder/empty image does not satisfy this check; this is a known, documented pending item (see docs/IOS_SIGNING_AND_ARCHIVE.md), not fixed by this script`
  };
}

function checkLaunchScreenAndPrivacyDescriptions() {
  const text = readFileIfExists(INFO_PLIST) || '';
  const hasLaunchScreen = /<key>UILaunchScreen<\/key>/.test(text);
  const hasCameraDescription = /<key>NSCameraUsageDescription<\/key>/.test(text);
  const ok = hasLaunchScreen && hasCameraDescription;
  return {
    ok,
    detail: ok ? 'launch screen configured, camera usage description present' : `missing: ${!hasLaunchScreen ? 'UILaunchScreen ' : ''}${!hasCameraDescription ? 'NSCameraUsageDescription' : ''}`.trim()
  };
}

function checkSigningConfigured() {
  const text = readFileIfExists(PBXPROJ) || '';
  const hasAutomaticSigning = /CODE_SIGN_STYLE = Automatic;/.test(text);
  const hasTeam = /DEVELOPMENT_TEAM = [^;]+;/.test(text) && !/DEVELOPMENT_TEAM = ;/.test(text);
  const ok = hasAutomaticSigning && hasTeam;
  return { ok, detail: ok ? 'Automatic signing with a configured team' : 'signing style or development team not configured' };
}

function runAllChecks() {
  const checks = {
    workspaceClean: checkWorkspaceClean(),
    safeDefaultFlags: checkFlags(),
    noServiceRoleOrRealSecrets: checkNoServiceRoleOrRealSecrets(),
    schemeShared: checkSchemeShared(),
    bundleIdentifier: checkBundleIdentifier(),
    versionAndBuild: checkVersionAndBuild(),
    appIconPresence: checkAppIconPresence(),
    launchScreenAndPrivacyDescriptions: checkLaunchScreenAndPrivacyDescriptions(),
    signingConfigured: checkSigningConfigured()
  };
  const passed = Object.values(checks).every((c) => c.ok);
  return { passed, checks };
}

function main() {
  const { passed, checks } = runAllChecks();
  for (const [name, result] of Object.entries(checks)) {
    console.log(`[ios-archive-guard] ${result.ok ? 'PASS' : 'FAIL'} ${name}: ${result.detail}`);
  }
  if (!passed) {
    console.error('[ios-archive-guard] one or more checks failed — do not archive/upload until resolved');
    process.exitCode = 1;
  } else {
    console.log('[ios-archive-guard] all checks passed');
  }
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  main();
}

export { runAllChecks, readXcconfigValue, checkAppIconPresence, pngDimensions, MIN_APP_ICON_DIMENSION };
