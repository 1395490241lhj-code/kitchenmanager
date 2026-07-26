import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const root = new URL("../ios-native/Kitchen Manager/KitchenManager/", import.meta.url);
const read = name => readFileSync(new URL(name, root), "utf8");
const control = read("ClipboardPasteControl.swift");
const home = read("HomeView.swift");
const addRecipe = read("AddRecipeViews.swift");
const clipboardImport = read("ClipboardRecipeImport.swift");

// The shared control is used by more than one screen, so a single hardcoded
// `displayMode` is a cross-screen regression waiting to happen: that is exactly
// how the Home clipboard-banner work turned the recipe-import paste affordance
// into a bare icon. These assertions pin the *default* rather than the value at
// any one call site.
test("shared paste control defaults to a labeled presentation, never icon-only", () => {
  assert.match(control, /enum ClipboardPasteControlStyle/);
  assert.match(control, /case iconAndLabel/);
  assert.match(control, /case iconOnly/);

  // The default must be the labeled style, so no call site can silently lose its
  // visible text again by omitting the parameter.
  assert.match(control, /var style: ClipboardPasteControlStyle = \.iconAndLabel/);

  // displayMode is driven by the style, not hardcoded.
  assert.match(control, /configuration\.displayMode = style\.displayMode/);
  assert.doesNotMatch(control, /configuration\.displayMode = \.iconOnly/);
  assert.match(control, /case \.iconAndLabel: \.iconAndLabel/);
  assert.match(control, /case \.iconOnly: \.iconOnly/);

  // An icon-only control must fill the frame its call site gives it, otherwise it
  // sits at its ~41pt intrinsic icon width inside a wider visible capsule and the
  // capsule's edges tap nothing.
  assert.match(control, /var horizontalContentHugging: UILayoutPriority/);
  assert.match(control, /case \.iconAndLabel: \.required/);
  assert.match(control, /case \.iconOnly: \.defaultLow/);
  assert.match(control, /control\.setContentHuggingPriority\(style\.horizontalContentHugging, for: \.horizontal\)/);
});

test("the shared control keeps the native, user-initiated paste path", () => {
  // Still a UIPasteControl bridge — not a reimplemented paste button.
  assert.match(control, /struct ClipboardPasteControl: UIViewRepresentable/);
  assert.match(control, /func makeUIView\(context: Context\) -> UIPasteControl/);
  assert.match(control, /UIPasteControl\(configuration: configuration\)/);
  assert.match(control, /UIPasteConfigurationSupporting/);
  assert.match(control, /control\.accessibilityIdentifier = "clipboard\.paste\.control"/);

  // The control itself must never touch the pasteboard directly: the system
  // hands text to it, which is what preserves the privacy prompt.
  assert.doesNotMatch(control, /UIPasteboard/);

  // Detection stays on the privacy-preserving DetectedValues API and never reads
  // clipboard contents to decide whether to show the banner.
  assert.match(clipboardImport, /DetectedValues\.probableWebURL/);
  assert.doesNotMatch(clipboardImport, /pasteboard\.string/);
  assert.doesNotMatch(clipboardImport, /pasteboard\.url\b/);
});

test("Home opts into icon-only explicitly and supplies its own visible label", () => {
  // Home is the one screen allowed to be icon-only, because it draws the brand
  // capsule and the wording "粘贴导入" itself.
  assert.match(
    home,
    /ClipboardPasteControl\(\s*accessibilityLabel: "粘贴导入",\s*style: \.iconOnly,/
  );
  assert.match(home, /Text\("粘贴导入"\)/);

  // The label must also be applied at the SwiftUI level: `UIPasteControl` resets
  // its own accessibilityLabel to the system default ("Paste") on re-layout, so
  // the UIKit-side assignment alone is not enough.
  assert.match(home, /ClipboardPasteControl\([\s\S]*?\.accessibilityLabel\("粘贴导入"\)/);

  // The visible label must not intercept taps, so the whole area stays the
  // native control's.
  assert.match(home, /Text\("粘贴导入"\)[\s\S]*?\.allowsHitTesting\(false\)/);
  // ...and must not be a second VoiceOver element competing with the button.
  assert.match(home, /Text\("粘贴导入"\)[\s\S]*?\.accessibilityHidden\(true\)/);

  // Both layers share one frame inside a same-sized ZStack, so the visible
  // capsule and the tappable control cannot drift apart.
  const promptActions = home.slice(
    home.indexOf("private var promptActions"),
    home.indexOf('Button("忽略"')
  );
  const frames = promptActions.match(/\.frame\(minWidth: 118, minHeight: AppTheme\.minimumHitTarget\)/g);
  assert.equal(frames?.length, 3, "期望原生控件、可见 label、外层 ZStack 使用同一 frame");
});

test("recipe import uses the labeled default and keeps its existing wording", () => {
  const importSection = addRecipe.slice(
    addRecipe.indexOf('Section("菜谱链接")'),
    addRecipe.indexOf('Section("菜谱链接")') + 700
  );
  assert.match(importSection, /ClipboardPasteControl\(/);
  // No style override here: it must inherit the labeled default rather than
  // Home's icon-only presentation.
  assert.doesNotMatch(importSection, /style: \.iconOnly/);
  // Its own pre-existing copy is preserved, not replaced with Home's wording.
  assert.match(importSection, /accessibilityLabel: "粘贴剪贴板内容"/);
  assert.match(importSection, /\.frame\(minHeight: 44\)/);
});
