import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source = fs.readFileSync(new URL('../site/assets/fixture-i18n.js', import.meta.url), 'utf8');
test('fixture translations preserve page globals and literal hardware values', () => {
  const messages = { selected: 'Selected {name}', read: '{count}: {serial}' };
  const context = vm.createContext({ document: { querySelector: () => ({ textContent: JSON.stringify(messages) }) } });
  vm.runInContext(source, context);
  assert.equal(vm.runInContext('window = globalThis; window.messages = []; messages.push("hello"); JSON.stringify(messages)', context), '["hello"]');
  assert.equal(vm.runInContext('t("selected", {name: "{count}<device>"})', context), 'Selected {count}<device>');
  assert.equal(vm.runInContext('t("read", {count: 3, serial: "01ff"})', context), '3: 01ff');
});
