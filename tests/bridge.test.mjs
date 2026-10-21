import assert from "node:assert/strict";
import { test } from "node:test";
import { readFile } from "node:fs/promises";
import { createHash, webcrypto } from "node:crypto";
import vm from "node:vm";

const source = await readFile(new URL("../ios/WandBrowser/Resources/HardwareBridge.js", import.meta.url), "utf8");
const sdkSource = await readFile(new URL("./fixtures/hito_ble_transport.js", import.meta.url), "utf8");
const serviceUUID = "5cc44b16-070a-11ed-b939-0242ac120002";
const characteristicUUID = "5cc44b17-070a-11ed-b939-0242ac120002";
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

function browser({ protocol = "https:", frame = false, initialized = true, respond } = {}) {
  const calls = [];
  const context = vm.createContext({
    Event, EventTarget, DOMException, TextEncoder, TextDecoder, ArrayBuffer, Uint8Array, DataView,
    AbortController, btoa, atob, crypto: webcrypto, setTimeout, clearTimeout,
    console: { log() {}, trace() {} },
    location: { protocol },
    document: { visibilityState: "visible", documentElement: { lang: "en" } },
    navigator: { userActivation: { isActive: true } }
  });
  context.window = context;
  context.top = frame ? {} : context;
  context.webkit = { messageHandlers: { wand: { async postMessage(request) {
    calls.push(request);
    return respond ? await respond(request, context) : { ok: null };
  } } } };
  vm.runInContext(source, context);
  let token = webcrypto.randomUUID();
  if (initialized) context.__hitoWand?.initialize(token);
  return {
    context, calls,
    emit(type, value, eventToken = token) { context.__hitoWand.receive(eventToken, type, value); },
    reset() { context.__hitoWand.receive(token, "reset", null); },
    initialize() { token = webcrypto.randomUUID(); context.__hitoWand.initialize(token); }
  };
}

function peripheral({ limit = 512, response = "Hito simulated response", handshake = false } = {}) {
  let app;
  let received = Buffer.alloc(0), expected = 0, receivingReply = false, replyOffset = 0;
  const writes = [], events = [];
  const replyBytes = Buffer.from(response);
  function notify(data) {
    const value = Buffer.from(data).toString("base64");
    events.push(value);
    app.emit("ble.value", { characteristic: "characteristic", value });
  }
  function nextReplyChunk() {
    if (replyOffset >= replyBytes.length) return;
    const chunk = replyBytes.subarray(replyOffset, replyOffset + 19);
    replyOffset += chunk.length;
    setTimeout(() => notify(Buffer.concat([Buffer.from("d"), chunk])), 1);
  }
  app = browser({ async respond({ op, args }) {
    switch (op) {
      case "ble.requestDevice": return { ok: { id: "device", name: "Hito test wallet" } };
      case "ble.connect": return { ok: null };
      case "ble.services": return { ok: [{ id: "service", uuid: serviceUUID, isPrimary: true, device: "device" }] };
      case "ble.characteristics": return { ok: [{ id: "characteristic", uuid: characteristicUUID, service: "service",
        properties: { read: true, write: true, writeWithoutResponse: true, notify: true } }] };
      case "ble.read": return { ok: Buffer.from([0, 1, 127, 255]).toString("base64") };
      case "ble.startNotifications":
      case "ble.stopNotifications": return { ok: null };
      case "ble.write":
      case "ble.writeWithResponse":
      case "ble.writeWithoutResponse": {
        const data = Buffer.from(args.data, "base64");
        if (data.length > limit) return { error: { name: "InvalidModificationError", message: `Write exceeds ${limit} bytes.` } };
        writes.push(data);
        if (handshake) {
          if (data.toString() === "ok" && receivingReply) { nextReplyChunk(); }
          else if (data[0] === 0x69) {
            expected = data.readUInt32LE(1); received = Buffer.alloc(0);
            setTimeout(() => notify(Buffer.from("ok")), 1);
          } else if (data[0] === 0x64) {
            received = Buffer.concat([received, data.subarray(1)]);
            assert.ok(received.length <= expected);
            setTimeout(() => notify(Buffer.from("ok")), 1);
            if (received.length === expected) {
              setTimeout(() => {
                receivingReply = true;
                const header = Buffer.alloc(5); header[0] = 0x69; header.writeUInt32LE(replyBytes.length, 1);
                notify(header);
              }, 8);
            }
          } else throw new Error("Malformed Hito packet boundary.");
        }
        return { ok: null };
      }
      case "ble.disconnect":
        app.emit("ble.disconnected", { device: "device" });
        return { ok: null };
      default: throw new Error(`Unexpected ${op}`);
    }
  } });
  return Object.assign(app, { writes, events, getReceived: () => received, notify });
}

