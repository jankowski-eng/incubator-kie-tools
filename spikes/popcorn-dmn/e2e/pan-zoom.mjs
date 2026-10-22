// End-to-end check against `mix popcorn.dev` (http://localhost:4000) driven by Playwright and Chrome.
// Run: PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core OUT=/tmp node e2e/pan-zoom.mjs
import { createRequire } from "node:module";
const require = createRequire(`${process.env.PLAYWRIGHT_CORE}/`);
const OUT = process.env.OUT ?? ".";
const { chromium } = require("playwright-core");
const browser = await chromium.launch({ channel: "chrome", headless: true });
const page = await browser.newPage({ viewport: { width: 1100, height: 900 } });
const logs = [];
page.on("console", (m) => {
  if (!m.text().includes("404")) logs.push(`[${m.type()}] ${m.text()}`.slice(0, 300));
});
page.on("pageerror", (e) => logs.push(`[pageerror] ${e.message}`.slice(0, 300)));
let fails = 0;
const ok = (name, cond, extra = "") => {
  if (!cond) fails++;
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}${extra ? "  — " + extra : ""}`);
};
const settle = (ms = 350) => page.waitForTimeout(ms);
const vb = async () => (await page.locator("#drd").getAttribute("viewBox")).split(" ").map(Number);

await page.goto("http://localhost:4000");
await page.waitForFunction(
  () => document.querySelector("#scene")?.children.length > 0 && document.querySelector("#panel table"),
  null,
  { timeout: 90000 }
);
const fit = await vb();
ok("starts fitted to the diagram", fit.length === 4 && fit[2] >= 820, fit.join(" "));

// wheel zoom around the pointer keeps the point under it fixed
const box = await page.locator("#drd").boundingBox();
const px = box.x + box.width * 0.25,
  py = box.y + box.height * 0.25;
// the svg keeps the viewBox aspect ratio (xMidYMid meet), so screen px per unit is the smaller of the two scales
const unit = (v) => Math.min(box.width / v[2], box.height / v[3]);
const frac = (v) => [
  (px - box.x - (box.width - unit(v) * v[2]) / 2) / unit(v) + v[0],
  (py - box.y - (box.height - unit(v) * v[3]) / 2) / unit(v) + v[1],
];
const before = frac(fit);
await page.mouse.move(px, py);
for (let i = 0; i < 5; i++) {
  await page.mouse.wheel(0, -120);
  await settle(120);
}
await settle(300);
const zoomed = await vb();
const after = frac(zoomed);
ok("wheel up zooms in", zoomed[2] < fit[2] * 0.7, `${fit[2]} -> ${zoomed[2].toFixed(0)}`);
ok(
  "zoom keeps the point under the cursor fixed",
  Math.abs(after[0] - before[0]) < 3 && Math.abs(after[1] - before[1]) < 3,
  `${before.map((n) => n.toFixed(0))} vs ${after.map((n) => n.toFixed(0))}`
);
await page.mouse.wheel(0, 600);
await settle(400);
ok("wheel down zooms out", (await vb())[2] > zoomed[2]);

// buttons
await page.locator('[data-click="fit"]').click();
await settle(300);
ok("Fit restores the fitted view", (await vb()).join(" ") === fit.join(" "));
await page.locator('[data-click="zoom-in"]').click();
await settle(300);
const zi = await vb();
ok("+ zooms in about the centre", zi[2] < fit[2] && Math.abs(zi[0] + zi[2] / 2 - (fit[0] + fit[2] / 2)) < 2);
await page.locator('[data-click="zoom-out"]').click();
await page.locator('[data-click="zoom-out"]').click();
await settle(300);
ok("− zooms out", (await vb())[2] > fit[2]);
await page.locator('[data-click="fit"]').click();
await settle(300);

// pan: drag on empty canvas moves the view by the dragged distance
await page.locator('[data-click="zoom-in"]').click();
await settle(300);
const z = await vb();
// find a point on the bare background (the svg element itself), away from nodes and edges
const [sx, sy] = await page.evaluate((b) => {
  for (let fy = 0.9; fy > 0.05; fy -= 0.1)
    for (let fx = 0.95; fx > 0.4; fx -= 0.05) {
      const x = b.x + b.width * fx,
        y = b.y + b.height * fy;
      if (document.elementFromPoint(x, y)?.id === "drd") return [x, y];
    }
  return [b.x + 5, b.y + 5];
}, box);
await page.mouse.move(sx, sy);
await page.mouse.down();
for (let i = 1; i <= 10; i++) await page.mouse.move(sx - i * 8, sy - i * 4);
await page.mouse.up();
await settle(400);
const p = await vb();
const perPx = 1 / unit(z);
ok(
  "dragging the background pans",
  Math.abs(p[0] - z[0] - 80 * perPx) < 2 && Math.abs(p[1] - z[1] - 40 * perPx) < 2 && p[2] === z[2],
  `dx=${(p[0] - z[0]).toFixed(1)} (expected ${(80 * perPx).toFixed(1)})`
);

// editing still works when zoomed and panned: a node drag moves by the dragged distance in model units
const visibleId = await page.evaluate(() => {
  const svg = document.querySelector("#drd").getBoundingClientRect();
  for (const g of document.querySelectorAll("#scene g[data-id]")) {
    const r = g.querySelector(".shape").getBoundingClientRect();
    const x = r.x + r.width / 2,
      y = r.y + r.height / 2;
    if (
      x > svg.x + 40 &&
      x < svg.right - 80 &&
      y > svg.y + 40 &&
      y < svg.bottom - 60 &&
      document.elementFromPoint(x, y)?.closest("[data-id]") === g
    )
      return g.dataset.id;
  }
  return null;
});
const g = page.locator(`#scene g[data-id="${visibleId}"]`);
const t0 = (await g.getAttribute("transform")).match(/-?\d+/g).map(Number);
const gb = await g.locator(".shape").boundingBox();
await page.mouse.move(gb.x + gb.width / 2, gb.y + gb.height / 2);
await page.mouse.down();
for (let i = 1; i <= 10; i++) await page.mouse.move(gb.x + gb.width / 2 + i * 5, gb.y + gb.height / 2 + i * 3);
await page.mouse.up();
await settle(500);
const t1 = (await g.getAttribute("transform")).match(/-?\d+/g).map(Number);
ok(
  "node drag is still accurate in a zoomed view",
  Math.abs(t1[0] - t0[0] - 50 * perPx) < 3 && Math.abs(t1[1] - t0[1] - 30 * perPx) < 3,
  `moved ${t1[0] - t0[0]},${t1[1] - t0[1]} model units for 50,30 px (expect ${(50 * perPx).toFixed(1)},${(30 * perPx).toFixed(1)})`
);
ok("view is kept while editing (no snap back to fit)", (await vb())[2] === z[2]);
await page.screenshot({ path: `${OUT}/z1.png` });

console.log(`\n${fails === 0 ? "ALL PASSED" : fails + " FAILED"}`);
console.log(logs.filter((l) => !l.startsWith("[log] popcorn")).join("\n"));
await browser.close();
