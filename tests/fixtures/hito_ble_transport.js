// hito_ble_transport.js
// Browser (Web Bluetooth) equivalent of your Python BluetoothTransport + HandshakeStream.
// Protocol:
//  - SEND:  i<u32le size> then repeated d<chunk...> ; device replies "ok" / "err..."
//  - RECV:  device sends i<u32le size> then d<chunk...> ; we reply "ok" after header and each chunk

export class HandshakeError extends Error {
  constructor(message) {
    super(message);
    this.name = "HandshakeError";
  }
}

// -----------------------------------------------------------------------------
// Tiny async mutex (like asyncio.Lock)
// -----------------------------------------------------------------------------
class AsyncMutex {
  constructor() {
    this._p = Promise.resolve();
  }
  async run(fn) {
    const prev = this._p;
    let release;
    this._p = new Promise((r) => (release = r));
    await prev;
    try {
      return await fn();
    } finally {
      release();
    }
  }
}

// -----------------------------------------------------------------------------
// HandshakeStream (byte-framed request/response + ACK parsing)
// You must implement _write(bytes) and call onNotify(bytes) from BLE notifications.
// -----------------------------------------------------------------------------
export class HandshakeStream {
  constructor({ packetSize = 505 } = {}) {
    this._packetSize = packetSize;

    /** @type {Uint8Array} */
    this._buf = new Uint8Array(0);

    // ACK waiting
    this._ackWaiter = null; // { resolve, reject, timer }
    this._ackValue = null; // { ok: boolean, desc: string }

    // Data waiting (response packages)
    this._dataWaiter = null; // { resolve, reject, timer? }
    this._dataEventTick = 0;

    this._lock = new AsyncMutex();
  }

  // ----- incoming data hook -----
  onNotify(dataBytes) {
    // dataBytes: Uint8Array
    this._buf = concatU8(this._buf, dataBytes);
    this._dataEventTick++;

    this._tryParseAck();

    // Wake any waiters (ACK or data) by resolving "tick promises"
    if (this._dataWaiter?.poke) this._dataWaiter.poke();
  }

  // ----- ACK parsing -----
  _tryParseAck() {
    if (this._ackValue) return;
    if (this._buf.length < 2) return;

    // Match python: startswith(b"ok") or startswith(b"err")
    if (startsWithAscii(this._buf, "ok")) {
      const desc = decodeUtf8(this._buf.slice(2));
      this._buf = new Uint8Array(0);
      this._ackValue = { ok: true, desc };
      this._resolveAck();
    } else if (this._buf.length >= 3 && startsWithAscii(this._buf, "err")) {
      const desc = decodeUtf8(this._buf.slice(3));
      this._buf = new Uint8Array(0);
      this._ackValue = { ok: false, desc };
      this._resolveAck();
    }
  }

  _resolveAck() {
    if (!this._ackWaiter) return;
    const { resolve, timer } = this._ackWaiter;
    clearTimeout(timer);
    this._ackWaiter = null;
    resolve(this._ackValue);
  }

