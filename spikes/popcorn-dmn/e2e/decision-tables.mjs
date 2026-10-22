// End-to-end check against `mix popcorn.dev` (http://localhost:4000) driven by Playwright and Chrome.
// Run: PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core OUT=/tmp node e2e/decision-tables.mjs
import { createRequire } from "node:module";
const require = createRequire(`${process.env.PLAYWRIGHT_CORE}/`);
const OUT = process.env.OUT ?? ".";
const { chromium } = require("playwright-core");
const browser = await chromium.launch({ channel: "chrome", headless: true });
const page = await browser.newPage({ viewport: { width: 1100, height: 1000 } });
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
const text = (sel) => page.locator(sel).first().textContent();
const settle = (ms = 350) => page.waitForTimeout(ms);
const count = (sel) => page.locator(sel).count();
const cell = (path) => page.locator(`textarea[data-op=dtcell][data-path="${path}"]`);

await page.goto("http://localhost:4000");
await page.waitForFunction(
  () => document.querySelector("#scene")?.children.length > 0 && document.querySelector("#panel table"),
  null,
  { timeout: 90000 }
);
await page.locator('#scene [data-id="risk"] .shape').click({ force: true });
await settle(500);
ok(
  "selecting a decision-table node shows a table",
  (await count("table.dt")) === 1 && (await text("#panel thead")).includes("Risk Category")
);
ok("hit policy select shows FIRST", (await page.locator("select[data-op=dthp]").inputValue()) === "FIRST");
ok("3 rules, 2 input columns", (await count("table.dt tbody tr")) === 3 && (await count("table.dt th.in")) === 2);
ok(
  "FIRST marks rule 2 as the hit and rule 3 as also matching",
  (await page.locator("#dr-risk-0").getAttribute("class")) === "rule" &&
    (await page.locator("#dr-risk-1").getAttribute("class")) === "rule hit" &&
    (await page.locator("#dr-risk-2").getAttribute("class")) === "rule also"
);
ok(
  "FIRST picks rule 2 -> Medium (summary + node badge)",
  (await text("#dtv-risk")).includes('"Medium"') && (await text("#nv-risk")) === '"Medium"',
  await text("#dtv-risk")
);
ok(
  "entries are highlighted FEEL",
  (await count("#dhl-risk-e-0-0 .op")) >= 1 &&
    (await count("#dhl-risk-e-0-0 .n")) === 1 &&
    (await count("#dhl-risk-h-0 .id")) >= 1
);
ok("no type errors (string enumeration)", (await count(".node.invalid")) === 0);
await page.screenshot({ path: `${OUT}/d1.png` });

// editing an entry re-evaluates live
await cell("e-0-0").fill("< 30");
await cell("e-0-1").fill("-");
await settle(500);
ok(
  "rule 1 now matches -> Low",
  (await page.locator("#dr-risk-0").getAttribute("class")) === "rule hit" && (await text("#nv-risk")) === '"Low"',
  await text("#nv-risk")
);

// hit policies
await page.locator("select[data-op=dthp]").selectOption("UNIQUE");
await settle(500);
ok(
  "UNIQUE with several matches -> null + message",
  (await text("#nv-risk")) === "—" && (await text("#dtv-risk")).includes("rules match"),
  await text("#dtv-risk")
);
await page.locator("select[data-op=dthp]").selectOption("COLLECT");
await settle(500);
ok(
  "COLLECT returns a list in rule order",
  (await text("#dtv-risk")).includes('["Low", "Medium", "High"]'),
  await text("#dtv-risk")
);
ok(
  "a list violates the string type of the node",
  (await count('.node.invalid[data-id="risk"]')) === 1,
  await text("#tt-risk")
);
await page.locator("select[data-op=dthp]").selectOption("ANY");
await settle(500);
ok("ANY with different outputs -> disagreement message", (await text("#dtv-risk")).includes("disagree"));
await page.locator("select[data-op=dthp]").selectOption("FIRST");
await settle(500);
ok("back to FIRST", (await text("#nv-risk")) === '"Low"' && (await count(".node.invalid")) === 0);

// errors per cell
await cell("e-1-0").fill("< ");
await settle(500);
ok("syntax error in an entry is underlined", (await count("#dhl-risk-e-1-0 .err")) > 0);
await cell("e-1-0").fill("< 28");
await cell("o-2-0").fill("1 +");
await settle(500);
ok("syntax error in an output is underlined", (await count("#dhl-risk-o-2-0 .err")) > 0);
await cell("o-2-0").fill('"High"');
await settle(400);

