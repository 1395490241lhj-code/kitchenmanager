/*
 * src/server/services/ai-conversation-turn-limit.js
 *
 * One logical Kitchen AI conversation turn = one unit of the shared AI quota.
 *
 * Why: a single user-visible turn can run up to AI_CONVERSATION_MAX_STEPS_PER_TURN
 * provider steps (the iOS read-tool loop re-POSTs /api/ai-conversation with the
 * tool results after every read). Charging every step against the shared
 * 30/10min bucket meant "30 requests" silently became "5 questions".
 *
 * Design: a server-written ledger keyed by (connection IP, client turn ID).
 *
 *   - The client turn ID is only a lookup key and confers nothing by itself.
 *     A step is free only when THIS server previously recorded a paid,
 *     admitted step for the same (IP, turnID). An unknown, forged, malformed
 *     or expired turn ID therefore falls through to the normal limiter.
 *   - The grant is written only after checkAiRateLimit admitted the paying
 *     step. A 429'd first step records nothing, so an over-quota client cannot
 *     mint grants.
 *   - Only continuation-shaped requests (last message role === 'tool', which is
 *     what the read-tool loop sends) are eligible. A fresh question reusing an
 *     old turn ID is charged.
 *   - Every eligible step increments a separate step counter. At most
 *     (AI_CONVERSATION_MAX_STEPS_PER_TURN - 1) continuations per turn are free;
 *     later continuations are charged again.
 *   - Grant and step counters live AI_CONVERSATION_TURN_TTL_MS in the same
 *     store the AI limiter uses (shared across instances when configured),
 *     with a fixed, non-sliding expiry.
 *   - Any ledger store failure charges the step normally (fail closed).
 *   - Checking for a grant is a genuine read (store.peek): an unknown, forged,
 *     malformed, expired or never-admitted turn ID creates no ledger state.
 *     Only a paid, admitted step writes a grant; the step counter is written
 *     only after a grant was found.
 *
 * Trust boundary: the transcript, including the trailing role 'tool' message,
 * is client-supplied. The server does not verify that the tool result answers a
 * tool call it emitted for this turn. What is enforced is the budget: one paid
 * unit buys at most MAX_STEPS provider steps for that (IP, turnID).
 *
 * Worst case for any client: one paid unit buys at most MAX_STEPS provider
 * steps, which is exactly the bound a legitimate turn already has.
 */
const {
  AI_CONVERSATION_MAX_STEPS_PER_TURN,
  AI_CONVERSATION_TURN_TTL_MS
} = require('../config');
const { checkAiRateLimit, getClientIp, getSharedAiRateLimitStore } = require('./rate-limit');

const TURN_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MEMORY_LEDGER_SWEEP_INTERVAL_MS = 60 * 1000;

// In-process ledger used when no shared store is configured. Entries expire on
// a fixed window and are swept lazily so unknown turn IDs cannot accumulate.
function createMemoryTurnLedger() {
  const entries = new Map();
  let lastSweepAt = 0;
  function sweep(now) {
    if (now - lastSweepAt < MEMORY_LEDGER_SWEEP_INTERVAL_MS) return;
    lastSweepAt = now;
    for (const [key, entry] of entries) {
      if (now >= entry.expiresAt) entries.delete(key);
    }
  }
  return {
    async consumeBy(key, windowMs, amount, now) {
      sweep(now);
      let entry = entries.get(key);
      if (!entry || now >= entry.expiresAt) {
        entry = { count: 0, expiresAt: now + windowMs };
        entries.set(key, entry);
      }
      entry.count += amount;
      return { count: entry.count };
    },
    // Map.get only: never inserts, and an expired entry is removed, not renewed.
    async peek(key, now) {
      const entry = entries.get(key);
      if (!entry) return 0;
      if (now >= entry.expiresAt) {
        entries.delete(key);
        return 0;
      }
      return entry.count;
    },
    _clear() { entries.clear(); lastSweepAt = 0; },
    _size() { return entries.size; }
  };
}

const memoryTurnLedger = createMemoryTurnLedger();

function turnLedger() {
  // A configured shared store is always the ledger, so grants never split
  // across instances. If it cannot peek/consumeBy, the call throws and the
  // caller charges the step (fail closed).
  return getSharedAiRateLimitStore() || memoryTurnLedger;
}

function normalizeTurnId(raw) {
  if (typeof raw !== 'string') return null;
  const value = raw.trim();
  return TURN_ID_PATTERN.test(value) ? value.toLowerCase() : null;
}

// Decided on the raw body because the limiter intentionally runs before body
// normalization; a free step still has to pass normalization afterwards.
function isContinuationShaped(body) {
  const messages = body && Array.isArray(body.messages) ? body.messages : null;
  if (!messages || !messages.length) return false;
  const last = messages[messages.length - 1];
  return Boolean(last && typeof last === 'object' && last.role === 'tool');
}

function ledgerKeys(req, turnId) {
  const base = `ai-turn:${getClientIp(req)}:${turnId}`;
  return { grant: `${base}:grant`, steps: `${base}:steps` };
}

async function tryFreeContinuation(req, turnId, now) {
  const store = turnLedger();
  const keys = ledgerKeys(req, turnId);
  const granted = await store.peek(keys.grant, now);
  if (!(granted >= 1)) return false;
  const steps = await store.consumeBy(keys.steps, AI_CONVERSATION_TURN_TTL_MS, 1, now);
  return steps.count <= AI_CONVERSATION_MAX_STEPS_PER_TURN - 1;
}

async function recordPaidTurn(req, turnId, now) {
  const keys = ledgerKeys(req, turnId);
  await turnLedger().consumeBy(keys.grant, AI_CONVERSATION_TURN_TTL_MS, 1, now);
}

/**
 * Rate-limit decision for one POST /api/ai-conversation provider step.
 * Returns checkAiRateLimit's shape plus `accounting`:
 *   'continuation' - free step of an already-paid turn;
 *   'charged'      - consumed one shared AI quota unit (or was limited).
 */
async function checkConversationStepRateLimit(req, now = Date.now()) {
  const body = req.body && typeof req.body === 'object' ? req.body : {};
  const turnId = normalizeTurnId(body.turnID);
  const continuation = isContinuationShaped(body);

  if (turnId && continuation) {
    try {
      if (await tryFreeContinuation(req, turnId, now)) {
        return { limited: false, retryAfterSeconds: 0, backend: 'turn_ledger', accounting: 'continuation' };
      }
    } catch (_) {
      // Ledger unavailable: never a reason to skip the limiter.
    }
  }

  const result = await checkAiRateLimit(req, now);
  // Only a genuine first step (not continuation-shaped) opens a turn. A charged
  // continuation (unknown/expired turn or step bound exceeded) leaves no state.
  if (!result.limited && turnId && !continuation) {
    try {
      await recordPaidTurn(req, turnId, now);
    } catch (_) {
      // Without a recorded grant, later steps of this turn are simply charged.
    }
  }
  return { ...result, accounting: 'charged' };
}

module.exports = {
  checkConversationStepRateLimit,
  isContinuationShaped,
  normalizeTurnId,
  memoryTurnLedger
};
