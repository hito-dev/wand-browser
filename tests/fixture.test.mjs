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

function cameraFixture(getUserMedia, NDEFReader = class {}) {
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
    addEventListener(name, handler) { const previous = events[name]; events[name] = () => { previous?.(); handler(); }; },
    log(message) { logs.push(message); },
    t(key) { return key; },
    NDEFReader,
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

function nfcFixture() {
  const readers = [];
  class Reader {
    constructor() { readers.push(this); }
    async scan({ signal }) {
      this.signal = signal;
      signal.addEventListener('abort', () => this.onreadingerror?.());
    }
  }
  return { ...cameraFixture(async () => {}, Reader), readers };
}

test('NFC fixture displays a record then stops without reporting cancellation as failure', async () => {
  const ui = nfcFixture();
  await ui.elements.scan.onclick();
  assert.equal(ui.elements.scan.disabled, true);
  await ui.elements.scan.onclick();
  assert.equal(ui.readers.length, 1);
  const first = ui.readers[0];
  const event = { message: { records: [{ recordType: 'text', data: new TextEncoder().encode('Hello') }] } };
  first.onreading(event);
  assert.equal(first.signal.aborted, true);
  assert.equal(ui.elements.scan.disabled, false);
  assert.deepEqual(ui.logs, ['active', 'read', 'text: Hello']);
  await ui.elements.scan.onclick();
  first.onreading(event);
  first.onreadingerror();
  assert.equal(ui.readers[1].signal.aborted, false);
  assert.deepEqual(ui.logs, ['active', 'read', 'text: Hello', 'active']);
  ui.elements.abort.onclick();
  assert.equal(ui.readers[1].signal.aborted, true);
  assert.equal(ui.logs.includes('readingError'), false);
});

test('NFC fixture retains genuine errors and stops on page exit', async () => {
  const ui = nfcFixture();
  await ui.elements.scan.onclick();
  ui.readers[0].onreadingerror();
  assert.deepEqual(ui.logs, ['active', 'readingError']);
  assert.equal(ui.readers[0].signal.aborted, true);
  assert.equal(ui.elements.scan.disabled, false);
  await ui.elements.scan.onclick();
  ui.events.pagehide();
  assert.equal(ui.readers[1].signal.aborted, true);
  assert.equal(ui.readers[0].signal.aborted, true);
  assert.equal(ui.elements.scan.disabled, false);
});


test('NFC fixture recovers from permission denial and cancellation before activation', async () => {
  class DeniedReader {
    async scan() { throw Object.assign(new Error('denied'), { name: 'NotAllowedError' }); }
  }
  const denied = cameraFixture(async () => {}, DeniedReader);
  await denied.elements.scan.onclick();
  assert.equal(denied.elements.scan.disabled, false);
  assert.deepEqual(denied.logs, ['NotAllowedError: denied']);
  let rejectScan;
  class PendingReader {
    scan() { return new Promise((_, reject) => { rejectScan = reject; }); }
  }
  const pending = cameraFixture(async () => {}, PendingReader);
  const start = pending.elements.scan.onclick();
  pending.elements.abort.onclick();
  rejectScan(Object.assign(new Error('cancelled'), { name: 'AbortError' }));
  await start;
  assert.equal(pending.elements.scan.disabled, false);
  assert.deepEqual(pending.logs, []);
});
