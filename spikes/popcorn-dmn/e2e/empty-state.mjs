// End-to-end check against `mix popcorn.dev` (http://localhost:4000) driven by Playwright and Chrome.
// Run: PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core OUT=/tmp node e2e/empty-state.mjs
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
const settle = (ms = 650) => page.waitForTimeout(ms);
const count = (sel) => page.locator(sel).count();
const text = (sel) => page.locator(sel).first().textContent();
const newDmn = async () => {
  await page.getByRole("button", { name: /File/ }).click();
  await page.getByRole("menuitem", { name: "New DMN" }).click();
  await settle(600);
};

await page.goto("http://localhost:4000");
await page.waitForFunction(() => document.querySelector("#scene")?.children.length > 0, null, { timeout: 90000 });
await page.keyboard.press("Escape");
await settle();

ok("there is no 'Popcorn spike' chip in the topbar", (await count("#docname")) === 0 && !(await text(".topbar")).includes("Popcorn spike"));
ok("with nodes on the canvas there is no card", await page.locator("#empty").isHidden());

// ---- New DMN
await newDmn();
ok("New DMN empties the diagram", (await count("#scene g[data-id]")) === 0 && (await count("#scene line.vis")) === 0);
ok("and shows the welcome card", await page.locator("#empty").isVisible());
ok("with the same wording and starters as KIE", (await text("#empty h2")) === "This DMN's diagram is empty" && (await text("#empty")).includes("Start by dragging nodes from the Palette".replace("Palette", "palette")) && (await page.locator("#empty .starter").allTextContents()).map((t) => t.trim()).join("|") === "New decision table…|New decision…|New input data…");
const card = await page.locator(".emptycard").boundingBox();
const stage = await page.locator(".stage").boundingBox();
ok("the card is in the middle of the canvas", Math.abs(card.x + card.width / 2 - (stage.x + stage.width / 2)) < 90 && Math.abs(card.y + card.height / 2 - (stage.y + stage.height / 2)) < 60, `${Math.round(card.x + card.width / 2)},${Math.round(card.y + card.height / 2)} vs ${Math.round(stage.x + stage.width / 2)},${Math.round(stage.y + stage.height / 2)}`);
ok("it does not cover the palette or the zoom controls", await page.evaluate(() => { const c = document.querySelector(".emptycard").getBoundingClientRect(), p = document.querySelector("#palette").getBoundingClientRect(), z = document.querySelector(".zoomctl").getBoundingClientRect(); const hit = (a, b) => !(a.right < b.left || a.left > b.right || a.bottom < b.top || a.top > b.bottom); return !hit(c, p) && !hit(c, z); }));
ok("nothing is selected and the panel is empty", (await count("#scene .node.sel")) === 0 && (await page.locator("#panel").innerText()).trim() === "");
ok("the toast tells how to go back", (await text("#toast")).includes("Undo"));
ok("Undo is now available", await page.locator('[data-click="undo"]').isEnabled());
await page.locator('[data-click="undo"]').click();
await settle(700);
ok("Undo brings the previous model back, card gone", (await count("#scene g[data-id]")) === 8 && (await page.locator("#empty").isHidden()));
await page.locator('[data-click="redo"]').click();
await settle(700);
ok("Redo empties it again and the card returns", (await count("#scene g[data-id]")) === 0 && (await page.locator("#empty").isVisible()));

// the empty model works in the other views
await page.locator('[data-click="tab:types"]').click();
await settle();
ok("Data types shows no types", (await text("#ttree")).includes("No data types yet"));
await page.locator('[data-click="tab:editor"]').click();
await settle();
await page.locator(".xmlbtn").click();
await settle(600);
ok("the XML inspector shows an empty document", (await text("#xinfo")).includes("lines") && (await page.evaluate(() => [...document.querySelectorAll("#xcode .xc")].map((c) => c.textContent).join("\n"))).includes('name="Untitled"'));
await page.locator(".xmlbtn").click();
await settle();

// ---- dismiss, and it comes back with the next empty diagram
await page.locator('[data-click="empty-dismiss"]').click();
await settle();
ok("the card can be dismissed", await page.locator("#empty").isHidden());
ok("the canvas stays empty", (await count("#scene g[data-id]")) === 0);

// ---- dragging from the palette still works, also over where the card was
await newDmn();
ok("a new DMN brings the card back", await page.locator("#empty").isVisible());
await page.locator('#palette [data-kind="decision"]').dragTo(page.locator(".emptycard"));
await settle(600);
ok("dropping a palette item on the card adds the node", (await count("#scene g[data-id]")) === 1);
ok("and the card is gone", await page.locator("#empty").isHidden());

// ---- starters
await newDmn();
await page.locator('[data-click="empty-add:table"]').click();
await settle(700);
ok("'New decision table' makes a decision with a table", (await count("#scene g[data-id]")) === 1 && (await count("table.dt")) === 1 && (await count("#scene .node.sel")) === 1);
const nb = await page.locator("#scene .node .shape").boundingBox();
ok("in the middle of the canvas", Math.abs(nb.x + nb.width / 2 - (stage.x + stage.width / 2)) < 30 && Math.abs(nb.y + nb.height / 2 - (stage.y + stage.height / 2)) < 30, `${Math.round(nb.x + nb.width / 2)},${Math.round(nb.y + nb.height / 2)} vs ${Math.round(stage.x + stage.width / 2)},${Math.round(stage.y + stage.height / 2)}`);
ok("the card goes away once there is a node", await page.locator("#empty").isHidden());
await newDmn();
await page.locator('[data-click="empty-add:input"]').click();
await settle(600);
ok("'New input data' makes an input node", (await count("#scene .shape.input")) === 1);
await newDmn();
await page.locator('[data-click="empty-add:decision"]').click();
await settle(600);
ok("'New decision' makes a decision", (await count("#scene .shape.decision")) === 1);

// ---- deleting everything shows the card again
await newDmn();
await page.locator('[data-click="empty-add:decision"]').click();
await settle(500);
await page.keyboard.press("Escape");
await page.locator('#scene .node .shape').click();
await page.keyboard.press("Delete");
await settle(500);
ok("deleting the last node shows the card again", await page.locator("#empty").isVisible());

// ---- export of a blank DMN is a valid empty document
const [dl] = await Promise.all([
  page.waitForEvent("download"),
  (async () => { await page.getByRole("button", { name: /File/ }).click(); await page.getByRole("menuitem", { name: "Export DMN" }).click(); })(),
]);
await dl.saveAs(`${OUT}/blank.dmn`);
const xml = fs.readFileSync(`${OUT}/blank.dmn`, "utf8");
ok("the blank DMN exports as an empty definitions element", xml.includes('name="Untitled"') && !xml.includes("<decision") && dl.suggestedFilename() === "Untitled.dmn", dl.suggestedFilename());
await page.screenshot({ path: `${OUT}/empty.png` });

ok("no page errors", logs.length === 0, logs.join(" | "));
console.log(`\n${fails === 0 ? "ALL PASSED" : fails + " FAILED"}`);
await browser.close();
process.exit(fails ? 1 : 0);