async function connect(app) {
  const device = await app.context.navigator.bluetooth.requestDevice({ filters: [{ namePrefix: "Hito" }], optionalServices: [serviceUUID] });
  const server = await device.gatt.connect();
  const service = await server.getPrimaryService(serviceUUID);
  const characteristic = await service.getCharacteristic(characteristicUUID);
  return { device, server, service, characteristic };
}

test("hardware APIs are absent from insecure pages and child frames", () => {
  for (const options of [{ protocol: "http:" }, { frame: true }]) {
    const app = browser(options);
    assert.equal(app.context.navigator.bluetooth, undefined);
    assert.equal(app.context.NDEFReader, undefined);
  }
});

test("requests wait for native document initialization and require visibility/gesture", async () => {
  const app = browser({ initialized: false, respond: () => ({ ok: { id: "device", name: "Hito" } }) });
  const pending = app.context.navigator.bluetooth.requestDevice({ acceptAllDevices: true });
  await delay(1);
  assert.equal(app.calls.length, 0);
  app.initialize();
  await pending;
  app.context.document.visibilityState = "hidden";
  await assert.rejects(app.context.navigator.bluetooth.requestDevice({ acceptAllDevices: true }), { name: "SecurityError" });
  app.context.document.visibilityState = "visible";
  app.context.navigator.userActivation.isActive = false;
  await assert.rejects(app.context.navigator.bluetooth.requestDevice({ acceptAllDevices: true }), { name: "SecurityError" });
});

test("binary views preserve byte offsets, values, return types and event handlers", async () => {
  const app = peripheral();
  const { device, server, service, characteristic } = await connect(app);
  assert.equal(server.device, device);
  assert.equal(characteristic.service, service);
  assert.equal((await service.getCharacteristic(characteristicUUID)), characteristic);
  const backing = new Uint8Array([99, 1, 2, 255, 88]);
  await characteristic.writeValueWithoutResponse(new DataView(backing.buffer, 1, 3));
  assert.deepEqual([...app.writes[0]], [1, 2, 255]);
  let events = 0;
  characteristic.oncharacteristicvaluechanged = event => { assert.equal(event.target, characteristic); events++; };
  const value = await characteristic.readValue();
  assert.ok(value instanceof DataView);
  assert.deepEqual([...new Uint8Array(value.buffer)], [0, 1, 127, 255]);
  assert.equal(await characteristic.startNotifications(), characteristic);
  app.notify([5, 6]);
  assert.equal(characteristic.value.getUint8(1), 6);
  assert.equal(events, 2);
  characteristic.oncharacteristicvaluechanged = null;
  app.notify([7]);
  assert.equal(events, 2);
});

test("disconnect invalidates service handles and events from expired visits are discarded", async () => {
  const app = peripheral();
  const { device, characteristic } = await connect(app);
  let disconnected = 0;
  device.ongattserverdisconnected = () => disconnected++;
  device.gatt.disconnect();
  await delay(1);
  assert.equal(disconnected, 1);
  await device.gatt.connect();
  await assert.rejects(characteristic.readValue(), { name: "InvalidStateError" });
  app.reset();
  app.initialize();
  await assert.rejects(device.gatt.connect(), { name: "InvalidStateError" });
  app.emit("ble.value", { characteristic: "characteristic", value: "AA==" }, webcrypto.randomUUID());
  assert.equal(disconnected, 2);
});

test("NFC serializes UTF-8, UTF-16 and sliced binary inputs without data loss", async () => {
  const app = browser();
  const reader = new app.context.NDEFReader();
  await reader.write("hello");
  assert.equal(Buffer.from(app.calls.at(-1).args.records[0].data, "base64").toString(), "hello");
  await reader.write({ records: [{ recordType: "text", encoding: "utf-16", lang: "de", data: "Grüße" }] });
  assert.equal(Buffer.from(app.calls.at(-1).args.records[0].data, "base64").subarray(2).toString("utf16le"), "Grüße");
  const data = new Uint8Array([0, 1, 255, 0]);
  await reader.write(new DataView(data.buffer, 1, 2), { overwrite: false });
  assert.deepEqual([...Buffer.from(app.calls.at(-1).args.records[0].data, "base64")], [1, 255]);
  assert.equal(app.calls.at(-1).args.overwrite, false);
  await assert.rejects(reader.makeReadOnly(), { name: "NotSupportedError" });
});

