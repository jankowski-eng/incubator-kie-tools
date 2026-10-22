// End-to-end check against `mix popcorn.dev` (http://localhost:4000) driven by Playwright and Chrome.
// Run: PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core OUT=/tmp node e2e/data-types.mjs
import { createRequire } from "node:module";
import fs from "node:fs";
const require = createRequire(`${process.env.PLAYWRIGHT_CORE}/`);
const OUT = process.env.OUT ?? ".";
const { chromium } = require("playwright-core");
const browser = await chromium.launch({ channel: "chrome", headless: true });
const page = await browser.newPage({ viewport: { width: 1300, height: 800 } });
const logs = [];
page.on("pageerror", (e) => logs.push(`[pageerror] ${e.message}`.slice(0, 300)));
let fails = 0;
const ok = (name, cond, extra = "") => {
  if (!cond) fails++;
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}${extra ? "  — " + extra : ""}`);
};
const text = (sel) => page.locator(sel).first().textContent();
const settle = (ms = 350) => page.waitForTimeout(ms);
const count = (sel) => page.locator(sel).count();
const rows = () => count("#ttree .trow");
const xml = async () => {
  await page.locator(".xmlbtn").click();
  await page.waitForFunction(() => document.querySelectorAll("#xcode .xc").length > 0);
  await settle(300);
  const t = await page.evaluate(() => [...document.querySelectorAll("#xcode .xc")].map((c) => c.textContent).join("\n") + "\n");
  await page.locator(".xmlbtn").click();
  await settle();
  return t;
};
const undo = async () => {
  await page.locator('[data-click="undo"]').click();
  await settle(500);
};

await page.goto("http://localhost:4000");
await page.waitForFunction(() => document.querySelector("#scene")?.children.length > 0, null, { timeout: 90000 });
await page.locator('[data-click="tab:types"]').click();
await settle();

// ---- layout: tree table, no permanent form controls, inspector closed until something is selected
ok("12 rows: 5 types + 7 fields", (await rows()) === 12);
ok("rows have no inputs, selects or checkboxes", (await count("#ttree input, #ttree select, #ttree [type=checkbox]")) === 0);
const fills = () => page.evaluate(() => { const l = document.querySelector(".tlayout").getBoundingClientRect(), t = document.querySelector("#ttree").getBoundingClientRect(), i = document.querySelector("#tinspector").getBoundingClientRect(); return { gap: Math.round(l.width - t.width - i.width), tree: Math.round(t.width), insp: Math.round(i.width), total: Math.round(l.width) }; });
const f0 = await fills();
ok("with the properties closed the tree takes the whole width", f0.gap <= 2 && f0.tree >= f0.total - 2, JSON.stringify(f0));
ok("inspector starts closed", (await page.locator("#tview").getAttribute("data-inspector")) === "closed");
ok("structures and fields are told apart", (await count("#ttree .tname.struct")) === 2 && (await count("#ttree .ticon.k-struct")) === 2);
ok("constraint summary is shown on the row", (await text("#trow-1-1 .tcons")) === "(0..20]" && (await text("#trow-1-0 .tcons")) === "> 0" && (await text("#trow-0-2 .tcons")) === "—");

// ---- fold / unfold
await page.locator('#trow-0 [data-click="ttoggle:0"]').click();
await settle();
ok("collapsing a structure hides its fields", (await rows()) === 8 && (await count("#trow-0-0")) === 0);
await page.locator('#trow-0 [data-click="ttoggle:0"]').click();
await settle();
ok("expanding shows them again", (await rows()) === 12);
ok("there are no expand/collapse-all buttons", (await count('[data-click="texpand"], [data-click="tcollapse"]')) === 0);
ok("chevrons are drawn as arrows in the text colour", (await count("#trow-0 .tchev svg path")) === 1 && (await page.locator("#trow-0 .tchev").evaluate((e) => e.getBoundingClientRect().width)) >= 16);

// ---- search keeps the hierarchy
await page.locator("[data-op=tsearch]").fill("rate");
await settle();
ok("search shows the match under its parent", (await rows()) === 2 && (await count("#trow-1")) === 1 && (await count("#trow-1-1")) === 1 && (await count("#ttree mark")) === 1);
await page.locator("[data-op=tsearch]").fill("zzz");
await settle();
ok("search with no match says so", (await rows()) === 0 && (await text("#ttree")).includes("Nothing matches"));
await page.locator("[data-op=tsearch]").fill("");
await settle();
ok("clearing the search restores the tree", (await rows()) === 12);

// ---- selection, inspector, validation
await page.locator("#trow-1-1").click();
await settle();
await settle(500);
const f2 = await fills();
ok("with the properties open, tree and properties fill the width with no blank space", f2.gap <= 2 && f2.insp > 250 && f2.tree > 400, JSON.stringify(f2));
ok(
  "selecting a field opens the inspector with its properties",
  (await page.locator("#tview").getAttribute("data-inspector")) === "open" &&
    (await page.locator("#iname").inputValue()) === "Rate" &&
    (await page.locator("#itype").inputValue()) === "number" &&
    (await text('.seg button[aria-pressed="true"]')) === "Interval"
);
ok("the inspector tracks the selection", await (async () => {
  await page.locator("#trow-0-0").click();
  await settle();
  return (await page.locator("#iname").inputValue()) === "Income" && (await text('.seg button[aria-pressed="true"]')) === "Compare";
})());
await page.locator("#iname").fill("Debt");
await settle(400);
ok("a duplicate name is reported in the inspector and on the row", (await text("#tmsg-0-0")).includes("already used") && (await count("#trow-0-0.err")) === 1);
await page.locator("#iname").fill("Income");
await settle(400);
ok("fixing the name clears the error", (await text("#tmsg-0-0")) === "" && (await count("#trow-0-0.err")) === 0);
await page.locator('[data-click="tinsp-toggle"]').first().click();
await settle();
await page.waitForTimeout(400);
const f1 = await fills();
ok("closed again, nothing is left blank", f1.gap <= 2, JSON.stringify(f1));
ok("the inspector can be closed", (await page.locator("#tview").getAttribute("data-inspector")) === "closed");
await page.locator("#trow-0-1").click();
await settle();
ok("it stays closed while moving the selection", (await page.locator("#tview").getAttribute("data-inspector")) === "closed");
await page.locator('.ttoolbar [data-click="tinsp-toggle"]').click();
await settle();

// ---- constraints: visual editors write canonical FEEL, advanced keeps the original text
await page.locator("#trow-0-0").click();
await settle();
await page.locator("[data-op=cval]").fill("10");
await settle(300);
ok("editing a comparison rewrites its text", (await text("#trow-0-0 .tcons")) === ">= 10");
await page.locator("[data-op=cop]").selectOption("<");
await settle(300);
ok("changing the operator too", (await text("#trow-0-0 .tcons")) === "< 10");
await undo();
await undo();
ok("undo goes back to the original constraint", (await text("#trow-0-0 .tcons")) === ">= 0");
await page.locator("#trow-1-1").click();
await settle();
await page.locator("[data-op=cb]").fill("25");
await page.locator("[data-op=clo]").selectOption("[");
await settle(300);
ok("an interval is edited with its bounds and brackets", (await text("#trow-1-1 .tcons")) === "[0..25]");
// a list of values
await page.locator("#trow-1-2").click();
await settle();
await page.locator("[data-op=citem]").fill("480");
await page.locator("[data-op=citem]").press("Enter");
await settle(400);
ok("Enter adds a value to the list", (await text("#trow-1-2 .tcons")) === "120, 180, 240, 360, 480" && (await count(".chip")) === 5);
await page.locator('.chip:has-text("180") button').click();
await settle(400);
ok("a chip can be removed", (await text("#trow-1-2 .tcons")) === "120, 240, 360, 480");
// strings are quoted
await page.locator("#trow-4").click();
await settle();
await page.locator("[data-op=citem]").fill("Critical");
await page.locator("[data-op=citem]").press("Enter");
await settle(400);
ok("values of a string type are quoted", (await text("#trow-4 .tcons")).endsWith('"High", "Critical"'), await text("#trow-4 .tcons"));
// FEEL that has no visual form
await page.locator("#trow-2").click();
await settle();
await page.locator('[data-click="cmode:2:feel"]').click();
await settle(300);
const complex = '> 0 and < 100 or = 150';
await page.locator("textarea[data-op=ctext]").fill(complex);
await settle(400);
ok("complex FEEL is kept exactly as typed", (await text("#trow-2 .tcons")) === complex);
await page.locator("#trow-3").click();
await page.locator("#trow-2").click();
await settle(400);
ok(
  "it comes back as FEEL, with the visual modes disabled so nothing is overwritten",
  (await text('.seg button[aria-pressed="true"]')) === "FEEL" && (await page.locator('.seg button[data-click^="cmode:2:cmp"]').isDisabled())
);
await page.locator("textarea[data-op=ctext]").fill("[0..");
await settle(400);
ok("a broken expression is underlined and explained", (await count("#chl-2 .err")) > 0 && (await text("#cmsg-2")).length > 0);
await page.locator("textarea[data-op=ctext]").fill("[0..100]");
await settle(300);

// ---- type references and List
await page.locator("#trow-1-0").click();
await settle();
await page.locator("#itype").selectOption("tRatio");
await settle(400);
ok("a field can reference a custom type", (await text("#trow-1-0 .ttype")) === "tRatio" && (await count("#trow-1-0 .ttype.custom")) === 1);
await page.locator("[data-op=tcoll]").check();
await settle(400);
ok("List shows [] next to the type", (await text("#trow-1-0 .ttype")) === "tRatio[]");
const x1 = await xml();
ok("the XML has the reference and the collection flag", x1.includes("<typeRef>tRatio</typeRef>") && x1.includes('name="Amount"') && /isCollection="true"/.test(x1));

// ---- quick edit: double click renames, Escape cancels, Enter keeps
await page.locator("#trow-1-2 .tname").dblclick();
await settle(300);
ok("double click turns the name into an input", (await count("#trow-1-2 input.tedit")) === 1);
await page.keyboard.type("Months");
await page.keyboard.press("Escape");
await settle(400);
ok("Escape cancels the rename", (await text("#trow-1-2 .tname")) === "Term" && (await count("input.tedit")) === 0);
await page.locator("#trow-1-2 .tname").dblclick();
await settle(300);
await page.keyboard.type("Months");
await page.keyboard.press("Enter");
await settle(400);
ok("Enter keeps it", (await text("#trow-1-2 .tname")) === "Months" && (await count("input.tedit")) === 0);
await page.locator("#trow-1-2 .ttype").click();
await settle(300);
ok("a click on the type of the selected row opens a quick selector", (await count("#trow-1-2 select.tedit")) === 1);
await page.locator("#trow-1-2 select.tedit").selectOption("string");
await settle(400);
ok("choosing a type applies it at once", (await text("#trow-1-2 .ttype")) === "string");
await undo();
await undo();
await undo();
ok("undo steps back through the quick edits", (await text("#trow-1-2 .tname")) === "Term" || (await text("#trow-1-2 .ttype")) === "number");

// ---- keyboard on the tree
await page.locator("#trow-0").click();
await page.locator("#ttree").focus();
await page.keyboard.press("ArrowDown");
await settle(300);
ok("ArrowDown selects the next row", (await count("#trow-0-0.sel")) === 1);
await page.keyboard.press("ArrowLeft");
await settle(300);
ok("ArrowLeft on a field goes to its parent", (await count("#trow-0.sel")) === 1);
await page.keyboard.press("ArrowLeft");
await settle(300);
ok("ArrowLeft on an open structure folds it", (await count("#trow-0-0")) === 0);
await page.keyboard.press("ArrowRight");
await page.keyboard.press("ArrowRight");
await settle(300);
ok("ArrowRight unfolds it and then enters it", (await count("#trow-0-0")) === 1 && (await count("#trow-0-0.sel")) === 1);
await page.keyboard.press("End");
await settle(300);
ok("End goes to the last row", (await count("#trow-4.sel")) === 1);
await page.keyboard.press("Enter");
await settle(300);
ok("Enter on the tree starts renaming", (await count("#trow-4 input.tedit")) === 1);
await page.keyboard.press("Escape");
await settle(300);
ok("focus returns to the tree", await page.evaluate(() => document.activeElement.id === "ttree"));

// ---- create and delete
await page.locator('[data-click="add-type"]').click();
await settle(400);
ok("a new data type is created in rename mode", (await rows()) === 13 && (await count("#trow-5 input.tedit")) === 1);
await page.keyboard.type("tMine");
await page.keyboard.press("Enter");
await settle(400);
ok("and named", (await text("#trow-5 .tname")) === "tMine");
await page.locator("#trow-5").click();
await settle(300);
await page.locator("#itype").selectOption("");
await settle(400);
ok("a new type is a plain string until it is made a structure", (await count('#trow-5 [data-click="tadd-child:5"]')) === 1);
await page.locator('#trow-5 [data-click="tadd-child:5"]').click();
await settle(400);
await page.keyboard.press("Enter");
await settle(300);
ok("fields can be added to it", (await count("#trow-5-0")) === 1 && (await text("#trow-5-0 .tname")) === "field");
await page.locator('#trow-5 [data-click="tadd-child:5"]').click();
await settle(400);
await page.keyboard.press("Enter");
await settle(300);
ok("a second field gets a distinct name", (await text("#trow-5-1 .tname")) === "field2");
await page.locator('#trow-5-1 [data-click="tdel:5-1"]').click();
await settle(400);
ok("a field is deleted from its row", (await count("#trow-5-1")) === 0 && (await count("#trow-5-0")) === 1);
await page.locator('#trow-3 [data-click="tdel:3"]').click();
await settle(400);
ok("a type that nodes use cannot be deleted, and says why", (await count("#trow-3")) === 1 && (await text("#toast")).includes("is used by"), await text("#toast"));
await page.locator('#trow-5 [data-click="tdel:5"]').click();
await settle(400);
ok("an unused type is deleted", (await count("#trow-5")) === 0);
await undo();
ok("undo restores it with its fields", (await count("#trow-5")) === 1);

// ---- the XML keeps the structure; export + import loses nothing
const x2 = await xml();
ok("nested components and constraints are in the XML", x2.includes('<itemDefinition') && x2.includes('<itemComponent') && (x2.includes("allowedValues") || x2.includes("typeConstraint")) && x2.includes("tMine"));
const nameBefore = await text("#trow-1-2 .tname");
const treeBefore = await page.locator("#ttree .trow").evaluateAll((els) => els.map((e) => e.id + "|" + e.querySelector(".tname").textContent + "|" + e.querySelector(".ttype").textContent + "|" + e.querySelector(".tcons").textContent));
const [dl] = await Promise.all([
  page.waitForEvent("download"),
  (async () => {
    await page.getByRole("button", { name: /File/ }).click();
    await page.getByRole("menuitem", { name: "Export DMN" }).click();
  })(),
]);
await dl.saveAs(`${OUT}/types-export.dmn`);
const exported = fs.readFileSync(`${OUT}/types-export.dmn`, "utf8");
await page.locator("#file").setInputFiles(`${OUT}/types-export.dmn`);
await settle(1200);
await page.locator('[data-click="tab:types"]').click();
await settle();
const treeAfter = await page.locator("#ttree .trow").evaluateAll((els) => els.map((e) => e.id + "|" + e.querySelector(".tname").textContent + "|" + e.querySelector(".ttype").textContent + "|" + e.querySelector(".tcons").textContent));
ok("importing the export gives exactly the same tree (names, types, constraints)", JSON.stringify(treeAfter) === JSON.stringify(treeBefore), `${treeBefore.length} rows vs ${treeAfter.length}`);
ok("the renamed field kept its name", (await text("#trow-1-2 .tname")) === nameBefore, nameBefore);
ok("constraints survive the round trip", (await text("#trow-0-0 .tcons")) === ">= 0" && (await text("#trow-4 .tcons")).endsWith('"High", "Critical"') && (await text("#trow-2 .tcons")) === "[0..100]");
ok("the import report says nothing was dropped", (await text("#report")).includes("Nothing was lost"), (await text("#report")).slice(0, 160));
ok("no page errors", logs.length === 0, logs.join(" | "));
await page.screenshot({ path: `${OUT}/types-final.png` });

console.log(`\n${fails === 0 ? "ALL PASSED" : fails + " FAILED"}`);
await browser.close();
process.exit(fails ? 1 : 0);
