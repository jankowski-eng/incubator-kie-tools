// Layout and on-canvas affordances against `mix popcorn.dev` (http://localhost:4000).
// Run: PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core OUT=/tmp node e2e/workspace.mjs
import { createRequire } from "node:module";
const require = createRequire(`${process.env.PLAYWRIGHT_CORE}/`);
const OUT = process.env.OUT ?? ".";
const { chromium } = require("playwright-core");
const FIXTURE = new URL("../test/fixtures/kie_sample.dmn", import.meta.url).pathname;
const browser = await chromium.launch({ channel: "chrome", headless: true });
const page = await (await browser.newContext({ viewport: { width: 1280, height: 720 } })).newPage();
let fails = 0;
const ok = (name, cond, extra = "") => {
  if (!cond) fails++;
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}${extra ? "  — " + extra : ""}`);
};
const settle = (ms = 400) => page.waitForTimeout(ms);
const count = (sel) => page.locator(sel).count();

await page.goto("http://localhost:4000");
await page.waitForFunction(
  () => document.querySelector("#scene")?.children.length > 0 && document.querySelector("#panel table"),
  null,
  { timeout: 90000 }
);

ok(
  "the app fits the window (no page scroll)",
  (await page.evaluate(() => document.documentElement.scrollHeight)) <= 720
);
const stage = await page.locator(".stage").boundingBox();
const panel = await page.locator("#panel table").first().boundingBox();
ok("canvas and the editing table are visible together", stage.y + stage.height < 720 && panel.y < 720, `${panel.y}`);

// selecting a node shows its expression in the dock without scrolling
await page.locator('#scene g[data-id="risk"]').click();
await settle();
ok("selecting a node shows its table in view", (await page.locator("table.dt").first().boundingBox()).y < 720);

// splitter resizes the dock and remembers it
const dock0 = (await page.locator(".dock").boundingBox()).height;
const sp = await page.locator("#splitter").boundingBox();
await page.mouse.move(sp.x + sp.width / 2, sp.y + 7);
await page.mouse.down();
await page.mouse.move(sp.x + sp.width / 2, sp.y - 120, { steps: 5 });
await page.mouse.up();
const dock1 = (await page.locator(".dock").boundingBox()).height;
ok("dragging the splitter enlarges the dock", dock1 > dock0 + 80, `${dock0} -> ${dock1}`);
await page.reload();
await page.waitForFunction(() => document.querySelector("#panel table"), null, { timeout: 90000 });
ok("dock height survives a reload", Math.abs((await page.locator(".dock").boundingBox()).height - dock1) < 3);

// help popover
await page.locator("#help-btn").click();
ok("help popover opens", await page.locator("#help").isVisible());
await page.keyboard.press("Escape");
ok("Escape closes it", await page.locator("#help").isHidden());

// rename by double-click and F2
await page.locator('#scene g[data-id="front"]').dblclick();
await settle(800);
ok(
  "double-click focuses the name field",
  await page.evaluate(() => document.activeElement?.classList.contains("nname")),
  await page.evaluate(() => document.activeElement?.outerHTML.slice(0, 80))
);
await page.locator("#drd").click({ position: { x: 5, y: 200 } });
await page.locator('#scene g[data-id="front"]').click();
await settle();
await page.evaluate(() => document.activeElement?.blur());
await page.keyboard.press("F2");
ok("F2 focuses the name field", await page.evaluate(() => document.activeElement?.classList.contains("nname")));
await page.evaluate(() => document.activeElement?.blur());

// delete badge
const n0 = await count("#scene g[data-id]");
await page.locator('#scene g[data-id="front"] .del').click();
await settle(600);
ok("the × badge deletes the selected node", (await count("#scene g[data-id]")) === n0 - 1);
await page.locator("[data-click=undo]").click();
await settle(600);
ok("undo brings it back", (await count("#scene g[data-id]")) === n0);

// Enter moves down a decision-table column
await page.locator('#scene g[data-id="risk"]').click();
await settle();
const cells = page.locator('table.dt tbody textarea[data-op="dtcell"]');
await cells.first().focus();
const col = await page.evaluate(() => document.activeElement.closest("td")?.cellIndex);
await page.keyboard.press("Enter");
const moved = await page.evaluate(() => {
  const a = document.activeElement;
  return { col: a.closest("td")?.cellIndex, row: a.closest("tr")?.rowIndex };
});
ok("Enter goes to the same column one row down", moved.col === col && moved.row > 1, JSON.stringify(moved));
await page.keyboard.press("Shift+Enter");
ok("Shift+Enter goes back up", (await page.evaluate(() => document.activeElement.closest("tr").rowIndex)) < moved.row);

// compact import summary
await page.locator("#file").setInputFiles(FIXTURE);
await settle(900);
const rep = await page.locator("#report").boundingBox();
ok("import summary is compact", rep.height < 80, `${rep.height}`);
ok("details are collapsed", (await page.locator("#report details").getAttribute("open")) === null);
await page.locator("#report details summary").click();
ok("details open on demand", await page.locator("#report ul.dropped").first().isVisible());
await page.locator("#report .x").click();
await settle();
ok("the summary can be dismissed", (await page.locator("#report").innerHTML()) === "");

// unconnected values show a dash, not "null"
await page.screenshot({ path: `${OUT}/ws1.png` });
await page.evaluate(() => document.activeElement?.blur());

console.log(`\n${fails === 0 ? "ALL PASSED" : fails + " FAILED"}`);
await browser.close();
