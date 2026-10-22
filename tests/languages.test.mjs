import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source = fs.readFileSync(new URL('../site/assets/languages.js', import.meta.url), 'utf8');

function setup(open = true) {
  const events = {};
  let focused = false;
  const summary = { focus() { focused = true; } };
  const inside = {};
  const disclosure = { open, querySelector: () => summary, contains: target => target === inside };
  vm.runInNewContext(source, { document: {
    querySelector: () => disclosure,
    addEventListener(name, handler) { events[name] = handler; },
  } });
  return { events, disclosure, inside, focused: () => focused };
}

test('Escape dismisses an open language chooser and restores trigger focus', () => {
  const ui = setup();
  let prevented = false;
  ui.events.keydown({ key: 'Escape', preventDefault() { prevented = true; } });
  assert.equal(ui.disclosure.open, false);
  assert.equal(ui.focused(), true);
  assert.equal(prevented, true);
});

test('closed chooser leaves Escape and focus alone; other keys remain native', () => {
  const ui = setup(false);
  ui.events.keydown({ key: 'Escape', preventDefault() { assert.fail('closed chooser intercepted Escape'); } });
  assert.equal(ui.focused(), false);
  ui.disclosure.open = true;
  ui.events.keydown({ key: 'Tab', preventDefault() { assert.fail('chooser intercepted Tab'); } });
  assert.equal(ui.disclosure.open, true);
});

test('inside clicks preserve ordinary links; outside clicks dismiss without moving focus', () => {
  const ui = setup();
  ui.events.click({ target: ui.inside });
  assert.equal(ui.disclosure.open, true);
  ui.events.click({ target: {} });
  assert.equal(ui.disclosure.open, false);
  assert.equal(ui.focused(), false);
});
