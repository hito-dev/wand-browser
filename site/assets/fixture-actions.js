
const run = action => async () => { try { await action(); } catch (e) { log(`${e.name}: ${e.message}`); } };
let reader, abort;
document.querySelector("#ble").onclick = run(async () => {
  const device = await navigator.bluetooth.requestDevice({
    filters: [{ namePrefix: "hito" }, { namePrefix: "Hito" }],
    optionalServices: ["5cc44b16-070a-11ed-b939-0242ac120002"]
  });
  log(t("selected", {name: device.name}));
  await device.gatt.connect();
  log(t("connected"));
  device.ongattserverdisconnected = () => log(t("disconnected"));
});
document.querySelector("#scan").onclick = run(async () => {
  reader ??= new NDEFReader();
  abort = new AbortController();
  reader.onreading = ({ message, serialNumber }) => {
    log(t("read", {count: message.records.length, serial: serialNumber || t("unavailable")}));
    for (const record of message.records) {
      log(`${record.recordType}: ${record.recordType === "text" || record.recordType === "url"
        ? new TextDecoder(record.encoding ?? "utf-8").decode(record.data)
        : Array.from(new Uint8Array(record.data.buffer)).join(",")}`);
    }
  };
  reader.onreadingerror = () => log(t("readingError"));
  await reader.scan({ signal: abort.signal });
  log(t("active"));
});
document.querySelector("#abort").onclick = () => abort?.abort();
document.querySelector("#write").onclick = run(async () => {
  await (reader ?? new NDEFReader()).write(document.querySelector("#text").value);
  log(t("written"));
});
document.querySelector("#binary").onclick = run(async () => {
  await (reader ?? new NDEFReader()).write(new Uint8Array([0, 1, 127, 128, 255]));
  log(t("binaryWritten"));
});
