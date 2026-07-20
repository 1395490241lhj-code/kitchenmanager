import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  parseMarketingVersion,
  parseBuildNumber,
  readPbxprojVersions,
  readBuildLedger,
  writeBuildLedger,
  bumpBuildNumberInPbxproj
} from '../scripts/ios-release-support.mjs';

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

function makeTempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'km-ios-release-test-'));
}

// ── parseMarketingVersion ────────────────────────────────────────────────

test('parseMarketingVersion accepts X.Y and X.Y.Z, rejects malformed strings', () => {
  assert.equal(parseMarketingVersion('1.0'), '1.0');
  assert.equal(parseMarketingVersion('1.2.3'), '1.2.3');
  assert.equal(parseMarketingVersion('  1.2.3  '), '1.2.3');
  for (const bad of ['1', 'v1.0.0', '1.0.0.0', '1.a.0', '', null, undefined, '1.0-beta']) {
    assert.equal(parseMarketingVersion(bad), null, `expected null for ${JSON.stringify(bad)}`);
  }
});

// ── parseBuildNumber ─────────────────────────────────────────────────────

test('parseBuildNumber accepts a plain positive integer, rejects everything else', () => {
  assert.equal(parseBuildNumber('1'), 1);
  assert.equal(parseBuildNumber('42'), 42);
  // Surrounding whitespace is trimmed before validating — a regex-captured
  // value may carry incidental whitespace, and that alone should never fail
  // an otherwise-valid build number.
  assert.equal(parseBuildNumber(' 1'), 1);
  assert.equal(parseBuildNumber('1 '), 1);
  for (const bad of ['0', '007', '-1', '1.5', '', null, undefined, 'abc', '99999999999999999999']) {
    assert.equal(parseBuildNumber(bad), null, `expected null for ${JSON.stringify(bad)}`);
  }
});

// ── readPbxprojVersions ──────────────────────────────────────────────────

test('readPbxprojVersions detects consistent versions across multiple targets', () => {
  const dir = makeTempDir();
  const pbxprojPath = path.join(dir, 'project.pbxproj');
  fs.writeFileSync(pbxprojPath, [
    'MARKETING_VERSION = 1.2.0;',
    'CURRENT_PROJECT_VERSION = 5;',
    'MARKETING_VERSION = 1.2.0;',
    'CURRENT_PROJECT_VERSION = 5;'
  ].join('\n'));
  const result = readPbxprojVersions(pbxprojPath);
  assert.equal(result.marketingVersionRaw, '1.2.0');
  assert.equal(result.buildNumberRaw, '5');
  assert.equal(result.marketingVersionsConsistent, true);
  assert.equal(result.buildNumbersConsistent, true);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('readPbxprojVersions flags an inconsistent version across targets', () => {
  const dir = makeTempDir();
  const pbxprojPath = path.join(dir, 'project.pbxproj');
  fs.writeFileSync(pbxprojPath, [
    'MARKETING_VERSION = 1.2.0;',
    'CURRENT_PROJECT_VERSION = 5;',
    'MARKETING_VERSION = 1.3.0;',
    'CURRENT_PROJECT_VERSION = 6;'
  ].join('\n'));
  const result = readPbxprojVersions(pbxprojPath);
  assert.equal(result.marketingVersionRaw, null);
  assert.equal(result.marketingVersionsConsistent, false);
  assert.deepEqual(result.allMarketingVersions.sort(), ['1.2.0', '1.3.0']);
  assert.equal(result.buildNumberRaw, null);
  assert.equal(result.buildNumbersConsistent, false);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('readPbxprojVersions on the real repository project file is currently consistent and well-formed', () => {
  const pbxprojPath = path.join(ROOT, 'ios-native', 'Kitchen Manager', 'Kitchen Manager.xcodeproj', 'project.pbxproj');
  const result = readPbxprojVersions(pbxprojPath);
  assert.equal(result.marketingVersionsConsistent, true);
  assert.equal(result.buildNumbersConsistent, true);
  assert.ok(parseMarketingVersion(result.marketingVersionRaw));
  assert.ok(parseBuildNumber(result.buildNumberRaw) !== null);
});

// ── build ledger ─────────────────────────────────────────────────────────

test('readBuildLedger defaults to 0 when the file is missing or malformed', () => {
  const dir = makeTempDir();
  assert.deepEqual(readBuildLedger(path.join(dir, 'does-not-exist.json')), { lastBuildNumber: 0 });
  const malformedPath = path.join(dir, 'malformed.json');
  fs.writeFileSync(malformedPath, 'not json');
  assert.deepEqual(readBuildLedger(malformedPath), { lastBuildNumber: 0 });
  const negativePath = path.join(dir, 'negative.json');
  fs.writeFileSync(negativePath, JSON.stringify({ lastBuildNumber: -5 }));
  assert.deepEqual(readBuildLedger(negativePath), { lastBuildNumber: 0 });
  fs.rmSync(dir, { recursive: true, force: true });
});

test('writeBuildLedger then readBuildLedger round-trips', () => {
  const dir = makeTempDir();
  const ledgerPath = path.join(dir, 'ledger.json');
  writeBuildLedger(ledgerPath, { lastBuildNumber: 17 });
  assert.deepEqual(readBuildLedger(ledgerPath), { lastBuildNumber: 17 });
  fs.rmSync(dir, { recursive: true, force: true });
});

// ── bumpBuildNumberInPbxproj ─────────────────────────────────────────────

test('bumpBuildNumberInPbxproj replaces every occurrence and reports the count', () => {
  const dir = makeTempDir();
  const pbxprojPath = path.join(dir, 'project.pbxproj');
  fs.writeFileSync(pbxprojPath, [
    'CURRENT_PROJECT_VERSION = 1;',
    'CURRENT_PROJECT_VERSION = 1;',
    'CURRENT_PROJECT_VERSION = 1;'
  ].join('\n'));
  const result = bumpBuildNumberInPbxproj(pbxprojPath, 2);
  assert.equal(result.replacedCount, 3);
  assert.equal(result.wrote, true);
  const updated = fs.readFileSync(pbxprojPath, 'utf8');
  assert.equal((updated.match(/CURRENT_PROJECT_VERSION = 2;/g) || []).length, 3);
  assert.equal(updated.includes('CURRENT_PROJECT_VERSION = 1;'), false);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('bumpBuildNumberInPbxproj dry-run never writes the file', () => {
  const dir = makeTempDir();
  const pbxprojPath = path.join(dir, 'project.pbxproj');
  const original = 'CURRENT_PROJECT_VERSION = 1;';
  fs.writeFileSync(pbxprojPath, original);
  const result = bumpBuildNumberInPbxproj(pbxprojPath, 2, { dryRun: true });
  assert.equal(result.replacedCount, 1);
  assert.equal(result.wrote, false);
  assert.equal(fs.readFileSync(pbxprojPath, 'utf8'), original);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('bumpBuildNumberInPbxproj reports zero replacements when nothing matches, without throwing', () => {
  const dir = makeTempDir();
  const pbxprojPath = path.join(dir, 'project.pbxproj');
  fs.writeFileSync(pbxprojPath, 'NO_VERSION_HERE = true;');
  const result = bumpBuildNumberInPbxproj(pbxprojPath, 2);
  assert.equal(result.replacedCount, 0);
  assert.equal(result.wrote, false);
  fs.rmSync(dir, { recursive: true, force: true });
});
