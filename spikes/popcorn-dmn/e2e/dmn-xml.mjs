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
const exportDmn = async () => {
  await page.getByRole("button", { name: /File/ }).click();
  await page.getByRole("menuitem", { name: "Export DMN" }).click();
};
const text = (sel) => page.locator(sel).first().textContent();
const settle = (ms = 500) => page.waitForTimeout(ms);
// the dock and the import summary float over the canvas and can cover nodes: close them before clicking one
const clickNode = async (sel, opts) => {
  if (await page.locator("#report .x").isVisible()) await page.locator("#report .x").click();
  await page.keyboard.press("Escape");
  await page.waitForTimeout(300);
  await page.locator(sel).click(opts);
};
const count = (sel) => page.locator(sel).count();

await page.goto("http://localhost:4000");
await page.waitForFunction(
  () => document.querySelector("#scene")?.children.length > 0 && document.querySelector("#panel table"),
  null,
  { timeout: 90000 }
);

// ---- XML inspector
await page.locator(".xmlbtn").click();
await settle(600);
const xml = await page.evaluate(
  () => [...document.querySelectorAll("#xcode .xc")].map((c) => c.textContent).join("\n") + "\n"
);
ok(
  "XML inspector shows generated DMN",
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
ok("the editor stays visible beside the inspector", await page.locator("#view-editor").isVisible());
await page.screenshot({ path: `${OUT}/x1.png` });
await page.locator(".xmlbtn").click();
await settle();

// ---- export download, then import the downloaded file again
const [dl] = await Promise.all([page.waitForEvent("download", { timeout: 15000 }), exportDmn()]);
const exported = `${OUT}/exported.dmn`;
await dl.saveAs(exported);
const exportedXml = fs.readFileSync(exported, "utf8");
ok(
  "export downloads a .dmn file",
  dl.suggestedFilename().endsWith(".dmn") && exportedXml.startsWith("<?xml"),
  dl.suggestedFilename()
);
ok("download equals what the XML tab showed", exportedXml === xml);
ok("the file holds no test values", !exportedXml.includes("9000") && !exportedXml.includes("spike:value"));
// the test values are a scenario: saved on their own
await page.locator("#scn-toggle").click();
const [sdl] = await Promise.all([
  page.waitForEvent("download", { timeout: 15000 }),
  page.getByRole("menuitem", { name: "Save scenarios" }).click(),
]);
const scenarios = `${OUT}/exported.scenarios.json`;
await sdl.saveAs(scenarios);
const saved = JSON.parse(fs.readFileSync(scenarios, "utf8"));
ok(
  "scenarios download as JSON by input name",
  sdl.suggestedFilename().endsWith(".scenarios.json") &&
    saved.scenarios.length === 1 &&
    saved.scenarios[0].inputs["Applicant Data"].includes("Income: 9000"),
  sdl.suggestedFilename()
);
await clickNode('#scene [data-id="app"]');
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
  "re-importing the export restores the diagram, but not the test values",
  (await count("#scene g[data-id]")) === 8 &&
    (await count("#scene line.vis")) === 10 &&
    (await text("#nv-front")) === "—",
  await text("#nv-front")
);
await page.locator("#scn-file").setInputFiles(scenarios);
await settle(900);
ok("loading the scenarios restores the values", (await text("#nv-front")) === "22.6673", await text("#nv-front"));
ok(
  "report says nothing was lost",
  (await text("#report")).includes("imported 8 nodes, 10 requirements, 5 data types") &&
    (await text("#report")).includes("Nothing was lost"),
  (await text("#report")).slice(0, 120)
);

