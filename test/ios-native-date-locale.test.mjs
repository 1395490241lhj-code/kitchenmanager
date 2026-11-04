import test from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

// The iOS bundle is localized only in English, so a DatePicker that is not
// pinned follows Locale.current and shows "Nov 7, 2026" in a Chinese form.
// Every picker carries .kitchenDateLocale() (KitchenControls.swift).
const root = fileURLToPath(new URL("../ios-native/Kitchen Manager/KitchenManager/", import.meta.url));

function swiftFiles(dir) {
  return readdirSync(dir).flatMap(name => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return swiftFiles(path);
    return name.endsWith(".swift") ? [path] : [];
  });
}

test("every DatePicker is pinned to the product's zh_Hans_CN date locale", () => {
  let pickers = 0;
  for (const file of swiftFiles(root)) {
    const source = readFileSync(file, "utf8");
    const declared = (source.match(/\bDatePicker\(/g) ?? []).length;
    const pinned = (source.match(/\.kitchenDateLocale\(\)/g) ?? []).length;
    pickers += declared;
    assert.equal(pinned, declared, `${file.slice(root.length)}: ${declared} DatePicker, ${pinned} pinned`);
  }
  assert.ok(pickers >= 7, `expected the app's date pickers to be found, found ${pickers}`);
});

// Foundation formatting ignores the SwiftUI environment, so date text must
// name its locale too: KitchenDateStyle, or an explicit .locale(...).
test("date text is formatted with the pinned locale, not Locale.current", () => {
  const unpinned = [];
  for (const file of swiftFiles(root)) {
    readFileSync(file, "utf8").split("\n").forEach((line, index) => {
      if (line.trim().startsWith("//")) return;
      const formatsDate = /\.formatted\(date:|\.formatted\(\.dateTime|Date\.FormatStyle\(/.test(line);
      if (formatsDate && !/locale/i.test(line)) unpinned.push(`${file.slice(root.length)}:${index + 1}`);
    });
  }
  assert.deepEqual(unpinned, []);
});

test("the pin is per picker, not an app-wide locale that would change number parsing", () => {
  const app = readFileSync(join(root, "ContentView.swift"), "utf8");
  const scene = app.slice(app.indexOf("var body: some Scene"));
  assert.doesNotMatch(scene.slice(0, scene.indexOf("\n    }\n")), /\.environment\(\\\.locale/);
});
