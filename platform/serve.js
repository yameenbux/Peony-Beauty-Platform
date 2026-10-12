/* The built site, served the way Render serves it, on a port nobody else is
 * using.
 *
 * The browser tests used to open these pages as file:// URLs. That cannot see
 * the two things most likely to be wrong: an absolute path, and the catch-all
 * rewrite that puts the booking page at /her-name. A relative link that works
 * from /book/index.html and breaks from /studio-mila has already shipped once,
 * and no file:// test could ever have caught it.
 *
 * The resolution order below is Render's, and the order matters: a real file
 * always wins, so the rewrite can never shadow /app/, /site/ or an asset.
 *
 *   const { start } = require("./serve");
 *   const srv = await start();        // srv.origin -> http://127.0.0.1:<port>
 *   ...
 *   await srv.close();
 */
const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.join(__dirname, "..", "dist");
const TYPES = {
  ".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8",
  ".js": "application/javascript; charset=utf-8", ".json": "application/json",
  ".webmanifest": "application/manifest+json", ".svg": "image/svg+xml",
  ".png": "image/png", ".ico": "image/x-icon", ".woff2": "font/woff2",
  ".xml": "application/xml", ".txt": "text/plain; charset=utf-8",
};

function resolve(urlPath) {
  const clean = decodeURIComponent(urlPath.split("?")[0].split("#")[0]);
  const full = path.join(ROOT, clean.replace(/^\/+/, ""));
  /* Outside the build: a traversal attempt, or a bug. Neither gets a file. */
  if (!full.startsWith(ROOT)) return null;
  if (fs.existsSync(full) && fs.statSync(full).isFile()) return full;        // a real file wins
  const idx = path.join(full, "index.html");
  if (fs.existsSync(idx)) return idx;                                        // then a directory
  if (clean === "/") return path.join(ROOT, "index.html");
  return path.join(ROOT, "book", "index.html");                              // then the rewrite
}

function start() {
  return new Promise((resolve_) => {
    const srv = http.createServer((req, res) => {
      const f = resolve(req.url);
      if (!f || !fs.existsSync(f)) { res.writeHead(404); return res.end("not found"); }
      res.writeHead(200, { "content-type": TYPES[path.extname(f)] || "application/octet-stream" });
      res.end(fs.readFileSync(f));
    });
    srv.listen(0, "127.0.0.1", () => {
      const port = srv.address().port;
      resolve_({
        port,
        origin: "http://127.0.0.1:" + port,
        close: () => new Promise((r) => srv.close(r)),
      });
    });
  });
}

module.exports = { start, ROOT };