// ---- KIE-style fixture
await page.locator("#file").setInputFiles(FIXTURE);
await settle(900);
const report = await text("#report");
ok(
  "fixture imports: 6 nodes, 6 requirements, 3 types",
  (await count("#scene g[data-id]")) === 8 &&
    (await count("#scene line.vis")) === 8 &&
    report.includes("imported 6 nodes, 6 requirements, 3 data types, 1 annotation, 1 knowledge source"),
  report.slice(0, 160)
);
ok(
  "report lists what is converted, and no longer annotations, sources or their links",
  report.includes("Fee: invocation to a FEEL function call") &&
    !report.includes("knowledgeSource") &&
    !report.includes("textAnnotation") &&
    !report.includes("authorityRequirement") &&
    !report.includes("association"),
  report
);
ok("shapeless elements placed automatically", report.includes("3 placed automatically"));
ok(
  "file positions are kept (Applicant Data at 40,320)",
  (await page.locator('#scene [data-id="_app"]').getAttribute("transform")) === "translate(40 320)",
  await page.locator('#scene [data-id="_app"]').getAttribute("transform")
);
await clickNode('#scene [data-id="_risk"]');
await settle(400);
ok(
  "imported decision table renders with FIRST and 2 rules",
  (await page.locator("select[data-op=dthp]").inputValue()) === "FIRST" && (await count("table.dt tbody tr")) === 2
);
await clickNode('#scene [data-id="_loan_d"]');
await settle(400);
ok(
  "imported context (limit + result) renders",
  (await count("textarea[data-cell]")) === 2 &&
    (await page.locator('textarea[data-cell="_loan_d:0"]').inputValue()) === "Lender Acceptable DTI() + 5"
);
await clickNode('#scene [data-id="_app"]');
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
  (await count("#ttree .trow")) === 5 &&
    (await text("#trow-0-0 .tcons")) === ">= 0" &&
    (await text("#trow-2 .ttype")).includes("[]"),
  String(await count("#ttree .trow"))
);
await page.locator('[data-click="tab:editor"]').click();
await settle(300);

// ---- fixture round trip through export + import is lossless for what is supported
const [dl2] = await Promise.all([page.waitForEvent("download"), exportDmn()]);
await dl2.saveAs(`${OUT}/fixture-export.dmn`);
await page.locator("#file").setInputFiles(`${OUT}/fixture-export.dmn`);
await settle(900);
const report2 = await text("#report");
ok(
  "exporting the imported fixture and importing again loses nothing",
  report2.includes("imported 6 nodes, 6 requirements, 3 data types") && !report2.includes("Lost when saving"),
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

// an element id that tries to break out of an HTML attribute is refused at import
const evil = `<definitions xmlns="https://www.omg.org/spec/DMN/20240513/MODEL/" name="x"><inputData id="a&quot; onmouseover=&quot;window.__pwned=1&quot; x=&quot;" name="N"><variable name="N"/></inputData></definitions>`;
await page.locator("#file").setInputFiles({ name: "evil.dmn", mimeType: "text/xml", buffer: Buffer.from(evil) });
await settle(600);
ok(
  "an id with quotes is refused",
  (await text("#report")).includes("invalid element id"),
  (await text("#report")).slice(0, 120)
);
ok(
  "nothing was injected into the page",
  (await count("[onmouseover]")) === 0 && (await count("#scene g[data-id]")) === 8
);

// element ids with dots are valid DMN ids and must still get incremental updates (a CSS #id selector would not)
const dotted = `<definitions xmlns="https://www.omg.org/spec/DMN/20240513/MODEL/" name="x" id="d"><decision id="dec.1" name="Dotted"><variable id="v.1" name="Dotted"/><literalExpression><text>1 + 1</text></literalExpression></decision></definitions>`;
await page.locator("#file").setInputFiles({ name: "dots.dmn", mimeType: "text/xml", buffer: Buffer.from(dotted) });
await settle(900);
await page.locator('#scene g[data-id="dec.1"] .shape').click();
await settle(400);
ok("a dotted id shows its value", (await page.locator('[id="nv-dec.1"]').textContent()) === "2");
await page.locator('textarea[data-cell="dec.1:0"]').fill("40 + 2");
await settle(600);
ok(
  "and is updated when the expression changes",
  (await page.locator('[id="nv-dec.1"]').textContent()) === "42",
  await page.locator('[id="nv-dec.1"]').textContent()
);

console.log(`\n${fails === 0 ? "ALL PASSED" : fails + " FAILED"}`);
console.log(logs.filter((l) => !l.startsWith("[log] popcorn")).join("\n"));
await browser.close();
