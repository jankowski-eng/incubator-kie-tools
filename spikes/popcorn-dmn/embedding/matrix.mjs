// Runs the embedding scenarios in Chrome and prints a table.
// Run: node embedding/server.mjs &  then  PLAYWRIGHT_CORE=/path/to/playwright-core node embedding/matrix.mjs
import { createRequire } from "node:module";
const require = createRequire(`${process.env.PLAYWRIGHT_CORE}/`);
const { chromium } = require("playwright-core");

const app = (p) => `http://localhost:${p}/`;
const host = (p, src, allow) =>
  `http://127.0.0.1:${p}/embed?src=${encodeURIComponent(src)}${allow ? `&allow=${encodeURIComponent(allow)}` : ""}`;
const ALLOW = "cross-origin-isolated";

const scenarios = [
  { name: "standalone page (control)", url: app(4101), frameOf: "top" },
  {
    name: "same-origin iframe, parent isolated",
    url: `http://localhost:4101/embed?src=${encodeURIComponent("/")}`,
    frameOf: 4101,
  },
  { name: "cross-site iframe, host has NO isolation headers", url: host(4110, app(4101), ALLOW), frameOf: 4101 },
  { name: "cross-site iframe, host plain, app plain", url: host(4110, app(4103)), frameOf: 4103 },
  { name: "host require-corp + app isolated/CORP, no allow attr", url: host(4111, app(4101)), frameOf: 4101 },
  {
    name: "host require-corp + app isolated/CORP, allow=cross-origin-isolated",
    url: host(4111, app(4101), ALLOW),
    frameOf: 4101,
  },
  { name: "host require-corp + app isolated but NO CORP", url: host(4111, app(4102), ALLOW), frameOf: 4102 },
  { name: "host require-corp + plain app", url: host(4111, app(4103), ALLOW), frameOf: 4103 },
  { name: "host credentialless + app credentialless/CORP", url: host(4112, app(4104), ALLOW), frameOf: 4104 },
  { name: "host credentialless + app isolated/CORP (require-corp)", url: host(4112, app(4101), ALLOW), frameOf: 4101 },
  {
    name: "host require-corp + COOP same-origin-allow-popups + app isolated",
    url: host(4113, app(4101), ALLOW),
    frameOf: 4101,
  },
];

const browser = await chromium.launch({ channel: "chrome", headless: true });
const rows = [];
for (const s of scenarios) {
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  const problems = [];
  page.on("requestfailed", (r) =>
    problems.push(`${r.failure()?.errorText ?? "failed"} ${new URL(r.url()).pathname}`.slice(0, 80))
  );
  page.on("console", (m) => {
    if (m.type() === "error" && /blocked|COEP|CORP|Cross-Origin/i.test(m.text())) problems.push(m.text().slice(0, 90));
  });
  await page.goto(s.url).catch(() => {});
  let frame = null,
    state = "no frame";
  const deadline = Date.now() + 25000;
  while (Date.now() < deadline) {
    frame =
      s.frameOf === "top"
        ? page.mainFrame()
        : page
            .frames()
            .find((f) => f !== page.mainFrame() && new URL(f.url() || "http://x").port === String(s.frameOf));
    if (frame) {
      const r = await frame
        .evaluate(() => ({
          iso: self.crossOriginIsolated,
          sab: typeof SharedArrayBuffer,
          popcorn: document.documentElement.dataset.popcorn ?? null,
        }))
        .catch(() => null);
      if (r) {
        state = r;
        if (r.popcorn) break;
      }
    }
    await page.waitForTimeout(400);
  }
  rows.push({
    scenario: s.name,
    isolated: state.iso ?? "-",
    SAB: state.sab ?? "-",
    result: state.popcorn ?? (state === "no frame" ? "iframe did not load" : "never booted"),
    message: state.popcorn === "unsupported" ? "shows the header hint" : "",
    problems: [...new Set(problems)].slice(0, 2).join(" | "),
  });
  await ctx.close();
}

// popup: what can the opener still do once the app (COOP same-origin) is in another browsing context group?
{
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  await page.goto(`http://127.0.0.1:4110/popup?src=${encodeURIComponent(app(4101))}`);
  const [popup] = await Promise.all([ctx.waitForEvent("page"), page.click("#open")]);
  await popup.waitForFunction(() => document.documentElement.dataset.popcorn, null, { timeout: 25000 }).catch(() => {});
  const inPopup = await popup
    .evaluate(() => ({
      opener: window.opener === null ? "null (severed)" : "present",
      iso: self.crossOriginIsolated,
      popcorn: document.documentElement.dataset.popcorn,
    }))
    .catch(() => ({}));
  await page.waitForTimeout(3500);
  const seenByOpener = await page.evaluate(() => window.result);
  rows.push({
    scenario: "popup from a plain host (window.open)",
    isolated: inPopup.iso ?? "-",
    SAB: "-",
    result: inPopup.popcorn ?? "never booted",
    problems: `popup.opener ${inPopup.opener}; opener sees popup.closed=${seenByOpener?.closedAfter3s}`,
  });
  await ctx.close();
}
await browser.close();
console.table(rows);
