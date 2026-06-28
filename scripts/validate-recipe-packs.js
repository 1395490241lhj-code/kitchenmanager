#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const ROOT_DIR = path.resolve(__dirname, '..');
const TARGETS = [
  {
    label: 'recipe pack samples',
    file: path.join(ROOT_DIR, 'docs', 'recipe-packs', 'recipe-pack-samples.json')
  },
  {
    label: 'formal recipe pack data',
    file: path.join(ROOT_DIR, 'data', 'recipe-packs.json')
  }
];

const REQUIRED_FIELDS = [
  'id',
  'name',
  'packs',
  'cuisine',
  'tags',
  'coreIngredients',
  'stapleIngredients',
  'optionalIngredients',
  'flavorIngredients',
  'seasonings',
  'equipment',
  'timeMinutes',
  'difficulty',
  'servings',
  'leftoverFriendly',
  'lunchboxFriendly',
  'spicyLevel',
  'oilLevel',
  'proteinLevel',
  'sourceType',
  'sourceNotes',
  'reviewStatus',
  'cookingNotes'
];

const ARRAY_FIELDS = [
  'packs',
  'cuisine',
  'tags',
  'coreIngredients',
  'stapleIngredients',
  'optionalIngredients',
  'flavorIngredients',
  'seasonings',
  'equipment'
];

const INGREDIENT_FIELDS = [
  'coreIngredients',
  'stapleIngredients',
  'optionalIngredients',
  'flavorIngredients',
  'seasonings'
];

const ENUMS = {
  packs: ['basic-home', 'quick-solo', 'light-healthy', 'spicy-sichuan-hunan', 'high-protein'],
  difficulty: ['easy', 'medium', 'hard'],
  spicyLevel: ['none', 'mild', 'medium', 'hot'],
  oilLevel: ['low', 'medium', 'high'],
  proteinLevel: ['low', 'medium', 'high'],
  reviewStatus: ['draft', 'review-needed', 'approved'],
  sourceType: [
    'original',
    'adapted',
    'common-dish',
    'ai-draft',
    'original-adapted',
    'public-health-inspired',
    'supermarket-inspired'
  ]
};

const NOODLE_STAPLES = ['面条', '乌冬面', '乌冬', '意面', '米粉', '河粉'];
const RICE_STAPLES = ['米饭', '糙米饭'];
const RICE_DISH_NAME_RE = /饭|盖饭|炒饭|下饭|肉丝|豆腐|茄子|鸡丁|牛肉|滑鸡|回锅肉|土豆丝|炒蛋|辣子鸡/;
const SOUP_NAME_RE = /汤|汤面/;
const MEAT_OR_SEAFOOD_RE = /肉|牛|猪|鸡|鱼|虾|三文鱼|金枪鱼|肥牛|五花肉|火腿/;
const EGG_RE = /鸡蛋|蛋/;

const errors = [];
const warnings = [];

function relative(file) {
  return path.relative(ROOT_DIR, file);
}

function pushError(message) {
  errors.push(message);
}

function pushWarning(message) {
  warnings.push(message);
}

function label(recipe) {
  if (!recipe || typeof recipe !== 'object') return '<invalid recipe>';
  return `${recipe.id || '<missing id>'} (${recipe.name || '<missing name>'})`;
}

function hasAny(values, candidates) {
  return values.some((value) => candidates.includes(value));
}

function hasTag(recipe, tag) {
  return Array.isArray(recipe.tags) && recipe.tags.includes(tag);
}

function hasPack(recipe, pack) {
  return Array.isArray(recipe.packs) && recipe.packs.includes(pack);
}

function parseJson(file) {
  if (!fs.existsSync(file)) {
    pushError(`${relative(file)}: file not found.`);
    return null;
  }

  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    pushError(`${relative(file)}: could not parse JSON: ${error.message}`);
    return null;
  }
}

