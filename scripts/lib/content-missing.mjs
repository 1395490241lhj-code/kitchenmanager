export const allowedContentMissingUncertaintyTypes = new Set([
  'scan-page-blank',
  'source-content-missing',
]);

// A recipe may only claim contentMissing=true (skipping the normal
// non-empty ingredients/2-6 step method requirement) when it carries a
// page-boundary uncertainty whose reasonCode proves the source page itself
// has no visible body content. This keeps the exception narrow: it cannot
// be used to paper over genuinely incomplete extraction work.
export const isVerifiedContentMissing = (recipe) => (
  recipe?.contentMissing === true
  && Array.isArray(recipe.uncertainties)
  && recipe.uncertainties.some((u) => u.type === 'page-boundary'
    && allowedContentMissingUncertaintyTypes.has(u.reasonCode))
);

// A recipe may claim contentIncomplete=true (relaxing the normal 2-6 step /
// non-empty ingredients / string characteristicsSummary requirements) only
// when it is NOT also a fully-missing page (contentMissing must be falsy)
// and it carries a page-boundary uncertainty proving the source scan itself
// ends or begins mid-recipe. This keeps the exception narrow: it documents
// genuinely truncated printed content instead of papering over incomplete
// extraction work, and it always forces reviewRequired=true downstream.
export const isVerifiedContentIncomplete = (recipe) => (
  recipe?.contentIncomplete === true
  && recipe?.contentMissing !== true
  && Array.isArray(recipe.uncertainties)
  && recipe.uncertainties.some((u) => u.type === 'page-boundary'
    && u.reasonCode === 'source-content-missing')
);
