import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const { validateIOSRelease } = require('../scripts/validate-ios-release.mjs');
const { bumpIOSBuild } = require('../scripts/bump-ios-build.mjs');
const { runAllChecks, readXcconfigValue, checkAppIconPresence } = require('../scripts/ios-archive-guard.mjs');

function makeTempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'km-ios-release-scripts-test-'));
}

const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

function pngChunk(type, data) {
  const typeBuf = Buffer.from(type, 'ascii');
  const lengthBuf = Buffer.alloc(4);
  lengthBuf.writeUInt32BE(data.length, 0);
  const crcBuf = Buffer.alloc(4);
  crcBuf.writeUInt32BE(zlib.crc32(Buffer.concat([typeBuf, data])), 0);
  return Buffer.concat([lengthBuf, typeBuf, data, crcBuf]);
}

// Writes a real, valid, decodable grayscale PNG at the given pixel
// dimensions — used to test the app-icon guard's dimension check without
// depending on any real icon artwork existing in the repository.
function writeTestPng(filePath, width, height) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr.writeUInt8(8, 8); // bit depth
  ihdr.writeUInt8(0, 9); // color type: grayscale
  ihdr.writeUInt8(0, 10); // compression
  ihdr.writeUInt8(0, 11); // filter
  ihdr.writeUInt8(0, 12); // interlace

  const rowSize = 1 + width; // filter byte + gray samples
  const raw = Buffer.alloc(rowSize * height, 128);
  for (let y = 0; y < height; y++) raw[y * rowSize] = 0; // filter type 0 per row
  const idatData = zlib.deflateSync(raw);

  const png = Buffer.concat([
    PNG_SIGNATURE,
    pngChunk('IHDR', ihdr),
    pngChunk('IDAT', idatData),
    pngChunk('IEND', Buffer.alloc(0))
  ]);
  fs.writeFileSync(filePath, png);
}

function writePbxproj(dir, { marketingVersion = '1.0.0', buildNumber = '1' } = {}) {
  const pbxprojPath = path.join(dir, 'project.pbxproj');
  fs.writeFileSync(pbxprojPath, [
    `MARKETING_VERSION = ${marketingVersion};`,
    `CURRENT_PROJECT_VERSION = ${buildNumber};`
  ].join('\n'));
  return pbxprojPath;
}

// ── validate-ios-release.mjs ─────────────────────────────────────────────

