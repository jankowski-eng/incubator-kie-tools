// End-to-end check against `mix popcorn.dev` (http://localhost:4000) driven by Playwright and Chrome.
// Run: PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core OUT=/tmp node e2e/diagram-and-types.mjs
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
const center = async (sel) => {
  const b = await page.locator(sel).first().boundingBox();
  return { x: b.x + b.width / 2, y: b.y + b.height / 2 };
};

await page.goto("http://localhost:4000");
await page.waitForFunction(
  () => document.querySelector("#scene")?.children.length > 0 && document.querySelector("#panel table"),
  null,
  { timeout: 90000 }
);
ok(
  "renders 8 nodes, 10 edges, 8 handles",
  (await count("#scene g[data-id]")) === 8 && (await count("#scene line.vis")) === 10 && (await count(".handle")) === 8
);
ok("sample conforms to its types (no invalid nodes)", (await count(".node.invalid")) === 0);

// ---------- data types tab
await page.locator('[data-click="tab:types"]').click();
await settle();
ok(
  "types tab visible, editor hidden",
  (await page.locator("#view-editor").isHidden()) && (await page.locator("#view-types").isVisible())
);
ok(
  "tree shows 5 types + 7 components",
  (await count("table.types tbody tr")) === 12,
  String(await count("table.types tbody tr"))
);
ok(
  "struct has +field, scalar does not",
  (await count('[data-click="add-child:0"]')) === 1 && (await count('[data-click="add-child:2"]')) === 0
);
ok(
  "constraint kinds shown (range on tRatio)",
  (await page.locator('select[data-op=ckind][data-path="2"]').inputValue()) === "range"
);
ok("constraint is highlighted FEEL", (await count("#chl-2 .n")) >= 1 && (await text("#chl-2")) === "[0..100]");
await page.screenshot({ path: `${OUT}/t1.png` });

// tighten tRatio to [0..20] -> Front End Ratio (22.67) must become invalid
await page.locator('textarea[data-op=ctext][data-path="2"]').fill("[0..20]");
await settle(500);
await page.locator('[data-click="tab:editor"]').click();
await settle();
ok("violating value flags node invalid", (await count('.node.invalid[data-id="front"]')) === 1);
ok(
  "tooltip explains violation",
  (await text("#tt-front")).includes("violates constraint [0..20]"),
  await text("#tt-front")
);
ok("panel shows the error", (await text("#nerr-front")).includes("violates"), await text("#nerr-front"));
await page.screenshot({ path: `${OUT}/t2.png` });

// broken constraint text
await page.locator('[data-click="tab:types"]').click();
await settle();
await page.locator('textarea[data-op=ctext][data-path="2"]').fill("[0..");
await settle(500);
ok(
  "invalid constraint syntax is underlined + messaged",
  (await count("#chl-2 .err")) > 0 && (await text("#cmsg-2")).length > 0,
  await text("#cmsg-2")
);
await page.locator('textarea[data-op=ctext][data-path="2"]').fill("[0..100]");
await settle(400);

// remove constraint of tVerdict, add field to tApplicant, rename tRatio
await page.locator('select[data-op=ckind][data-path="3"]').selectOption("");
await settle(400);
ok("constraint editor disappears when kind is none", (await count('textarea[data-op=ctext][data-path="3"]')) === 0);
await page.locator('[data-click="add-child:0"]').click();
await settle(400);
ok("add field appends a component row", (await count("table.types tbody tr")) === 13);
await page.locator('input[data-op=tname][data-path="2"]').fill("tPercent");
await page.locator('input[data-op=tname][data-path="2"]').blur();
await settle(500);
await page.locator('[data-click="tab:editor"]').click();
await settle();
ok(
  "renaming a type refactors node references",
  (await page.locator("select[data-op=ntype]").inputValue()) === "tPercent",
  await page.locator("select[data-op=ntype]").inputValue()
);
ok("still valid after rename", (await count(".node.invalid")) === 0);

// ---------- palette drag-in
await page.dragAndDrop('#palette [data-kind="decision"]', "#drd", { targetPosition: { x: 120, y: 330 } });
await settle(600);
ok("drop adds a node", (await count("#scene g[data-id]")) === 9);
const newId = await page
  .locator("#scene g[data-id]")
  .evaluateAll((els) => els.map((e) => e.dataset.id).find((i) => /^n\d+$/.test(i)));
ok(
  "new node is selected and its table shown",
  (await count(`.node.sel[data-id="${newId}"]`)) === 1 &&
    (await page.locator(".nname").inputValue()) === "New decision",
  newId
);
await page.locator(".nname").fill("Risk Score");
await settle();
ok("rename updates the diagram", (await text(`#nm-${newId}`)) === "Risk Score");
await page.locator(`textarea[data-cell="${newId}:0"]`).fill("Front End Ratio * 2");
await settle(500);
ok(
  "new node expression sees nothing until connected (warning, null)",
  (await text(`#nv-${newId}`)) === "null",
  await text(`#nv-${newId}`)
);

