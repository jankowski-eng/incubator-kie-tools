// End-to-end check against `mix popcorn.dev` (http://localhost:4000) driven by Playwright and Chrome.
// Run: PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core OUT=/tmp node e2e/drag-latency.mjs
import { createRequire } from "node:module";
const require = createRequire(`${process.env.PLAYWRIGHT_CORE}/`);
const OUT = process.env.OUT ?? ".";
const { chromium } = require("playwright-core");
const file = process.argv[2],
  label = process.argv[3];
const browser = await chromium.launch({ channel: "chrome", headless: true });
const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });
await page.goto("http://localhost:4000");
await page.waitForFunction(() => document.querySelector("#panel table"), null, { timeout: 90000 });
if (file !== "sample") {
  await page.locator("#file").setInputFiles(file);
  await page.waitForFunction(() => document.querySelectorAll("#scene g[data-id]").length > 20, null, {
    timeout: 200000,
  });
}
const id = await page.locator("#scene g[data-id]").nth(20).getAttribute("data-id");
const node = page.locator(`#scene [data-id="${id}"]`);
const tr = () => node.getAttribute("transform");
const b = await node.locator(".shape").boundingBox();
await page.mouse.move(b.x + b.width / 2, b.y + b.height / 2);
await page.mouse.down();
const t0 = Date.now();
const steps = 40;
const start = await tr();
for (let i = 1; i <= steps; i++) await page.mouse.move(b.x + b.width / 2 + i * 2, b.y + b.height / 2 + i);
const driverMs = Date.now() - t0;
await page.mouse.up();
// wait until the transform stops changing for 250 ms
let last = await tr(),
  stable = Date.now();
while (Date.now() - stable < 250) {
  await page.waitForTimeout(15);
  const cur = await tr();
  if (cur !== last) {
    last = cur;
    stable = Date.now();
  }
}
const total = Date.now() - t0 - 250;
console.log(
  `${label}: ${steps} moves | driver finished sending in ${driverMs} ms | node reached its final position after ${total} ms (${(total / steps).toFixed(1)} ms/move end-to-end) | ${start} -> ${last}`
);
await browser.close();
