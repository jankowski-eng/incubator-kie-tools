// Serves the built spike (../public, run `mix popcorn.dev` or `mix popcorn.cook` first) under several header
// combinations, plus host pages that embed it, to find out where Popcorn can and cannot run.
// Apps live on http://localhost:410x, hosts on http://127.0.0.1:411x, so every embed is cross-site.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";

const PUBLIC = path.resolve(new URL("../public/", import.meta.url).pathname);
const TYPES = {
  ".html": "text/html",
  ".mjs": "text/javascript",
  ".js": "text/javascript",
  ".wasm": "application/wasm",
  ".json": "application/json",
  ".tar": "application/x-tar",
  ".css": "text/css",
};

const ISOLATE = { "Cross-Origin-Opener-Policy": "same-origin", "Cross-Origin-Embedder-Policy": "require-corp" };
const CORP = { "Cross-Origin-Resource-Policy": "cross-origin" };

export const APPS = {
  4101: { name: "app: isolated + CORP", headers: { ...ISOLATE, ...CORP } },
  4102: { name: "app: isolated, no CORP", headers: { ...ISOLATE } },
  4103: { name: "app: plain (no headers)", headers: {} },
  4104: {
    name: "app: credentialless + CORP",
    headers: { "Cross-Origin-Opener-Policy": "same-origin", "Cross-Origin-Embedder-Policy": "credentialless", ...CORP },
  },
};
export const HOSTS = {
  4110: { name: "host: plain", headers: {} },
  4111: { name: "host: COEP require-corp", headers: { ...ISOLATE } },
  4112: {
    name: "host: COEP credentialless",
    headers: { "Cross-Origin-Opener-Policy": "same-origin", "Cross-Origin-Embedder-Policy": "credentialless" },
  },
  4113: {
    name: "host: COEP require-corp, COOP same-origin-allow-popups",
    headers: {
      "Cross-Origin-Opener-Policy": "same-origin-allow-popups",
      "Cross-Origin-Embedder-Policy": "require-corp",
    },
  },
};

function serve(port, spec, handler) {
  http
    .createServer((req, res) => {
      const url = new URL(req.url, "http://x");
      for (const [k, v] of Object.entries(spec.headers)) res.setHeader(k, v);
      res.setHeader("Cache-Control", "no-store");
      if (handler && handler(req, res, url)) return;
      let p = decodeURIComponent(url.pathname);
      if (p === "/") p = "/index.html";
      const file = path.join(PUBLIC, p);
      if (!file.startsWith(PUBLIC) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
        res.writeHead(404);
        return res.end("not found");
      }
      res.writeHead(200, { "Content-Type": TYPES[path.extname(file)] ?? "application/octet-stream" });
      fs.createReadStream(file).pipe(res);
    })
    .listen(port, "127.0.0.1");
}

// a page that embeds an app in an iframe; ?src=<url>&allow=<permissions policy>
const embedPage = (req, res, url) => {
  if (url.pathname !== "/embed") return false;
  const src = url.searchParams.get("src");
  const allow = url.searchParams.get("allow");
  res.writeHead(200, { "Content-Type": "text/html" });
  res.end(
    `<!doctype html><title>host</title><body style="margin:0"><iframe id="app" src="${src}" ${allow ? `allow="${allow}"` : ""} style="width:100%;height:700px;border:0"></iframe>`
  );
  return true;
};
// a page that opens the app in a popup and reports what the opener can still see
const popupPage = (req, res, url) => {
  if (url.pathname !== "/popup") return false;
  res.writeHead(200, { "Content-Type": "text/html" });
  res.end(`<!doctype html><title>host</title><button id="open">open</button><script>
    window.result = null;
    document.getElementById('open').onclick = () => {
      const w = window.open(${JSON.stringify(url.searchParams.get("src"))}, 'app');
      window.w = w;
      setTimeout(() => { window.result = { closedAfter3s: w.closed }; }, 3000);
    };</script>`);
  return true;
};

for (const [port, spec] of Object.entries(APPS)) serve(Number(port), spec, embedPage);
for (const [port, spec] of Object.entries(HOSTS))
  serve(Number(port), spec, (q, r, u) => embedPage(q, r, u) || popupPage(q, r, u));
console.log("embedding servers up:", Object.keys(APPS).concat(Object.keys(HOSTS)).join(", "));
