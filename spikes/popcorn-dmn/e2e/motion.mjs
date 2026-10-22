// End-to-end check against `mix popcorn.dev` (http://localhost:4000) driven by Playwright and Chrome.
// Run: PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core OUT=/tmp node e2e/motion.mjs
// Samples a value on every animation frame while something is opened or closed, and checks that it moves through
// intermediate values instead of jumping.
import { createRequire } from "node:module";
const require = createRequire(`${process.env.PLAYWRIGHT_CORE}/`);
const { chromium } = require("playwright-core");
const browser = await chromium.launch({ channel: "chrome", headless: true });
let fails = 0;
const ok = (name, cond, extra = "") => {
  if (!cond) fails++;
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}${extra ? "  — " + extra : ""}`);
};

const open = async (reduced) => {
  const ctx = await browser.newContext({ viewport: { width: 1400, height: 800 }, reducedMotion: reduced ? "reduce" : "no-preference" });
  const page = await ctx.newPage();
  await page.goto("http://localhost:4000");
  await page.waitForFunction(() => document.querySelector("#scene")?.children.length > 0, null, { timeout: 90000 });
  await page.keyboard.press("Escape");
  await page.waitForTimeout(700);
  return page;
};

// records `read()` every frame for 900 ms, runs `act` right after the recorder starts, returns the samples
const record = async (page, read, act) => {
  await page.evaluate((src) => {
    const read = new Function(`return (${src})()`);
    window.__s = [];
    const t0 = performance.now();
    const f = () => {
      window.__s.push(+read());
      if (performance.now() - t0 < 900) requestAnimationFrame(f);
    };
    f();
  }, read.toString());
  await act();
  await page.waitForTimeout(1000);
  return page.evaluate(() => window.__s);
};
// how many frames are strictly between the first and last distinct values, and does it only go one way
const analyse = (s) => {
  const lo = Math.min(s[0], s.at(-1)), hi = Math.max(s[0], s.at(-1));
  const between = s.filter((v) => v > lo + (hi - lo) * 0.03 && v < hi - (hi - lo) * 0.03).length;
  const up = s.at(-1) > s[0];
  const mono = s.every((v, i) => i === 0 || (up ? v >= s[i - 1] - 0.5 : v <= s[i - 1] + 0.5));
  return { between, mono, from: Math.round(s[0]), to: Math.round(s.at(-1)) };
};

let page = await open(false);
const width = (sel) => `() => document.querySelector("${sel}").getBoundingClientRect().width`;

// ---- XML pane
let s = await record(page, width("#xmlpane"), () => page.locator(".xmlbtn").click());
let a = analyse(s);
ok("the XML pane grows into place", a.between >= 4 && a.mono && a.to > 400, JSON.stringify(a));
s = await record(page, width("#xmlpane"), () => page.locator(".xmlbtn").click());
a = analyse(s);
ok("and shrinks away when closed", a.between >= 4 && a.mono && a.to <= 1, JSON.stringify(a));
ok("closed it cannot be reached by keyboard or pointer", (await page.locator("#xmlpane").evaluate((e) => getComputedStyle(e).visibility)) === "hidden");

// ---- expanding the pane
await page.locator(".xmlbtn").click();
await page.waitForTimeout(700);
s = await record(page, width("#xmlpane"), () => page.locator("#xexpand").click());
a = analyse(s);
ok("expanding glides to the full width", a.between >= 4 && a.mono && a.to >= 1390, JSON.stringify(a));
await page.locator("#xexpand").click();
await page.waitForTimeout(700);
await page.locator(".xmlbtn").click();
await page.waitForTimeout(700);

// ---- Data types properties
await page.locator('[data-click="tab:types"]').click();
await page.waitForTimeout(500);
s = await record(page, width("#tinspector"), () => page.locator("#trow-0-0").click());
a = analyse(s);
ok("the properties slide in when a row is selected", a.between >= 3 && a.mono && a.to > 250, JSON.stringify(a));
s = await record(page, width("#tinspector"), () => page.locator('#tinspector [data-click="tinsp-toggle"]').click());
a = analyse(s);
ok("and slide out when closed", a.between >= 3 && a.mono && a.to <= 1, JSON.stringify(a));
await page.locator('[data-click="tab:editor"]').click();
await page.waitForTimeout(500);

// ---- the expression panel
s = await record(page, () => document.querySelector("#dock").getBoundingClientRect().height ? +getComputedStyle(document.querySelector("#dock")).opacity * 100 : 0, () => page.locator('#scene [data-id="front"] .shape').click());
a = analyse(s);
ok("selecting a node fades the panel in", a.between >= 3 && a.to === 100, JSON.stringify(a));
s = await record(page, () => document.querySelector("#panel").children.length ? +getComputedStyle(document.querySelector("#dock")).opacity * 100 : 0, () => page.keyboard.press("Escape"));
a = analyse(s);
ok("closing it fades it out before it is removed", a.between >= 3 && a.to === 0, JSON.stringify(a));
ok("and the panel is really empty afterwards", (await page.locator("#panel").innerText()).trim() === "");

// ---- switching to another node swaps the content with a fade, without hiding the panel
await page.locator('#scene [data-id="loan"] .shape').click();
await page.waitForTimeout(500);
s = await record(page, () => Math.min(...[...document.querySelectorAll("#panel > *")].map((e) => +getComputedStyle(e).opacity * 100)), () => page.locator('#scene [data-id="back"] .shape').click());
ok("another node swaps the content with a short fade", Math.min(...s) < 100 && s.at(-1) === 100, `min ${Math.round(Math.min(...s))}`);

// ---- the camera
const vb = `() => +document.querySelector("#drd").getAttribute("viewBox").split(" ")[2]`;
s = await record(page, vb, () => page.locator('[data-click="zoom-in"]').click());
a = analyse(s);
ok("zoom buttons glide", a.between >= 3 && a.mono, JSON.stringify(a));
s = await record(page, vb, () => page.locator('[data-click="fit"]').click());
a = analyse(s);
ok("so does Fit", a.between >= 3 && a.mono, JSON.stringify(a));
const before = await page.evaluate(() => document.querySelector("#drd").getAttribute("viewBox"));
await page.locator("#drd").hover();
await page.mouse.wheel(0, -120);
await page.waitForTimeout(150);
ok("the wheel is immediate (no lag behind the gesture)", (await page.evaluate(() => document.querySelector("#drd").getAttribute("viewBox"))) !== before);
await page.context().close();

// ---- reduced motion: the same actions apply at once
page = await open(true);
s = await record(page, width("#xmlpane"), () => page.locator(".xmlbtn").click());
a = analyse(s);
ok("with prefers-reduced-motion the pane opens without gliding", a.between <= 1 && a.to > 400, JSON.stringify(a));
s = await record(page, vb, () => page.locator('[data-click="zoom-in"]').click());
a = analyse(s);
ok("and the zoom buttons jump", a.between <= 1, JSON.stringify(a));
await page.context().close();

console.log(`\n${fails === 0 ? "ALL PASSED" : fails + " FAILED"}`);
await browser.close();
process.exit(fails ? 1 : 0);
