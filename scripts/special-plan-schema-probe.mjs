#!/usr/bin/env node
// Bounded provider probe for the Special Plan strict response schema.
//
// Sends the EXACT schema `getSpecialPlanResponseFormat` builds for a provider,
// with the exact production prompt, straight to that provider. Nothing here
// touches production: it talks to the provider directly with a key supplied in
// the environment, and it never enables the server flag.
//
// Answers the two questions that gate AI_SPECIAL_PLAN_SCHEMA=YES:
//   1. does the provider ACCEPT the schema (or 400 on a keyword)?
//   2. does the schema actually change dish-count / baseServings compliance?
//
// Credentials are read from the environment, or from an untracked file
// outside both worktrees (default /tmp/km-special-plan-schema-probe.env,
// override with KM_PROBE_ENV_FILE). Provider secrets never belong in a repo
// path. The file is `KEY=value` per line; nothing here ever prints a key.
//
// The repo's Groq key is OPENAI_API_KEY — see src/server/config.js, where the
// groq provider config is built from it. GROQ_API_KEY is accepted as a
// convenience alias here only.
//
// Usage:
//   node scripts/special-plan-schema-probe.mjs gemini 3 prompt-A.txt
//   node scripts/special-plan-schema-probe.mjs groq   3 prompt-A.txt
//
// Runs are paced 35s apart. Never lower that: a 4s cadence tripped upstream
// rate limiting during Phase 1 and polluted the sample.

import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const {
  getSpecialPlanResponseFormat,
  isSchemaUnsupportedError,
  describe
} = require('../src/server/services/special-plan-schema');

