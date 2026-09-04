// Strict response schema for a Special Plan menu request. Gemini only.
//
// Special Plan is the one menu request where the client rejects a whole
// generation on two contract terms the prose has proven unable to hold: the
// dish count, and the base yield every AI-written recipe must declare. This
// asks the provider to enforce them at the schema level instead.
//
// **This is deliberately a Gemini-primary capability, not a portable one.**
// Gemini was observed accepting the whole schema — `enum`, `anyOf`, and the
// `minItems`/`maxItems` bounds that carry the exact dish count — and returning
// exactly the requested count with every AI recipe declaring the contracted
// yield. `minItems`/`maxItems` are absent from the OpenAI structured-output
// subset that `strict: true` selects, so a Groq variant would have to drop the
// primary cardinality constraint; a schema that has silently lost the term it
// exists to enforce is not the same contract under a shared name. Groq is the
// fallback and keeps the pre-Phase-2 `{ type: 'json_object' }` path it has
// production history with, with the client validators as the trust boundary.
//
// Scope is narrow. Ordinary weekly menu requests keep their existing response
// format and tolerant decoding on both providers; nothing here is reachable
// without an event request that fixed a dish count.

const AI_RECIPE_BASE_SERVINGS = 4;

/// One recipe the model reuses from `existingRecipes`. It carries no
/// `baseServings`: the yield of a recipe the user already owns is whatever
/// that recipe records, and the client's `validateBaseYield` exempts it. A
/// schema that demanded 4 here would be asking the model to assert a
/// provenance the app knows to be false.
const EXISTING_RECIPE = {
  type: 'object',
  additionalProperties: false,
  properties: {
    source: { type: 'string', enum: ['existing'] },
    existingRecipeID: { type: 'string' },
    name: { type: 'string' },
    reason: { type: 'string' }
  },
  required: ['source', 'existingRecipeID', 'name', 'reason']
};

/// One recipe the model writes. `baseServings` is pinned by `enum` rather
/// than restated in prose, because this is the value whose absence rejects
/// the entire generation.
const AI_RECIPE = {
  type: 'object',
  additionalProperties: false,
  properties: {
    source: { type: 'string', enum: ['ai'] },
    name: { type: 'string' },
    // `minItems` here matters more than on `recipes`: the client drops any
    // dish with an empty ingredient or step list, so an empty-but-present
    // array satisfies the schema and then silently costs a dish. Forcing the
    // key to exist without forcing it to be non-empty would make that more
    // likely, not less.
    ingredients: { type: 'array', minItems: 1, items: { type: 'string' } },
    steps: { type: 'array', minItems: 1, items: { type: 'string' } },
    tags: { type: 'array', items: { type: 'string' } },
    cookingTime: { type: 'integer' },
    difficulty: { type: 'string' },
    reason: { type: 'string' },
    baseServings: { type: 'integer', enum: [AI_RECIPE_BASE_SERVINGS] }
  },
  // Strict mode requires every declared property to be listed. These are the
  // fields a Special Plan dish genuinely needs — the client drops any dish
  // missing a name, an ingredient or a step — plus the two the draft carries.
  required: [
    'source', 'name', 'ingredients', 'steps', 'tags',
    'cookingTime', 'difficulty', 'reason', 'baseServings'
  ]
};

/// The event reading travels in the same round trip. Every field is required
/// because strict mode demands it, but the values stay permissive: the raw
/// request remains the canonical intent and the client already treats every
/// event field as optional, defaulting a missing title or date itself. The
/// prompt tells the model to write null for a date it cannot read; typed as a
/// string it will emit `"null"` or `""` instead, both of which
/// `SpecialPlanInterpretation.date(from:)` already reads as no date. Nothing
/// here should make event extraction able to invalidate a valid menu.
const EVENT = {
  type: 'object',
  additionalProperties: false,
  properties: {
    title: { type: 'string' },
    scheduledAt: { type: 'string' },
    peopleCount: { type: 'integer' },
    constraintNotes: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string' }
  },
  required: ['title', 'scheduledAt', 'peopleCount', 'constraintNotes', 'notes']
};