test('validateIOSRelease passes for a well-formed, non-regressed version/build', () => {
  const dir = makeTempDir();
  const pbxprojPath = writePbxproj(dir, { marketingVersion: '1.2.0', buildNumber: '5' });
  const ledgerPath = path.join(dir, 'ledger.json');
  fs.writeFileSync(ledgerPath, JSON.stringify({ lastBuildNumber: 4 }));
  const result = validateIOSRelease({ pbxprojPath, ledgerPath });
  assert.equal(result.valid, true, JSON.stringify(result.errors));
  assert.equal(result.marketingVersion, '1.2.0');
  assert.equal(result.buildNumber, 5);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('validateIOSRelease fails a malformed marketing version', () => {
  const dir = makeTempDir();
  const pbxprojPath = writePbxproj(dir, { marketingVersion: 'v1.2', buildNumber: '5' });
  const result = validateIOSRelease({ pbxprojPath, ledgerPath: path.join(dir, 'missing-ledger.json') });
  assert.equal(result.valid, false);
  assert.ok(result.errors.some((e) => e.includes('malformed')));
  fs.rmSync(dir, { recursive: true, force: true });
});

test('validateIOSRelease fails a non-integer build number', () => {
  const dir = makeTempDir();
  const pbxprojPath = writePbxproj(dir, { marketingVersion: '1.2.0', buildNumber: '1.5' });
  const result = validateIOSRelease({ pbxprojPath, ledgerPath: path.join(dir, 'missing-ledger.json') });
  assert.equal(result.valid, false);
  assert.ok(result.errors.some((e) => e.includes('malformed')));
  fs.rmSync(dir, { recursive: true, force: true });
});

test('validateIOSRelease fails a build number that regresses below the ledger', () => {
  const dir = makeTempDir();
  const pbxprojPath = writePbxproj(dir, { marketingVersion: '1.2.0', buildNumber: '3' });
  const ledgerPath = path.join(dir, 'ledger.json');
  fs.writeFileSync(ledgerPath, JSON.stringify({ lastBuildNumber: 10 }));
  const result = validateIOSRelease({ pbxprojPath, ledgerPath });
  assert.equal(result.valid, false);
  assert.ok(result.errors.some((e) => e.includes('lower than the last recorded build number')));
  fs.rmSync(dir, { recursive: true, force: true });
});

test('validateIOSRelease on the real repository project is currently valid', () => {
  const result = validateIOSRelease();
  assert.equal(result.valid, true, JSON.stringify(result.errors));
});

// ── bump-ios-build.mjs ───────────────────────────────────────────────────

test('bumpIOSBuild increments past both the current file value and the ledger, whichever is higher', () => {
  const dir = makeTempDir();
  const pbxprojPath = writePbxproj(dir, { buildNumber: '5' });
  const ledgerPath = path.join(dir, 'ledger.json');
  fs.writeFileSync(ledgerPath, JSON.stringify({ lastBuildNumber: 9 }));
  const result = bumpIOSBuild({ pbxprojPath, ledgerPath });
  assert.equal(result.newBuildNumber, 10, 'ledger (9) was higher than the file value (5), so the new value must exceed the ledger');
  assert.deepEqual(JSON.parse(fs.readFileSync(ledgerPath, 'utf8')), { lastBuildNumber: 10 });
  fs.rmSync(dir, { recursive: true, force: true });
});

test('bumpIOSBuild dry-run does not write the pbxproj or the ledger', () => {
  const dir = makeTempDir();
  const pbxprojPath = writePbxproj(dir, { buildNumber: '5' });
  const ledgerPath = path.join(dir, 'ledger.json');
  fs.writeFileSync(ledgerPath, JSON.stringify({ lastBuildNumber: 5 }));
  const beforePbxproj = fs.readFileSync(pbxprojPath, 'utf8');
  const result = bumpIOSBuild({ pbxprojPath, ledgerPath, dryRun: true });
  assert.equal(result.newBuildNumber, 6);
  assert.equal(fs.readFileSync(pbxprojPath, 'utf8'), beforePbxproj);
  assert.deepEqual(JSON.parse(fs.readFileSync(ledgerPath, 'utf8')), { lastBuildNumber: 5 });
  fs.rmSync(dir, { recursive: true, force: true });
});

test('bumpIOSBuild refuses to bump when the pbxproj already has inconsistent build numbers', () => {
  const dir = makeTempDir();
  const pbxprojPath = path.join(dir, 'project.pbxproj');
  fs.writeFileSync(pbxprojPath, 'CURRENT_PROJECT_VERSION = 1;\nCURRENT_PROJECT_VERSION = 2;');
  assert.throws(() => bumpIOSBuild({ pbxprojPath, ledgerPath: path.join(dir, 'ledger.json') }), /already inconsistent/);
  fs.rmSync(dir, { recursive: true, force: true });
});

// ── ios-archive-guard.mjs ────────────────────────────────────────────────

test('readXcconfigValue does not leak the next line\'s content for an empty value (regression: \\s matches newlines)', () => {
  const text = 'SUPABASE_URL =\nSUPABASE_PUBLISHABLE_KEY = something\n';
  assert.equal(readXcconfigValue(text, 'SUPABASE_URL'), '');
  assert.equal(readXcconfigValue(text, 'SUPABASE_PUBLISHABLE_KEY'), 'something');
});

test('readXcconfigValue trims same-line whitespace and returns null for a missing key', () => {
  assert.equal(readXcconfigValue('FOO   =   bar  \n', 'FOO'), 'bar');
  assert.equal(readXcconfigValue('FOO = bar\n', 'MISSING'), null);
});

test('checkAppIconPresence fails when no .appiconset directory exists at all', () => {
  const dir = makeTempDir();
  const result = checkAppIconPresence(dir);
  assert.equal(result.ok, false);
  assert.match(result.detail, /no AppIcon\.appiconset found at all/);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('checkAppIconPresence fails when the appiconset only contains a trivial placeholder image (regression: a 1x1 PNG must not bypass this guard)', () => {
  const dir = makeTempDir();
  const iconDir = path.join(dir, 'Assets.xcassets', 'AppIcon.appiconset');
  fs.mkdirSync(iconDir, { recursive: true });
  fs.writeFileSync(path.join(iconDir, 'Contents.json'), '{}');
  writeTestPng(path.join(iconDir, 'icon-1x1.png'), 1, 1);
  const result = checkAppIconPresence(dir);
  assert.equal(result.ok, false, result.detail);
  assert.match(result.detail, /contains no image at least/);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('checkAppIconPresence fails when the appiconset directory exists but has zero image files (Contents.json alone is not enough)', () => {
  const dir = makeTempDir();
  const iconDir = path.join(dir, 'Assets.xcassets', 'AppIcon.appiconset');
  fs.mkdirSync(iconDir, { recursive: true });
  fs.writeFileSync(path.join(iconDir, 'Contents.json'), '{}');
  const result = checkAppIconPresence(dir);
  assert.equal(result.ok, false, result.detail);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('checkAppIconPresence passes when a real, non-trivially-sized PNG icon exists', () => {
  const dir = makeTempDir();
  const iconDir = path.join(dir, 'Assets.xcassets', 'AppIcon.appiconset');
  fs.mkdirSync(iconDir, { recursive: true });
  fs.writeFileSync(path.join(iconDir, 'Contents.json'), '{}');
  writeTestPng(path.join(iconDir, 'icon-1024.png'), 1024, 1024);
  const result = checkAppIconPresence(dir);
  assert.equal(result.ok, true, result.detail);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('checkAppIconPresence on the real repository currently fails (no asset catalog exists yet — a real, un-fabricated blocker)', () => {
  const result = checkAppIconPresence();
  assert.equal(result.ok, false);
});

test('runAllChecks on the real repository currently passes every check except the two genuinely-pending ones', () => {
  const { checks } = runAllChecks();
  // These reflect real, currently-true, non-fabricated facts about this
  // repository at the time this test runs — not aspirational values.
  assert.equal(checks.safeDefaultFlags.ok, true, checks.safeDefaultFlags.detail);
  assert.equal(checks.noServiceRoleOrRealSecrets.ok, true, checks.noServiceRoleOrRealSecrets.detail);
  assert.equal(checks.schemeShared.ok, true, checks.schemeShared.detail);
  assert.equal(checks.bundleIdentifier.ok, true, checks.bundleIdentifier.detail);
  assert.equal(checks.versionAndBuild.ok, true, checks.versionAndBuild.detail);
  assert.equal(checks.signingConfigured.ok, true, checks.signingConfigured.detail);
  assert.equal(checks.launchScreenAndPrivacyDescriptions.ok, true, checks.launchScreenAndPrivacyDescriptions.detail);
  // appIconPresence is a known, documented, currently-unmet pending item
  // (no app icon artwork exists yet) — asserting it stays false here would
  // make this test fail the moment someone adds a real icon, which is the
  // point at which this assertion should be removed, not before.
});
