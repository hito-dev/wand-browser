/* Wand Browser's supported Web Bluetooth / Web NFC subset. No network dependencies. */
(() => {
  "use strict";
  if (window !== window.top || location.protocol !== "https:") return;
  if (window.__hitoWand) return;

  let token = null;
  let resolveReady, rejectReady, ready;
  const devices = new Map(), services = new Map(), characteristics = new Map(), readers = new Map();
  const abortCleanups = new Map();
  const fail = (name, message) => name === "TypeError" ? new TypeError(message) : new DOMException(message, name);
  function newReady() {
    ready = new Promise((resolve, reject) => { resolveReady = resolve; rejectReady = reject; });
    ready.catch(() => {});
  }
  newReady();

  function visible() {
    if (document.visibilityState !== "visible") throw fail("SecurityError", "Hardware requires a visible document.");
  }
  function gesture() {
    if (navigator.userActivation && !navigator.userActivation.isActive) {
      throw fail("SecurityError", "Choose this action with a tap or click.");
    }
  }
  function bytes(value) {
    if (value instanceof ArrayBuffer) return new Uint8Array(value);
    if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    throw new TypeError("Expected an ArrayBuffer or ArrayBuffer view.");
  }
  function base64(value) {
    const data = bytes(value);
    let text = "";
    for (let i = 0; i < data.length; i += 8192) text += String.fromCharCode(...data.subarray(i, i + 8192));
    return btoa(text);
  }
  function dataView(value) {
    const text = atob(value);
    const data = Uint8Array.from(text, character => character.charCodeAt(0));
    return new DataView(data.buffer);
  }
  function stringBytes(value, encoding = "utf-8") {
    if (encoding === "utf-8") return new TextEncoder().encode(value);
    if (encoding !== "utf-16") throw new TypeError("Unsupported text encoding.");
    const data = new Uint8Array(2 + value.length * 2);
    const view = new DataView(data.buffer);
    view.setUint16(0, 0xfeff, true);
    for (let i = 0; i < value.length; i++) view.setUint16(2 + i * 2, value.charCodeAt(i), true);
    return data;
  }
  function readonly(object, values) {
    for (const [key, value] of Object.entries(values)) {
      Object.defineProperty(object, key, { value, enumerable: true });
    }
  }
  function handler(prototype, type) {
    const values = new WeakMap();
    Object.defineProperty(prototype, `on${type}`, {
      enumerable: true,
      get() { return values.get(this) ?? null; },
      set(value) {
        const old = values.get(this);
        if (old) this.removeEventListener(type, old);
        if (typeof value === "function") { values.set(this, value); this.addEventListener(type, value); }
        else values.delete(this);
      }
    });
  }
  function current(object) {
    if (!token || object._token !== token) throw fail("InvalidStateError", "This handle belongs to an expired document visit.");
  }
  function cancel(id, requestToken) {
    if (requestToken && requestToken === token) {
      window.webkit.messageHandlers.wand.postMessage({
        id: crypto.randomUUID(), token: requestToken, op: "cancel", args: { target: id }
      }).catch(() => {});
    }
  }
  async function request(op, args = {}, { signal, id = crypto.randomUUID(), retainAbort = false } = {}) {
    visible();
    if (signal?.aborted) throw signal.reason ?? fail("AbortError", "The operation was cancelled.");
    let requestToken = null;
    let abort;
    const aborted = new Promise((_, reject) => {
      abort = () => {
        cancel(id, requestToken);
        reject(signal.reason ?? fail("AbortError", "The operation was cancelled."));
        cleanup();
      };
    });
    function cleanup() {
      signal?.removeEventListener("abort", abort);
      abortCleanups.delete(id);
    }
    if (signal) {
      signal.addEventListener("abort", abort, { once: true });
      abortCleanups.set(id, cleanup);
    }
    try {
      await Promise.race([ready, aborted]);
      visible();
      if (signal?.aborted) throw signal.reason ?? fail("AbortError", "The operation was cancelled.");
      requestToken = token;
      const response = await Promise.race([
        window.webkit.messageHandlers.wand.postMessage({ id, token: requestToken, op, args }), aborted
      ]);
      if (requestToken !== token) throw fail("AbortError", "The document visit ended.");
      if (response.error) throw fail(response.error.name, response.error.message);
      if (!retainAbort) cleanup();
      return response.ok;
    } catch (error) {
      cleanup();
      throw error;
    }
  }

  class BluetoothDevice extends EventTarget {
    constructor(value) {
      super();
      this._token = token;
      readonly(this, { id: value.id, name: value.name, gatt: new BluetoothRemoteGATTServer(this) });
    }
  }
  handler(BluetoothDevice.prototype, "gattserverdisconnected");
  class BluetoothRemoteGATTServer {
    constructor(device) { readonly(this, { device }); this._connected = false; this._epoch = 0; }
    get connected() { return this._connected; }
    async connect() {
      current(this.device);
      const epoch = this._epoch;
      await request("ble.connect", { device: this.device.id });
      if (epoch !== this._epoch) throw fail("NetworkError", "Connection was cancelled.");
      this._connected = true;
      return this;
    }
    disconnect() {
      current(this.device);
      markDisconnected(this.device);
      request("ble.disconnect", { device: this.device.id }).catch(() => {});
    }
    async getPrimaryServices(uuid) {
      current(this.device);
      if (!this.connected) throw fail("NetworkError", "Device is disconnected.");
      const values = await request("ble.services", { device: this.device.id, ...(uuid === undefined ? {} : { uuid }) });
      return values.map(value => {
        if (!services.has(value.id)) services.set(value.id, new BluetoothRemoteGATTService(this.device, value));
        return services.get(value.id);
      });
    }
    async getPrimaryService(uuid) {
      if (uuid === undefined) throw new TypeError("A service UUID is required.");
      const result = await this.getPrimaryServices(uuid);
      if (!result.length) throw fail("NotFoundError", "Service not found.");
      return result[0];
    }
  }
  class BluetoothRemoteGATTService {
    constructor(device, value) {
      this._id = value.id; this._token = token; this._epoch = device.gatt._epoch;
      readonly(this, { device, uuid: value.uuid, isPrimary: value.isPrimary });
    }
    _check() {
      current(this);
      if (!this.device.gatt.connected || this._epoch !== this.device.gatt._epoch) {
        throw fail("InvalidStateError", "Rediscover services after reconnecting.");
      }
    }
    async getCharacteristics(uuid) {
      this._check();
      const values = await request("ble.characteristics", { service: this._id, ...(uuid === undefined ? {} : { uuid }) });
      return values.map(value => {
        if (!characteristics.has(value.id)) characteristics.set(value.id, new BluetoothRemoteGATTCharacteristic(this, value));
        return characteristics.get(value.id);
      });
    }
    async getCharacteristic(uuid) {
      if (uuid === undefined) throw new TypeError("A characteristic UUID is required.");
      const result = await this.getCharacteristics(uuid);
      if (!result.length) throw fail("NotFoundError", "Characteristic not found.");
      return result[0];
    }
  }
  class BluetoothRemoteGATTCharacteristic extends EventTarget {
    constructor(service, value) {
      super();
      this._id = value.id; this._token = token; this._value = null;
      readonly(this, { service, uuid: value.uuid, properties: Object.freeze(value.properties) });
    }
    get value() { return this._value; }
    async readValue() {
      this.service._check();
      this._value = dataView(await request("ble.read", { characteristic: this._id }));
      this.dispatchEvent(new Event("characteristicvaluechanged"));
      return this._value;
    }
    async _write(op, value) {
      this.service._check();
      const data = bytes(value);
      if (data.length > 512) throw fail("InvalidModificationError", "Bluetooth writes cannot exceed 512 bytes.");
      await request(op, { characteristic: this._id, data: base64(data) });
    }
    writeValue(value) { return this._write("ble.write", value); }
    writeValueWithResponse(value) { return this._write("ble.writeWithResponse", value); }
    writeValueWithoutResponse(value) { return this._write("ble.writeWithoutResponse", value); }
    async startNotifications() {
      this.service._check();
      await request("ble.startNotifications", { characteristic: this._id });
      return this;
    }
    async stopNotifications() {
      this.service._check();
      await request("ble.stopNotifications", { characteristic: this._id });
      return this;
    }
  }
  handler(BluetoothRemoteGATTCharacteristic.prototype, "characteristicvaluechanged");
  function markDisconnected(device) {
    const wasConnected = device.gatt._connected;
    device.gatt._connected = false; device.gatt._epoch++;
    for (const [id, service] of services) if (service.device === device) services.delete(id);
    for (const [id, characteristic] of characteristics) if (characteristic.service.device === device) characteristics.delete(id);
    if (wasConnected) device.dispatchEvent(new Event("gattserverdisconnected"));
  }
  class Bluetooth extends EventTarget {
    async requestDevice(options) {
      gesture();
      if (!options || typeof options !== "object") throw new TypeError("Device selection options are required.");
      const result = await request("ble.requestDevice", options);
      if (!devices.has(result.id)) devices.set(result.id, new BluetoothDevice(result));
      return devices.get(result.id);
    }
  }

  function serializeRecord(record) {
    if (!record || typeof record !== "object" || typeof record.recordType !== "string") throw new TypeError("Invalid NDEF record.");
    const supported = ["recordType", "id", "data", "mediaType", "encoding", "lang"];
    if (Object.keys(record).some(key => !supported.includes(key))) throw fail("NotSupportedError", "Unsupported NDEF record field.");
    const type = record.recordType;
    const encoding = record.encoding ?? "utf-8";
    let data = record.data;
    if (data === undefined && type === "empty") data = new Uint8Array();
    if (typeof data === "string") data = stringBytes(data, type === "text" ? encoding : "utf-8");
    const result = { recordType: type, id: record.id ?? "", data: base64(data) };
    if (type === "text") { result.encoding = encoding; result.lang = record.lang ?? document.documentElement.lang ?? "en"; if (!result.lang) result.lang = "en"; }
    if (type === "mime") result.mediaType = record.mediaType ?? "application/octet-stream";
    return result;
  }
  function serializeMessage(source) {
    if (typeof source === "string") return [serializeRecord({ recordType: "text", data: source })];
    if (source instanceof ArrayBuffer || ArrayBuffer.isView(source)) return [serializeRecord({ recordType: "mime", data: source })];
    if (!source || !Array.isArray(source.records) || !source.records.length) throw new TypeError("A nonempty NDEF message is required.");
    return source.records.map(serializeRecord);
  }
  class NDEFRecord {
    constructor(value) {
      readonly(this, {
        recordType: value.recordType, id: value.id ?? "", mediaType: value.mediaType ?? null,
        encoding: value.encoding ?? null, lang: value.lang ?? null, data: dataView(value.data)
      });
    }
    toRecords() { throw fail("NotSupportedError", "Nested NDEF records are not supported."); }
  }
  class NDEFMessage {
    constructor(source, decoded = false) {
      readonly(this, { records: Object.freeze((decoded ? source : serializeMessage(source)).map(value => new NDEFRecord(value))) });
    }
  }
  class NDEFReadingEvent extends Event {
    constructor(type, init) {
      super(type, init);
      readonly(this, { serialNumber: init.serialNumber ?? "", message: init.message instanceof NDEFMessage ? init.message : new NDEFMessage(init.message) });
    }
  }
  class NDEFReader extends EventTarget {
    constructor() {
      super();
      this._id = crypto.randomUUID(); this._scan = null;
      readers.set(this._id, this);
    }
    async scan(options = {}) {
      if (Object.keys(options).some(key => key !== "signal")) throw fail("NotSupportedError", "Unsupported scan option.");
      if (this._scan) throw fail("InvalidStateError", "This reader is already scanning.");
      const id = crypto.randomUUID();
      this._scan = id;
      try {
        await request("nfc.scan", { reader: this._id }, { id, signal: options.signal, retainAbort: true });
      } catch (error) {
        if (this._scan === id) this._scan = null;
        throw error;
      }
    }
    async write(source, options = {}) {
      if (Object.keys(options).some(key => !["signal", "overwrite"].includes(key))) throw fail("NotSupportedError", "Unsupported write option.");
      if (options.overwrite !== undefined && typeof options.overwrite !== "boolean") throw new TypeError("overwrite must be a boolean.");
      await request("nfc.write", { reader: this._id, records: serializeMessage(source), overwrite: options.overwrite ?? true }, { signal: options.signal });
    }
    async makeReadOnly() { throw fail("NotSupportedError", "Permanent tag locking is not supported."); }
  }
  handler(NDEFReader.prototype, "reading");
  handler(NDEFReader.prototype, "readingerror");

  let fullscreenActive = false, fullscreenRevision = -1;
  class WandFullscreen extends EventTarget {
    get active() { return fullscreenActive; }
    async request() {
      gesture();
      updateFullscreen(await request("fullscreen.request"));
    }
    async exit() { updateFullscreen(await request("fullscreen.exit")); }
  }
  const fullscreen = new WandFullscreen();
  function updateFullscreen(state) {
    if (!state || typeof state.active !== "boolean" || !Number.isSafeInteger(state.revision) || state.revision < fullscreenRevision) return;
    fullscreenRevision = state.revision;
    const changed = fullscreenActive !== state.active;
    fullscreenActive = state.active;
    if (changed) fullscreen.dispatchEvent(new Event("change"));
  }
  // Keep native Fullscreen API methods and document state untouched.
  if (!("wand" in window)) Object.defineProperty(window, "wand", { value: Object.freeze({ fullscreen }) });

  function reset() {
    rejectReady(fail("AbortError", "The document visit ended."));
    token = null;
    for (const device of devices.values()) markDisconnected(device);
    devices.clear(); services.clear(); characteristics.clear();
    for (const reader of readers.values()) {
      if (reader._scan) { reader._scan = null; reader.dispatchEvent(new Event("readingerror")); }
    }
    for (const cleanup of [...abortCleanups.values()]) cleanup();
    newReady();
  }
  function receive(eventToken, type, value) {
    if (!token || eventToken !== token) return;
    if (type === "reset") { reset(); return; }
    if (type === "fullscreen.change") { updateFullscreen(value); return; }
    if (type === "ble.disconnected") {
      const device = devices.get(value.device);
      if (device) markDisconnected(device);
    } else if (type === "ble.value") {
      const characteristic = characteristics.get(value.characteristic);
      if (characteristic) { characteristic._value = dataView(value.value); characteristic.dispatchEvent(new Event("characteristicvaluechanged")); }
    } else if (type.startsWith("nfc.")) {
      const reader = readers.get(value.reader);
      if (!reader || !reader._scan) return;
      if (type === "nfc.reading") {
        reader.dispatchEvent(new NDEFReadingEvent("reading", { serialNumber: value.serialNumber, message: new NDEFMessage(value.records, true) }));
      } else {
        if (type === "nfc.stopped") {
          abortCleanups.get(reader._scan)?.();
          reader._scan = null;
        }
        reader.dispatchEvent(new Event("readingerror"));
      }
    }
  }
  Object.defineProperty(window, "__hitoWand", { value: Object.freeze({
    initialize(next, fullscreenState) {
      if (token) reset();
      token = next; updateFullscreen(fullscreenState); resolveReady();
    },
    receive
  }) });
  if (!navigator.bluetooth) Object.defineProperty(navigator, "bluetooth", { value: new Bluetooth(), enumerable: true });
  for (const [name, value] of Object.entries({ NDEFReader, NDEFMessage, NDEFRecord, NDEFReadingEvent })) {
    if (!window[name]) Object.defineProperty(window, name, { value, configurable: false, enumerable: false });
  }
})();
