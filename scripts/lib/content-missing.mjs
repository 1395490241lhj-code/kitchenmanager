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
