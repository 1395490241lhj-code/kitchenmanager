import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const root = new URL('../ios-native/Kitchen Manager/', import.meta.url);
const read = path => readFileSync(new URL(path, root), 'utf8');
const project = read('Kitchen Manager.xcodeproj/project.pbxproj');
const content = read('KitchenManager/ContentView.swift');
const settings = read('KitchenManager/MainFeatureViews.swift');
const authService = read('KitchenManager/Authentication/SupabaseAuthService.swift');
const authStore = read('KitchenManager/Authentication/AuthStore.swift');
const accountViews = read('KitchenManager/Authentication/AccountViews.swift');
const accountService = read('KitchenManager/Authentication/APIAccountService.swift');
const config = read('Config/Shared.xcconfig');
const info = read('KitchenManager/Info.plist');
const ignore = read('../../.gitignore');

test('iOS Phase 1 uses the official Supabase package and Keychain session storage', () => {
  assert.match(project, /github\.com\/supabase\/supabase-swift/);
  assert.match(project, /productName = Supabase/);
  assert.match(authService, /KeychainLocalStorage/);
  assert.match(authService, /com\.lianghongjing\.kitchenmanager\.auth/);
  assert.doesNotMatch(authService, /UserDefaults/);
});

test('iOS auth configuration keeps real local values ignored and only injects public config', () => {
  assert.match(ignore, /Config\/Local\.xcconfig/);
  assert.match(config, /SUPABASE_PUBLISHABLE_KEY/);
  assert.doesNotMatch(config, /SERVICE_ROLE|DATABASE_PASSWORD|JWT_SECRET/);
  assert.match(project, /INFOPLIST_FILE = KitchenManager\/Info\.plist/);
  assert.match(info, /<key>KM_SUPABASE_PUBLISHABLE_KEY<\/key>[\s\S]*\$\(SUPABASE_PUBLISHABLE_KEY\)/);
  assert.match(info, /<key>KM_SUPABASE_URL<\/key>[\s\S]*\$\(SUPABASE_URL\)/);
});

test('Guest-first auth is app scoped without creating or switching kitchen persistence', () => {
  assert.match(content, /AuthenticationAssembly\.make\(\)/);
  assert.match(content, /await authStore\.start\(\)/);
  assert.match(settings, /游客模式/);
  assert.match(settings, /无需登录即可继续使用全部本机功能/);
  assert.doesNotMatch(authStore, /KitchenStore|KitchenPersistenceFactory|ModelContainer/);
});

test('protected account request uses the existing API client and verified token only in Authorization', () => {
  assert.match(accountService, /APIClient/);
  assert.match(accountService, /path: "api\/me"/);
  assert.match(accountService, /"Authorization": "Bearer/);
  assert.doesNotMatch(accountService, /print\(|debugPrint\(|logger/);
  assert.match(authStore, /accountMessage/);
});

test('Phase 1 UI labels identity as future sync preparation rather than completed sync', () => {
  assert.match(settings, /未来跨设备同步做准备/);
  assert.doesNotMatch(settings, /已同步到云端|自动同步已开启/);
});

test('authentication submissions are guarded in both state and UI layers', () => {
  assert.match(authStore, /guard activity != \.submitting else \{ return false \}/);
  assert.match(accountViews, /\.disabled\(authStore\.activity == \.submitting\)/);
});

test('signing out dismisses the account detail back to the Guest settings UI', () => {
  assert.match(accountViews, /if status == \.guest \{ dismiss\(\) \}/);
});
