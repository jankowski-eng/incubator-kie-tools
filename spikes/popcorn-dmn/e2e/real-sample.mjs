// End-to-end check against `mix popcorn.dev` (http://localhost:4000) driven by Playwright and Chrome.
// Imports the real KIE sample (test/fixtures/Sample.dmn, from sandbox.kie.org), gives it inputs and checks the decisions.
// Run: PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core OUT=/tmp node e2e/real-sample.mjs
import { createRequire } from "node:module";
import fs from "node:fs";
const require = createRequire(`${process.env.PLAYWRIGHT_CORE}/`);
const OUT = process.env.OUT ?? ".";
const SAMPLE = new URL("../test/fixtures/Sample.dmn", import.meta.url).pathname;
const { chromium } = require("playwright-core");
const browser = await chromium.launch({ channel: "chrome", headless: true });
const ctx = await browser.newContext({ acceptDownloads: true, viewport: { width: 1200, height: 1000 } });
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
await page.locator("#file").setInputFiles(SAMPLE);
await settle(1200);
const report = await text("#report");
ok(
  "imports 11 nodes, 11 requirements, 16 data types",
  report.includes("imported 11 nodes, 11 requirements, 16 data types"),
  report.slice(0, 100)
);
ok(
  "nothing lost, two invocations converted",
  report.includes("Nothing was lost") && (report.match(/invocation to a FEEL function call/g) ?? []).length === 2,
  report.slice(0, 260)
);
ok("file positions kept (no automatic placement)", !report.includes("placed automatically"));

// saving without edits must give back every element of the file, in the file's own prefixes, with its licence header
const tagCounts = (xml) => {
  const counts = {};
  for (const m of xml.replace(/<!--[\s\S]*?-->/g, "").matchAll(/<([A-Za-z][\w:.-]*)[\s>/]/g))
    counts[m[1]] = (counts[m[1]] ?? 0) + 1;
  return counts;
};
const original = fs.readFileSync(SAMPLE, "utf8");
const exportDmn = async () => {
  await page.getByRole("button", { name: /File/ }).click();
  await page.getByRole("menuitem", { name: "Export DMN" }).click();
};
const [dl0] = await Promise.all([page.waitForEvent("download"), exportDmn()]);
await dl0.saveAs(`${OUT}/real-unedited.dmn`);
const unedited = fs.readFileSync(`${OUT}/real-unedited.dmn`, "utf8");
ok(
  "saving without edits keeps every element of the real file",
  JSON.stringify(Object.entries(tagCounts(unedited)).sort()) ===
    JSON.stringify(Object.entries(tagCounts(original)).sort()),
  `${Object.keys(tagCounts(unedited)).length} element names`
);
ok(
  "licence header and the file's own prefixes are kept",
  unedited.includes("Licensed to the Apache Software Foundation") &&
    unedited.includes("<dmn:definitions") &&
    !unedited.includes("<decision ")
);

// node ids come from the file; look them up by name
const idOf = async (name) =>
  page.evaluate(
    (n) =>
      [...document.querySelectorAll("#scene g[data-id]")].find((g) => g.querySelector("text").textContent === n)
        ?.dataset.id,
    name
  );
const ids = Object.fromEntries(
  await Promise.all(
    [
      "Applicant Data",
      "Requested Product",
      "Credit Score",
      "Credit Score Rating",
      "Back End Ratio",
      "Front End Ratio",
      "Loan Pre-Qualification",
      "PITI",
      "DTI",
      "Lender Acceptable PITI",
    ].map(async (n) => [n, await idOf(n)])
  )
);
// the badge on a node is truncated; its tooltip holds the full value
const full = async (id) => (await text(`#tt-${id}`)).split("\n")[0].replace(/^value: /, "");
ok("all named elements are on the canvas", Object.values(ids).every(Boolean), JSON.stringify(ids).slice(0, 80));
ok(
  "business knowledge shows as a function",
  (await full(ids.PITI)) === "ƒ(pmt, tax, insurance, income)" && (await full(ids["Lender Acceptable PITI"])) === "ƒ()",
  await full(ids.PITI)
);

const setInput = async (name, value) => {
  await clickNode(`#scene [data-id="${ids[name]}"]`, { force: true });
  await settle(350);
  await page.locator(`textarea[data-cell="${ids[name]}:0"]`).fill(value);
  await settle(450);
};
const monthly = (income) =>
  `{Age: 35, Marital Status: "S", Employment Status: "Employed", Existing Customer: false, Monthly: {Income: ${income}, Repayments: 100, Expenses: 2000, Tax: 300, Insurance: 100}}`;