  async waitAck(timeoutMs = 5000) {
    // Fast path
    if (this._ackValue) {
      const v = this._ackValue;
      this._ackValue = null;
      if (!v.ok) throw new HandshakeError(v.desc || "device error");
      return v;
    }

    const v = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this._ackWaiter = null;
        reject(new HandshakeError("ack timeout"));
      }, timeoutMs);

      this._ackWaiter = { resolve, reject, timer };
    });

    this._ackValue = null;
    if (!v.ok) throw new HandshakeError(v.desc || "device error");
    return v;
  }

  // ----- sending -----
  async sendDataPackage(payloadBytes) {
    // payloadBytes: Uint8Array
    return this._lock.run(async () => {
      const size = payloadBytes.length;

      // reset state (matches python)
      this._buf = new Uint8Array(0);
      this._ackValue = null;

      // 1) header: 'i' + u32le
      const hdr = new Uint8Array(5);
      hdr[0] = "i".charCodeAt(0);
      writeU32LE(hdr, 1, size);

      await this._write(hdr);
      await this.waitAck(5000);

      // 2) chunks: 'd' + up to packetSize
      let sent = 0;
      while (sent < size) {
        const chunkLen = Math.min(this._packetSize, size - sent);
        const pkt = new Uint8Array(1 + chunkLen);
        pkt[0] = "d".charCodeAt(0);
        pkt.set(payloadBytes.slice(sent, sent + chunkLen), 1);

        await this._write(pkt);
        await this.waitAck(5000);

        sent += chunkLen;
      }
    });
  }

  // ----- receiving (mirrors python wait_data_package) -----
  async waitDataPackage({
    timeoutMs = 60000,
    chunkTimeoutMs = 5000,
  } = {}) {
    const deadline = Date.now() + timeoutMs;
    let lastProgress = Date.now();

    /** @type {number|null} */
    let expectedSize = null;
    let received = new Uint8Array(0);

    // A little "poke" primitive to avoid busy loops; onNotify calls poke()
    const waitForPokeOrTick = () =>
      new Promise((resolve) => {
        let done = false;
        const poke = () => {
          if (done) return;
          done = true;
          resolve();
        };
        this._dataWaiter = { poke };
        // also wake periodically like python (0.05s)
        setTimeout(poke, 50);
      });

    while (Date.now() < deadline) {
      await waitForPokeOrTick();
      this._dataWaiter = null;

      if (this._buf.length) lastProgress = Date.now();

      // parse header: i<u32le>
      if (
        expectedSize === null &&
        this._buf.length >= 5 &&
        this._buf[0] === "i".charCodeAt(0)
      ) {
        expectedSize = readU32LE(this._buf, 1);

        // ACK header
        await this._write(encodeAscii("ok"));

        // consume 5 bytes
        this._buf = this._buf.slice(5);

        if (expectedSize === 0) return received;
      }

      // parse chunks: while buf startswith 'd'
      while (
        expectedSize !== null &&
        this._buf.length >= 1 &&
        this._buf[0] === "d".charCodeAt(0)
      ) {
        if (this._buf.length < 2) break;

        // python treats everything after 'd' as chunk bytes; take only what we need
        const chunk = this._buf.slice(1);
        const need = expectedSize - received.length;
        const take = Math.min(chunk.length, need);

        received = concatU8(received, chunk.slice(0, take));

        // consume: 'd' + take
        this._buf = this._buf.slice(1 + take);

        // ACK chunk
        await this._write(encodeAscii("ok"));

        if (received.length === expectedSize) return received;
      }

      const waitTimeout = expectedSize === 0 ? timeoutMs : chunkTimeoutMs;
      if (Date.now() - lastProgress > waitTimeout) {
        await this._write(encodeAscii("err chunk_timeout"));
        throw new HandshakeError("no data progress");
      }
    }

    await this._write(encodeAscii("err data_timeout"));
    throw new HandshakeError("data timeout");
  }

  // ----- hook to implement in transport -----
  async _write(_bytes) {
    throw new Error("HandshakeStream._write() not implemented");
  }
}

// -----------------------------------------------------------------------------
// BluetoothTransport (Web Bluetooth)
// Mirrors python BluetoothTransport behavior but browser-style.
// Uses a single characteristic for write + notify (same UUID in your python).
// -----------------------------------------------------------------------------
export class BluetoothTransport extends HandshakeStream {
  static name = "bluetooth";

  constructor({
    namePrefixes = ["hito", "Hito"],
    serviceUuid = "5cc44b16-070a-11ed-b939-0242ac120002",
    txUuid = "5cc44b17-070a-11ed-b939-0242ac120002",
    packetSize = 505,
  } = {}) {
    super({ packetSize });

    this._namePrefixes = namePrefixes;
    this._serviceUuid = serviceUuid;
    this._txUuid = txUuid;

    this._device = null;
    this._server = null;
    this._service = null;
    this._txChar = null;

    this._onCharChanged = (ev) => {
      const dv = ev.target.value; // DataView
      const bytes = new Uint8Array(dv.buffer, dv.byteOffset, dv.byteLength);
      this.onNotify(bytes);
    };
  }