// ---------- connect via handle
const h = await center(`[data-id="${newId}"] .handle`);
const t = await center('[data-id="loan"] .shape');
await page.mouse.move(h.x, h.y);
await page.mouse.down();
await page.mouse.move((h.x + t.x) / 2, (h.y + t.y) / 2, { steps: 5 });
ok("rubber-band preview line while dragging", (await count("#preview line")) === 1);
await page.mouse.move(t.x, t.y, { steps: 5 });
await page.mouse.up();
await settle(500);
ok("connect adds an edge", (await count("#scene line.vis")) === 11);
// give the new node a requirement so its expression can see Front End Ratio: front -> new
const f = await center('[data-id="front"] .shape');
await page.locator('[data-id="front"]').click();
await settle(300);
const fh = await center('[data-id="front"] .handle');
const nn = await center(`[data-id="${newId}"] .shape`);
await page.mouse.move(fh.x, fh.y);
await page.mouse.down();
await page.mouse.move(nn.x, nn.y, { steps: 8 });
await page.mouse.up();
await settle(500);
ok("second connection (front -> new) makes the expression evaluate", (await count("#scene line.vis")) === 12);
await page.locator(`[data-id="${newId}"]`).click({ position: { x: 20, y: 40 } });
await settle(400);
ok("dependent value appears", /^\d/.test(await text(`#nv-${newId}`)), await text(`#nv-${newId}`));

// invalid connections are rejected with a reason
const ah = await (async () => {
  await page.locator('[data-id="app"]').click();
  await settle(300);
  return center('[data-id="app"] .handle');
})();
const pr = await center('[data-id="prod"] .shape');
await page.mouse.move(ah.x, ah.y);
await page.mouse.down();
await page.mouse.move(pr.x, pr.y, { steps: 5 });
await page.mouse.up();
await settle(400);
ok(
  "input -> input rejected",
  (await text("#status")).includes("✗ input cannot be required by input") && (await count("#scene line.vis")) === 12,
  await text("#status")
);
// cycle: loan -> front would be a cycle
await page.locator('[data-id="loan"]').click();
await settle(300);
const lh = await center('[data-id="loan"] .handle');
const fr = await center('[data-id="front"] .shape');
await page.mouse.move(lh.x, lh.y);
await page.mouse.down();
await page.mouse.move(fr.x, fr.y, { steps: 5 });
await page.mouse.up();
await settle(400);
ok("cycle rejected", (await text("#status")).includes("cycle"), await text("#status"));

// ---------- delete edge, delete node
const eb = await page.locator("#scene #edge-9 line.hit").boundingBox();
await page.mouse.click(eb.x + eb.width / 2, eb.y + eb.height / 2);
await settle(300);
ok("edge selectable", (await count("#scene g.edge.sel")) === 1);
await page.keyboard.press("Delete");
await settle(500);
ok("Delete removes selected edge", (await count("#scene line.vis")) === 11);
await page.locator(`[data-id="${newId}"]`).click({ position: { x: 20, y: 40 } });
await settle(300);
await page.keyboard.press("Delete");
await settle(500);
ok(
  "Delete removes selected node and its edges",
  (await count("#scene g[data-id]")) === 8 && (await count("#scene line.vis")) === 9
);
await page.keyboard.press("Control+z");
await settle(500);
ok("undo brings the node back", (await count("#scene g[data-id]")) === 9);

// ---------- auto layout
await page.locator('[data-click="layout"]').click();
await settle(700);
const boxes = await page.locator("#scene g[data-id]").evaluateAll((els) =>
  els.map((e) => {
    const r = e.querySelector(".shape").getBoundingClientRect();
    return { id: e.dataset.id, x: r.x, y: r.y, w: r.width, h: r.height };
  })
);
let overlap = false;
for (const a of boxes)
  for (const b of boxes)
    if (a.id < b.id && a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h) overlap = true;
ok("auto-layout leaves no overlaps", !overlap);
const byId = Object.fromEntries(boxes.map((b) => [b.id, b]));
ok(
  "requirements sit below their dependents",
  byId.app.y > byId.back.y && byId.prod.y > byId.front.y && byId.back.y > byId.loan.y && byId.front.y > byId.loan.y
);
ok("edges follow the new layout", (await page.locator("#scene line.vis").first().getAttribute("x1")) !== null);
await page.screenshot({ path: `${OUT}/t3.png` });
await page.locator('[data-click="undo"]').click();
await settle(500);
const afterUndo = await center('[data-id="loan"] .shape');
ok(
  "layout is one undo step",
  Math.abs(afterUndo.x - (byId.loan.x + byId.loan.w / 2)) > 1 ||
    Math.abs(afterUndo.y - (byId.loan.y + byId.loan.h / 2)) > 1
);

// Delete/Backspace only act from the canvas: with focus on a toolbar button Backspace must not delete the selection
const nodesBefore = await count("#scene g[data-id]");
await page.locator('[data-click="layout"]').click();
await settle(400);
await page.keyboard.press("Backspace");
await settle(400);
ok("Backspace with focus on a toolbar button deletes nothing", (await count("#scene g[data-id]")) === nodesBefore);
await page.locator('#scene [data-id="loan"]').click({ force: true });
await settle(300);
await page.keyboard.press("Backspace");
await settle(400);
ok("Backspace on the canvas still deletes the selected node", (await count("#scene g[data-id]")) === nodesBefore - 1);
ok("editor listeners are installed once", await page.evaluate(() => window.__dmnEditorBound === true));

console.log(`\n${fails === 0 ? "ALL PASSED" : fails + " FAILED"}`);
console.log(logs.filter((l) => !l.startsWith("[log] popcorn")).join("\n"));
await browser.close();
