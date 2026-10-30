import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source = fs.readFileSync(new URL('../site/assets/fixture-i18n.js', import.meta.url), 'utf8');
const actions = fs.readFileSync(new URL('../site/assets/fixture-actions.js', import.meta.url), 'utf8');
test('fixture translations preserve page globals and literal hardware values', () => {
  const messages = { selected: 'Selected {name}', read: '{count}: {serial}' };
  const context = vm.createContext({ document: { querySelector: () => ({ textContent: JSON.stringify(messages) }) } });
  vm.runInContext(source, context);
  assert.equal(vm.runInContext('window = globalThis; window.messages = []; messages.push("hello"); JSON.stringify(messages)', context), '["hello"]');
  assert.equal(vm.runInContext('t("selected", {name: "{count}<device>"})', context), 'Selected {count}<device>');
  assert.equal(vm.runInContext('t("read", {count: 3, serial: "01ff"})', context), '3: 01ff');
});

function cameraFixture(getUserMedia) {
  const logs = [];
  const events = {};
  const elements = Object.fromEntries(['ble', 'scan', 'abort', 'text', 'write', 'binary', 'camera-start', 'camera-stop'].map(id => [id, { disabled: id === 'camera-stop' }]));
  elements['camera-preview'] = {
    hidden: true,
    srcObject: null,
    playCalls: 0,
    pauseCalls: 0,
    async play() { this.playCalls += 1; },
    pause() { this.pauseCalls += 1; },
  };
  const context = vm.createContext({
    AbortController,
    navigator: { mediaDevices: { getUserMedia } },
    document: { querySelector(selector) { return elements[selector.slice(1)]; } },
    addEventListener(name, handler) { events[name] = handler; },
    log(message) { logs.push(message); },
    t(key) { return key; },
    NDEFReader: class {},
    TextDecoder,
    Uint8Array,
  });
  vm.runInContext(actions, context);
  return { elements, events, logs };
}

function streamFixture() {
  const listeners = {};
  const track = {
    readyState: 'live',
    stopCalls: 0,
    stop() { this.stopCalls += 1; this.readyState = 'ended'; },
    addEventListener(name, handler) { listeners[name] = handler; },
  };
  return { stream: { getTracks: () => [track] }, track, listeners };
}

test('camera fixture starts video, replaces old tracks, and stops cleanly', async () => {
  const first = streamFixture();
  const second = streamFixture();
  const streams = [first.stream, second.stream];
  const calls = [];
  const ui = cameraFixture(async constraints => { calls.push(constraints); return streams.shift(); });

  await ui.elements['camera-start'].onclick();
  assert.equal(JSON.stringify(calls[0]), JSON.stringify({ video: true, audio: false }));
  assert.equal(ui.elements['camera-preview'].srcObject, first.stream);
  assert.equal(ui.elements['camera-preview'].hidden, false);
  assert.equal(ui.elements['camera-preview'].playCalls, 1);
  assert.equal(ui.elements['camera-start'].disabled, true);
  assert.equal(ui.elements['camera-stop'].disabled, false);
  assert.deepEqual(ui.logs, ['cameraActive']);

  await ui.elements['camera-start'].onclick();
  assert.equal(first.track.stopCalls, 1);
  assert.equal(ui.elements['camera-preview'].srcObject, second.stream);
  ui.elements['camera-stop'].onclick();
  assert.equal(second.track.stopCalls, 1);
  assert.equal(ui.elements['camera-preview'].srcObject, null);
  assert.equal(ui.elements['camera-preview'].hidden, true);
  assert.equal(ui.elements['camera-start'].disabled, false);
  assert.equal(ui.elements['camera-stop'].disabled, true);
  assert.deepEqual(ui.logs, ['cameraActive', 'cameraActive', 'cameraStopped']);
});

test('camera fixture recovers from denial and releases capture on page exit', async () => {
  const denied = cameraFixture(async () => { throw Object.assign(new Error('denied'), { name: 'NotAllowedError' }); });
  await denied.elements['camera-start'].onclick();
  assert.equal(denied.elements['camera-start'].disabled, false);
  assert.equal(denied.elements['camera-stop'].disabled, true);
  assert.equal(denied.elements['camera-preview'].hidden, true);
  assert.deepEqual(denied.logs, ['NotAllowedError: denied']);

  const active = streamFixture();
  const ui = cameraFixture(async () => active.stream);
  await ui.elements['camera-start'].onclick();
  ui.events.pagehide();
  assert.equal(active.track.stopCalls, 1);
  assert.equal(ui.elements['camera-preview'].srcObject, null);
});

test('camera fixture discards a stream that arrives after page exit', async () => {
  let resolve;
  const pending = new Promise(done => { resolve = done; });
  const active = streamFixture();
  const ui = cameraFixture(() => pending);
  const start = ui.elements['camera-start'].onclick();
  ui.events.pagehide();
  resolve(active.stream);
  await start;
  assert.equal(active.track.stopCalls, 1);
  assert.equal(ui.elements['camera-preview'].srcObject, null);
  assert.equal(ui.elements['camera-preview'].hidden, true);
  assert.deepEqual(ui.logs, []);
});