function validateTopLevel(data, target) {
  const scope = relative(target.file);

  if (!data || typeof data !== 'object' || Array.isArray(data)) {
    pushError(`${scope}: top-level value must be an object.`);
    return [];
  }

  if (!Object.prototype.hasOwnProperty.call(data, 'version')) {
    pushError(`${scope}: top-level field "version" is required.`);
  }
  if (!Object.prototype.hasOwnProperty.call(data, 'status')) {
    pushError(`${scope}: top-level field "status" is required.`);
  }
  if (Object.prototype.hasOwnProperty.call(data, 'packs') && !Array.isArray(data.packs)) {
    pushError(`${scope}: top-level field "packs" must be an array when present.`);
  }
  if (!Array.isArray(data.recipes)) {
    pushError(`${scope}: top-level field "recipes" must be an array.`);
    return [];
  }

  return data.recipes;
}

function validatePackDefinitions(data, target) {
  const scope = relative(target.file);
  const packIds = new Set();

  if (!Array.isArray(data && data.packs)) {
    return null;
  }

  data.packs.forEach((pack, index) => {
    const prefix = `${scope} packs[${index}]`;

    if (!pack || typeof pack !== 'object' || Array.isArray(pack)) {
      pushError(`${prefix}: pack must be an object.`);
      return;
    }

    if (typeof pack.id !== 'string' || !pack.id.trim()) {
      pushError(`${prefix}: pack id is required.`);
    } else {
      if (packIds.has(pack.id)) {
        pushError(`${prefix}: duplicate pack id "${pack.id}".`);
      }
      packIds.add(pack.id);
      if (!ENUMS.packs.includes(pack.id)) {
        pushError(`${prefix}: unknown pack id "${pack.id}".`);
      }
    }

    if (typeof pack.name !== 'string' || !pack.name.trim()) {
      pushError(`${prefix}: pack name is required.`);
    }

    if (typeof pack.defaultEnabled !== 'boolean') {
      pushError(`${prefix}: defaultEnabled must be boolean.`);
    }
  });

  return packIds;
}

function validateRecipe(recipe, index, target, seenIds, seenNames, knownPackIds) {
  const scope = relative(target.file);
  const prefix = `${scope} recipes[${index}] ${label(recipe)}`;

  if (!recipe || typeof recipe !== 'object' || Array.isArray(recipe)) {
    pushError(`${scope} recipes[${index}]: recipe must be an object.`);
    return;
  }

  for (const field of REQUIRED_FIELDS) {
    if (!Object.prototype.hasOwnProperty.call(recipe, field)) {
      pushError(`${prefix}: missing required field "${field}".`);
    }
  }

  for (const field of ARRAY_FIELDS) {
    if (!Array.isArray(recipe[field])) {
      pushError(`${prefix}: "${field}" must be an array.`);
    }
  }

  if (typeof recipe.id === 'string') {
    if (seenIds.has(recipe.id)) {
      pushError(`${prefix}: duplicate id "${recipe.id}".`);
    }
    seenIds.add(recipe.id);
  } else {
    pushError(`${prefix}: "id" must be a string.`);
  }

  if (typeof recipe.name === 'string') {
    if (seenNames.has(recipe.name)) {
      pushError(`${prefix}: duplicate name "${recipe.name}".`);
    }
    seenNames.add(recipe.name);
  } else {
    pushError(`${prefix}: "name" must be a string.`);
  }

  if (Array.isArray(recipe.packs)) {
    for (const pack of recipe.packs) {
      if (!ENUMS.packs.includes(pack)) {
        pushError(`${prefix}: invalid pack "${pack}".`);
      }
      if (knownPackIds && !knownPackIds.has(pack)) {
        pushError(`${prefix}: recipe references pack "${pack}" that is not defined in top-level packs.`);
      }
    }
  }

  for (const field of ['difficulty', 'spicyLevel', 'oilLevel', 'proteinLevel', 'reviewStatus', 'sourceType']) {
    if (!ENUMS[field].includes(recipe[field])) {
      pushError(`${prefix}: invalid ${field} "${recipe[field]}".`);
    }
  }

  const seenIngredients = new Map();
  for (const field of INGREDIENT_FIELDS) {
    if (!Array.isArray(recipe[field])) continue;
    for (const ingredient of recipe[field]) {
      if (seenIngredients.has(ingredient)) {
        pushError(
          `${prefix}: ingredient "${ingredient}" appears in both ${seenIngredients.get(ingredient)} and ${field}.`
        );
      } else {
        seenIngredients.set(ingredient, field);
      }
    }
  }

  validateTagWarnings(recipe, prefix);
  validatePackWarnings(recipe, prefix);
}

