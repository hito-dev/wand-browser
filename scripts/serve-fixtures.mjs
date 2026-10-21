import https from "node:https";
import { readFile, realpath } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = await realpath(fileURLToPath(new URL("../tests/fixtures/", import.meta.url)));
const certificateRoot = new URL("../tests/.certificates/", import.meta.url);
const server = https.createServer({
  key: await readFile(new URL("server.key", certificateRoot)),
  cert: await readFile(new URL("server.pem", certificateRoot))
}, async (request, response) => {
  try {
    const name = decodeURIComponent(new URL(request.url, "https://localhost").pathname);
    const file = await realpath(path.join(root, name === "/" ? "bridge.html" : name));
    if (!file.startsWith(root + path.sep)) throw new Error("Outside fixture root");
    const types = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".json": "application/json" };
    response.writeHead(200, { "Content-Type": types[path.extname(file)] ?? "application/octet-stream", "Cache-Control": "no-store" });
    response.end(await readFile(file));
  } catch {
    response.writeHead(404); response.end("Not found");
  }
});
server.listen(18443, "127.0.0.1", () => console.log("Fixture server: https://localhost:18443/bridge.html"));
