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
  assert.match(control, /case customLabeled\(String\)/);

  // The default must be the labeled style, so no call site can silently lose its
  // visible text again by omitting the parameter.
  assert.match(control, /var style: ClipboardPasteControlStyle = \.iconAndLabel/);

  // displayMode is driven by the style, not hardcoded.
  assert.match(control, /configuration\.displayMode = style\.displayMode/);
  assert.doesNotMatch(control, /configuration\.displayMode = \.iconOnly/);
  assert.match(control, /case \.iconAndLabel: \.iconAndLabel/);
  assert.match(control, /case \.iconOnly, \.customLabeled: \.iconOnly/);

  // An icon-only control must fill the frame its call site gives it, otherwise it
  // sits at its ~41pt intrinsic icon width inside a wider visible capsule and the
  // capsule's edges tap nothing.
  assert.match(control, /var horizontalContentHugging: UILayoutPriority/);
  assert.match(control, /case \.iconAndLabel: \.required/);
  assert.match(control, /case \.iconOnly, \.customLabeled: \.defaultLow/);
  assert.match(control, /control\.setContentHuggingPriority\(style\.horizontalContentHugging, for: \.horizontal\)/);
});

test("the shared control keeps the native, user-initiated paste path", () => {
  // Still a UIPasteControl bridge — not a reimplemented paste button.
  assert.match(control, /struct ClipboardPasteControl: View/);
  assert.match(control, /private struct NativeClipboardPasteControl: UIViewRepresentable/);
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

test("custom labeled mode keeps native interaction and owns the visual label", () => {
  assert.match(control, /case customLabeled\(String\)/);
  assert.match(control, /if case \.customLabeled\(let label\) = style/);
  // 生产代码用 Label { Text } icon: { Image } 的尾随闭包写法（文字和图标要分别上色），
  // 与 Label(_:systemImage:) 简写等价。这里验证图标与 label 内容，不锁具体语法。
  assert.match(control, /Image\(systemName: "doc\.on\.clipboard"\)/);
  assert.match(control, /Text\(label\)/);
  assert.match(control, /\.allowsHitTesting\(false\)/);
  assert.match(control, /\.accessibilityHidden\(true\)/);
  assert.match(control, /\.accessibilityLabel\(accessibilityLabel\)/);
  assert.match(control, /\.frame\(maxWidth: \.infinity, minHeight: AppTheme\.minimumHitTarget\)/);
});

test("Home uses the shared custom labeled control without a duplicate overlay", () => {
  assert.match(
    home,
    /ClipboardPasteControl\(\s*accessibilityLabel: "粘贴导入",\s*style: \.customLabeled\("粘贴导入"\),/
  );
  const promptActions = home.slice(
    home.indexOf("private var promptActions"),
    home.indexOf('Button("忽略"')
  );
  assert.doesNotMatch(promptActions, /Text\("粘贴导入"\)/);
  assert.doesNotMatch(promptActions, /ZStack/);
});

test("recipe import uses the shared custom Chinese label", () => {
  const importSection = addRecipe.slice(
    addRecipe.indexOf('Section("菜谱链接")'),
    addRecipe.indexOf('Section("菜谱链接")') + 700
  );
  assert.match(importSection, /ClipboardPasteControl\(/);
  assert.match(importSection, /style: \.customLabeled\("粘贴导入"\)/);
  assert.match(importSection, /accessibilityLabel: "粘贴导入"/);
  assert.match(importSection, /\.frame\(minHeight: 44\)/);
});