await setInput("Requested Product", '{Type: "Standard Loan", Rate: 4.5, Term: 360, Amount: 300000}');
await setInput("Credit Score", "{FICO: 720}");
await setInput("Applicant Data", monthly(10000));
const verdict = async () => full(ids["Loan Pre-Qualification"]);
ok(
  "rating from the Credit Score Rating table",
  (await text(`#nv-${ids["Credit Score Rating"]}`)) === '"Good"',
  await text(`#nv-${ids["Credit Score Rating"]}`)
);
ok(
  "ratios use the BKM functions",
  (await text(`#nv-${ids["Back End Ratio"]}`)) === '"Sufficient"' &&
    (await text(`#nv-${ids["Front End Ratio"]}`)) === '"Sufficient"'
);
ok(
  "two-output table yields a context: Qualified",
  (await verdict()).startsWith('{Qualification: "Qualified"'),
  await verdict()
);
ok("no type errors against the 16 data types", (await count(".node.invalid")) === 0);

await setInput("Applicant Data", monthly(4000));
ok(
  "lower income: debt-to-income too high",
  (await verdict()).startsWith('{Qualification: "Not Qualified"'),
  await verdict()
);
await clickNode(`#scene [data-id="${ids["Loan Pre-Qualification"]}"]`, { force: true });
await settle(500);
ok(
  "the table highlights the matching rule (rule 2)",
  (await page.locator("tr.rule.hit").count()) === 1 && (await page.locator("tr.rule.hit td.rn").evaluate((e) => e.firstChild.textContent)) === "2"
);
ok(
  "two output columns with names",
  (await count("table.dt th.outh")) === 2 && (await count('textarea[data-op=dtcell][data-path="n-0"]')) === 1
);
ok(
  "rule outputs are editable cells",
  (await page.locator('textarea[data-op=dtcell][data-path="o-1-1"]').inputValue()).includes(
    "Debt to income ratio is too high"
  )
);
await page.screenshot({ path: `${OUT}/real1.png` });
await setInput("Credit Score", "{FICO: 580}");
ok("poor credit score wins (first matching rule)", (await verdict()).includes("Credit Score too low"), await verdict());

// BKM parameters are editable
await clickNode(`#scene [data-id="${ids.PITI}"]`, { force: true });
await settle(500);
ok(
  "BKM parameters shown in the panel",
  (await page.locator("input[data-op=nparams]").inputValue()) === "pmt, tax, insurance, income"
);
await page.locator("input[data-op=nparams]").fill("pmt, tax, insurance");
await settle(500);
ok("changing parameters changes the function", (await full(ids.PITI)) === "ƒ(pmt, tax, insurance)");
await page.locator("input[data-op=nparams]").fill("pmt, tax, insurance, income");
await settle(400);

// after editing, everything the editor does not touch is still in the saved file
const [dlEdited] = await Promise.all([page.waitForEvent("download"), exportDmn()]);
await dlEdited.saveAs(`${OUT}/real-edited.dmn`);
const edited = fs.readFileSync(`${OUT}/real-edited.dmn`, "utf8");
const before = tagCounts(original);
const afterCounts = tagCounts(edited);
ok(
  "after editing, no element of the original is gone",
  Object.entries(before).every(([name, n]) => (afterCounts[name] ?? 0) >= n),
  Object.entries(before)
    .filter(([name, n]) => (afterCounts[name] ?? 0) < n)
    .map(([k]) => k)
    .join(", ")
);
ok(
  "…and the DMNDI styles and labels are intact",
  (edited.match(/<dmndi:DMNStyle/g) ?? []).length === 11 && (edited.match(/<dmndi:DMNLabel/g) ?? []).length === 11
);

// export the whole thing and bring it back
const [dl] = await Promise.all([page.waitForEvent("download"), (async () => {
    await page.getByRole("button", { name: /File/ }).click();
    await page.getByRole("menuitem", { name: "Export DMN" }).click();
  })()]);
await dl.saveAs(`${OUT}/real-export.dmn`);
await page.locator("#file").setInputFiles(`${OUT}/real-export.dmn`);
await settle(1200);
const report2 = await text("#report");
ok(
  "export then import: still nothing lost",
  report2.includes("imported 11 nodes, 11 requirements, 16 data types") && report2.includes("Nothing was lost"),
  report2.slice(0, 160)
);
console.log(`\n${fails === 0 ? "ALL PASSED" : fails + " FAILED"}`);
console.log(logs.filter((l) => !l.startsWith("[log] popcorn")).join("\n"));
await browser.close();
