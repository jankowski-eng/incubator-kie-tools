// End-to-end check against `mix popcorn.dev` (http://localhost:4000) driven by Playwright and Chrome.
// Run: PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core OUT=/tmp node e2e/xml-inspector.mjs
// Set BIG=1 to also import a 400-node model and time the inspector on it.
import { createRequire } from "node:module";
import fs from "node:fs";
const require = createRequire(`${process.env.PLAYWRIGHT_CORE}/`);
const OUT = process.env.OUT ?? ".";
const { chromium } = require("playwright-core");
const browser = await chromium.launch({ channel: "chrome", headless: true });
const ctx = await browser.newContext({
  viewport: { width: 1400, height: 800 },
  permissions: ["clipboard-read", "clipboard-write"],
});
const page = await ctx.newPage();
const logs = [];
page.on("pageerror", (e) => logs.push(`[pageerror] ${e.message}`.slice(0, 300)));
let fails = 0;
const ok = (name, cond, extra = "") => {
  if (!cond) fails++;
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}${extra ? "  — " + extra : ""}`);
};
const settle = (ms = 650) => page.waitForTimeout(ms);
const count = (sel) => page.locator(sel).count();
const text = (sel) => page.locator(sel).first().textContent();
// the lines that carry the highlight, as text
const marked = () =>
  page.evaluate(() => [...document.querySelectorAll("#xcode .xl.xhl")].map((l) => l.querySelector(".xc").textContent));
const lineText = (n) => page.evaluate((n) => document.querySelector(`#xcode .xl[data-n="${n}"] .xc`)?.textContent, n);
const lineWithText = (needle) =>
  page.evaluate((s) => {
    const l = [...document.querySelectorAll("#xcode .xl")].find((l) => l.querySelector(".xc").textContent.includes(s));
    return l ? +l.dataset.n : 0;
  }, needle);
const clickLine = async (n) => {
  await page.locator(`#xcode .xl[data-n="${n}"] .xc`).scrollIntoViewIfNeeded();
  await page.locator(`#xcode .xl[data-n="${n}"] .xc`).click({ position: { x: 6, y: 8 } });
  await settle(500);
};
const fullText = () =>
  page.evaluate(() => [...document.querySelectorAll("#xcode .xc")].map((c) => c.textContent).join("\n") + "\n");
const undoDisabled = () => page.locator('[data-click="undo"]').isDisabled();
const open = async () => {
  await page.locator(".xmlbtn").click();
  await page.waitForFunction(() => document.querySelectorAll("#xcode .xc").length > 0);
  await settle();
};

await page.goto("http://localhost:4000");
await page.waitForFunction(() => document.querySelector("#scene")?.children.length > 0, null, { timeout: 90000 });
await page.keyboard.press("Escape");
await settle();

// ---- 1. open / close, topbar
ok(
  "the topbar has two views and an XML button, not an XML tab",
  (await count(".tabs button")) === 2 && (await count(".xmlbtn")) === 1 && (await count('[data-click="tab:xml"]')) === 0
);
ok(
  "undo and redo are icon buttons with tooltips",
  (await text('[data-click="undo"]')).trim() === "" &&
    (await page.locator('[data-click="undo"]').getAttribute("title")).includes("Z") &&
    (await page.locator('[data-click="redo"]').getAttribute("aria-label")) === "Redo"
);
ok("the inspector starts closed", await page.locator("#xmlpane").isHidden());
const undoWasDisabled = await undoDisabled();
await open();
ok(
  "the XML button opens it and shows pressed",
  (await page.locator("#xmlpane").isVisible()) &&
    (await page.locator(".xmlbtn").getAttribute("aria-pressed")) === "true"
);
ok(
  "it shows the document with line numbers",
  (await text("#xinfo")).includes("lines") &&
    (await lineText(1)).startsWith("<?xml") &&
    (await text('#xcode .xl[data-n="7"] .xn')) === "7"
);
const share = await page.evaluate(
  () =>
    document.querySelector("#xmlpane").getBoundingClientRect().width /
    document.querySelector(".page").getBoundingClientRect().width
);
ok("it takes about 40-45% of the width", share > 0.38 && share < 0.48, share.toFixed(2));
ok(
  "the diagram is still there and interactive",
  (await page.locator("#view-editor").isVisible()) && (await count("#scene g[data-id]")) === 8
);

