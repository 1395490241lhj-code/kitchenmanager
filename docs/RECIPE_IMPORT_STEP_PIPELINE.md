# Recipe Import — Step (`method`) Pipeline

How a Xiaohongshu/video link becomes the ordered `method` array the iOS app
and the PWA render. Scoped to **step generation**; name/ingredient/quantity
extraction is described where it lives (`RECIPE_EVIDENCE_SYSTEM_PROMPT` and
`evidence-item-preservation.js`) and is deliberately untouched by this
document's subject.

## Data flow

```text
URL (Share Extension / clipboard / manual paste)
  │
  ▼
POST /api/recipe-import-from-url                         (server.js)
  │
  ├─ extractRecipeSourcePayloadFromUrl                   (page-source.js)
  │     HTML → title / og: / JSON-LD / __INITIAL_STATE__ → pageText,
  │     media.videoUrls
  │
  ├─ decidePageTextPreference
  │     page text already complete enough? → skip video work entirely
  │
  ├─ extractVideoRecipeTextForImport                     (media-pipeline.js)
  │     pickBestVideoUrl → download → ffmpeg
  │       ├─ audio  → ASR  → transcriptText
  │       └─ frames → OCR  → ocrText
  │
  ├─ labeled section merge  (limitSourceSectionText / appendSourceSection)
  │     「页面文字」+「视频口播转录」+「视频画面文字」+「用户补充」
  │     → one sourceText blob
  │
  ▼
parseRecipeDraftWithAi                                   (server.js)
  │
  ├─ splitRecipeSourceText → cleanedRecipeText / excludedSocialText
  │     (page-source.js — drops comments/hashtags/social segments before
  │      the model ever sees them)
  │
  ├─ AI call #1: RECIPE_EVIDENCE_SYSTEM_PROMPT
  │     → evidence JSON (observedActions[], observedMainIngredients[], ...)
  │     This is the layer that separates ingredients from steps.
  │
  ├─ AI call #2: IMPORT_SIMPLE_SYSTEM_PROMPT   (sourceType === 'xiaohongshu')
  │              IMPORT_SYSTEM_PROMPT          (everything else)
  │     → recipe JSON incl. method: string[]
  │
  ├─ safeParseModelJson → repairRecipeJsonContent (JSON repair retry)
  │
  ├─ sanitizeRecipe                                      (server.js)
  │     stripStepPrefix → stripUnsupportedGenericMethodSteps
  │     → cleanRecipeSteps ◄── deterministic step post-processing
  │     → checkRecipeStepCoverage (warnings only, never edits steps)
  │
  └─ preserveEvidenceItemsInRecipe → diagnostics → response
        │
        ▼
   iOS: ImportedRecipe.method ([String]) → EditableRecipeDraft.stepsText
   PWA: normalizeRecipeMethodText(draft.method)
```

**Fallback path.** If AI call #2 is rate-limited or returns unparseable
JSON, `buildFallbackRecipeFromTranscript` →
`buildGroundedFallbackRecipe` (`grounded-recipe-fallback.js`) extracts
grounded action sentences from the transcript/OCR/page text directly. That
output goes through **the same** `cleanRecipeSteps`, so fallback steps are
no longer noticeably messier than the AI path.

One grounding rule was widened there: `classifyFallbackSentence` used to
require an ingredient-like object, which silently discarded clauses such as
「腌制10分钟」or「小火煎3分钟」— exactly the time/heat information that must
not be lost. A clause with a cooking action **and** an explicit
time/temperature/heat level now counts as grounded.

## Deterministic post-processing

`src/server/services/recipe-step-cleanup.js` — pure, dependency-free, and
unit tested in `test/recipe-step-cleanup.test.mjs`. It is **subtractive and
rearranging only**: every output character comes from the input, so it can
never invent an action, time, temperature, or seasoning.

Stages, in order:

1. **Normalize** — strip numbering prefixes (`1.` / `第一步：` / `步骤2：` /
   `一、` / `(1)`, applied repeatedly for OCR's stacked prefixes), subtitle
   timecodes (`00:12`), zero-width characters, quotes, filler discourse
   markers, trailing particles, and spoken subjects (`我们`, `大家`).
   `先` / `再` / `把` are explicitly preserved — they carry real ordering
   and disposal meaning in a recipe.
2. **Clause-level denoise** — split on `，。；` and drop clauses that match
   social/ad/chatter/reminder patterns **and contain no cooking verb**. A
   clause with a real cooking action is never dropped, so
   「肉丝放进去炒一下，大家记得点赞收藏」keeps the operation and loses the
   plug.
3. **Split** — a step is split when it is long enough *and* contains ≥2
   distinct main actions, at sentence boundaries first, then at stage
   markers (`然后` / `接着` / `之后` / `最后`). Tightly-coupled sequences
   like「炒至变色后盛出」are left intact.
4. **Filter** — drop whole-line ingredient lists (`食材：…`, or ≥3 short
   nouns with no verb), vague filler steps (`准备食材` / `开始烹饪`), and
   sub-2-character fragments.
5. **Near-dedup (OCR × ASR)** — four signals: exact key equality,
   substring containment, **character-subset containment** (catches
   「猪肉切成肉丝」vs「猪肉切丝」, which bigram similarity misses), and
   bigram Jaccard ≥ 0.72. When two are duplicates the survivor is chosen by
   *detail token count first* (digits, 分钟, 度, 大火/小火, 变色, 浓稠…),
   length second — so「小火煎3分钟」always beats「煎一下」. A second pass
   drops very short, detail-free fragments whose verbs are already covered
   by a fuller step (「腌一下」next to「…抓匀，腌制10分钟」). A third pass
   handles **cross-step** duplicates, where OCR compresses into one line
   what ASR said across two (「倒油烧热下入肉丝」vs「锅中倒油烧热」+
   「下入肉丝炒至变色盛出」): a candidate is dropped when ≥85% of its
   bigrams are already covered by earlier kept steps *and* it introduces no
   new detail token. The threshold is 0.85 rather than 0.9 because the
   bigram straddling the seam between two kept steps is necessarily absent.
6. **Merge** — adjacent steps both ≤11 chars in the same stage are joined
   with `，` (「青椒去籽切丝」+「蒜切末备用」).
7. **Conservative reorder** — only two unambiguous moves: pure prep steps
   (cutting/washing, with no 锅/火/油 anywhere) that appear after the first
   cooking step are moved before it, preserving relative order; and
   finish-only steps (出锅/装盘 with no other cooking action) move to the
   end. Everything else keeps source order — no "common sense" resequencing.
8. **Safety net** — if cleanup would empty the list, it returns the merely
   normalized input instead, sets `stepCleanupFellBack`, and adds a warning.
   An empty `method` is never produced by cleanup.

Caps: 12 steps, 90 characters per step.

### Diagnostics

Surfaced on the import response's `diagnostics` (and on the fallback
recipe's own `diagnostics`) for debugging without changing the saved
recipe shape:

`stepCleanupInputCount`, `stepCleanupOutputCount`,
`stepCleanupNoiseRemovedCount`, `stepCleanupIngredientListRemovedCount`,
`stepCleanupVagueRemovedCount`, `stepCleanupSplitCount`,
`stepCleanupMergedCount`, `stepCleanupDuplicateRemovedCount`,
`stepCleanupReorderedCount`, `stepCleanupFellBack`.

## Debugging a real link (stage snapshot)

Because the messy-input cases are hard to reproduce from fixtures, the
import routes can return a per-stage snapshot of what they actually saw.

**Gating — both conditions required:**

1. `process.env.NODE_ENV !== 'production'` (never returned in production);
2. the request body carries `debugStages: true` (opt-in; nothing extra is
   emitted by default, even in development).

```bash
curl -s localhost:3000/api/recipe-import-from-url \
  -H 'content-type: application/json' \
  -d '{"url":"<link>","debugStages":true}' | jq .debugStages
```

Returned under `debugStages`:

| Field | Stage |
|---|---|
| `pageText` | extracted page text |
| `asrText` | raw ASR transcript |
| `ocrText` | raw OCR text |
| `mergedSourceText` | the labeled blob sent to the evidence prompt |
| `aiRawMethod` | the model's `method` **before** any cleanup |
| `cleanedMethod` | `method` after `cleanRecipeSteps` |
| `stepCleanupDiagnostics` | the counters listed above |

Each text stage is `{ length, truncated, text }` — `length` is the true
length, `text` is capped at `IMPORT_DEBUG_STAGE_LIMIT` (2000 chars);
`aiRawMethod`/`cleanedMethod` are capped at 40 steps × 300 chars. This
bounds how much user content is echoed back.

`aiRawMethod` is snapshotted *before* `sanitizeRecipe`, which mutates
`recipe.method` in place — there is a test asserting that ordering.

**Retention and secrets.** The snapshot is response-only: it is not logged,
not persisted, and not written to the media cache, and it is dropped when
the response is sent. It references only source text already in memory for
this request. It never touches `OPENAI_API_KEY`, Supabase credentials,
`Authorization` headers, or `req.headers`; the only `process.env` read in
the whole helper block is `NODE_ENV`. `test/import-stage-debug.test.mjs`
enforces each of these.

The fallback branch returns the same shape with `aiRawMethod: null` — the
absence of AI output is precisely why the fallback ran.

`aiRawMethod` and `stepCleanupDiagnostics` are internal to
`parseRecipeDraftWithAi` and are destructured out of both routes' normal
responses, so the non-debug response shape is unchanged.

## Prompt constraints

Xiaohongshu imports use `IMPORT_SIMPLE_SYSTEM_PROMPT`. That prompt
historically carried the project's *weakest* step guidance while handling
its *messiest* input (raw ASR + OCR), which is a large part of why steps
came out disorganized. It now carries an explicit 「method 步骤质量约束」
block: real cooking order, one stage per step, split unrelated actions,
merge fragments, no numbering prefixes, no verbatim narration, no
ads/greetings/catchphrases/backstory, no re-listing the ingredient table,
no duplicated OCR/ASR descriptions, keep time/temperature/heat/ratios and
状态判断, invent nothing, no vague filler steps, and no fixed step count.

`IMPORT_SYSTEM_PROMPT` (all non-Xiaohongshu sources) is unchanged.

## Deliberate non-changes

- **`method` stays `string[]`.** Per-step structured objects were
  considered and rejected: the field is a stable contract across
  `sanitizeRecipe`, `evidence-item-preservation`, the PWA's
  `normalizeRecipeMethodText`, iOS `ImportedRecipe.method`,
  `EditableRecipeDraft.stepsText`, and saved SwiftData recipes. The
  ordering/dedup/splitting benefits are obtained deterministically in
  post-processing instead, with no DTO or persistence migration.
- Name, ingredient, seasoning, and quantity extraction are untouched —
  `cleanRecipeSteps` only ever receives `recipe.method`.
- `checkRecipeStepCoverage` still runs *after* cleanup, so if cleanup ever
  removed a step mentioning a key flavor ingredient, the existing coverage
  warning still fires.
