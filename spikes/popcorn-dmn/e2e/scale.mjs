// End-to-end check against `mix popcorn.dev` (http://localhost:4000) driven by Playwright and Chrome.
// Run: PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core OUT=/tmp node e2e/scale.mjs
import { createRequire } from "node:module";
import fs from "node:fs";
const require = createRequire(`${process.env.PLAYWRIGHT_CORE}/`);
const OUT = process.env.OUT ?? ".";
const { chromium } = require("playwright-core");
// 400 nodes is about 130 KB: over the 64 KiB limit of one JS->VM message, so import must chunk
const N_IN = Number(process.env.N_IN || 100),
  N_DEC = Number(process.env.N_DEC || 300);
// multi-byte text (accents, a surrogate pair) in every element, so chunk boundaries fall inside such characters
const NOTE = "<description>naïve café 😀 日本語</description>";
// ---- generate a big DMN (no DMNDI, so import must lay everything out)
let seed = 7;
const rnd = (n) => {
  seed = (seed * 16807) % 2147483647;
  return seed % n;
};
const names = [];
let body = "";
for (let i = 0; i < N_IN; i++) {
  names.push(`N${i}`);
  body += `<inputData id="n${i}" name="N${i}">${NOTE}<variable name="N${i}" typeRef="number"/><extensionElements><spike:value>${i + 1}</spike:value></extensionElements></inputData>\n`;
}
for (let i = 0; i < N_DEC; i++) {
  const id = N_IN + i,
    a = rnd(id),
    b = rnd(id);
  const reqs = [...new Set([a, b])];
  body +=
    `<decision id="n${id}" name="N${id}">${NOTE}<variable name="N${id}" typeRef="number"/>` +
    reqs
      .map(
        (r) =>
          `<informationRequirement><${r < N_IN ? "requiredInput" : "requiredDecision"} href="#n${r}"/></informationRequirement>`
      )
      .join("") +
    `<literalExpression><text>${reqs.map((r) => `N${r}`).join(" + ")} + 1</text></literalExpression></decision>\n`;
}
const xml = `<?xml version="1.0"?><definitions xmlns="https://www.omg.org/spec/DMN/20240513/MODEL/" xmlns:spike="urn:popcorn-dmn-spike" id="big" name="Big" namespace="x">\n${body}</definitions>`;
fs.writeFileSync(`${OUT}/big.dmn`, xml);
console.log(`generated ${N_IN + N_DEC} nodes, ${(xml.length / 1024).toFixed(0)} KB`);

const browser = await chromium.launch({ channel: "chrome", headless: true });
const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });
const logs = [];
page.on("console", (m) => {
  if (!m.text().includes("404")) logs.push(m.text().slice(0, 200));
});
page.on("pageerror", (e) => logs.push("ERR " + e.message.slice(0, 200)));
await page.goto("http://localhost:4000");
await page.waitForFunction(() => document.querySelector("#panel table"), null, { timeout: 90000 });

let t = Date.now();
await page.locator("#file").setInputFiles(`${OUT}/big.dmn`);
await page.waitForFunction((n) => document.querySelectorAll("#scene g[data-id]").length === n, N_IN + N_DEC, {
  timeout: 180000,
});
console.log(
  `import + auto-layout + render: ${Date.now() - t} ms  | ${await page
    .locator("#report")
    .textContent()
    .then((s) => s.slice(0, 110))}`
);
console.log("status:", await page.locator("#status").textContent());
console.log("edges:", await page.locator("#scene line.vis").count());

// select latency
const ids = await page.locator("#scene g[data-id]").evaluateAll((els) => els.map((e) => e.dataset.id));
const pick = ids[N_IN + 50];
t = Date.now();
await page.locator(`#scene [data-id="${pick}"] .shape`).click({ force: true });
await page.waitForFunction((id) => document.querySelector(".nname")?.value === id.replace("n", "N"), pick, {
  timeout: 60000,
});
console.log(`select a node (panel swap): ${Date.now() - t} ms`);

// drag latency
const b = await page.locator(`#scene [data-id="${pick}"] .shape`).boundingBox();
await page.mouse.move(b.x + b.width / 2, b.y + b.height / 2);
await page.mouse.down();
t = Date.now();
const steps = 30;
for (let i = 1; i <= steps; i++) await page.mouse.move(b.x + b.width / 2 + i * 3, b.y + b.height / 2 + i * 2);
await page.mouse.up();
await page.waitForFunction(() => true);
await page.waitForTimeout(300);
console.log(
  `drag: ${steps} moves in ${Date.now() - t - 300} ms => ~${Math.round((Date.now() - t - 300) / steps)} ms/move (driver-side; includes waiting for Elixir)`
);

// edit latency: change an input value; everything downstream re-evaluates
// the inspector floats over the canvas: close it and fit the view so that the input to edit is not under anything
await page.keyboard.press("Escape");
await page.locator('[data-click="fit"]').click();
await page.waitForTimeout(500);
// an input node whose centre is not covered by a neighbour's hover pad (a forced click would hit that instead)
const target = await page.evaluate(() => {
  for (const shape of document.querySelectorAll("#scene g[data-id] .shape.input")) {
    const r = shape.getBoundingClientRect();
    const top = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
    const id = shape.closest("[data-id]").dataset.id;
    if (top?.closest("[data-id]")?.dataset.id === id) return id;
  }
  return null;
});
if (!target) throw new Error("no input node is reachable at the fitted zoom");
await page.locator(`#scene [data-id="${target}"] .shape`).click({ force: true });
await page.waitForFunction((id) => document.querySelector(`textarea[data-cell="${id}:0"]`), target, { timeout: 60000 });
// the status line still shows the evaluation of an earlier operation, so wait for the result of this one:
// the badge of the edited node changes to the new value only after the edit has been evaluated
t = Date.now();
await page.locator(`textarea[data-cell="${target}:0"]`).fill("100");
await page.waitForFunction((id) => document.querySelector(`#nv-${id}`)?.textContent === "100", target, {
  timeout: 120000,
});
console.log(`edit a cell (re-evaluate all): ${Date.now() - t} ms | ${await page.locator("#status").textContent()}`);

// layout latency
// layout re-renders the whole scene, so mark a node and wait until that very element has been replaced
await page.evaluate(() => (document.querySelector("#scene g[data-id]").dataset.marker = "1"));
t = Date.now();
await page.locator('[data-click="layout"]').click();
await page.waitForFunction(() => !document.querySelector("#scene g[data-id]")?.dataset.marker, null, {
  timeout: 120000,
});
console.log(`auto-layout click -> scene replaced: ${Date.now() - t} ms`);
console.log(logs.filter((l) => !l.startsWith("popcorn")).join("\n"));
await browser.close();