// ---- 2. resize and expand
const grip = await page.locator(".xresize").boundingBox();
await page.mouse.move(grip.x + 4, 300);
await page.mouse.down();
await page.mouse.move(grip.x - 260, 300, { steps: 6 });
await page.mouse.up();
await settle();
const w2 = await page.evaluate(() => document.querySelector("#xmlpane").getBoundingClientRect().width);
ok("dragging the edge widens it", w2 > share * 1400 + 200, `${Math.round(w2)}px`);
await page.locator("#xexpand").click();
await settle();
ok(
  "expand gives it the whole width",
  (await page.locator("#view-editor").isHidden()) &&
    (await page.evaluate(() => Math.round(document.querySelector("#xmlpane").getBoundingClientRect().width))) >= 1390
);
await page.locator("#xexpand").click();
await settle();
ok("and back", await page.locator("#view-editor").isVisible());
await page.locator(".xmlbtn").click();
await settle();
await open();
ok(
  "the width is kept when it is closed and opened again",
  Math.abs((await page.evaluate(() => document.querySelector("#xmlpane").getBoundingClientRect().width)) - w2) < 4
);

// ---- 3. diagram -> XML
await page.locator('#scene [data-id="front"] .shape').click();
await settle(700);
let m = await marked();
ok(
  "selecting Front End Ratio highlights its <decision>",
  m[0] === '  <decision id="front" name="Front End Ratio">' && m.at(-1) === "  </decision>",
  m[0]
);
ok("the node stays selected on the diagram", (await count('#scene .node.sel[data-id="front"]')) === 1);
const visible = await page.evaluate(() => {
  const l = document.querySelector("#xcode .xl.xhl"),
    c = document.querySelector("#xcode").getBoundingClientRect(),
    r = l.getBoundingClientRect();
  return r.top >= c.top && r.bottom <= c.bottom;
});
ok("and the inspector scrolled to it", visible);
await page.locator('#scene [data-id="loan"] .shape').click();
await settle(700);
m = await marked();
ok(
  "selecting Loan Pre-Qualification highlights that decision",
  m[0] === '  <decision id="loan" name="Loan Pre-Qualification">'
);
await page.locator('#scene [data-id="dti"] .shape').click({ force: true });
await settle(700);
ok(
  "a business knowledge model finds its element",
  (await marked())[0] === '  <businessKnowledgeModel id="dti" name="Lender Acceptable DTI">'
);
await page.locator('#scene [data-id="app"] .shape').click({ force: true });
await settle(700);
ok("so does input data", (await marked())[0] === '  <inputData id="app" name="Applicant Data">');
const edge = await page.locator("#scene #edge-4 line.hit").boundingBox();
await page.mouse.click(edge.x + edge.width / 2, edge.y + edge.height / 2);
await settle(700);
m = await marked();
ok(
  "a requirement arrow finds its <informationRequirement>",
  m[0].includes("<informationRequirement") && m.length === 3,
  m[0]
);

