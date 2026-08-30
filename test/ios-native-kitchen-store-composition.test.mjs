import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

// Composition regression guard for the prepared-component persistence bug.
//
// `KitchenStore.init` takes every persistence as an optional and substitutes an
// isolated in-memory container for whatever is nil — a convenience for previews
// and tests, and a silent data-loss trap for the app. `KitchenManagerApp.init`
// hand-listed five of the six and left `preparedComponentPersistence` out, so
// prepared batches were written to a container that dies with the process.
//
// A Swift test cannot instantiate `@main struct KitchenManagerApp`, so the
// production composition root is guarded here, at the source level.

const root = new URL("../ios-native/Kitchen Manager/KitchenManager/", import.meta.url);
const read = name => readFileSync(new URL(name, root), "utf8");
const contentView = read("ContentView.swift");
const kitchenStore = read("KitchenStore.swift");
const factory = read("Persistence/KitchenPersistenceFactory.swift");

/** Slices between two anchors, failing loudly rather than silently widening. */
const between = (source, label, start, end) => {
  const from = source.indexOf(start);
  const to = source.indexOf(end);
  assert.ok(from !== -1, `${label}: anchor not found — ${start}`);
  assert.ok(to > from, `${label}: anchor not found after the first — ${end}`);
  return source.slice(from, to);
};

/** `KitchenManagerApp.init` — the production composition root only. */
const appInit = between(
  contentView,
  "KitchenManagerApp",
  "struct KitchenManagerApp: App {",
  "var body: some Scene"
);

test("the app composition root builds its KitchenStore from the whole persistence bundle", () => {
  assert.match(appInit, /KitchenPersistenceFactory\.application\(\)/);
  assert.match(appInit, /KitchenStore\(\s*persistence:/);
});

test("the app builds exactly one KitchenStore, and builds it that one way", () => {
  const constructions = appInit.match(/\bKitchenStore\(/g) ?? [];
  assert.equal(
    constructions.length, 1,
    "a second KitchenStore construction in the app would reintroduce the risk this guard exists for"
  );
});

test("the app composition root never hand-lists individual persistences", () => {
  for (const dependency of [
    "inventoryPersistence",
    "shoppingListPersistence",
    "todayPlanPersistence",
    "consumptionPersistence",
    "weeklyPlanPersistence",
    "preparedComponentPersistence",
  ]) {
    assert.doesNotMatch(
      appInit,
      new RegExp(`${dependency}\\s*:`),
      `KitchenManagerApp must not name ${dependency} itself — naming them one by one is how one got forgotten`
    );
  }
});

test("the bundle initializer forwards every persistence KitchenStore accepts", () => {
  const convenience = between(
    kitchenStore,
    "KitchenStore convenience init",
    "persistence: KitchenPersistenceBundle",
    "inventoryPersistence: InventoryPersistenceProtocol? = nil"
  );
  for (const [parameter, field] of [
    ["inventoryPersistence", "inventory"],
    ["shoppingListPersistence", "shoppingList"],
    ["todayPlanPersistence", "todayPlan"],
    ["consumptionPersistence", "consumption"],
    ["weeklyPlanPersistence", "weeklyPlan"],
    ["preparedComponentPersistence", "preparedComponents"],
  ]) {
    assert.match(convenience, new RegExp(`${parameter}: persistence\\.${field}\\b`));
  }
});

test("the durable application container carries the prepared-component model", () => {
  assert.match(factory, /static func makeContainer\(configuration: ModelConfiguration\)/);
  assert.match(factory, /PreparedComponentRecord\.self,\s*\n\s*configurations: configuration/);
  assert.match(factory, /static func application\(\) -> KitchenPersistenceBundle \{\s*\n\s*makeBundle\(isStoredInMemoryOnly: false\)/);
  assert.match(factory, /preparedComponents: SwiftDataPreparedComponentPersistence\(container: container\)/);
});
