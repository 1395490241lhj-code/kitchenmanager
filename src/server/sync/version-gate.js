// Minimum-client-version enforcement for /api/sync/* routes only. Never
// touches any other route (AI, recipe import, /api/me, etc.).
//
// Fail-safe rules (Phase 2C-1):
// - SYNC_VERSION_ENFORCEMENT_ENABLED missing/malformed -> disabled (matches
//   every other feature flag in this codebase: default off, explicit opt-in).
// - Enforcement explicitly enabled but MIN_IOS_APP_VERSION/MIN_IOS_BUILD/
//   MIN_IOS_CLIENT_SCHEMA missing or malformed -> never silently allow every
//   client through (that would defeat the point of turning enforcement on).
//   Instead this is treated as a server misconfiguration and every sync
//   request is refused with a distinct 503, so an operator sees the problem
//   immediately rather than an old client silently sneaking past a broken
//   config.
const VERSION_HEADER = 'x-kitchen-app-version';
const BUILD_HEADER = 'x-kitchen-app-build';
const SCHEMA_HEADER = 'x-kitchen-client-schema';

const INTEGER_PATTERN = /^\d+$/;
const SEMVER_PATTERN = /^(\d+)\.(\d+)(?:\.(\d+))?$/;

function parseBoolEnv(raw, fallback) {
  if (raw === undefined || raw === null || raw === '') return fallback;
  const normalized = String(raw).trim().toLowerCase();
  if (['1', 'true', 'yes'].includes(normalized)) return true;
  if (['0', 'false', 'no'].includes(normalized)) return false;
  return fallback;
}

// Numeric semantic-version comparison — never string/lexicographic. Returns
// null for anything that isn't exactly `major.minor` or `major.minor.patch`
// non-negative integers (no leading +/-, no whitespace-only, no overflow).
function parseSemVer(raw) {
  if (typeof raw !== 'string') return null;
  const trimmed = raw.trim();
  const match = SEMVER_PATTERN.exec(trimmed);
  if (!match) return null;
  const [, majorStr, minorStr, patchStr] = match;
  const major = Number(majorStr);
  const minor = Number(minorStr);
  const patch = patchStr === undefined ? 0 : Number(patchStr);
  if (![major, minor, patch].every(Number.isSafeInteger)) return null;
  return [major, minor, patch];
}

function formatSemVer(parsed) {
  return `${parsed[0]}.${parsed[1]}.${parsed[2]}`;
}

function compareSemVer(a, b) {
  for (let i = 0; i < 3; i += 1) {
    if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return 0;
}

// Shared by build number and schema version — both are plain non-negative
// integers. Rejects negative numbers, decimals, empty strings, and anything
// that would overflow safe-integer precision. Leading zeros ("007") are
// accepted and parsed as the equivalent integer (7).
function parseNonNegativeInteger(raw) {
  if (raw === undefined || raw === null) return null;
  const str = typeof raw === 'number' ? String(raw) : raw;
  if (typeof str !== 'string') return null;
  const trimmed = str.trim();
  if (!INTEGER_PATTERN.test(trimmed)) return null;
  const value = Number(trimmed);
  if (!Number.isSafeInteger(value)) return null;
  return value;
}

function loadVersionEnforcementConfig(env = process.env) {
  const enabled = parseBoolEnv(env.SYNC_VERSION_ENFORCEMENT_ENABLED, false);
  if (!enabled) {
    return { enabled: false, misconfigured: false };
  }
  const minVersion = parseSemVer(env.MIN_IOS_APP_VERSION);
  const minBuild = parseNonNegativeInteger(env.MIN_IOS_BUILD);
  const minSchema = parseNonNegativeInteger(env.MIN_IOS_CLIENT_SCHEMA);
  if (!minVersion || minBuild === null || minSchema === null) {
    return { enabled: true, misconfigured: true };
  }
  return { enabled: true, misconfigured: false, minVersion, minBuild, minSchema };
}

function readClientVersionHeaders(req) {
  return {
    versionRaw: req.get(VERSION_HEADER),
    buildRaw: req.get(BUILD_HEADER),
    schemaRaw: req.get(SCHEMA_HEADER)
  };
}

function sendMisconfigured(res) {
  return res.status(503).json({
    error: 'sync_version_enforcement_misconfigured',
    code: 'SYNC_VERSION_ENFORCEMENT_MISCONFIGURED',
    message: 'Sync is temporarily unavailable due to a server configuration issue.'
  });
}

function sendUpgradeRequired(res, config) {
  return res.status(426).json({
    error: 'client_upgrade_required',
    code: 'CLIENT_UPGRADE_REQUIRED',
    message: 'A newer app version is required to use cloud sync.',
    minimumVersion: formatSemVer(config.minVersion),
    minimumBuild: config.minBuild
  });
}

// `loadConfig` is re-invoked on every request (not cached at module load)
// so an operator can change the env var and redeploy without any other code
// change — matches every other flag in this codebase.
function createVersionGateMiddleware({ loadConfig = loadVersionEnforcementConfig } = {}) {
  return function versionGate(req, res, next) {
    const config = loadConfig();
    if (!config.enabled) return next();
    if (config.misconfigured) return sendMisconfigured(res);

    const { versionRaw, buildRaw, schemaRaw } = readClientVersionHeaders(req);
    const clientVersion = parseSemVer(versionRaw);
    const clientBuild = parseNonNegativeInteger(buildRaw);
    const clientSchema = parseNonNegativeInteger(schemaRaw);
    const headersPresent = versionRaw !== undefined && buildRaw !== undefined && schemaRaw !== undefined;
    const headersValid = headersPresent && clientVersion !== null && clientBuild !== null && clientSchema !== null;

    if (!headersValid) return sendUpgradeRequired(res, config);

    const meetsMinimum = compareSemVer(clientVersion, config.minVersion) >= 0
      && clientBuild >= config.minBuild
      && clientSchema >= config.minSchema;
    if (!meetsMinimum) return sendUpgradeRequired(res, config);

    return next();
  };
}

module.exports = {
  VERSION_HEADER,
  BUILD_HEADER,
  SCHEMA_HEADER,
  parseSemVer,
  formatSemVer,
  compareSemVer,
  parseNonNegativeInteger,
  loadVersionEnforcementConfig,
  createVersionGateMiddleware
};
