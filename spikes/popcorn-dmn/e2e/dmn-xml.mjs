// End-to-end check against `mix popcorn.dev` (http://localhost:4000) driven by Playwright and Chrome.
// Run: PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core OUT=/tmp node e2e/dmn-xml.mjs
import { createRequire } from "node:module";
import fs from "node:fs";
const require = createRequire(`${process.env.PLAYWRIGHT_CORE}/`);
const OUT = process.env.OUT ?? ".";
const { chromium } = require("playwright-core");
const FIXTURE = new URL("../test/fixtures/kie_sample.dmn", import.meta.url).pathname;
const browser = await chromium.launch({ channel: "chrome", headless: true });
const ctx = await browser.newContext({ acceptDownloads: true, viewport: { width: 1100, height: 1000 } });
const page = await ctx.newPage();
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
const settle = (ms = 500) => page.waitForTimeout(ms);
const count = (sel) => page.locator(sel).count();

await page.goto("http://localhost:4000");
await page.waitForFunction(
  () => document.querySelector("#scene")?.children.length > 0 && document.querySelector("#panel table"),
  null,
  { timeout: 90000 }
);

// ---- XML tab
await page.locator('[data-click="tab:xml"]').click();
await settle();
const xml = await text("#xml");
ok(
  "XML tab shows generated DMN",
  xml.startsWith('<?xml version="1.0"') &&
    xml.includes('<decision id="risk" name="Risk Category">') &&
    xml.includes('<decisionTable hitPolicy="FIRST">'),
  xml.slice(0, 40)
);
ok(
  "XML has types, requirements and diagram shapes",
  xml.includes('<itemDefinition id="_t0" name="tApplicant"') &&
    xml.includes('<requiredInput href="#app"/>') &&
    xml.includes("<dmndi:DMNShape") &&
    xml.includes("<dmndi:DMNEdge")
);
ok("editor view hidden while XML tab is open", await page.locator("#view-editor").isHidden());
await page.screenshot({ path: `${OUT}/x1.png` });
await page.locator('[data-click="tab:editor"]').click();
await settle();

// ---- export download, then import the downloaded file again
const [dl] = await Promise.all([
  page.waitForEvent("download", { timeout: 15000 }),
  page.locator('[data-click="export"]').click(),
]);
const exported = `${OUT}/exported.dmn`;
await dl.saveAs(exported);
const exportedXml = fs.readFileSync(exported, "utf8");
ok(
  "export downloads a .dmn file",
  dl.suggestedFilename().endsWith(".dmn") && exportedXml.startsWith("<?xml"),
  dl.suggestedFilename()
);
ok("download equals what the XML tab showed", exportedXml === xml);
await page.locator('#scene [data-id="app"]').click();
await settle(300);
await page.locator('[data-cell="app:0"]').fill("{Income: 1, Tax: 1, Insurance: 1, Debt: 1}");
await settle(500);
ok(
  "model edited before re-import (front ratio changed)",
  (await text("#nv-front")) !== "22.6673",
  await text("#nv-front")
);
await page.locator("#file").setInputFiles(exported);
await settle(900);
ok(
  "re-importing the export restores the model exactly",
  (await text("#nv-front")) === "22.6673" &&
    (await count("#scene g[data-id]")) === 8 &&
    (await count("#scene line.vis")) === 10,
  await text("#report")
);
ok(
  "report says nothing was dropped",
  (await text("#report")).includes("imported 8 nodes, 10 requirements, 5 data types") &&
    (await text("#report")).includes("Nothing was dropped"),
  (await text("#report")).slice(0, 120)
);