/// The canonical schema, in the dialect the OpenAI structured-output subset
/// accepts. `dishCount` records the cardinality the request asked for; the
/// array bounds that would enforce it are added per-provider by `translate`.
function buildCanonicalSchema(dishCount) {
  return {
    type: 'object',
    additionalProperties: false,
    properties: {
      event: EVENT,
      days: {
        type: 'array',
        minItems: 1,
        maxItems: 1,
        items: {
          type: 'object',
          additionalProperties: false,
          properties: {
            dayIndex: { type: 'integer' },
            meals: {
              type: 'array',
              minItems: 1,
              maxItems: 1,
              items: {
                type: 'object',
                additionalProperties: false,
                properties: {
                  mealIndex: { type: 'integer' },
                  title: { type: 'string' },
                  recipes: {
                    type: 'array',
                    minItems: dishCount,
                    maxItems: dishCount,
                    items: { anyOf: [AI_RECIPE, EXISTING_RECIPE] }
                  }
                },
                required: ['mealIndex', 'title', 'recipes']
              }
            }
          },
          required: ['dayIndex', 'meals']
        }
      },
      // No `shoppingItems`. `WeeklyMenuPlannerStore.makePlan` is its only
      // consumer and Special Plan never reads it: shopping for a Special Plan
      // is derived deterministically by `ShoppingListGenerator` from the
      // accepted recipes' own ingredients. Requiring the model to invent
      // quantities nothing reads would spend output on nothing and put a
      // second, untrusted source of shopping numbers in the response. The
      // Special Plan prompt does not ask for it either, so schema and prompt
      // agree; the weekly prompt and its tolerant format are unchanged.
      warnings: { type: 'array', items: { type: 'string' } }
    },
    required: ['event', 'days', 'warnings']
  };
}

/// Gemini is the only provider this schema is sent to. See the header: the
/// Groq dialect could not express the cardinality bound, so it is not offered
/// a weakened variant under the same name.
function supportsStrictSchema(provider) {
  return provider === 'gemini';
}

/// Whether an error proves this provider cannot accept the schema *request*,
/// as opposed to failing for any of the reasons that have nothing to do with
/// the response format.
///
/// Positive evidence is required, never "a 400 we did not recognise". A bare
/// status check would quietly convert strict mode into legacy mode for a bad
/// argument, a revoked key routed as 400, or any future 400 the provider
/// invents — and the degraded call would then look like an ordinary success.
/// Everything else keeps its existing handling: 401/403/404 fail fast,
/// 429/5xx/timeouts stay transient and reach the cross-provider fallback,
/// `json_validate_failed` stays with that fallback too, and a decoded response
/// that violates a content contract never reaches here at all — it is the
/// client that rejects those, after this route returned 200.
const SCHEMA_REJECTION_PATTERN = /response[_ ]?format|json[_ ]?schema|structured[_ ]?output/i;

function isSchemaUnsupportedError(err) {
  const { getUpstreamAiErrorInfo, isJsonValidateFailedError } = require('./ai-client');
  const info = getUpstreamAiErrorInfo(err);
  if (Number(info.status) !== 400) return false;
  // The provider's own model-produced-invalid-JSON signal. It means the schema
  // was accepted and the generation failed, so it belongs to the existing
  // cross-provider fallback, not here.
  if (isJsonValidateFailedError(err)) return false;

  const upstream = (err && err.response && err.response.data && err.response.data.error)
    || (err && err.error)
    || {};
  // OpenAI-compatible providers name the offending field.
  if (String(upstream.param || '') === 'response_format') return true;
  return SCHEMA_REJECTION_PATTERN.test(`${info.code || ''} ${upstream.param || ''} ${info.detail || ''}`);
}

/// The `response_format` for one Special Plan request, or `null` when this
/// request must keep the ordinary JSON-object format.
///
/// `dishCount` must be the fixed target. A request that lets the model choose
/// its own count has no cardinality to enforce and returns `null` rather than
/// an exact-zero schema.
function getSpecialPlanResponseFormat({ provider, dishCount } = {}) {
  if (!Number.isInteger(dishCount) || dishCount < 1) return null;
  if (!supportsStrictSchema(provider)) return null;
  return {
    type: 'json_schema',
    json_schema: {
      name: 'special_plan_menu',
      strict: true,
      schema: buildCanonicalSchema(dishCount)
    }
  };
}

/// What this provider actually gets. Only Gemini receives the strict schema;
/// every other provider is reported as the legacy contract it really uses, so
/// a Groq success can never be logged as a strict-schema success.
function describe(provider) {
  return supportsStrictSchema(provider)
    ? { contract: 'gemini_strict', enforcesDishCount: true, enforcesBaseServings: true }
    : { contract: 'legacy_json_object', enforcesDishCount: false, enforcesBaseServings: false };
}

module.exports = {
  AI_RECIPE_BASE_SERVINGS,
  isSchemaUnsupportedError,
  buildCanonicalSchema,
  describe,
  getSpecialPlanResponseFormat
};
