#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { userInfo } from "node:os";

const ENDPOINT = "https://api.typesafe.ai/v1/systemone";
const MODEL = "jev-latest";
const MAX_STATE_CHARS = 6000;
const RETRYABLE = new Set([429, 529]);

function fail(message, code = 2) {
  process.stderr.write(message + "\n");
  process.exit(code);
}

function resolveApiKey() {
  const envKey = process.env.TYPESAFE_API_KEY?.trim();
  if (envKey) return { value: envKey, source: "environment" };

  if (process.platform !== "darwin") return null;

  try {
    const account = process.env.USER?.trim() || userInfo().username;
    const value = execFileSync(
      "/usr/bin/security",
      ["find-generic-password", "-a", account, "-s", "typesafe-ai", "-w"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 3000 }
    ).trim();
    return value ? { value, source: "keychain" } : null;
  } catch {
    return null;
  }
}

async function readStdin() {
  let text = "";
  for await (const chunk of process.stdin) text += chunk;
  return text.trim();
}

function buildPayload(state) {
  return {
    model: MODEL,
    state,
    questions: {
      reasoning_tier: {
        type: "choice",
        instructions:
          "What is the lowest reasoning tier sufficient to execute this bounded coding task safely? Choose direct when accepted decisions and a local implementation path make the task mostly mechanical; standard when ordinary local reasoning is needed; deep only when unresolved architecture, concurrency, persistence, cross-contract, or root-cause uncertainty justifies expensive reasoning.",
        criteria: {
          direct: "Mechanical or tightly bounded implementation; no material unresolved design question.",
          standard: "Some local reasoning or trade-off analysis is needed, but no deep architectural uncertainty.",
          deep: "Material unresolved architecture, concurrency, persistence, cross-contract, or root-cause uncertainty remains."
        }
      },
      review_gate: {
        type: "choice",
        instructions:
          "What review level is proportionate after implementation? Do not request independent review merely because the task is large.",
        criteria: {
          skip: "Routine local change with focused tests/evidence and no shared or critical contract risk.",
          focused: "A focused self-review or narrow second look is useful for shared behavior or moderate regression risk.",
          independent: "Independent review is warranted for public/shared contracts, persistence or migration, auth/security, sync, concurrency/state ownership, destructive behavior, or uncertain regression-test validity."
        }
      },
      scope_pressure: {
        type: "choice",
        instructions:
          "Does the current bounded task state support direct execution, require one bounded context expansion, or conflict with an accepted decision/hard boundary?",
        criteria: {
          bounded: "Enough context is present to proceed inside the stated scope.",
          needs_context: "A concrete missing fact blocks safe execution and requires a bounded investigation.",
          decision_conflict: "Current evidence materially conflicts with an accepted decision or hard boundary; stop rather than silently widen scope."
        }
      }
    }
  };
}

function choice(answer, id) {
  if (!answer || answer.type !== "choice" || typeof answer.choice !== "string") {
    throw new Error(`Invalid TypeSafe answer for ${id}`);
  }
  return {
    choice: answer.choice,
    confidence: answer.confidence ?? null,
    probabilities: answer.probabilities ?? null
  };
}

async function request(payload, apiKey) {
  let lastError;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      const response = await fetch(ENDPOINT, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiKey}`,
          "Content-Type": "application/json"
        },
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(10000)
      });

      const body = await response.text();
      if (response.ok) return JSON.parse(body);

      lastError = new Error(`TypeSafe HTTP ${response.status}: ${body.slice(0, 500)}`);
      if (!RETRYABLE.has(response.status) || attempt === 2) throw lastError;
    } catch (error) {
      lastError = error;
      if (attempt === 2) throw error;
    }

    await new Promise(resolve => setTimeout(resolve, 250 * (2 ** attempt)));
  }
  throw lastError;
}

const raw = await readStdin();
if (!raw) fail("Provide compact routing state as JSON on stdin.");

let parsed;
try {
  parsed = JSON.parse(raw);
} catch {
  fail("stdin must be valid JSON.");
}

const state = Object.hasOwn(parsed, "state") ? parsed.state : parsed;
const serialized = JSON.stringify(state);
if (serialized.length > MAX_STATE_CHARS) {
  fail(`Routing state is too large (${serialized.length} chars; max ${MAX_STATE_CHARS}). Summarize it instead of sending source/logs.`);
}

const payload = buildPayload(state);

if (process.argv.includes("--dry-run")) {
  process.stdout.write(JSON.stringify({
    status: "dry_run",
    endpoint: ENDPOINT,
    model: MODEL,
    state_chars: serialized.length,
    question_ids: Object.keys(payload.questions)
  }, null, 2) + "\n");
  process.exit(0);
}

const credential = resolveApiKey();
if (!credential) {
  process.stdout.write(JSON.stringify({
    status: "unavailable",
    reason: "No TypeSafe credential found in TYPESAFE_API_KEY or macOS Keychain service typesafe-ai",
    fallback: "Use km-acceptance and repository rules directly; do not broaden scope because Jev is unavailable."
  }, null, 2) + "\n");
  process.exit(0);
}

try {
  const data = await request(payload, credential.value);
  const route = {
    reasoning_tier: choice(data.answers?.reasoning_tier, "reasoning_tier"),
    review_gate: choice(data.answers?.review_gate, "review_gate"),
    scope_pressure: choice(data.answers?.scope_pressure, "scope_pressure")
  };
  process.stdout.write(JSON.stringify({
    status: "ok",
    credential_source: credential.source,
    model: data.model ?? MODEL,
    route,
    usage: data.usage ?? null
  }, null, 2) + "\n");
} catch (error) {
  process.stdout.write(JSON.stringify({
    status: "error",
    reason: error instanceof Error ? error.message : String(error),
    fallback: "Use km-acceptance and repository rules directly; do not treat Jev failure as permission to reduce required evidence."
  }, null, 2) + "\n");
  process.exitCode = 1;
}
