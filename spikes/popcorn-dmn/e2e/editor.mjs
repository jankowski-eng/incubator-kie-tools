// End-to-end check against `mix popcorn.dev` (http://localhost:4000) driven by Playwright and Chrome.
// Run: PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core OUT=/tmp node e2e/editor.mjs
import { createRequire } from "node:module";
const require = createRequire(`${process.env.PLAYWRIGHT_CORE}/`);
const OUT = process.env.OUT ?? ".";
const { chromium } = require("playwright-core");
const browser = await chromium.launch({ channel: "chrome", headless: true });
const page = await browser.newPage({ viewport: { width: 940, height: 900 } });
const logs = [];
page.on("console", (m) => {
  if (!m.text().includes("404")) logs.push(`[${m.type()}] ${m.text()}`.slice(0, 300));
});
page.on("pageerror", (e) => logs.push(`[pageerror] ${e.message}`.slice(0, 300)));
const ok = (name, cond, extra = "") => console.log(`${cond ? "PASS" : "FAIL"}  ${name}${extra ? "  — " + extra : ""}`);
const text = (sel) => page.locator(sel).first().textContent();
const settle = (ms = 250) => page.waitForTimeout(ms);

await page.goto("http://localhost:4000");
await page.waitForFunction(
  () => document.querySelector("#scene")?.children.length > 0 && document.querySelector("#panel table"),
  null,
  { timeout: 90000 }
);

ok(
  "renders 8 nodes / 10 edges",
  (await page.locator("#scene g[data-id]").count()) === 8 && (await page.locator("#scene line.vis").count()) === 10
);
ok(
  "filled + open arrowheads",
  (await page.locator('#scene line[marker-end="url(#arrow-fill)"]').count()) === 8 &&
    (await page.locator('#scene line[marker-end="url(#arrow-open)"]').count()) === 2
);
ok("node value badge shows result", (await text("#nv-loan")) === '"Qualified"', await text("#nv-loan"));
ok("table for default selection (Front End Ratio)", (await text("#panel thead th")).includes("Front End Ratio"));
ok("status reports eval time", /evaluated \d+ cells in/.test(await text("#status")), await text("#status"));
await page.screenshot({ path: `${OUT}/s1.png` });

// --- drag: edges follow
const edgeBefore = await page.locator("#edge-2 line.vis").getAttribute("x1"); // front -> back
const g = page.locator('#scene g[data-id="front"]');
const b0 = await g.boundingBox();
await page.mouse.move(b0.x + b0.width / 2, b0.y + b0.height / 2);
await page.mouse.down();
const T = Date.now();
const steps = 30;
for (let i = 1; i <= steps; i++)
  await page.mouse.move(b0.x + b0.width / 2 + (-60 * i) / steps, b0.y + b0.height / 2 + (90 * i) / steps);
await page.mouse.up();
await settle(400);
const dragMs = Date.now() - T;
const b1 = await page.locator('#scene g[data-id="front"]').boundingBox();
const edgeAfter = await page.locator("#edge-2 line.vis").getAttribute("x1");
ok(
  "drag moves node",
  Math.round(b1.x - b0.x) === -60 && Math.round(b1.y - b0.y) === 90,
  `dx=${Math.round(b1.x - b0.x)} dy=${Math.round(b1.y - b0.y)}`
);
ok("edges follow dragged node", edgeBefore !== edgeAfter, `x1 ${edgeBefore} -> ${edgeAfter}`);
console.log(
  `INFO  drag: ${steps} moves in ~${dragMs} ms (incl. 400ms settle) => ~${Math.round((dragMs - 400) / steps)} ms/move`
);
ok("undo enabled after drag", !(await page.locator("[data-click=undo]").isDisabled()));
await page.locator("[data-click=undo]").click();
await settle(500);
const b2 = await page.locator('#scene g[data-id="front"]').boundingBox();
ok(
  "undo restores position",
  Math.round(b2.x - b0.x) === 0 && Math.round(b2.y - b0.y) === 0,
  `dx=${(b2.x - b0.x).toFixed(1)} dy=${(b2.y - b0.y).toFixed(1)} viewBox=${await page.locator("#drd").getAttribute("viewBox")}`
);
ok("redo works", (await page.locator("[data-click=redo]").isDisabled()) === false);
await page.locator("[data-click=redo]").click();
await settle(400);
await page.locator("[data-click=undo]").click();
await settle(400);

// --- table edits update everything
const before = await text("#nv-loan");
const income = page.locator('textarea[data-cell="front:3"]');
await income.fill("Applicant Data.Income / 3");
await settle(500);
ok("editing a cell updates its value", /^\d/.test(await text("#val-front-3")), await text("#val-front-3"));
ok("…and dependent result + node badge", (await text("#nv-loan")) !== before, `${before} -> ${await text("#nv-loan")}`);
ok("…and the front node badge", /^\d/.test(await text("#nv-front")), await text("#nv-front"));
console.log("INFO  " + (await text("#status")));

// --- error highlighting
await income.fill("1 +");
await settle(500);
ok("syntax error underlined", (await page.locator("#hl-front-3 .err").count()) > 0);
ok(
  "error message shown in value column",
  (await page.locator("#val-front-3 .bad").count()) === 1,
  await text("#val-front-3")
);
await income.fill("Applicant Data.Income");
await settle(400);

// --- keyword/string highlighting in Loan expression
await page.locator('#scene g[data-id="loan"]').click();
await settle(400);
ok("selecting node swaps the table", (await text("#panel thead th")).includes("Loan Pre-Qualification"));
ok(
  "keywords highlighted",
  (await page.locator("#hl-loan-0 .k").allTextContents()).includes("if"),
  (await page.locator("#hl-loan-0 .k").allTextContents()).join(",")
);
ok("strings highlighted", (await page.locator("#hl-loan-0 .s").count()) === 2);
ok(
  "numbers/ids/ops highlighted",
  (await page.locator("#hl-loan-0 .id").count()) > 0 && (await page.locator("#hl-loan-0 .op").count()) > 0
);
await page.screenshot({ path: `${OUT}/s2.png` });

// --- autocomplete
const loan = page.locator('textarea[data-cell="loan:0"]');
await loan.fill("");
await settle(300);
await loan.click();
await loan.pressSequentially("if Fro", { delay: 30 });
await settle(500);
const items = await page.locator("#ac-loan-0 li").allTextContents();
ok("autocomplete lists scope names", items.includes("Front End Ratio"), items.join(" | "));
await page.screenshot({ path: `${OUT}/s3.png` });
await loan.press("Tab");
await settle(500);
ok("Tab accepts first suggestion", (await loan.inputValue()) === "if Front End Ratio", await loan.inputValue());
ok("highlight tracks accepted text", (await page.locator("#hl-loan-0").textContent()) === "if Front End Ratio");

// --- model-level undo of typing
await page.locator("[data-click=undo]").click();
await settle(500);
ok(
  "undo reverts typed edits to previous text",
  (await page.locator('textarea[data-cell="loan:0"]').inputValue()).startsWith("if Front End Ratio <= Lender"),
  (await page.locator('textarea[data-cell="loan:0"]').inputValue()).slice(0, 50)
);
console.log(logs.join("\n"));
await browser.close();