function validateTagWarnings(recipe, prefix) {
  if (hasTag(recipe, 'noodle') && !hasAny(recipe.stapleIngredients || [], NOODLE_STAPLES)) {
    pushWarning(`${prefix}: tag "noodle" but stapleIngredients does not include a noodle staple.`);
  }

  if (
    hasTag(recipe, 'rice') &&
    !hasAny(recipe.stapleIngredients || [], RICE_STAPLES) &&
    !RICE_DISH_NAME_RE.test(recipe.name || '')
  ) {
    pushWarning(`${prefix}: tag "rice" but no rice staple and name is not clearly a rice dish.`);
  }

  if (hasTag(recipe, 'soup') && !SOUP_NAME_RE.test(recipe.name || '') && !hasTag(recipe, 'noodle')) {
    pushWarning(`${prefix}: tag "soup" but name/tags do not clearly indicate soup or soup noodles.`);
  }

  if (hasTag(recipe, 'high-protein') && recipe.proteinLevel !== 'high') {
    pushWarning(`${prefix}: tag "high-protein" but proteinLevel is "${recipe.proteinLevel}".`);
  }

  if (hasTag(recipe, 'meal-prep') && recipe.leftoverFriendly !== true && recipe.lunchboxFriendly !== true) {
    pushWarning(`${prefix}: tag "meal-prep" but neither leftoverFriendly nor lunchboxFriendly is true.`);
  }

  if (hasTag(recipe, 'vegetarian-friendly')) {
    const coreIngredients = recipe.coreIngredients || [];
    const meatIngredients = coreIngredients.filter((ingredient) => MEAT_OR_SEAFOOD_RE.test(ingredient));
    if (meatIngredients.length) {
      pushWarning(
        `${prefix}: tag "vegetarian-friendly" but coreIngredients includes meat/fish/seafood: ${meatIngredients.join(', ')}.`
      );
    }

    const eggIngredients = coreIngredients.filter((ingredient) => EGG_RE.test(ingredient));
    if (eggIngredients.length) {
      pushWarning(
        `${prefix}: tag "vegetarian-friendly" includes egg ingredient(s): ${eggIngredients.join(', ')}; confirm user diet setting.`
      );
    }
  }
}

function validatePackWarnings(recipe, prefix) {
  if (hasPack(recipe, 'quick-solo') && (recipe.servings > 2 || recipe.timeMinutes > 30)) {
    pushWarning(
      `${prefix}: pack "quick-solo" but servings=${recipe.servings} and timeMinutes=${recipe.timeMinutes}.`
    );
  }

  if (hasPack(recipe, 'light-healthy') && recipe.oilLevel === 'high') {
    pushWarning(`${prefix}: pack "light-healthy" but oilLevel is high.`);
  }

  if (hasPack(recipe, 'high-protein') && recipe.proteinLevel !== 'high') {
    pushWarning(`${prefix}: pack "high-protein" but proteinLevel is "${recipe.proteinLevel}".`);
  }

  if (
    hasPack(recipe, 'spicy-sichuan-hunan') &&
    recipe.spicyLevel === 'none' &&
    !hasTag(recipe, 'spicy')
  ) {
    pushWarning(`${prefix}: pack "spicy-sichuan-hunan" but spicyLevel is none and no spicy tag.`);
  }
}

function validateTarget(target) {
  const data = parseJson(target.file);
  const recipes = validateTopLevel(data, target);
  const knownPackIds = validatePackDefinitions(data, target);
  const seenIds = new Set();
  const seenNames = new Set();

  recipes.forEach((recipe, index) => validateRecipe(recipe, index, target, seenIds, seenNames, knownPackIds));

  console.log(`${target.label}: recipes=${recipes.length}`);
}

function main() {
  TARGETS.forEach(validateTarget);

  for (const error of errors) {
    console.error(`ERROR: ${error}`);
  }
  for (const warning of warnings) {
    console.warn(`WARNING: ${warning}`);
  }

  console.log(`errors: ${errors.length}`);
  console.log(`warnings: ${warnings.length}`);

  if (errors.length > 0) {
    console.error('Recipe pack data validation failed');
    process.exit(1);
  }

  console.log('Recipe pack data validation passed');
}

main();