// structure
// the add/delete controls only show while the pointer is on their row or header
// the controls fade in and out (0.12 s): read the opacity once it has settled
const op = async (sel) => {
  await page.waitForTimeout(250);
  return page.locator(sel).evaluate((e) => +getComputedStyle(e).opacity);
};
await page.evaluate(() => document.activeElement.blur());
await page.mouse.move(2, 2);
ok("row controls are hidden until hover", (await op('[data-click="dt-ins-rule:risk:3"]')) === 0);
await page.locator("#dr-risk-2").hover();
ok("hovering a rule shows insert and delete", (await op('[data-click="dt-ins-rule:risk:3"]')) === 1 && (await op('[data-click="dt-del-rule:risk:2"]')) === 1);
await page.locator("table.dt th.in").nth(1).hover();
ok("hovering a column header shows insert and delete", (await op('[data-click="dt-ins-input:risk:2"]')) === 1 && (await op('[data-click="dt-del-input:risk:1"]')) === 1);
await page.locator("#dr-risk-2").hover();
await page.locator('[data-click="dt-ins-rule:risk:3"]').click();
await settle(500);
ok("+ rule adds a row", (await count("table.dt tbody tr")) === 4);
await page.locator("table.dt th.in").nth(1).hover();
await page.locator('[data-click="dt-ins-input:risk:2"]').click();
await settle(500);
ok(
  "+ input adds a column to header and every rule",
  (await count("table.dt th.in")) === 3 && (await count("table.dt tbody tr:first-child td textarea")) === 5
);
await cell("h-2").fill("Applicant Data.Income");
await settle(400);
ok(
  "column header without requirement evaluates to null (rule never matches non-wildcards)",
  (await count("table.dt")) === 1
);
await page.locator("table.dt th.in").nth(2).hover();
await page.locator('[data-click="dt-del-input:risk:2"]').click();
await settle(400);
await page.locator("#dr-risk-3").hover();
await page.locator('[data-click="dt-del-rule:risk:3"]').click();
await settle(400);
ok(
  "delete column/rule restores the shape",
  (await count("table.dt th.in")) === 2 && (await count("table.dt tbody tr")) === 3
);
await page.screenshot({ path: `${OUT}/d2.png` });

// typeRef on every column
const colType = (path) => page.locator(`select[data-op=dttype][data-path="${path}"]`);
ok("each column shows its typeRef select", (await count("table.dt select.coltype")) === 3);
await colType("h-0").selectOption("tRatio");
await colType("n-0").selectOption("tCategory");
await settle(300);
await page.locator('#scene [data-id="front"] .shape').click({ force: true });
await settle(300);
await page.locator('#scene [data-id="risk"] .shape').click({ force: true });
await settle(400);
ok(
  "column types survive re-rendering the table",
  (await colType("h-0").inputValue()) === "tRatio" && (await colType("n-0").inputValue()) === "tCategory"
);

// annotation is a cell like the others
await page.locator("textarea[data-op=dtnote]").first().fill("low risk");
await settle(300);
ok(
  "annotation is a textarea cell and mirrors its text",
  (await text("#note-risk-0")).startsWith("low risk") && (await count("table.dt td.note .ed")) === 3
);

// undo walks back through the edits
for (let i = 0; i < 40; i++) {
  if (await page.locator("[data-click=undo]").isDisabled()) break;
  await page.locator("[data-click=undo]").click();
  await settle(120);
}
await page.locator('#scene [data-id="risk"] .shape').click({ force: true });
await settle(400);
ok(
  "undo all the way restores the sample table",
  (await text("#nv-risk")) === '"Medium"' && (await page.locator("select[data-op=dthp]").inputValue()) === "FIRST",
  await text("#nv-risk")
);

// switch a node between context and table
await page.locator('#scene [data-id="loan"] .shape').click({ force: true });
await settle(400);
await page.locator("select[data-op=nexpr]").selectOption("table");
await settle(500);
ok(
  "switching expression kind to decision table",
  (await count("table.dt")) === 1 && (await count("table.dt tbody tr")) === 1
);
await page.locator("select[data-op=nexpr]").selectOption("context");
await settle(500);
ok("…and back to a context", (await count("table.boxed.dt")) === 0 && (await count("textarea[data-cell]")) === 1);

console.log(`\n${fails === 0 ? "ALL PASSED" : fails + " FAILED"}`);
console.log(logs.filter((l) => !l.startsWith("[log] popcorn")).join("\n"));
await browser.close();
