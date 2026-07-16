// Phase 2C-2 health/ready endpoints.
//
// GET /health: process-alive only. No DB/network access, no config checks —
// must return fast even if Supabase or env config is broken, so an
// orchestrator can distinguish "process is up" from "process is ready".
//
// GET /ready: explicit named checks (config presence/shape, optionally a
// minimal read-only Supabase connectivity probe). Every check is injected by
// the caller (server.js) as { name, run: async () => boolean } — this module
// has no built-in knowledge of Supabase/version-gate/rate-limit config, so it
// stays independently testable without real network access.
//
// Response bodies only ever contain { status, version, environment, checks }
// where checks is a map of check-name -> boolean. Never a URL, key, project
// ref, stack trace, or other internal config value.

function createHealthHandler({
  environment = process.env.NODE_ENV || 'development',
  release = process.env.SYNC_RELEASE_VERSION || 'unknown'
} = {}) {
  return function healthHandler(req, res) {
    res.status(200).json({ status: 'ok', version: release, environment });
  };
}

async function runCheckWithTimeout(run, timeoutMs) {
  try {
    const result = await Promise.race([
      Promise.resolve().then(run),
      new Promise((resolve) => setTimeout(() => resolve(false), timeoutMs))
    ]);
    return result === true;
  } catch {
    return false;
  }
}

function createReadyHandler({
  checks = [],
  environment = process.env.NODE_ENV || 'development',
  release = process.env.SYNC_RELEASE_VERSION || 'unknown',
  timeoutMs = 2000
} = {}) {
  return async function readyHandler(req, res) {
    const results = {};
    let allPass = true;
    for (const check of checks) {
      const pass = await runCheckWithTimeout(check.run, timeoutMs);
      results[check.name] = pass;
      if (!pass) allPass = false;
    }
    res.status(allPass ? 200 : 503).json({
      status: allPass ? 'ready' : 'not_ready',
      version: release,
      environment,
      checks: results
    });
  };
}

module.exports = { createHealthHandler, createReadyHandler, runCheckWithTimeout };