// ---- 4. XML -> diagram
const frontVar = await lineWithText('<variable id="front-var"');
const before = await page.evaluate(() => document.querySelector("#xcode").scrollTop);
await clickLine(frontVar);
ok("clicking inside the decision selects its node", (await count('#scene .node.sel[data-id="front"]')) === 1);
ok(
  "with the same selection style as the editor",
  await page
    .locator('#scene .node.sel[data-id="front"] .shape')
    .evaluate((e) => parseFloat(getComputedStyle(e).strokeWidth) > 2)
);
ok(
  "and the panel below shows it",
  (await text("#panel .nodehead input.nname")) !== null &&
    (await page.locator("input[data-op=nname]").inputValue()) === "Front End Ratio"
);
ok(
  "the code is not scrolled under the reader",
  (await page.evaluate(() => document.querySelector("#xcode").scrollTop)) === before ||
    Math.abs((await page.evaluate(() => document.querySelector("#xcode").scrollTop)) - before) < 2
);
const textLine = await lineWithText("<text>Applicant Data.Tax</text>");
await clickLine(textLine);
ok("a <text> deep inside still belongs to the decision", (await count('#scene .node.sel[data-id="front"]')) === 1);
await clickLine(await lineWithText('<decision id="back"'));
ok(
  "another decision selects another node",
  (await count('#scene .node.sel[data-id="back"]')) === 1 && (await count("#scene .node.sel")) === 1
);
await clickLine(await lineWithText('<informationRequirement id="_req-app-front"'));
ok("a requirement in the code selects that arrow", (await count("#scene g.edge.sel")) === 1);
await clickLine(1);
ok("a line outside every element changes nothing", (await count("#scene g.edge.sel")) === 1);
ok("none of this entered the undo history", (await undoDisabled()) === undoWasDisabled);

// ---- 5/6. Data types <-> XML
await page.locator('[data-click="tab:types"]').click();
await settle(500);
await page.locator("#trow-0-1").click();
await settle(700);
m = await marked();
ok("a selected field finds its <itemComponent>", m[0] === '    <itemComponent id="_t0-1" name="Tax">', m[0]);
await page.locator("#trow-1").click();
await settle(700);
m = await marked();
ok(
  "a selected type finds its <itemDefinition>",
  m[0] === '  <itemDefinition id="_t1" name="tRequested">' && m.at(-1) === "  </itemDefinition>"
);
await clickLine(await lineWithText('<itemComponent id="_t1-2" name="Term">'));
ok(
  "clicking an <itemComponent> selects the field in Data types",
  (await count("#trow-1-2.sel")) === 1 && (await page.locator("#view-types").isVisible())
);
ok("the inspector stayed open when the view changed", await page.locator("#xmlpane").isVisible());
await page.locator('[data-click="tab:editor"]').click();
await settle(500);
await clickLine(await lineWithText('<itemDefinition id="_t3"'));
ok(
  "selecting a type from the editor view switches to Data types",
  (await count("#trow-3.sel")) === 1 && (await page.locator("#view-types").isVisible())
);
await clickLine(await lineWithText('<inputData id="app"'));
ok(
  "and a node switches back to the editor",
  (await page.locator("#view-editor").isVisible()) && (await count('#scene .node.sel[data-id="app"]')) === 1
);

// ---- 7. rename keeps the link
await page.locator('#scene [data-id="risk"] .shape').click();
await settle(600);
await page.locator("input[data-op=nname]").fill("Risk Level");
await settle(900);
m = await marked();
ok("after a rename the highlight follows the element", m[0] === '  <decision id="risk" name="Risk Level">', m[0]);
await clickLine(await lineWithText('<decision id="risk"'));
ok("and a click still reaches it", (await count('#scene .node.sel[data-id="risk"]')) === 1);

// ---- 8. the document follows the model
const lines0 = Number((await text("#xinfo")).split(" ")[0]);
await page
  .locator('#palette [data-kind="decision"]')
  .dragTo(page.locator("#drd"), { targetPosition: { x: 120, y: 300 } });
await settle(900);
const lines1 = Number((await text("#xinfo")).split(" ")[0]);
ok("adding a node adds its lines", lines1 > lines0 + 5, `${lines0} -> ${lines1}`);
m = await marked();
ok(
  "and the new node is the highlighted one",
  m[0].startsWith("  <decision id=") && m[0].includes("New decision"),
  m[0]
);

