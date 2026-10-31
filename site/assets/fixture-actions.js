
const run = action => async () => { try { await action(); } catch (e) { log(`${e.name}: ${e.message}`); } };
document.querySelector("#text").value = `https://example.com/?r=${String(Math.floor(Math.random() * 10000)).padStart(4, "0")}`;
let reader, abort;
let cameraStream;
let cameraGeneration = 0;
const cameraStart = document.querySelector("#camera-start");
const cameraStop = document.querySelector("#camera-stop");
const cameraPreview = document.querySelector("#camera-preview");

function resetCamera(stream = cameraStream) {
  cameraGeneration += 1;
  stream?.getTracks().forEach(track => track.stop());
  if (!stream || stream === cameraStream) cameraStream = undefined;
  cameraPreview.pause();
  cameraPreview.srcObject = null;
  cameraPreview.hidden = true;
  cameraStart.disabled = false;
  cameraStop.disabled = true;
}

cameraStart.onclick = run(async () => {
  resetCamera();
  const generation = cameraGeneration;
  cameraStart.disabled = true;
  let stream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({ video: true, audio: false });
  } catch (error) {
    resetCamera();
    throw error;
  }
  if (generation !== cameraGeneration) {
    stream.getTracks().forEach(track => track.stop());
    return;
  }
  cameraStream = stream;
  cameraPreview.srcObject = stream;
  cameraPreview.hidden = false;
  cameraStop.disabled = false;
  try {
    await cameraPreview.play();
  } catch (error) {
    resetCamera(stream);
    throw error;
  }
  for (const track of stream.getTracks()) {
    track.addEventListener("ended", () => {
      if (stream === cameraStream && stream.getTracks().every(item => item.readyState === "ended")) resetCamera(stream);
    }, { once: true });
  }
  log(t("cameraActive"));
});

cameraStop.onclick = () => {
  if (!cameraStream) return;
  resetCamera();
  log(t("cameraStopped"));
};

addEventListener("pagehide", () => resetCamera());
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
const scanButton = document.querySelector("#scan");
function stopNFCScan() {
  abort?.abort();
  scanButton.disabled = false;
}
scanButton.onclick = run(async () => {
  if (abort && !abort.signal.aborted) return;
  const controller = new AbortController();
  const scanReader = new NDEFReader();
  reader = scanReader;
  abort = controller;
  scanButton.disabled = true;
  const current = () => abort === controller && !controller.signal.aborted;
  scanReader.onreading = ({ message, serialNumber }) => {
    if (!current()) return;
    try {
      log(t("read", {count: message.records.length, serial: serialNumber || t("unavailable")}));
      for (const record of message.records) {
        log(`${record.recordType}: ${record.recordType === "text" || record.recordType === "url"
          ? new TextDecoder(record.encoding ?? "utf-8").decode(record.data)
          : Array.from(new Uint8Array(record.data.buffer, record.data.byteOffset, record.data.byteLength)).join(",")}`);
      }
    } finally {
      stopNFCScan();
    }
  };
  scanReader.onreadingerror = () => {
    if (!current()) return;
    log(t("readingError"));
    stopNFCScan();
  };
  try {
    await scanReader.scan({ signal: controller.signal });
    if (current()) log(t("active"));
  } catch (error) {
    const intentional = controller.signal.aborted;
    if (abort === controller) stopNFCScan();
    if (!intentional) throw error;
  }
});
document.querySelector("#abort").onclick = stopNFCScan;
addEventListener("pagehide", stopNFCScan);
document.querySelector("#write").onclick = run(async () => {
  await (reader ?? new NDEFReader()).write(document.querySelector("#text").value);
  log(t("written"));
});
document.querySelector("#binary").onclick = run(async () => {
  await (reader ?? new NDEFReader()).write(new Uint8Array([0, 1, 127, 128, 255]));
  log(t("binaryWritten"));
});