test("NFC resolves scan before reading and keeps timeout separate from settled promises", async () => {
  const app = browser();
  const reader = new app.context.NDEFReader();
  let count = 0, errors = 0;
  reader.onreading = event => {
    count++;
    assert.equal(event.serialNumber, "");
    assert.equal(new TextDecoder().decode(event.message.records[0].data), "tag");
  };
  reader.onreadingerror = () => errors++;
  await reader.scan();
  assert.equal(count, 0);
  const id = app.calls.at(-1).args.reader;
  app.emit("nfc.reading", { reader: id, serialNumber: "", records: [{ recordType: "text", id: "", encoding: "utf-8", lang: "en", data: btoa("tag") }] });
  app.emit("nfc.error", { reader: id, error: { name: "NotReadableError", message: "Session expired" } });
  assert.equal(count, 1);
  assert.equal(errors, 1);
  await assert.rejects(reader.scan(), { name: "InvalidStateError" });
  // Native restart keeps the same reader registration.
  app.emit("nfc.reading", { reader: id, records: [{ recordType: "text", data: btoa("tag") }] });
  assert.equal(count, 2);
});

test("NFC abort works before and after activation and releases listeners", async () => {
  const app = browser();
  const reader = new app.context.NDEFReader();
  const already = new AbortController(); already.abort();
  await assert.rejects(reader.scan({ signal: already.signal }), { name: "AbortError" });
  assert.equal(app.calls.length, 0);
  const controller = new AbortController();
  await reader.scan({ signal: controller.signal });
  const scan = app.calls.at(-1);
  controller.abort();
  await delay(1);
  assert.equal(app.calls.at(-1).op, "cancel");
  assert.equal(app.calls.at(-1).args.target, scan.id);
  app.emit("nfc.stopped", { reader: scan.args.reader, request: scan.id });
  await reader.scan();
  app.reset(); app.initialize();
  await reader.scan();
});

test("native errors become named DOMExceptions and unsupported options are explicit", async () => {
  const app = browser({ respond: () => ({ error: { name: "NotAllowedError", message: "Denied by user" } }) });
  await assert.rejects(app.context.navigator.bluetooth.requestDevice({ acceptAllDevices: true }), { name: "NotAllowedError", message: "Denied by user" });
  const reader = new app.context.NDEFReader();
  await assert.rejects(reader.scan({ unsupported: true }), { name: "NotSupportedError" });
  await assert.rejects(reader.write("x", { overwrite: "no" }), { name: "TypeError" });
});

test("unchanged SDK fixture has its recorded SHA-256", async () => {
  const provenance = JSON.parse(await readFile(new URL("./fixtures/sdk-provenance.json", import.meta.url), "utf8"));
  assert.equal(createHash("sha256").update(sdkSource).digest("hex"), provenance.sha256);
});

test("unchanged Hito SDK completes packet/ACK command exchange with packetSize 19", async () => {
  const app = peripheral({ limit: 20, handshake: true });
  const module = new vm.SourceTextModule(sdkSource, { context: app.context });
  await module.link(() => { throw new Error("Unexpected SDK dependency."); });
  await module.evaluate();
  const transport = new module.namespace.BluetoothTransport({ packetSize: 19 });
  const command = "test:" + "0123456789".repeat(20);
  assert.equal(await transport.sendCommand(command), "Hito simulated response");
  assert.equal(app.getReceived().toString(), command);
  assert.ok(app.writes.every(value => value.length <= 20));
  assert.ok(app.calls.some(value => value.op === "ble.stopNotifications"));
  assert.ok(app.calls.some(value => value.op === "ble.disconnect"));
});

test("default SDK packets fail explicitly at a smaller connection limit without fragmentation", async () => {
  const app = peripheral({ limit: 182, handshake: true });
  const module = new vm.SourceTextModule(sdkSource, { context: app.context });
  await module.link(() => {});
  await module.evaluate();
  const transport = new module.namespace.BluetoothTransport();
  await assert.rejects(transport.sendCommand("x".repeat(505)), { name: "InvalidModificationError" });
  assert.equal(app.writes.length, 1); // Only the 5-byte header reached the peripheral.
  assert.equal(app.calls.find(value => value.op === "ble.writeWithoutResponse" && Buffer.from(value.args.data, "base64").length === 506) !== undefined, true);
});