// ---- 9. undo / redo
await page.locator('[data-click="undo"]').click();
await settle(900);
ok("undo removes the node from the code", Number((await text("#xinfo")).split(" ")[0]) === lines0);
ok(
  "the highlight is not left on a node that is gone",
  (await marked()).every((l) => !l.includes("New decision"))
);
await page.locator('#scene [data-id="front"] .shape').click();
await settle(600);
await page.locator("textarea[data-cell]").first().fill("1 + 1");
await settle(900);
ok("editing a cell shows in the code", (await fullText()).includes("<text>1 + 1</text>"));
await page.locator('[data-click="undo"]').click();
await settle(900);
ok("undo brings the old text back", !(await fullText()).includes("<text>1 + 1</text>"));
const sel = await marked();
ok(
  "the selection and its range are still right after undo",
  sel[0] === '  <decision id="front" name="Front End Ratio">' && sel.at(-1) === "  </decision>"
);
await page.locator('[data-click="redo"]').click();
await settle(900);
ok("redo changes the code again", (await fullText()).includes("<text>1 + 1</text>"));
await page.locator('[data-click="undo"]').click();
await settle(600);

// ---- 10. views with the inspector open
await page.locator('[data-click="tab:types"]').click();
await settle(500);
ok(
  "Data types works with the inspector open",
  (await page.locator("#xmlpane").isVisible()) && (await page.locator("#view-types").isVisible())
);
await page.locator('[data-click="tab:editor"]').click();
await settle(500);

// ---- folding, find, wrap, copy
const defs = await lineWithText("<definitions");
const n0 = await count("#xcode .xl:not([hidden])");
await page.locator(`#xcode .xl[data-n="${defs}"] .xg`).click();
await settle(300);
ok("folding the root hides everything inside it", (await count("#xcode .xl:not([hidden])")) < 5 && n0 > 100);
await page.locator(`#xcode .xl[data-n="${defs}"] .xg`).click();
await settle(300);
ok("and unfolding brings it back", (await count("#xcode .xl:not([hidden])")) === n0);
// the fold control is a real button: reachable by keyboard, named, and it says whether it is open
const fold = page.locator(`#xcode .xl[data-n="${defs}"] .xg`);
ok(
  "the fold control is a button with a name and an expanded state",
  (await fold.evaluate((el) => el.tagName)) === "BUTTON" &&
    (await fold.getAttribute("aria-expanded")) === "true" &&
    /^Fold lines/.test(await fold.getAttribute("aria-label"))
);
await fold.focus();
await page.keyboard.press("Enter");
await settle(300);
ok(
  "Enter folds it and the state follows",
  (await count("#xcode .xl:not([hidden])")) < 5 &&
    (await fold.getAttribute("aria-expanded")) === "false" &&
    /^Unfold lines/.test(await fold.getAttribute("aria-label"))
);
await page.keyboard.press("Space");
await settle(300);
ok(
  "Space opens it again",
  (await count("#xcode .xl:not([hidden])")) === n0 && (await fold.getAttribute("aria-expanded")) === "true"
);
await page.locator("#xsearch").fill("decisionTable");
await settle(400);
ok(
  "find counts the matches",
  /^\d+ \/ \d+$/.test(await text("#xcount")) || /^\d+$/.test(await text("#xcount")),
  await text("#xcount")
);
await page.locator("#xsearch").press("Enter");
await settle(300);
ok("Enter goes to the next one", /^\d+ \/ \d+$/.test(await text("#xcount")));
await page.locator("#xsearch").fill("");
await page.locator("#xwrap").click();
ok(
  "word wrap toggles",
  (await page.locator("#xcode").evaluate((e) => e.classList.contains("wrap"))) &&
    (await page.locator("#xwrap").getAttribute("aria-pressed")) === "true"
);
await page.locator("#xwrap").click();
await page.locator("#xcopy").click();
await settle(300);
ok(
  "Copy puts the whole document on the clipboard",
  (await page.evaluate(() => navigator.clipboard.readText())) === (await fullText())
);
ok(
  "the code is read only: no editable fields in the panel",
  (await count("#xcode textarea, #xcode input, #xcode [contenteditable]")) === 0
);