// Load credentials from the external file before anything reads process.env.
const ENV_FILE = process.env.KM_PROBE_ENV_FILE || '/tmp/km-special-plan-schema-probe.env';
if (existsSync(ENV_FILE)) {
  for (const line of readFileSync(ENV_FILE, 'utf8').split('\n')) {
    const match = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
    if (match && !process.env[match[1]]) process.env[match[1]] = match[2].replace(/^["']|["']$/g, '');
  }
  console.log(`loaded credentials from ${ENV_FILE}`);
}

const [provider = 'gemini', countArg = '3', promptPath] = process.argv.slice(2);
const runs = Math.min(Number(countArg) || 3, 3); // hard cap: this is a probe, not a benchmark
const DISH_COUNT = 6;

const PROVIDERS = {
  gemini: {
    url: 'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions',
    key: process.env.GEMINI_API_KEY,
    model: process.env.GEMINI_MODEL || 'gemini-3.6-flash',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai/'
  },
  groq: {
    url: 'https://api.groq.com/openai/v1/chat/completions',
    key: process.env.OPENAI_API_KEY || process.env.GROQ_API_KEY,
    model: process.env.OPENAI_MODEL || 'openai/gpt-oss-120b',
    baseUrl: 'https://api.groq.com/openai/v1'
  }
};

const config = PROVIDERS[provider];
if (!config) throw new Error(`unknown provider: ${provider}`);
if (!config.key) throw new Error(`no API key in env for ${provider}`);
if (!promptPath) throw new Error('pass the path to a dumped production prompt');

const prompt = readFileSync(promptPath, 'utf8');
const responseFormat = getSpecialPlanResponseFormat({
  provider,
  baseUrl: config.baseUrl,
  model: config.model,
  dishCount: DISH_COUNT
});
if (!responseFormat) throw new Error(`${provider}/${config.model} builds no strict schema`);

console.log(`probe ${provider} ${config.model} — ${JSON.stringify(describe(provider))}`);

// The id of a real candidate recipe offered in the prompt, when the run is
// probing the reuse branch. Reported against what the model actually returns,
// so an invented id is visible rather than silently counted as a reuse.
const CANDIDATE_ID = process.env.KM_PROBE_CANDIDATE_ID || null;

/// One of the five outcomes, never a catch-all. A 429 is infrastructure, not a
/// schema rejection: conflating them would make a quota blip look like proof
/// that a schema keyword is unsupported.
function classifyFailure(status, body) {
  if (status === 429 || status >= 500) return 'PROVIDER_INFRA_FAILURE';
  // Ask the production predicate itself, so this also reports whether the real
  // degrade path would recognise this exact error.
  const shaped = { status, response: { status, data: body } };
  if (isSchemaUnsupportedError(shaped)) return 'STRICT_SCHEMA_REJECTED';
  return 'OTHER_PROVIDER_FAILURE';
}

function evaluate(content) {
  let parsed;
  try { parsed = JSON.parse(content); } catch { return { category: 'STRICT_ACCEPTED_BUT_CLIENT_REJECTED', reason: 'undecodable' }; }

  const event = parsed.event;
  const eventPresent = !!event && typeof event === 'object';
  const eventFields = eventPresent
    ? {
        title: typeof event.title === 'string' && event.title.length > 0,
        scheduledAt: typeof event.scheduledAt === 'string',
        peopleCount: Number.isInteger(event.peopleCount),
        constraintNotes: Array.isArray(event.constraintNotes),
        notes: typeof event.notes === 'string'
      }
    : null;

  const recipes = (parsed.days || []).flatMap(d => (d.meals || []).flatMap(m => m.recipes || []));
  const existing = recipes.filter(r => r.source === 'existing');
  const ai = recipes.filter(r => r.source !== 'existing');

  const existingDetail = existing.map(r => ({
    idMatchesCandidate: CANDIDATE_ID ? r.existingRecipeID === CANDIDATE_ID : null,
    returnedId: CANDIDATE_ID && r.existingRecipeID === CANDIDATE_ID ? 'candidate' : 'other',
    // The provenance guarantee: a reused recipe must not claim a body or a yield.
    carriesNoRecipeBody: !('ingredients' in r) && !('steps' in r) && !('baseServings' in r)
  }));

  const result = {
    decoded: recipes.length,
    target: DISH_COUNT,
    sourceSplit: { ai: ai.length, existing: existing.length },
    eventPresent,
    eventFields,
    baseServings: ai.map(r => r.baseServings ?? null),
    existingDetail,
    exactCount: recipes.length === DISH_COUNT,
    yieldHeld: ai.every(r => r.baseServings === 4)
  };

  // Client-side rules, as the app applies them.
  const mappable = recipes.filter(r =>
    r.source === 'existing'
      ? typeof r.existingRecipeID === 'string' && r.existingRecipeID.length > 0
      : typeof r.name === 'string' && r.name.length > 0
        && Array.isArray(r.ingredients) && r.ingredients.length > 0
        && Array.isArray(r.steps) && r.steps.length > 0);
  result.mapped = mappable.length;
  const clientOk = mappable.length >= Math.max(2, DISH_COUNT - 1) && result.yieldHeld && eventPresent;
  result.category = clientOk ? 'STRICT_ACCEPTED_VALID' : 'STRICT_ACCEPTED_BUT_CLIENT_REJECTED';
  return result;
}

for (let i = 0; i < runs; i++) {
  const started = Date.now();
  let row = { run: i + 1, provider };
  try {
    const res = await fetch(config.url, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${config.key}` },
      // Byte-parity with postChatCompletion: it omits temperature for
      // gemini-3.6-flash and sends 0.2 otherwise. A probe that differs from
      // production here is not evidence about production.
      body: JSON.stringify({
        model: config.model,
        messages: [
          { role: 'system', content: 'Kitchen Manager task: weekly-menu-plan. Return only the requested content.' },
          { role: 'user', content: prompt }
        ],
        ...(provider === 'gemini' && config.model === 'gemini-3.6-flash' ? {} : { temperature: 0.2 }),
        response_format: responseFormat
      }),
      // The same 45s primary budget the route gives this task.
      signal: AbortSignal.timeout(45000)
    });
    const ms = Date.now() - started;
    const body = await res.json().catch(() => ({}));
    if (!res.ok) {
      // The outcome that matters most: a rejected schema keyword is a 400 that
      // no fallback covers, so it must block enabling the flag.
      row = { ...row, ms, http: res.status,
        category: classifyFailure(res.status, body),
        code: body?.error?.code ?? null,
        param: body?.error?.param ?? null,
        message: String(body?.error?.message ?? '').slice(0, 300) };
    } else {
      row = { ...row, ms, http: 200, ...evaluate(body?.choices?.[0]?.message?.content ?? '') };
    }
  } catch (e) {
    row = { ...row, ms: Date.now() - started, category: 'PROVIDER_INFRA_FAILURE', transport: e.name };
  }
  console.log(JSON.stringify(row));
  if (i < runs - 1) await new Promise(r => setTimeout(r, 35000));
}