  async isAvailable() {
    return !!(navigator.bluetooth && navigator.bluetooth.requestDevice);
  }

  async connect() {
    if (this._device?.gatt?.connected) {
      return;
    }
    if (!await this.isAvailable()) {
      throw new Error("Web Bluetooth is not available in this browser/context.");
    }

    // Best-effort filters: WebBluetooth namePrefix filter is supported in Chromium-based browsers.
    const filters = this._namePrefixes.map((p) => ({
      namePrefix: p,
      //services: [this._serviceUuid],
    }));

    this._device = await navigator.bluetooth.requestDevice({
      filters,
      optionalServices: [this._serviceUuid],
    });

    this._device.addEventListener("gattserverdisconnected", () => {
      // You can add reconnection logic here if you want.
    });

    this._server = await this._device.gatt.connect();
    this._service = await this._server.getPrimaryService(this._serviceUuid);
    this._txChar = await this._service.getCharacteristic(this._txUuid);

    await this._txChar.startNotifications();
    this._txChar.addEventListener("characteristicvaluechanged", this._onCharChanged);
  }

  async disconnect() {
    try {
      console.trace("Disconnecting BluetoothTransport...");
      if (this._txChar) {
        this._txChar.removeEventListener("characteristicvaluechanged", this._onCharChanged);
        // stopNotifications() exists but can throw on some stacks; best-effort
        try { await this._txChar.stopNotifications(); } catch {}
      }
    } finally {
      if (this._device?.gatt?.connected) {
        console.log("Closing GATT connection...");
        this._device.gatt.disconnect();
        console.log("GATT disconnected.");
      }
      this._device = this._server = this._service = this._txChar = null;
    }
  }

  isConnected() {
    return !!(this._device?.gatt?.connected);
  }

  // HandshakeStream hook
  async _write(bytes) {
    if (!this._txChar) throw new Error("BLE not connected");
    // Prefer writeValueWithoutResponse where available (matches python response=False)
    if (this._txChar.writeValueWithoutResponse) {
      await this._txChar.writeValueWithoutResponse(bytes);
    } else {
      await this._txChar.writeValue(bytes);
    }
  }

  // Convenience API similar to python Transport.send_command
  async sendCommand(line, { timeoutMs = 60000, addNewline = false, disconnect = true } = {}) {
    console.log("options: ", { timeoutMs, addNewline, disconnect });
    await this.connect();
    try {
      console.log("Sending command:", line);
      const payload = encodeUtf8(addNewline ? (line.endsWith("\n") ? line : line + "\n") : line);
      await this.sendDataPackage(payload);
      console.log("Waiting for response...");

      const respBytes = await this.waitDataPackage({ timeoutMs });
      console.log("Received response.");
      return decodeUtf8(respBytes);
    } finally {
      if (disconnect) { 
        console.log("Disconnecting...");
        await this.disconnect();
      }
    }
  }
}

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------
function concatU8(a, b) {
  if (!a?.length) return b;
  if (!b?.length) return a;
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

function startsWithAscii(u8, s) {
  if (u8.length < s.length) return false;
  for (let i = 0; i < s.length; i++) {
    if (u8[i] !== s.charCodeAt(i)) return false;
  }
  return true;
}

function writeU32LE(u8, off, n) {
  u8[off + 0] = (n >>> 0) & 0xff;
  u8[off + 1] = (n >>> 8) & 0xff;
  u8[off + 2] = (n >>> 16) & 0xff;
  u8[off + 3] = (n >>> 24) & 0xff;
}

function readU32LE(u8, off) {
  return (
    (u8[off + 0] |
      (u8[off + 1] << 8) |
      (u8[off + 2] << 16) |
      (u8[off + 3] << 24)) >>> 0
  );
}

function encodeAscii(s) {
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i) & 0x7f;
  return out;
}

function encodeUtf8(s) {
  return new TextEncoder().encode(s);
}

function decodeUtf8(u8) {
  return new TextDecoder("utf-8", { fatal: false }).decode(u8);
}