// ---- 11. light and dark
const tagColor = () =>
  page
    .locator("#xcode .xt")
    .first()
    .evaluate((e) => getComputedStyle(e).color);
await page.emulateMedia({ colorScheme: "light" });
await page.evaluate(() => {
  document.documentElement.dataset.theme = "light";
});
const light = await tagColor();
await page.screenshot({ path: `${OUT}/xml-light.png` });
await page.evaluate(() => {
  document.documentElement.dataset.theme = "dark";
});
const dark = await tagColor();
await page.screenshot({ path: `${OUT}/xml-dark.png` });
ok("the code has its own colours in light and dark", light !== dark, `${light} / ${dark}`);
await page.evaluate(() => {
  delete document.documentElement.dataset.theme;
});

// ---- exported file equals what the inspector shows
const [dl] = await Promise.all([
  page.waitForEvent("download"),
  (async () => {
    await page.getByRole("button", { name: /File/ }).click();
    await page.getByRole("menuitem", { name: "Export DMN" }).click();
  })(),
]);
await dl.saveAs(`${OUT}/inspector-export.dmn`);
await settle(300);
ok(
  "the download is exactly what the inspector shows",
  fs.readFileSync(`${OUT}/inspector-export.dmn`, "utf8") === (await fullText())
);

await page.locator(".xmlbtn").click();
await settle();
ok("it closes", await page.locator("#xmlpane").isHidden());
await page.locator('#scene [data-id="loan"] .shape').click();
await settle(500);
await page.locator(".xmlbtn").click();
await settle(900);
ok(
  "opened later it is already on the current selection",
  (await marked())[0] === '  <decision id="loan" name="Loan Pre-Qualification">'
);

// ---- 12. a big model
if (process.env.BIG) {
  await page.locator(".xmlbtn").click();
  await settle();
  const big = `${OUT}/big.dmn`;
  if (!fs.existsSync(big)) throw new Error(`run scale.mjs first so ${big} exists`);
  await page.locator("#file").setInputFiles(big);
  await page.waitForFunction(() => document.querySelectorAll("#scene g[data-id]").length >= 400, null, {
    timeout: 180000,
  });
  const t0 = Date.now();
  await page.locator(".xmlbtn").click();
  await page.waitForFunction(() => document.querySelectorAll("#xcode .xc").length > 1000, null, { timeout: 60000 });
  const openMs = Date.now() - t0;
  const nlines = Number((await text("#xinfo")).split(" ")[0]);
  console.log(`INFO  400 nodes: ${nlines} lines, inspector open in ${openMs} ms`);
  ok("the inspector opens on a big model in reasonable time", openMs < 8000, `${openMs} ms`);
  const t1 = Date.now();
  await page.locator('#scene [data-id="n350"] .shape').click({ force: true });
  await page.waitForFunction(() => document.querySelector("#xcode .xl.xhl"), null, { timeout: 30000 });
  console.log(`INFO  select a node -> code highlighted: ${Date.now() - t1} ms`);
  // in a dense diagram the click may land on a neighbour: what matters is that the code shows the node that got selected
  const picked = await page.locator("#scene .node.sel").first().getAttribute("data-id");
  ok(
    "selecting still finds the right element",
    (await marked())[0].includes(`id="${picked}"`),
    `${picked}: ${(await marked())[0]}`
  );
  const t2 = Date.now();
  await clickLine(await lineWithText('<decision id="n120"'));
  ok("and clicking the code selects the node", (await count('#scene .node.sel[data-id="n120"]')) === 1);
  console.log(`INFO  click in the code -> node selected: ${Date.now() - t2 - 500} ms`);
}

ok("no page errors", logs.length === 0, logs.join(" | "));
console.log(`\n${fails === 0 ? "ALL PASSED" : fails + " FAILED"}`);
await browser.close();
process.exit(fails ? 1 : 0);