// ---- KIE-style fixture
await page.locator("#file").setInputFiles(FIXTURE);
await settle(900);
const report = await text("#report");
ok(
  "fixture imports: 6 nodes, 6 requirements, 3 types",
  (await count("#scene g[data-id]")) === 6 &&
    (await count("#scene line.vis")) === 6 &&
    report.includes("imported 6 nodes, 6 requirements, 3 data types"),
  report.slice(0, 160)
);
ok(
  "report lists dropped elements",
  [
    "knowledgeSource",
    "textAnnotation",
    "association",
    "authorityRequirement",
    "Fee: invocation to a FEEL function call",
  ].every((k) => report.includes(k)),
  report
);
ok("shapeless element placed automatically", report.includes("1 placed automatically"));
ok(
  "file positions are kept (Applicant Data at 40,320)",
  (await page.locator('#scene [data-id="_app"]').getAttribute("transform")) === "translate(40 320)",
  await page.locator('#scene [data-id="_app"]').getAttribute("transform")
);
await page.locator('#scene [data-id="_risk"]').click();
await settle(400);
ok(
  "imported decision table renders with FIRST and 2 rules",
  (await page.locator("select[data-op=dthp]").inputValue()) === "FIRST" && (await count("table.dt tbody tr")) === 2
);
await page.locator('#scene [data-id="_loan_d"]').click();
await settle(400);
ok(
  "imported context (limit + result) renders",
  (await count("textarea[data-cell]")) === 2 &&
    (await page.locator('textarea[data-cell="_loan_d:0"]').inputValue()) === "Lender Acceptable DTI() + 5"
);
await page.locator('#scene [data-id="_app"]').click();
await settle(300);
await page.locator('[data-cell="_app:0"]').fill("{Income: 1000, Debt: 100}");
await settle(600);
ok(
  "imported model evaluates end to end (Approve)",
  (await text("#nv-_loan_d")) === '"Approve"' && (await text("#nv-_risk")) === '"Low"',
  `${await text("#nv-_back")} / ${await text("#nv-_risk")} / ${await text("#nv-_loan_d")}`
);
await page.locator('[data-click="tab:types"]').click();
await settle(400);
ok(
  "imported data types in the Data types tab",
  (await count("table.types tbody tr")) === 5 &&
    (await page.locator('select[data-op=ckind][data-path="0-0"]').inputValue()) === "range",
  String(await count("table.types tbody tr"))
);
await page.locator('[data-click="tab:editor"]').click();
await settle(300);

// ---- fixture round trip through export + import is lossless for what is supported
const [dl2] = await Promise.all([page.waitForEvent("download"), page.locator('[data-click="export"]').click()]);
await dl2.saveAs(`${OUT}/fixture-export.dmn`);
await page.locator("#file").setInputFiles(`${OUT}/fixture-export.dmn`);
await settle(900);
const report2 = await text("#report");
ok(
  "exporting the imported fixture and importing again drops nothing",
  report2.includes("imported 6 nodes, 6 requirements, 3 data types") && report2.includes("Nothing was dropped"),
  report2.slice(0, 160)
);
await page.screenshot({ path: `${OUT}/x2.png` });

// ---- undo walks back to the original sample
for (let i = 0; i < 20; i++) {
  if (await page.locator("[data-click=undo]").isDisabled()) break;
  await page.locator("[data-click=undo]").click();
  await settle(150);
}
ok(
  "undo returns to the original sample after imports",
  (await count("#scene g[data-id]")) === 8 && (await text("#nv-front")) === "22.6673"
);

// ---- bad input
await page.locator("#file").setInputFiles({ name: "x.dmn", mimeType: "text/xml", buffer: Buffer.from("<svg/>") });
await settle(600);
ok(
  "non-DMN file is refused with a message",
  (await text("#report")).includes("not a DMN file") && (await count("#scene g[data-id]")) === 8,
  await text("#report")
);
await page
  .locator("#file")
  .setInputFiles({ name: "y.dmn", mimeType: "text/xml", buffer: Buffer.from("<definitions><decision") });
await settle(600);
ok(
  "malformed XML is refused with a message",
  (await text("#report")).includes("XML parse error"),
  (await text("#report")).slice(0, 100)
);

console.log(`\n${fails === 0 ? "ALL PASSED" : fails + " FAILED"}`);
console.log(logs.filter((l) => !l.startsWith("[log] popcorn")).join("\n"));
await browser.close();
