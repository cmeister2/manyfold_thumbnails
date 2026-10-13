import {createServer} from "node:http";
import {createReadStream} from "node:fs";
import {realpath, stat} from "node:fs/promises";
import {resolve, sep, extname} from "node:path";

const root = await realpath(resolve(process.argv[2] || "dist/demo"));
const mount = "/manyfold_thumbnails/";
const port = Number(process.env.THUMBNAILS_DEMO_PORT || 4174);
const types = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8", ".ttf": "font/ttf",
  ".woff": "font/woff", ".woff2": "font/woff2", ".svg": "image/svg+xml",
  ".png": "image/png", ".ico": "image/x-icon", ".txt": "text/plain; charset=utf-8",
  ".md": "text/plain; charset=utf-8",
};

const server = createServer(async (request, response) => {
  try {
    if (!["GET", "HEAD"].includes(request.method)) {
      response.writeHead(405, {Allow: "GET, HEAD"}).end(); return;
    }
    const pathname = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
    if (!pathname.startsWith(mount)) { response.writeHead(404).end(); return; }
    const file = await realpath(resolve(root, pathname.slice(mount.length) || "index.html"));
    if (!file.startsWith(`${root}${sep}`)) { response.writeHead(404).end(); return; }
    const details = await stat(file);
    if (!details.isFile()) { response.writeHead(404).end(); return; }
    response.writeHead(200, {"Content-Type": types[extname(file)] || "application/octet-stream", "Content-Length": details.size});
    if (request.method === "HEAD") response.end();
    else createReadStream(file).pipe(response);
  } catch {
    response.writeHead(404).end();
  }
});

server.listen(port, "127.0.0.1", () => console.log(`Thumbnail demo: http://127.0.0.1:${port}${mount}`));
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => server.close());
